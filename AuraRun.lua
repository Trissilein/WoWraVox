local _, ns = ...

-- One state machine per aura run: decides whether an aura end ("expire") or a timeline node is announced.
-- Sources (Cooldown Manager, readable aura, saved time, cast) only report events; output happens only on a state
-- change, at most once per (run, key). Pure Lua: no WoW API besides the optional issecretvalue guard.
--
-- api = { now(), schedule(delay, fn) -> handle, cancel(handle), emit(rule, spellID, key, info), trace(entry),
--         allowEstimates(), probe(rule, spellID) }   (trace, allowEstimates and probe are optional)
-- mgr:Event(rule, track, source, payload) -> decision string
--   rule = { id, oneEffect, endOnEarlyRemoval? }; track = TrackID of the seen spell (one run per rule for oneEffect)
--   source = "CDM" | "AURA" | "SAVED" | "CAST" | "MARKER" | "RESET"
--   payload = { kind = "start"|"timing"|"remove"|"cast"|"marker", spellID, instanceID, expiration, remaining,
--               duration, setAt, quality, key, event }   event = the caller's source name, passed to emit and trace
-- Time quality (lower wins, never overwritten by a worse one in a run): 1 CDM, 2 readable aura, 3 saved, 4 estimate.
local AuraRun = { REPLACE_WINDOW = 0.5, NATURAL_TOLERANCE = 1.5, EXACT_EARLY = 0.25, CAST_GRACE = 1.0, REFRESH_JUMP = 0.5,
    STALE_WINDOW = 3, STALE_GRACE = 1.0, CAST_AFTER_AURA = 0.3 }
ns.AuraRun = AuraRun

local QUALITY = { CDM = 1, AURA = 2, SAVED = 3, CAST = 4 }

local function finite(value)
    if type(value) ~= "number" then return false end
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then return false end
    end
    return value == value and value ~= math.huge and value ~= -math.huge
end

local function public(value)
    if value == nil or type(value) == "number" and not finite(value) then return nil end
    return value
end

function AuraRun.Create(api)
    local runs, dead, counter = {}, {}, 0 -- dead[key][instanceID] = time the instance ended (per rule and track)
    local mgr = {}

    local function bury(key, instance, now)
        if instance == nil then return end
        local graves = dead[key] or { n = 0 }
        dead[key], graves[instance], graves.n = graves, now, graves.n + 1
        if graves.n > 50 then
            for id, at in pairs(graves) do
                if id ~= "n" and now - at >= AuraRun.STALE_WINDOW then graves[id], graves.n = nil, graves.n - 1 end
            end
        end
    end
    local function buried(key, instance, now)
        local at = instance ~= nil and dead[key] and dead[key][instance]
        return at and now - at < AuraRun.STALE_WINDOW
    end

    local function keyOf(rule, track)
        return tostring(rule.id or rule) .. "|" .. tostring(rule.oneEffect and "*" or track)
    end

    -- Timer slots: holder[field] = { handle }; a newer call or clear() voids the old callback, even one that fires
    -- synchronously inside schedule().
    local function clear(holder, field)
        local slot = holder[field]
        holder[field] = nil
        if slot and slot.handle then api.cancel(slot.handle) end
    end
    local function later(holder, field, delay, fn)
        clear(holder, field)
        local slot = {}
        holder[field] = slot
        local handle = api.schedule(math.max(0, delay), function()
            if holder[field] ~= slot then return end
            holder[field] = nil
            fn()
        end)
        if holder[field] == slot then slot.handle = handle end
    end

    local function trace(run, rule, payload, source, key, decision)
        if not api.trace then return end
        api.trace({ t = api.now(), rule = rule, source = payload.event or source, spellID = payload.spellID,
            key = key, runID = run and run.id, decision = decision, expected = run and run.expected,
            estimated = run and (run.quality or 4) >= 3, firstEnd = run and run.firstEndAt })
    end

    local function stopTimers(run)
        clear(run, "pending")
        clear(run, "estimate")
        for _, member in pairs(run.members) do clear(member, "due") end
    end

    -- A readable aura's end is checked once at its exact time (UNIT_AURA normally reports it first).
    local function arm(run, spellID, member)
        clear(member, "due")
        if not (api.probe and member.quality == 2 and member.expected) then return end
        local target = member.expected
        later(member, "due", target - api.now(), function()
            if run.members[spellID] ~= member or api.now() < target - 0.001 then return end
            api.probe(run.rule, spellID)
            -- Still there after the re-read: unreadable now (secret in combat, no Cooldown Manager frame). Its exact
            -- end stands in for the removal that cannot be seen, after the replacement window.
            if run.state ~= "active" or run.members[spellID] ~= member or member.expected ~= target then return end
            later(member, "due", AuraRun.REPLACE_WINDOW, function()
                if run.state ~= "active" or run.members[spellID] ~= member or member.expected ~= target then return end
                mgr:Event(run.rule, member.track, "AURA", { kind = "remove", spellID = spellID,
                    instanceID = member.instance, event = "AURA_DEADLINE" })
            end)
        end)
    end

    -- A member with an end time, or one a Cooldown Manager frame reports (its removal will be seen), is an end source.
    local function timed(run)
        for _, member in pairs(run.members) do if member.expected or member.cdm then return true end end
        return false
    end

    -- Last resort (quality 4): a cast whose run has no end source ends at cast + learned duration, if allowed (a member
    -- without either, e.g. a secret aura without a Cooldown Manager frame, cannot report its end).
    local function armEstimate(run, payload)
        clear(run, "estimate")
        if not run.castExpected or timed(run) then return end
        local target = run.castExpected
        later(run, "estimate", target - api.now(), function()
            if run.state ~= "active" or timed(run) or run.sourced or api.now() < target - 0.001 then return end
            if not (api.allowEstimates and api.allowEstimates()) then
                trace(run, run.rule, payload, "CAST", "expire", "suppressed:estimate-off")
                return
            end
            run.expected, run.quality = target, 4
            run.firstEndAt = api.now()
            mgr.finish(run, "estimated", payload.spellID, { spellID = payload.spellID, event = "ESTIMATE" }, "CAST")
        end)
    end

    local function open(key, rule, track, carry)
        counter = counter + 1
        local run = { id = counter, key = key, state = "active", members = {}, emitted = {}, rule = rule, track = track }
        runs[key] = run
        if carry then
            for spellID, member in pairs(carry.members) do
                run.members[spellID] = { instance = member.instance, expected = member.expected, quality = member.quality,
                    track = member.track, preCast = member.preCast, since = member.since, seenAt = member.seenAt, cdm = member.cdm }
                arm(run, spellID, run.members[spellID])
            end
            run.castExpected, run.lastCast = carry.castExpected, carry.lastCast
        end
        return run
    end

    -- Final state. how: natural | consumed | unknown | estimated (announced), silent | replaced (not announced).
    function mgr.finish(run, how, spellID, payload, source)
        stopTimers(run)
        run.state, run.how, run.endedAt = how == "replaced" and "replaced" or "ended", how, api.now()
        if how == "replaced" or how == "silent" or run.emitted.expire then
            -- Traced only when an end was in question (a removal came); a plain recast or new instance is no candidate.
            if run.firstEndAt then
                trace(run, run.rule, payload, source, "expire", "suppressed:" .. (run.emitted.expire and "run" or how))
            end
            return "suppressed"
        end
        run.emitted.expire = true
        trace(run, run.rule, payload, source, "expire", "emit")
        api.emit(run.rule, spellID, "expire", { how = how, estimated = how == "estimated",
            event = payload.event or source, runID = run.id })
        return "emit"
    end

    local function expectedFrom(payload, now)
        if finite(payload.expiration) and payload.expiration > 0 then return payload.expiration, true end
        if finite(payload.remaining) and payload.remaining >= 0 then return now + payload.remaining, true end
        if finite(payload.duration) and payload.duration > 0 and finite(payload.setAt) then
            return payload.setAt + payload.duration, false
        end
    end

    local function start(run, key, rule, track, source, payload, now)
        local spellID, instance = payload.spellID or track, public(payload.instanceID)
        local expected, exact = expectedFrom(payload, now)
        local live, kind = run and run.state == "active", payload.kind
        if kind == "timing" and not live then return "ignored" end
        -- An ended instance, or a frame without an instance right after an end, lights once more: no new run.
        if buried(key, instance, now)
            or instance == nil and run and run.state == "ended" and now - run.endedAt < AuraRun.STALE_WINDOW then
            trace(run, rule, payload, source, "start", "suppressed:stale")
            return "stale"
        end
        local member, decision = live and run.members[spellID], "start"
        if not live then
            -- Lit again while a removal waited for its replacement: a refresh or a switch, no end.
            if run and run.state == "pending" then
                mgr.finish(run, "replaced", spellID, payload, source)
                decision = "refresh"
            end
            run = open(key, rule, track)
        elseif member and instance ~= nil and member.instance ~= nil and member.instance ~= instance then
            -- Same spell, new aura instance: a new run; the old instance is gone for good.
            bury(key, member.instance, now)
            mgr.finish(run, "replaced", spellID, payload, source)
            run = open(key, rule, track, run)
            run.castExpected, decision = nil, "refresh"
            clear(run.members[spellID], "due")
            run.members[spellID].expected, run.members[spellID].quality, run.members[spellID].preCast = nil, nil, nil
        elseif member and exact and member.expected and (member.quality or 4) <= 2
            and expected > member.expected + AuraRun.REFRESH_JUMP then
            -- Same instance, end moved later: refreshed, a new run.
            mgr.finish(run, "replaced", spellID, payload, source)
            run = open(key, rule, track, run)
            decision = "refresh"
        end
        member = run.members[spellID]
        if not member then
            if kind == "timing" then return "ignored" end
            member = { track = track }
            run.members[spellID] = member
        end
        if instance ~= nil and member.instance ~= instance then member.instance, member.since = instance, now end
        if source == "CDM" then member.cdm = true end
        local quality = payload.quality or QUALITY[source] or 4
        -- A start time read at first sight only (setAt) never moves an end already known for this instance.
        if expected and (exact or not member.expected)
            and (not member.expected or not member.quality or quality <= member.quality) then
            member.seenAt = now
            if member.expected ~= expected then
                member.expected, member.quality = expected, quality
                arm(run, spellID, member)
            end
            run.expected, run.quality = expected, quality
        end
        if timed(run) then clear(run, "estimate") end
        return decision
    end

    local function remove(run, rule, source, payload, now)
        local spellID, instance = payload.spellID, public(payload.instanceID)
        if not run then return "ignored" end
        if run.state ~= "active" then
            trace(run, rule, payload, source, "expire", "suppressed:" .. run.state)
            return "ignored"
        end
        local member = run.members[spellID]
        if not member or instance ~= nil and member.instance ~= nil and member.instance ~= instance
            or instance == nil and member.instance ~= nil and now - member.since < AuraRun.STALE_GRACE then
            run.sourced = true
            trace(run, rule, payload, source, "expire", "suppressed:stale")
            return "stale"
        end
        clear(member, "due")
        run.members[spellID] = nil
        bury(run.key, member.instance, now)
        if next(run.members) then
            trace(run, rule, payload, source, "expire", "suppressed:members")
            return "member"
        end
        run.firstEndAt = now
        local expected = member.expected or run.castExpected
        run.expected, run.quality = expected, member.expected and member.quality or expected and 4 or nil
        if member.preCast and now - run.lastCast <= AuraRun.CAST_GRACE then
            return mgr.finish(run, "replaced", spellID, payload, source)
        end
        -- An exact end (Cooldown Manager: live set time + duration or remaining time; readable aura) is never more than
        -- a moment early: a removal 1 s before it is a seal switch or use, not the natural end.
        local before = (run.quality or 4) <= 2 and AuraRun.EXACT_EARLY or AuraRun.NATURAL_TOLERANCE
        if expected and now >= expected - before and now - expected <= AuraRun.NATURAL_TOLERANCE then
            return mgr.finish(run, "natural", spellID, payload, source)
        end
        -- Early (or no usable end time): wait W for a replacement (seal switch, refresh) before deciding. A guessed end
        -- (cast + learned duration) cannot tell early from natural: such a removal ends as unknown.
        local early = expected ~= nil and now < expected and run.quality ~= 4
        run.state = "pending"
        later(run, "pending", AuraRun.REPLACE_WINDOW, function()
            if run.state ~= "pending" then return end
            local consume = rule.endOnEarlyRemoval
            if consume == nil then consume = rule.oneEffect == true end
            mgr.finish(run, not early and "unknown" or consume and "consumed" or "silent", spellID, payload, source)
        end)
        return "pending"
    end

    function mgr:Event(rule, track, source, payload)
        if source == "RESET" then return self:Reset() end
        if type(rule) ~= "table" or type(payload) ~= "table" then return nil end
        local key, now, kind = keyOf(rule, track), api.now(), payload.kind
        local run = runs[key]
        if kind == "marker" then
            local markerKey = payload.key
            if not run or run.state ~= "active" or run.emitted[markerKey] then
                trace(run, rule, payload, source, markerKey, "suppressed:" .. (not run and "idle"
                    or run.state ~= "active" and run.state or "run"))
                return "drop"
            end
            run.emitted[markerKey] = true
            trace(run, rule, payload, source, markerKey, "emit")
            api.emit(rule, payload.spellID or track, markerKey, { event = payload.event or source, runID = run.id })
            return "emit"
        elseif kind == "cast" then
            local carry = run and run.state == "active" and run or nil
            if run and (run.state == "active" or run.state == "pending") then
                mgr.finish(run, "replaced", payload.spellID or track, payload, source)
            end
            run = open(key, rule, track, carry)
            run.lastCast = now
            payload.setAt = payload.setAt or now
            run.castExpected = expectedFrom(payload, now)
            -- A recast restarts the aura: the old end time no longer holds; any source may set the new one. In a
            -- one-effect rule the cast replaces the other triggers (one seal at a time).
            for spellID, member in pairs(run.members) do
                member.preCast = true
                if rule.oneEffect and member.track ~= track then
                    clear(member, "due")
                    run.members[spellID] = nil
                    bury(key, member.instance, now)
                elseif not (member.seenAt and now - member.seenAt <= AuraRun.CAST_AFTER_AURA) then
                    member.expected, member.quality = nil, nil
                    clear(member, "due")
                end
            end
            if not timed(run) then run.expected, run.quality = run.castExpected, run.castExpected and 4 or nil end
            armEstimate(run, payload)
            return "start"
        elseif kind == "start" or kind == "timing" then
            return start(run, key, rule, track, source, payload, now)
        elseif kind == "remove" then
            payload.spellID = payload.spellID or track
            return remove(run, rule, source, payload, now)
        end
        return nil
    end

    function mgr:Get(rule, track)
        if type(rule) ~= "table" then return nil end
        return runs[keyOf(rule, track)]
    end

    function mgr:Reset()
        for _, run in pairs(runs) do stopTimers(run) end
        runs, dead = {}, {}
        return "reset"
    end

    return mgr
end
