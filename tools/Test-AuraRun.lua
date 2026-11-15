-- AuraRun.lua: one state machine per aura run. MOCKED event sequences (fake clock); they follow the Blizzard order
-- described in .agents/AURAEND-BRIEF.md §2, but do not prove real Blizzard timing or audible output.
local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. detail) or "")) end
    print("PASS " .. name)
end

local AuraRun = ns.AuraRun
local W = AuraRun.REPLACE_WINDOW
local clock, queue, emits, traces, estimates, probes = 0, {}, {}, {}, true, {}
local function advance(to)
    while true do
        local best
        for index, timer in ipairs(queue) do
            if not timer.cancelled and timer.at <= to and (not best or timer.at < queue[best].at) then best = index end
        end
        if not best then break end
        local timer = table.remove(queue, best)
        if timer.at > clock then clock = timer.at end
        timer.fn()
    end
    clock = math.max(clock, to)
end
local api = {
    now = function() return clock end,
    schedule = function(delay, fn) local t = { at = clock + delay, fn = fn }; queue[#queue + 1] = t; return t end,
    cancel = function(t) t.cancelled = true end,
    emit = function(rule, spellID, key, info)
        emits[#emits + 1] = { rule = rule, spellID = spellID, key = key, t = clock, how = info.how, runID = info.runID,
            event = info.event }
    end,
    trace = function(entry) traces[#traces + 1] = entry end,
    allowEstimates = function() return estimates end,
    probe = function(rule, spellID) probes[#probes + 1] = spellID end,
}
local mgr
local function reset(t)
    clock, queue, emits, traces, estimates, probes = t or 100, {}, {}, {}, true, {}
    mgr = AuraRun.Create(api)
end
local function count(key)
    local n = 0
    for _, e in ipairs(emits) do if e.key == (key or "expire") then n = n + 1 end end
    return n
end
local function ends() local list = {} for _, e in ipairs(emits) do if e.key == "expire" then list[#list + 1] = e end end return list end
local SEALS = { id = "seals", oneEffect = true }
local DP = { id = "dp" }
local A, B = 20154, 21084

-- event helpers (track = spellID for these tests)
local function ev(rule, source, kind, spellID, fields)
    local payload = { kind = kind, spellID = spellID, event = source .. "_" .. kind }
    for k, v in pairs(fields or {}) do payload[k] = v end
    return mgr:Event(rule, spellID, source, payload)
end
local function startCDM(rule, spell, inst, duration, setAt)
    return ev(rule, "CDM", "start", spell, { instanceID = inst, duration = duration or 30, setAt = setAt })
end
local function removeCDM(rule, spell, inst) return ev(rule, "CDM", "remove", spell, { instanceID = inst }) end

check("REPLACE_WINDOW is exported and 0.5 s", W == 0.5)

-- S1 natural end: BuffIcon removed alert (old instance) -> Essential Cleared (old instance) -> RefreshData /
-- ActiveStateChanged (the frame's last instance) -> UNIT_AURA; a stale apply in between; every event duplicated.
reset(100)
startCDM(SEALS, A, 5, 30, 100)
advance(130)
removeCDM(SEALS, A, 5)
check("S1 natural end is announced at once on the first removal", count() == 1 and ends()[1].t == 130 and ends()[1].how == "natural",
    tostring(ends()[1] and ends()[1].t))
removeCDM(SEALS, A, 5)
check("S1 stale apply of the ended instance is ignored", startCDM(SEALS, A, 5, 30, 130) == "stale")
removeCDM(SEALS, A, 5)
removeCDM(SEALS, A, nil) -- as if the instance were secret
ev(SEALS, "AURA", "remove", A, { instanceID = 5 })
advance(135)
check("S1 duplicates from four viewers and the aura path add nothing", count() == 1, tostring(count()))
local emitTrace = 0
for _, entry in ipairs(traces) do if entry.decision == "emit" and entry.key == "expire" then emitTrace = emitTrace + 1 end end
check("S1 the announced end has an emit trace", emitTrace == 1)

-- S1 with a readable exact end (quality 2) and the probe at the exact time.
reset(100)
ev(DP, "AURA", "start", A, { instanceID = 9, expiration = 130 })
advance(130)
check("S1 a readable end is probed once at its exact time", #probes == 1 and probes[1] == A)
ev(DP, "AURA", "remove", A, { instanceID = 9 })
check("S1 readable natural end of a plain rule is announced at once", count() == 1 and ends()[1].t == 130)

-- S2 recast: same instance (cast, aura keeps its ID) and new instance (old one removed after the cast).
reset(100)
startCDM(SEALS, A, 5, 30, 100)
advance(110)
ev(SEALS, "CAST", "cast", A, { duration = 30 })
local castRun = mgr:Get(SEALS, A)
advance(140)
removeCDM(SEALS, A, 5)
check("S2 recast on the same instance: one end at cast + duration", count() == 1 and ends()[1].t == 140 and ends()[1].runID == castRun.id)
reset(100)
startCDM(SEALS, A, 5, 30, 100)
advance(110)
ev(SEALS, "CAST", "cast", A, { duration = 30 })
removeCDM(SEALS, A, 5)
startCDM(SEALS, A, 6, 30, 110)
advance(111)
check("S2 recast with a new instance: the old instance's removal is silent", count() == 0)
advance(140)
removeCDM(SEALS, A, 6)
check("S2 the new instance ends once", count() == 1 and ends()[1].t == 140)
reset(100)
startCDM(DP, A, 5, 30, 100)
advance(110)
startCDM(DP, A, 6, 30, 110)
removeCDM(DP, A, 5)
advance(140)
removeCDM(DP, A, 6)
check("S2 new instance before the old removal: the late old removal is stale, one end", count() == 1 and ends()[1].t == 140)

-- S8 nodes: once per run, never after the end or while pending.
reset(100)
startCDM(SEALS, A, 5, 30, 100)
ev(SEALS, "MARKER", "marker", A, { key = "m1" })
ev(SEALS, "MARKER", "marker", A, { key = "m1" })
check("S8 a node is announced once per run", count("m1") == 1)
advance(110)
removeCDM(SEALS, A, 5)
ev(SEALS, "MARKER", "marker", A, { key = "m2" })
check("S8 no node while the removal waits for a replacement", count("m2") == 0)
advance(110 + W)
ev(SEALS, "MARKER", "marker", A, { key = "m2" })
check("S8 no node after the end", count("m2") == 0 and count() == 1)
check("S8 no node without a run", ev({ id = "x" }, "MARKER", "marker", 1, { key = "m1" }) == "drop")

-- S4 Judgement: early removal, no trigger cast.
reset(100)
startCDM(SEALS, A, 5, 30, 100)
advance(110)
removeCDM(SEALS, A, 5)
check("S4 consumed: nothing before W", count() == 0)
advance(110 + W)
check("S4 consumed one-effect seal: one end after W", count() == 1 and ends()[1].how == "consumed" and ends()[1].t <= 110 + W)
reset(100)
startCDM(DP, A, 5, 30, 100)
advance(110)
removeCDM(DP, A, 5)
advance(112)
check("S4 early removal of a plain rule stays silent (endOnEarlyRemoval = oneEffect)", count() == 0)
reset(100)
startCDM({ id = "opt", endOnEarlyRemoval = true }, A, 5, 30, 100)
advance(110)
removeCDM({ id = "opt", endOnEarlyRemoval = true }, A, 5)
advance(112)
check("S4 endOnEarlyRemoval overrides the default", count() == 1)

-- S3 seal switch A -> B: every order of {remove A, start B, cast B}, each event 1-3 times, cast up to 1 s before.
local switchEvents = {
    function() removeCDM(SEALS, A, 5) end,
    function() startCDM(SEALS, B, 7, 30, clock) end,
    function() ev(SEALS, "CAST", "cast", B, { duration = 30 }) end,
}
local function permutations(n)
    local out = {}
    local function go(prefix, used)
        if #prefix == n then out[#out + 1] = { table.unpack(prefix) } return end
        for i = 1, n do
            if not used[i] then
                used[i] = true; prefix[#prefix + 1] = i
                go(prefix, used)
                prefix[#prefix] = nil; used[i] = false
            end
        end
    end
    go({}, {})
    return out
end
local failures = {}
for _, order in ipairs(permutations(3)) do
    for dup = 1, 3 do
        reset(100)
        startCDM(SEALS, A, 5, 30, 100)
        advance(110)
        for _, index in ipairs(order) do
            for _ = 1, dup do switchEvents[index]() end
            clock = clock + 0.1
        end
        advance(120)
        local run = mgr:Get(SEALS, B)
        if count() ~= 0 or not (run and run.state == "active" and run.members[B]) then
            failures[#failures + 1] = table.concat(order, "") .. "x" .. dup .. ":" .. count()
        end
    end
end
check("S3 seal switch in every order (with duplicates) announces no end and keeps B", #failures == 0, table.concat(failures, " "))
reset(100)
startCDM(SEALS, A, 5, 30, 100)
advance(110)
ev(SEALS, "CAST", "cast", B, { duration = 30 })
clock = 110.9
check("S3 a cast of seal B drops seal A: A's removal 0.9 s later is stale (no wait, no end)",
    removeCDM(SEALS, A, 5) == "stale" and mgr:Get(SEALS, A).state == "active" and count() == 0)
startCDM(SEALS, B, 7, 30, 110.9)
advance(140.9)
removeCDM(SEALS, B, 7)
check("S3 ...and B's own end is announced once", count() == 1 and ends()[1].how == "natural")
reset(100)
startCDM(SEALS, A, 5, 30, 100)
advance(110)
ev(SEALS, "CAST", "cast", A, { duration = 30 })
clock = 110.9
removeCDM(SEALS, A, 5)
check("S3 a recast 0.9 s before the old instance goes decides at once: replaced, no wait",
    mgr:Get(SEALS, A).how == "replaced" and count() == 0, tostring(mgr:Get(SEALS, A).how))
reset(100)
startCDM(DP, A, 5, 30, 100)
advance(110)
removeCDM(DP, A, 5)
check("refresh: lit again while the removal waits is reported as a refresh (no new start)", startCDM(DP, A, nil, 30, 110.2) == "refresh")
reset(100)
startCDM(SEALS, A, 5, 30, 100)
advance(110)
removeCDM(SEALS, A, 5)
local timingDecision = ev(SEALS, "CDM", "timing", A, { duration = 30 })
advance(150)
check("T2 Judgement: a report without a new instance within W (another frame still lit) does not undo the end",
    timingDecision == "ignored" and count() == 1 and ends()[1].how == "consumed", tostring(timingDecision))

-- S5 baseline / reload: no start time (no end known) -> unknown end after W; saved time (quality 3) -> natural.
reset(100)
ev(SEALS, "CDM", "start", A, { instanceID = 5, duration = 30 }) -- baseline: no setAt
advance(120)
removeCDM(SEALS, A, 5)
advance(120 + W)
check("S5 baseline without an end time: end after W", count() == 1 and ends()[1].how == "unknown" and ends()[1].t == 120 + W)
reset(100)
ev(SEALS, "CDM", "start", A, { instanceID = 5, expiration = 121, quality = 3 })
advance(120.2)
removeCDM(SEALS, A, 5)
check("S5 saved end (+-1 s) counts as natural", count() == 1 and ends()[1].how == "natural" and ends()[1].t == 120.2)

-- Quality: a worse source never overwrites a better end in the same run.
reset(100)
ev(DP, "CDM", "start", A, { instanceID = 5, expiration = 130 })
ev(DP, "SAVED", "timing", A, { expiration = 129.2, quality = 3 })
ev(DP, "AURA", "timing", A, { expiration = 129.4 })
check("quality: CDM end is kept against saved and readable times", mgr:Get(DP, A).members[A].expected == 130)
ev(DP, "CDM", "start", A, { instanceID = 5, duration = 30, setAt = 105 })
check("quality: a later setAt of the same instance does not move the end", mgr:Get(DP, A).members[A].expected == 130)

-- S6 cast only: estimate at cast + learned duration, only when allowed and no other source exists.
reset(100)
ev(SEALS, "CAST", "cast", A, { duration = 30 })
advance(129.9)
check("S6 estimate: nothing before the estimated end", count() == 0)
advance(130)
check("S6 estimate on: one estimated end", count() == 1 and ends()[1].how == "estimated" and ends()[1].t == 130)
reset(100)
estimates = false
ev(SEALS, "CAST", "cast", A, { duration = 30 })
advance(140)
check("S6 estimate off: no end", count() == 0)
reset(100)
ev(SEALS, "CAST", "cast", A, { duration = 30 })
startCDM(SEALS, A, 5, 30, 100)
advance(131)
check("S6 a real source wins: no estimated end", count() == 0)
removeCDM(SEALS, A, 5)
advance(132)
check("S6 ...and the real removal ends the run", count() == 1 and ends()[1].how ~= "estimated")

-- S7 one effect, buff + debuff (Bloodlust / Sated): the end comes when the last member goes.
reset(100)
ev(SEALS, "AURA", "start", A, { instanceID = 1, expiration = 140 })
ev(SEALS, "AURA", "start", B, { instanceID = 2, expiration = 700 })
advance(140)
ev(SEALS, "AURA", "remove", A, { instanceID = 1 })
check("S7 buff end is silent while the debuff runs", count() == 0)
advance(700)
ev(SEALS, "AURA", "remove", B, { instanceID = 2 })
check("S7 debuff end announces the end once, at once", count() == 1 and ends()[1].t == 700)

-- RESET: everything dropped, no output.
reset(100)
startCDM(SEALS, A, 5, 30, 100)
advance(110)
removeCDM(SEALS, A, 5)
mgr:Event(SEALS, A, "RESET", {})
advance(120)
check("RESET drops pending decisions without output", count() == 0 and mgr:Get(SEALS, A) == nil)

-- Permutation: one natural end reported by five sources at the same moment, in every order, each 1-4 times,
-- 0-0.6 s apart: exactly one end, at the first report.
local naturalSources = {
    function() removeCDM(SEALS, A, 5) end,          -- BuffIcon TriggerAuraRemovedAlert (old instance)
    function() removeCDM(SEALS, A, 5) end,          -- Essential OnAuraInstanceInfoCleared (old instance)
    function() removeCDM(SEALS, A, 5) end,          -- RefreshData / OnActiveStateChanged (frame's last instance)
    function() ev(SEALS, "AURA", "remove", A, { instanceID = 5 }) end, -- processAura
    function() startCDM(SEALS, A, 5, 30, clock) end, -- a stale frame lights once more
}
failures = {}
local seed = 12345
local function lcg() seed = (seed * 1103515245 + 12345) % 2147483648; return seed end
local function pick(n) return lcg() % n + 1 end
local orders = permutations(5)
for _, order in ipairs(orders) do
    reset(100)
    startCDM(SEALS, A, 5, 30, 100)
    advance(130) -- reports come at or after the exact end (Blizzard never removes early), 0..0.6 s apart
    local first
    for _, index in ipairs(order) do
        for _ = 1, pick(4) do
            clock = clock + (pick(7) - 1) * 0.1
            if index ~= 5 and not first then first = clock end
            naturalSources[index]()
        end
    end
    advance(clock + 3)
    local list = ends()
    if #list ~= 1 or list[1].t ~= first then
        failures[#failures + 1] = table.concat(order, "") .. ":" .. #list .. "@" .. tostring(list[1] and list[1].t) .. "/" .. tostring(first)
    end
end
check("permutation: " .. #orders .. " orders of five end reports give one end at the first report", #failures == 0,
    table.concat(failures, " ", 1, math.min(#failures, 5)))

-- Consistency fuzz: random event soup on a one-effect and a plain rule; per run id at most one end and one of each
-- node, no node after the end, estimates only when allowed, every output traced. (Internal properties only: the
-- world fuzz below checks ends against physical ends.)
local function fuzz(rule, runsWanted)
    local bad
    for sequence = 1, runsWanted do
        local startSeed = seed
        reset(100)
        estimates = lcg() % 2 == 0
        local log, inst = {}, 1
        for _ = 1, 30 do
            local op = pick(6)
            local spell = pick(2) == 1 and A or B
            if op == 1 then
                if pick(3) == 1 then inst = inst + 1 end
                log[#log + 1] = "s" .. (spell == A and "A" or "B") .. ":" .. inst
                ev(rule, pick(2) == 1 and "CDM" or "AURA", "start", spell, { instanceID = inst, duration = 10, setAt = clock,
                    expiration = pick(2) == 1 and clock + pick(10) or nil })
            elseif op == 2 then
                log[#log + 1] = "t" .. (spell == A and "A" or "B")
                ev(rule, "SAVED", "timing", spell, { expiration = clock + pick(10), quality = 3 })
            elseif op == 3 then
                local which = pick(3) == 1 and nil or inst - (pick(2) - 1)
                log[#log + 1] = "r" .. (spell == A and "A" or "B") .. ":" .. tostring(which)
                ev(rule, "CDM", "remove", spell, { instanceID = which })
            elseif op == 4 then
                log[#log + 1] = "c" .. (spell == A and "A" or "B")
                ev(rule, "CAST", "cast", spell, { duration = pick(10) })
            elseif op == 5 then
                log[#log + 1] = "m"
                ev(rule, "MARKER", "marker", spell, { key = "m" .. pick(2) })
            else
                local step = pick(20) * 0.1
                log[#log + 1] = "+" .. step
                advance(clock + step)
            end
        end
        advance(clock + 60)
        local perRun, endedRuns, emitTraces = {}, {}, 0
        for _, entry in ipairs(traces) do if entry.decision == "emit" then emitTraces = emitTraces + 1 end end
        for _, e in ipairs(emits) do
            local id = e.runID .. "|" .. e.key
            perRun[id] = (perRun[id] or 0) + 1
            if perRun[id] > 1 then bad = "two " .. e.key .. " in run " .. e.runID end
            if e.key == "expire" then endedRuns[e.runID] = true
            elseif endedRuns[e.runID] then bad = "node after the end of run " .. e.runID end
            if e.how == "estimated" and not estimates then bad = "estimate while switched off" end
        end
        if emitTraces ~= #emits then bad = "emits without trace: " .. #emits .. "/" .. emitTraces end
        if bad then return false, "seed " .. startSeed .. " seq " .. sequence .. ": " .. bad .. " :: " .. table.concat(log, " ") end
    end
    return true
end
seed = 20261115
local okOne, whyOne = fuzz(SEALS, 200)
check("consistency fuzz: 200 one-effect sequences, at most one end and one of each node per run", okOne, whyOne)
local okPlain, whyPlain = fuzz(DP, 200)
check("consistency fuzz: 200 plain-rule sequences keep the same properties", okPlain, whyPlain)

-- Review R1 scenarios (MOCKED order).
-- T1: a frame without an instance lights once more right after a natural end, then goes dark: still one end.
reset(100)
startCDM(SEALS, A, 5, 30, 100)
advance(130)
removeCDM(SEALS, A, 5)
local relit = ev(SEALS, "CDM", "start", A, { duration = 30, setAt = 130.05 })
advance(130.1)
removeCDM(SEALS, A, nil)
advance(135)
check("T1 natural end, then a relight without instance and its removal: one end", count() == 1 and relit == "stale",
    tostring(relit) .. "/" .. count())

-- T5: same-seal recast with a new instance through two viewers, in both cast orders; the second viewer's removal of
-- the old aura comes without instance after the new instance was already reported.
for _, castFirst in ipairs({ true, false }) do
    reset(100)
    startCDM(SEALS, A, 5, 30, 100)
    advance(110)
    if castFirst then ev(SEALS, "CAST", "cast", A, { duration = 30 }) end
    removeCDM(SEALS, A, 5)                  -- Essential Cleared(A, 5)
    startCDM(SEALS, A, 6, 30, 110)          -- Essential Set(A, 6)
    removeCDM(SEALS, A, 5)                  -- BuffIcon removed alert (old 5)
    removeCDM(SEALS, A, nil)                -- BuffIcon dark, instance unknown (secret)
    startCDM(SEALS, A, 6, 30, 110)          -- BuffIcon applied (6)
    if not castFirst then ev(SEALS, "CAST", "cast", A, { duration = 30 }) end
    advance(139)
    local before = count()
    advance(140)
    removeCDM(SEALS, A, 6)
    check("T5 recast with a new instance (cast " .. (castFirst and "first" or "last") .. "): no end at the recast, "
        .. "one natural end at 140", before == 0 and count() == 1 and ends()[1].t == 140 and ends()[1].how == "natural",
        before .. "/" .. count())
end

-- T3: readable seal, then secret (combat, no Cooldown Manager frame): the probe cannot see the end; the exact end
-- stands in after W.
reset(100)
ev(SEALS, "AURA", "start", A, { instanceID = 5, expiration = 130 })
advance(129.9)
check("T3 nothing before the exact end", count() == 0)
advance(131)
check("T3 readable seal unreadable at its end: one end at end + W", count() == 1 and ends()[1].t == 130 + W
    and #probes == 1, tostring(ends()[1] and ends()[1].t))
-- ...but a removal the probe could see wins at once, and the stand-in adds nothing.
reset(100)
api.probe = function() ev(SEALS, "AURA", "remove", A, { instanceID = 5 }) end
ev(SEALS, "AURA", "start", A, { instanceID = 5, expiration = 130 })
advance(131)
check("T3 a probe that sees the removal ends at once, no second end", count() == 1 and ends()[1].t == 130)
api.probe = function(rule, spellID) probes[#probes + 1] = spellID end

-- T3b: readable seal recast in combat (cast only afterwards): the estimate ends it; aura read just before the cast
-- (UNIT_AURA ahead of the cast event) keeps its exact end.
reset(100)
ev(SEALS, "AURA", "start", A, { instanceID = 5, expiration = 130 })
advance(110)
ev(SEALS, "CAST", "cast", A, { duration = 30 })
advance(141)
check("T3b recast in combat without any later source: estimated end at 140", count() == 1 and ends()[1].t == 140
    and ends()[1].how == "estimated", tostring(ends()[1] and ends()[1].t))
reset(100)
advance(110)
ev(SEALS, "AURA", "start", A, { instanceID = 6, expiration = 140.2 })
ev(SEALS, "CAST", "cast", A, { duration = 30 })
check("T3b an end read 0 s before the cast is kept", mgr:Get(SEALS, A).members[A].expected == 140.2)

-- MITTEL 3: seal switch shortly before the end, UNIT_AURA ahead of the cast: no end; an exact end 0.1 s early is natural.
reset(100)
ev(SEALS, "AURA", "start", A, { instanceID = 5, expiration = 130 })
advance(128.8)
ev(SEALS, "AURA", "remove", A, { instanceID = 5 })
ev(SEALS, "AURA", "start", B, { instanceID = 6, expiration = 158.8 })
ev(SEALS, "CAST", "cast", B, { duration = 30 })
advance(130)
check("switch 1.2 s before an exact end is no end", count() == 0)
reset(100)
ev(SEALS, "AURA", "start", A, { instanceID = 5, expiration = 130 })
advance(129.9)
ev(SEALS, "AURA", "remove", A, { instanceID = 5 })
check("an exact end reported 0.1 s early is natural, at once", count() == 1 and ends()[1].how == "natural")

-- MITTEL 4 (T6b): only a guessed end (cast + learned duration), real end 3 s earlier on a plain rule: announced as an
-- unknown end after W instead of silence.
reset(100)
ev(DP, "CAST", "cast", A, { duration = 30 })
ev(DP, "CDM", "start", A, { instanceID = 7, duration = 30 }) -- no start time
advance(127)
removeCDM(DP, A, 7)
advance(140)
check("T6b plain rule, real end 3 s before the guessed end: one end", count() == 1 and ends()[1].how == "unknown")

-- T7: a saved end (+-1 s) replaced by the readable exact end 0.8 s later is no refresh: the node stays once.
reset(100)
ev(SEALS, "CDM", "start", A, { instanceID = 5, expiration = 129.2, quality = 3 })
advance(126.5)
ev(SEALS, "MARKER", "marker", A, { key = "m1" })
local d7 = ev(SEALS, "AURA", "start", A, { instanceID = 5, expiration = 130 })
ev(SEALS, "MARKER", "marker", A, { key = "m1" })
check("T7 saved -> readable end of the same instance: same run, node once", d7 == "start" and count("m1") == 1, d7)

-- T8: a one-effect rule's cast ending seal A does not make A's instance stale for another rule.
reset(100)
local ONLY_A = { id = "onlyA" }
ev(SEALS, "AURA", "start", A, { instanceID = 5, expiration = 130 })
ev(ONLY_A, "AURA", "start", A, { instanceID = 5, expiration = 130 })
ev(SEALS, "CAST", "cast", B, { duration = 30 })
check("T8 graves are per rule", ev(ONLY_A, "AURA", "start", A, { instanceID = 5, expiration = 135 }) ~= "stale")

-- World fuzz (review R1): a physical seal timeline is generated first; each physical change is reported by the sources
-- in a Blizzard-like order (per viewer: removed alert / Cleared of the old instance, optional removal without instance
-- (secret), Set / applied of the new one; viewers, aura path and cast in random order; duplicates; jitter). The oracle
-- matches ends to PHYSICAL ends (natural / Judgement): none lost, none false, a natural one at its first report.
do
    local wclock, wqueue, wemits = 0, {}, {}
    local function wadvance(to)
        while true do
            local best
            for i, t in ipairs(wqueue) do
                if not t.cancelled and t.at <= to and (not best or t.at < wqueue[best].at) then best = i end
            end
            if not best then break end
            local t = table.remove(wqueue, best)
            if t.at > wclock then wclock = t.at end
            t.fn()
        end
        wclock = math.max(wclock, to)
    end
    local wapi = {
        now = function() return wclock end,
        schedule = function(d, fn) local t = { at = wclock + d, fn = fn }; wqueue[#wqueue + 1] = t; return t end,
        cancel = function(t) t.cancelled = true end,
        emit = function(rule, _, key, info) wemits[#wemits + 1] = { rule = rule.id, key = key, t = wclock, how = info.how } end,
        allowEstimates = function() return true end,
        probe = function() end, -- the aura path's own events model the re-read
    }
    local wseed
    local function wpick(n) wseed = (wseed * 1103515245 + 12345) % 2147483648; return math.floor(wseed / 65536) % n + 1 end
    local function chance(p) return wpick(1000) <= p * 1000 end
    local SPELLS = { 20289, 20305, 20375, 20915 }
    local function shuffle(list) for i = #list, 2, -1 do local j = wpick(i); list[i], list[j] = list[j], list[i] end return list end

    local function runOne(cfg)
        wclock, wqueue, wemits = 100, {}, {}
        local m = AuraRun.Create(wapi)
        local log, inst, cur, truth = {}, 0, nil, {}
        local combat = chance(0.5)
        local function send(source, kind, spell, fields)
            for _, rule in ipairs(cfg.rules) do
                if rule.tracks[spell] then
                    local payload = { kind = kind, spellID = spell, event = source .. "_" .. kind }
                    for k, v in pairs(fields or {}) do payload[k] = v end
                    m:Event(rule, spell, source, payload)
                end
            end
            log[#log + 1] = string.format("%.2f %s:%s:%s:%s", wclock, source, kind, spell, tostring(fields and fields.instanceID))
        end
        local function report(old, new, castSpell, isEnd)
            -- The viewers handle the same UNIT_AURA in one frame: they all see the new aura set at the same time.
            local blocks, setAt = {}, wclock
            local function dup() return wpick(cfg.maxDup) end
            local gone = old and not (new and new.inst == old.inst)
            if cfg.cdm and combat then
                blocks[#blocks + 1] = function() -- buff icon: removed alert (old) ... applied (new)
                    if gone then for _ = 1, dup() do send("CDM", "remove", old.spell, { instanceID = not cfg.secret and old.inst or nil }) end end
                    if new then for _ = 1, dup() do send("CDM", "start", new.spell, { instanceID = new.inst, duration = 30, setAt = setAt }) end end
                end
                blocks[#blocks + 1] = function() -- Essential: Cleared(old) -> dark (frame's last instance) -> Set(new)
                    if gone then
                        send("CDM", "remove", old.spell, { instanceID = not cfg.secret and old.inst or nil })
                        send("CDM", "remove", old.spell, { instanceID = not (cfg.secret or cfg.goneNil) and old.inst or nil })
                    end
                    if new and new.inPlace then send("CDM", "timing", new.spell, { instanceID = new.inst, duration = 30 })
                    elseif new then send("CDM", "start", new.spell, { instanceID = new.inst, duration = 30, setAt = setAt }) end
                end
            end
            if not combat then
                local calls = {}
                if old and not (new and new.spell == old.spell) then
                    calls[#calls + 1] = function() send("AURA", "remove", old.spell, { instanceID = old.inst }) end
                end
                if new then calls[#calls + 1] = function() send("AURA", "start", new.spell, { instanceID = new.inst, expiration = new.exp }) end end
                blocks[#blocks + 1] = function() for _, call in ipairs(shuffle(calls)) do call() end end
            end
            if castSpell then blocks[#blocks + 1] = function()
                for _ = 1, chance(0.2) and 2 or 1 do send("CAST", "cast", castSpell, { duration = 30 }) end
            end end
            local firstRemoveAt
            for _, block in ipairs(shuffle(blocks)) do
                local before = #log
                block()
                if isEnd and not firstRemoveAt and #log > before then firstRemoveAt = wclock end
                if cfg.jitter then wadvance(wclock + (wpick(4) - 1) * 0.1) end
            end
            return firstRemoveAt
        end
        local function ended(kind) local at = report(cur, nil, nil, true); truth[#truth + 1] = { at = at, kind = kind }; cur = nil end
        for _ = 1, cfg.steps do
            local action = wpick(5)
            if not cur or action <= 2 then
                local spell = SPELLS[wpick(cfg.spellCount)]
                local new
                if cur and cur.spell == spell and chance(0.5) then
                    new = { spell = spell, inst = cur.inst, exp = wclock + 30, inPlace = true }
                else
                    inst = inst + 1
                    new = { spell = spell, inst = inst, exp = wclock + 30 }
                end
                report(cur, new, spell)
                cur = new
            elseif action == 3 then
                ended("consumed") -- Judgement
            elseif chance(0.5) then
                wadvance(cur.exp)
                ended("natural")
            else
                wadvance(math.min(wclock + wpick(20), cur.exp))
                if wclock >= cur.exp then ended("natural") end
            end
            if cfg.cdm and chance(0.1) and not cur and inst > 0 then
                send("CDM", "start", SPELLS[1], { instanceID = inst, duration = 30, setAt = wclock }) -- stale relight
            end
            local gcdTo = wclock + 1.5 + wpick(10) * 0.1
            if cur and cur.exp <= gcdTo then wadvance(math.max(wclock, cur.exp)); ended("natural") end
            wadvance(math.max(wclock, gcdTo))
        end
        wadvance(wclock + 2)
        local mine, used, problem = {}, {}, nil
        for _, e in ipairs(wemits) do if e.rule == cfg.rules[1].id and e.key == "expire" then mine[#mine + 1] = e end end
        for _, physical in ipairs(truth) do
            if physical.at then
                local hit
                for i, e in ipairs(mine) do
                    if not used[i] and e.t >= physical.at - 0.001 and e.t <= physical.at + W + 0.6 + 0.001 then hit = i; break end
                end
                if not hit then problem = problem or ("LOST " .. physical.kind .. " end at " .. physical.at)
                else
                    used[hit] = true
                    if physical.kind == "natural" and mine[hit].t > physical.at + 0.001 then
                        problem = problem or string.format("late natural end +%.2f (%s)", mine[hit].t - physical.at, mine[hit].how)
                    end
                end
            end
        end
        for i, e in ipairs(mine) do
            if not used[i] and e.how ~= "estimated" then problem = problem or string.format("FALSE end at %.2f (%s)", e.t, e.how) end
        end
        return problem, log, combat
    end

    local function campaign(name, cfg, count, startSeed)
        wseed = startSeed
        local bad, first = 0, nil
        for _ = 1, count do
            local seedNow = wseed
            local problem, log, combat = runOne(cfg)
            if problem then
                bad = bad + 1
                first = first or ("seed " .. seedNow .. " combat=" .. tostring(combat) .. " " .. problem .. " :: "
                    .. table.concat(log, " ", math.max(1, #log - 30)))
            end
        end
        check("world fuzz " .. name .. ": " .. count .. " timelines, no end lost, false or late", bad == 0,
            bad .. " bad, first: " .. tostring(first))
    end
    local SEALS_W = { id = "seals", oneEffect = true, tracks = { [20289] = true, [20305] = true, [20375] = true, [20915] = true } }
    local SOC = { id = "soc", tracks = { [20375] = true } }
    local base = { rules = { SEALS_W }, cdm = true, maxDup = 2, jitter = true, steps = 12, spellCount = 4 }
    local function with(fields) local cfg = {} for k, v in pairs(base) do cfg[k] = v end for k, v in pairs(fields) do cfg[k] = v end return cfg end
    campaign("A (instances readable, two viewers, duplicates, jitter)", base, 400, 777)
    campaign("B (as A, the dark frame's removal without instance)", with({ goneNil = true }), 300, 778)
    campaign("C (no jitter, up to 3 duplicates)", with({ jitter = false, maxDup = 3 }), 300, 779)
    campaign("D (instances secret on removal)", with({ secret = true }), 300, 780)
    campaign("E (two rules share 20375)", with({ rules = { SEALS_W, SOC } }), 300, 781)
    campaign("F (one seal, recasts)", with({ spellCount = 1 }), 400, 782)
    campaign("G (no Cooldown Manager)", with({ cdm = false, maxDup = 1 }), 300, 783)
end
