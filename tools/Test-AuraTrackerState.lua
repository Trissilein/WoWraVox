local now = 100
local timers = {}
local emitted = {}
local cancelled = {}

local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. detail) or "")) end
    print("PASS " .. name)
end

local function makeAPI()
    return {
        now = function() return now end,
        schedule = function(delay, callback)
            local timer = { delay = delay, callback = callback, cancelled = false }
            table.insert(timers, timer)
            return timer
        end,
        cancel = function(timer)
            timer.cancelled = true
            cancelled[timer] = true
        end,
        emit = function(ruleID, eventType, context)
            table.insert(emitted, { ruleID = ruleID, eventType = eventType, context = context })
        end,
    }
end

local function resetHarness()
    now = 100
    timers = {}
    emitted = {}
    cancelled = {}
end

local function newManager()
    return ns.AuraTrackerState.Create(makeAPI())
end

local function active(manager, ruleID, spellID, expirationTime, instanceID, options)
    return manager:Update(ruleID, spellID, {
        presence = "active",
        expirationTime = expirationTime,
        instanceID = instanceID,
        icon = "icon-" .. tostring(spellID),
        stacks = 2,
        source = "player",
    }, options or { beforeExpireEnabled = true, warningSeconds = 5 })
end

local function fire(timer, at)
    now = at
    timer.callback()
end

-- Same active state must keep one timer and emit only once.
resetHarness()
local manager = newManager()
local first = active(manager, "rule-a", 1234, 120, 9)
local firstTimer = timers[1]
active(manager, "rule-a", 1234, 120, 9)
check("dedupe keeps one timer", #timers == 1 and firstTimer ~= nil)
check("Get returns public state", manager:Get("rule-a", 1234).presence == "active"
    and manager:Get("rule-a")[1234].warningFired == false)
fire(firstTimer, 115)
firstTimer.callback()
check("warning emits once", #emitted == 1 and emitted[1].eventType == "beforeExpire"
    and emitted[1].context.remaining == 5)
check("duration object stays out of public context", emitted[1].context.durationObject == nil)

-- Refresh cancels prior timer, creates a new deadline, and makes old callback stale.
resetHarness()
manager = newManager()
active(manager, "rule-a", 1234, 120, 9)
local staleTimer = timers[1]
now = 105
active(manager, "rule-a", 1234, 130, 9)
local refreshedTimer = timers[2]
check("refresh cancels old timer", cancelled[staleTimer] == true and refreshedTimer.delay == 20)
fire(staleTimer, 115)
check("stale callback cannot emit", #emitted == 0)
fire(refreshedTimer, 125)
check("refreshed deadline emits once", #emitted == 1 and emitted[1].context.expirationTime == 130)

-- Unknown and inactive observations invalidate pending work.
for _, presence in ipairs({ "unknown", "inactive" }) do
    resetHarness()
    manager = newManager()
    active(manager, "rule-a", 1234, 120, 9)
    local pending = timers[1]
    manager:Update("rule-a", 1234, { presence = presence })
    fire(pending, 115)
    check(presence .. " cancels alarm", cancelled[pending] == true and #emitted == 0
        and manager:Get("rule-a", 1234).presence == presence)
end

-- Unknown/CDM source changes retain identity and warning dedupe for one aura instance.
resetHarness()
manager = newManager()
active(manager, "rule-a", 1234, 120, 9)
fire(timers[1], 115)
manager:Update("rule-a", 1234, { presence = "unknown" })
manager:Update("rule-a", 1234, { presence = "active", source = "cdm" })
manager:Update("rule-a", 1234, { presence = "active", expirationTime = 120, instanceID = 9,
    source = "aura" }, { beforeExpireEnabled = true, warningSeconds = 5 })
check("source change keeps warning deduped", manager:Get("rule-a", 1234).warningFired == true
    and #emitted == 1 and #timers == 1)

resetHarness()
manager = newManager()
active(manager, "rule-a", 1234, 120, 9)
local sourceChangeTimer = timers[1]
manager:Update("rule-a", 1234, { presence = "unknown" })
manager:Update("rule-a", 1234, { presence = "active", source = "cdm" })
now = 110
manager:Update("rule-a", 1234, { presence = "active", expirationTime = 120, instanceID = 9,
    source = "aura" }, { beforeExpireEnabled = true, warningSeconds = 5 })
check("source change rearms same instance", cancelled[sourceChangeTimer] == true and #timers == 2
    and timers[2].delay == 5)

-- Baseline inside warning window is adopted silently and never alarms retroactively.
resetHarness()
manager = newManager()
now = 116
active(manager, "rule-a", 1234, 120, 9, { beforeExpireEnabled = true, warningSeconds = 5, baseline = true })
check("baseline inside warning window stays silent", #timers == 0
    and manager:Get("rule-a", 1234).warningFired == true)

-- Baseline outside warning window may schedule the future warning.
resetHarness()
manager = newManager()
active(manager, "rule-a", 1234, 120, 9, { beforeExpireEnabled = true, warningSeconds = 5, baseline = true })
check("baseline keeps future warning", #timers == 1 and timers[1].delay == 15)

-- Bounds default to 5 seconds and clamp to the supported range.
resetHarness()
manager = newManager()
local low = active(manager, "rule-a", 1234, 120, 9, { beforeExpireEnabled = true, warningSeconds = 0 })
check("warning lower bound clamps to one", low.warningSeconds == 1 and timers[1].delay == 19)
manager:Update("rule-b", 1234, { presence = "active", expirationTime = 120, instanceID = 10 },
    { beforeExpireEnabled = true })
check("warning defaults to five", manager:Get("rule-b", 1234).warningSeconds == 5)
manager:Update("rule-c", 1234, { presence = "active", expirationTime = 200, instanceID = 11 },
    { beforeExpireEnabled = true, warningSeconds = 99 })
check("warning upper bound clamps to sixty", manager:Get("rule-c", 1234).warningSeconds == 60)

-- Percentage mode uses only a public duration and treats 0% as immediately before expiry.
resetHarness()
manager = newManager()
manager:Update("rule-pct", 1234, {
    presence = "active", expirationTime = 140, instanceID = 20, duration = 40,
}, { beforeExpireEnabled = true, warningPercent = 25 })
check("25% remaining schedules at three quarters of the duration", #timers == 1
    and timers[1].delay == 30 and manager:Get("rule-pct", 1234).warningPercent == 25)
fire(timers[1], 130)
check("percentage warning context reports remaining time", #emitted == 1
    and emitted[1].context.remaining == 10 and emitted[1].context.warningPercent == 25)

resetHarness()
manager = newManager()
manager:Update("rule-pct", 1234, {
    presence = "active", expirationTime = 140, instanceID = 20, duration = 40,
}, { beforeExpireEnabled = true, warningPercent = 100 })
check("100% schedules at application", #timers == 1 and timers[1].delay == 0)
fire(timers[1], 100)
check("100% warns once at application time", #emitted == 1 and emitted[1].context.remaining == 40)

resetHarness()
manager = newManager()
manager:Update("rule-pct", 1234, {
    presence = "active", expirationTime = 140, instanceID = 20, duration = 40,
}, { beforeExpireEnabled = true, warningPercent = 0 })
check("0% schedules immediately before expiry", #timers == 1 and timers[1].delay == 39.75)
fire(timers[1], 139.75)
check("0% warning stays before natural expiration", #emitted == 1
    and emitted[1].context.remaining == 0.25)

resetHarness()
manager = newManager()
manager:Update("rule-pct", 1234, {
    presence = "active", expirationTime = 140, instanceID = 20,
}, { beforeExpireEnabled = true, warningPercent = 50 })
check("percentage warning stays unavailable without readable duration", #timers == 0)

-- Opaque duration data stays in memory, never read or sent to emit.
resetHarness()
manager = newManager()
local opaque = setmetatable({}, {
    __index = function() error("duration object inspected") end,
    __tostring = function() error("duration object stringified") end,
    __pairs = function() error("duration object serialized") end,
})
manager:Update("rule-a", 1234, {
    presence = "active",
    expirationTime = 120,
    instanceID = 9,
    durationObject = opaque,
}, { beforeExpireEnabled = true, warningSeconds = 5 })
local publicState = manager:Get("rule-a", 1234)
check("duration object handoff preserves identity", manager:GetDurationObject("rule-a", 1234) == opaque)
fire(timers[1], 115)
check("opaque duration object is not exposed", publicState.durationObject == nil
    and emitted[1].context.durationObject == nil)

-- Reset cancels pending work and rejects callback even if host invokes it later.
resetHarness()
manager = newManager()
active(manager, "rule-a", 1234, 120, 9)
local resetTimer = timers[1]
manager:Reset()
fire(resetTimer, 115)
check("reset cancels and invalidates callback", cancelled[resetTimer] == true
    and manager:Get("rule-a") == nil and #emitted == 0)

resetHarness()
manager = newManager()
active(manager, "rule-a", 1234, 120, 9)
local ruleTimer = timers[1]
check("ResetRule removes only selected rule", manager:ResetRule("rule-a") == true
    and cancelled[ruleTimer] == true and manager:Get("rule-a") == nil)
