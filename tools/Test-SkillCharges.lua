-- Fengari harness for SkillTracking.lua charge behavior: "Gains a Charge" (chargeGained) announces every
-- returning charge, with readable and with hidden charge counts, and never twice for one charge.

local now = 0
local chargeData = {}
local notices = {}
local chargeDurationAvailable = true
local durationCalls = { charge = 0, cooldown = 0 }
local frameSerial = 0

local function check(name, condition, detail)
    if not condition then
        error("FAIL " .. name .. (detail and (" " .. detail) or ""))
    end
    print("PASS " .. name)
end

local function setCharges(spellID, current, maximum)
    chargeData[spellID] = { currentCharges = current, maxCharges = maximum or 2 }
end

function GetTime() return now end
function date() return "00:00:00" end
function issecretvalue(value) return value == "SECRET" end
function issecrettable() return false end
function wipe(value)
    for key in pairs(value) do value[key] = nil end
end

C_Timer = { After = function() end }

local function newFrame()
    frameSerial = frameSerial + 1
    local frame = { scripts = {}, id = frameSerial }
    function frame:SetSize() end
    function frame:SetPoint() end
    function frame:SetAlpha() end
    function frame:Show() end
    function frame:SetScript(name, callback) self.scripts[name] = callback end
    function frame:SetCooldownFromDurationObject(duration) self.durationObject = duration end
    function frame:SetCooldown() end
    function frame:Trigger(name)
        local callback = self.scripts[name]
        if callback then callback(self) end
    end
    return frame
end

UIParent = {}
function CreateFrame() return newFrame() end

C_Spell = {
    GetSpellCharges = function(spellID) return chargeData[spellID] end,
    GetSpellCooldown = function()
        return { startTime = 0, duration = 0, isEnabled = true, isOnGCD = false }
    end,
    GetSpellChargeDuration = function()
        durationCalls.charge = durationCalls.charge + 1
        if not chargeDurationAvailable then return nil end
        return { kind = "charge-duration" }
    end,
    GetSpellCooldownDuration = function()
        durationCalls.cooldown = durationCalls.cooldown + 1
        return { kind = "cooldown-duration" }
    end,
}

DEFAULT_CHAT_FRAME = { AddMessage = function() end }
ns.AuraSoundFallback = { Log = function() end, SetDebugEnabled = function() end, ClearLog = function() end }

local tracking = ns.SkillTracking
tracking.Configure(function() return true end, function(rule, cause, event)
    table.insert(notices, { id = rule.id, cause = cause, event = event })
end, function(key) return key end)

local function reset()
    tracking.ResetAll()
    now = 0
    notices = {}
    chargeData = {}
    chargeDurationAvailable = true
    durationCalls = { charge = 0, cooldown = 0 }
end

local function makeRule(id, spellID, triggerType)
    return { id = id, spellID = spellID, name = id, enabled = true, triggerType = triggerType }
end

local function scan(rules, event)
    tracking.Scan(rules, event or "SPELL_UPDATE_CHARGES")
end

-- Fires the duration-object watcher of a rule the way WoW does when the recharge timer ends.
local function finishRecharge(rule)
    local frame = tracking.durationFrames[rule]
    if frame and frame.watchState then
        frame:Trigger("OnCooldownDone")
        return true
    end
    return false
end

-- Readable charges: event path announces 0->1 and 1->2 once each; a watcher firing afterwards is a no-op.
reset()
local gain = makeRule("gain", 1001, "chargeGained")
local rules = { gain }
setCharges(1001, 0, 2)
scan(rules, "BASELINE")
check("baseline is silent", #notices == 0)
check("watcher uses the charge duration for chargeGained",
    durationCalls.charge > 0 and durationCalls.cooldown == 0
    and tracking.durationFrames[gain].durationObject.kind == "charge-duration")
setCharges(1001, 1, 2)
scan(rules)
check("readable 0->1 announces once", #notices == 1 and notices[1].cause == "chargeGained")
check("watcher after the event does not double", finishRecharge(gain) and #notices == 1)
setCharges(1001, 2, 2)
scan(rules)
check("readable 1->2 announces once", #notices == 2 and notices[2].cause == "chargeGained")
check("full charges disarm the watcher", finishRecharge(gain) == false and #notices == 2)
setCharges(1001, 1, 2)
scan(rules)
check("spending a charge announces nothing", #notices == 2)

-- Watcher first, event second: still exactly one announcement per charge.
reset()
gain = makeRule("gain", 1001, "chargeGained")
rules = { gain }
setCharges(1001, 0, 2)
scan(rules, "BASELINE")
setCharges(1001, 1, 2)
check("watcher announces a readable gain", finishRecharge(gain) and #notices == 1)
scan(rules)
check("event after the watcher does not double", #notices == 1)

-- Hidden charge count: the finished recharge announces each returning charge once.
reset()
gain = makeRule("gain", 1001, "chargeGained")
rules = { gain }
setCharges(1001, 0, 2)
scan(rules, "BASELINE")
chargeData[1001] = { currentCharges = "SECRET", maxCharges = 2 }
scan(rules)
check("hidden count: events stay silent", #notices == 0)
check("hidden count: watcher stays armed", tracking.durationFrames[gain].watchState ~= nil)
check("hidden count: first recharge announces once", finishRecharge(gain) and #notices == 1
    and notices[1].cause == "chargeGained" and notices[1].event == "OnCooldownDone")
check("hidden count: next charge is watched again", tracking.durationFrames[gain].watchState ~= nil)
check("hidden count: second recharge announces once more", finishRecharge(gain) and #notices == 2)
setCharges(1001, 2, 2)
scan(rules)
check("count readable again: no repeat for the same charges", #notices == 2)
setCharges(1001, 1, 2)
scan(rules)
setCharges(1001, 2, 2)
scan(rules)
check("readable tracking resumes after combat", #notices == 3)

-- No duration object available: no watcher, the event path still works, nothing errors.
reset()
chargeDurationAvailable = false
gain = makeRule("gain", 1001, "chargeGained")
rules = { gain }
setCharges(1001, 0, 2)
scan(rules, "BASELINE")
check("missing duration object: no watcher armed", finishRecharge(gain) == false)
setCharges(1001, 1, 2)
scan(rules)
check("missing duration object: event path announces", #notices == 1)

-- Casting re-arms the watcher for a chargeGained rule.
reset()
gain = makeRule("gain", 1001, "chargeGained")
rules = { gain }
setCharges(1001, 2, 2)
scan(rules, "BASELINE")
check("full charges: nothing to watch", finishRecharge(gain) == false)
setCharges(1001, 1, 2)
tracking.OnCast(1001, "guid-1", rules)
check("cast arms the recharge watcher", tracking.durationFrames[gain].watchState ~= nil)

-- Other triggers are unaffected: offCooldown keeps its own cooldown watcher and own announcement.
reset()
local solo = makeRule("solo", 2001, "offCooldown")
rules = { solo }
setCharges(2001, 0, 2)
scan(rules, "BASELINE")
check("offCooldown keeps the cooldown duration", durationCalls.cooldown > 0 and durationCalls.charge == 0)
setCharges(2001, 1, 2)
scan(rules)
check("independent 0->1 announces own rule", #notices == 1 and notices[1].id == "solo" and notices[1].cause == "offCooldown")
setCharges(2001, 2, 2)
scan(rules)
check("independent 1->2 never cross announces", #notices == 1)
