local _, ns = ...

-- Fires the intermediate timeline markers (Markers.lua) of a running effect. Endpoints are not handled here:
-- 0 % is the start event itself and 100 % the real end event (aura removed / ready again).
--
-- api = { now(), schedule(delay, fn) -> handle, cancel(handle), emit(ruleID, spellID, markerKey, info) }
-- Update(ruleID, spellID, info): info = { active, start, duration, expiration, estimated, markers, baseline }
--   start: time the effect began (GetTime scale); duration: seconds (readable, overridden or learned);
--   expiration: exact end time when Blizzard exposes one;
--   estimated: true when the duration is a learned/overridden guess, passed through to emit;
--   baseline: true for a state found at login/reload; markers already in the past are skipped, never replayed.
local MarkerTimers = {}
ns.MarkerTimers = MarkerTimers

local function finite(value)
    if type(value) ~= "number" then return false end
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then return false end
    end
    return value == value and value ~= math.huge and value ~= -math.huge
end

function MarkerTimers.Create(api)
    local runs = {}       -- "<ruleID>|<spellID>" -> { start, duration, timers = { key -> handle }, generation }
    local generation = 0
    local manager = {}

    local function stop(run)
        if not run then return end
        for _, handle in pairs(run.timers) do api.cancel(handle) end
        run.timers = {}
        generation = generation + 1
        run.generation = generation
    end

    function manager:Update(ruleID, spellID, info)
        if ruleID == nil or not finite(spellID) or type(info) ~= "table" then return nil end
        local id = tostring(ruleID) .. "|" .. tostring(spellID)
        local run = runs[id]
        if not info.active then
            stop(run)
            runs[id] = nil
            return nil
        end
        local start, duration = info.start, info.duration
        if not finite(start) then return run end
        if not (finite(duration) and duration > 0) then duration = nil end
        local expiration = finite(info.expiration) and info.expiration > 0 and info.expiration or nil
        -- Same window (same start and duration within a frame): nothing to do.
        local sameWindow = run and math.abs(run.start - start) < 0.05
            and (run.duration or -1) == (duration or -1) and run.signature == info.signature
        if sameWindow then
            -- If this update cannot read end time, keep last exact value for this same run.
            if not expiration then expiration = run.expiration end
            local sameExpiration = (not expiration and not run.expiration)
                or (expiration and run.expiration and math.abs(expiration - run.expiration) < 0.05)
            if sameExpiration then
                -- A guess confirmed by a real reading (or the other way round): same timers, new label.
                run.estimated, run.info = info.estimated == true, info
                return run
            end
        end
        stop(run)
        generation = generation + 1
        run = { start = start, duration = duration, expiration = expiration, timers = {}, generation = generation, signature = info.signature,
            estimated = info.estimated == true, info = info }
        runs[id] = run
        local now = api.now()
        local Markers = ns.Markers
        for _, marker in ipairs(info.markers or {}) do
            if not Markers.IsEndpoint(marker.key) then
                -- Use Blizzard's exact end directly for seconds-before-end nodes, even without a duration.
                local exactEndNode = marker.anchor == "end" and marker.offset and expiration
                local offset = exactEndNode and marker.offset or Markers.Seconds(marker, duration)
                local fireAt = exactEndNode and expiration - offset or offset and start + offset
                -- Nothing at or after the end: the real end event owns 100 %. Without a known duration a
                -- start-anchored node simply fires; if the effect is gone by then, the run was stopped already.
                local beforeEnd = expiration and fireAt and fireAt < expiration
                    or not expiration and (not duration or offset < duration)
                if fireAt and beforeEnd then
                    local delay = fireAt - now
                    if delay >= 0 or (delay > -0.25 and not info.baseline) then
                        local captured, key = run.generation, marker.key
                        local markerIsExact = exactEndNode and true or false
                        run.timers[key] = api.schedule(math.max(0, delay), function()
                            local current = runs[id]
                            if current ~= run or run.generation ~= captured then return end
                            run.timers[key] = nil
                            api.emit(ruleID, spellID, key, {
                                estimated = run.estimated and not markerIsExact,
                                start = run.start, duration = run.duration,
                            })
                        end)
                    end
                end
            end
        end
        return run
    end

    -- The effect was applied (or refreshed) again just now: its nodes count from `start`, the old timers are void.
    -- Without a running window yet, nothing is scheduled; the next Update starts one.
    function manager:Restart(ruleID, spellID, start, estimated)
        local run = runs[tostring(ruleID) .. "|" .. tostring(spellID)]
        if not (run and run.info and finite(start)) then return false end
        local info = {}
        for key, value in pairs(run.info) do info[key] = value end
        info.start, info.expiration, info.baseline = start, nil, false
        if estimated ~= nil then info.estimated = estimated == true end
        self:Update(ruleID, spellID, info)
        return true
    end

    function manager:StopOthers(ruleID, keepSpellID)
        local prefix, keep = tostring(ruleID) .. "|", tostring(ruleID) .. "|" .. tostring(keepSpellID)
        for id, run in pairs(runs) do
            if id ~= keep and id:sub(1, #prefix) == prefix then
                stop(run)
                runs[id] = nil
            end
        end
    end

    function manager:Stop(ruleID, spellID)
        local id = tostring(ruleID) .. "|" .. tostring(spellID)
        stop(runs[id])
        runs[id] = nil
    end

    function manager:Reset()
        for _, run in pairs(runs) do stop(run) end
        runs = {}
    end

    function manager:Get(ruleID, spellID)
        return runs[tostring(ruleID) .. "|" .. tostring(spellID)]
    end

    return manager
end

-- Learned durations: the last readable duration per spell ID, kept across sessions so intermediate markers can run
-- (marked as estimated) when the duration is secret in combat. store = WoWraVoxProfilesDB.auraDurations.
function MarkerTimers.Learn(store, spellID, duration)
    if type(store) ~= "table" or not finite(spellID) or not finite(duration) or duration <= 0 or duration > 86400 then return false end
    store[spellID] = math.floor(duration * 100 + 0.5) / 100
    return true
end

-- Duration for a rule: readable value, else the rule's own override, else the learned one.
-- Returns duration, estimated (true when not read from the effect itself).
function MarkerTimers.DurationFor(rule, spellID, readable, store)
    if finite(readable) and readable > 0 then return readable, false end
    local override = rule and tonumber(rule.durationOverride)
    if override and override > 0 then return override, true end
    local learned = type(store) == "table" and tonumber(store[spellID]) or nil
    if learned and learned > 0 then return learned, true end
    -- Another rank / twin ID of the same spell may be the one that was seen (and learned).
    local family = type(store) == "table" and ns.SpellRanks and ns.SpellRanks.FamilyOf and ns.SpellRanks.FamilyOf(spellID)
    for _, member in ipairs(family or {}) do
        local value = tonumber(store[member])
        if value and value > 0 then return value, true end
    end
    return nil, true
end
