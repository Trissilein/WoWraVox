local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. detail) or "")) end
    print("PASS " .. name)
end

-- Fake clock and timers
local clock, queue, fired = 100, {}, {}
local function run(to)
    clock = to
    table.sort(queue, function(a, b) return a.at < b.at end)
    local still = {}
    for _, t in ipairs(queue) do
        if not t.cancelled and t.at <= clock then t.fn() elseif not t.cancelled then still[#still + 1] = t end
    end
    queue = still
end
local api = {
    now = function() return clock end,
    schedule = function(delay, fn) local t = { at = clock + delay, fn = fn }; queue[#queue + 1] = t; return t end,
    cancel = function(t) t.cancelled = true end,
    emit = function(ruleID, spellID, key, info) fired[#fired + 1] = key .. (info.estimated and "~" or "") end,
}
local T = ns.MarkerTimers.Create(api)
local rule = {}
ns.Markers.Normalize(rule, "auras")
ns.Markers.Add(rule, 50)
ns.Markers.Add(rule, 90)

T:Update("r", 7, { active = true, start = 100, duration = 20, markers = rule.markers })
run(109)
check("nothing before 50 %", #fired == 0)
run(110)
check("50 % fires at 10 s", table.concat(fired, ",") == "m1")
run(118)
check("90 % fires at 18 s", table.concat(fired, ",") == "m1,m2")
run(125)
check("endpoints are not timer-driven", #fired == 2)

-- Removal cancels pending markers
fired = {}
T:Update("r", 7, { active = true, start = 200, duration = 20, markers = rule.markers })
clock = 200
T:Update("r", 7, { active = false })
run(230)
check("aura gone: pending markers cancelled", #fired == 0)

-- Same window does not re-arm; refresh (new start) re-arms
fired = {}
clock = 300
T:Update("r", 7, { active = true, start = 300, duration = 20, markers = rule.markers })
T:Update("r", 7, { active = true, start = 300, duration = 20, markers = rule.markers })
run(311)
check("same window fires once", table.concat(fired, ",") == "m1")
T:Update("r", 7, { active = true, start = 311, duration = 20, markers = rule.markers })
run(321.5)
check("refresh restarts the timeline", table.concat(fired, ",") == "m1,m1")

-- Baseline: markers already past are skipped
T:Reset()
fired = {}
clock = 400
T:Update("r", 8, { active = true, start = 385, duration = 20, baseline = true, markers = rule.markers })
run(420)
check("login mid-effect skips past markers", table.concat(fired, ",") == "m2")

-- Estimated duration flag passes through
fired = {}
clock = 500
T:Update("r", 9, { active = true, start = 500, duration = 10, estimated = true, markers = rule.markers })
run(505)
check("estimated duration is marked", table.concat(fired, ",") == "m1~")

-- Learn and DurationFor
local store = {}
check("learn stores rounded duration", ns.MarkerTimers.Learn(store, 7, 12.3456) and store[7] == 12.35)
check("no learning of junk", not ns.MarkerTimers.Learn(store, 7, -1) and not ns.MarkerTimers.Learn(store, nil, 5))
local d, est = ns.MarkerTimers.DurationFor({}, 7, 30, store)
check("readable duration wins", d == 30 and est == false)
d, est = ns.MarkerTimers.DurationFor({ durationOverride = 15 }, 7, nil, store)
check("override beats learned", d == 15 and est == true)
d, est = ns.MarkerTimers.DurationFor({}, 7, nil, store)
check("learned when nothing else", d == 12.35 and est == true)
check("unknown gives nil", ns.MarkerTimers.DurationFor({}, 99, nil, store) == nil)

-- "2 s after start" runs without a known duration; percent nodes wait for one
T:Reset()
fired = {}
local r2 = {}
ns.Markers.Normalize(r2, "auras")
local s2 = ns.Markers.Add(r2, 50)
ns.Markers.SetTiming(r2, s2, "start", 2)
local p2 = ns.Markers.Add(r2, 80)
clock = 600
T:Update("r2", 5, { active = true, start = 600, duration = nil, markers = r2.markers })
run(605)
check("start-anchored node fires without a duration, percent node does not", table.concat(fired, ",") == s2)

-- A new trigger of a one-effect rule voids the old one's pending nodes
T:Reset(); fired = {}; queue = {}
local r3 = {}
ns.Markers.Normalize(r3, "auras")
ns.Markers.Add(r3, 90)
clock = 1000
T:Update("r3", 21, { active = true, start = 1000, duration = 30, markers = r3.markers })
clock = 1010
T:Update("r3", 22, { active = true, start = 1010, duration = 30, markers = r3.markers })
T:StopOthers("r3", 22)
check("StopOthers removes the old run", T:Get("r3", 21) == nil and T:Get("r3", 22) ~= nil)
run(1030)
check("old trigger's 90 % never fires", #fired == 0)
run(1037)
check("new trigger's 90 % fires at its own time", #fired == 1)

-- Re-applied: the nodes count from the new start
T:Reset(); fired = {}; queue = {}
clock = 2000
T:Update("r3", 21, { active = true, start = 2000, duration = 30, markers = r3.markers })
clock = 2020
check("Restart reports success", T:Restart("r3", 21, 2020) == true)
run(2027)
check("nothing at the old 90 %", #fired == 0)
run(2047)
check("fires at the new 90 %", #fired == 1)
