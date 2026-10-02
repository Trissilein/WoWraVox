local now = 0
local timerCallbacks = {}
local ttsMessages = {}
local nativeRegistered = false

local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. detail) or "")) end
    print("PASS " .. name)
end

function wipe(value)
    for key in pairs(value) do value[key] = nil end
end

function GetTime()
    return now
end

function date()
    return "00:00:00"
end

function GetLocale()
    return "enUS"
end

function issecretvalue()
    return false
end

function issecrettable()
    return false
end

function InCombatLockdown()
    return false
end

-- C_Spell.IsSelfBuff stub: spell IDs in selfBuffIDs report true, everything else false.
local selfBuffIDs = { [204018] = true }
C_Spell = {
    IsSelfBuff = function(spellID) return selfBuffIDs[spellID] == true end,
}

C_Timer = {}
function C_Timer.After(_, callback)
    table.insert(timerCallbacks, callback)
end

local function runTimers()
    local callbacks = timerCallbacks
    timerCallbacks = {}
    for _, callback in ipairs(callbacks) do callback() end
end

C_UnitAuras = {
    GetUnitAuraBySpellID = function()
        return nil
    end,
}

C_VoiceChat = {
    SpeakText = function(_, message)
        table.insert(ttsMessages, message)
    end,
}

Enum = {
    UnitAuraSoundTrigger = { Added = 1, Removed = 2 },
}

ns = addonNamespace
ns.Locales = { enUS = {} }
ns.Profiles = {
    RuleMatchesCurrentSpecialization = function() return true end,
}
ns.AuraSoundFallback = {
    IsRegistered = function() return nativeRegistered end,
    GetCategorySoundFile = function(category)
        return category == "defensive" and "defensive.ogg" or nil
    end,
    Log = function() end,
}

CreateFrame = function()
    local frame = {}
    function frame:RegisterEvent() end
    function frame:RegisterUnitEvent() end
    function frame:SetScript() end
    function frame:UnregisterAllEvents() end
    return frame
end

local aurasSecret = true
C_Secrets = {
    ShouldAurasBeSecret = function() return aurasSecret end,
}

local function clearOutput()
    now = 0
    timerCallbacks = {}
    ttsMessages = {}
    nativeRegistered = false
    aurasSecret = true
    ns._Aura.resetEventState()
end

-- Self-only rule: a successful cast whose ID equals the tracked aura ID and is a self buff announces the player's own effect.
local function makeRule(message)
    return {
        id = "own",
        enabled = true,
        applyEnabled = true,
        spellIDs = { 204018 },
        applyMessage = message or "Protected",
        alertCategory = "defensive",
        voiceID = 8,
        volume = 100,
        speechSpeed = 100,
        applySoundEnabled = false,
        applySoundChannel = "Master",
        screenProfiles = {},
    }
end

local function castSelf(rule, speak, guid)
    WoWraVoxDB = { auras = { rule } }
    C_VoiceChat = speak and {
        SpeakText = function(_, message)
            table.insert(ttsMessages, message)
        end,
    } or nil
    ns._Aura.handleCast("player", guid or "cast-guid", 204018)
    runTimers()
end

clearOutput()
castSelf(makeRule("Protected"), true)
check("own cast announces once", #ttsMessages == 1 and ttsMessages[1] == "Protected")

clearOutput()
castSelf(makeRule("Immune to Magic"), false)
check("missing TTS stays silent (category word is native only)", #ttsMessages == 0)

clearOutput()
aurasSecret = false
castSelf(makeRule("Protected"), true)
check("cast path is silent while auras are readable", #ttsMessages == 0)

-- Same-ID self-buff gate (replaces the removed combat cast map).
clearOutput()
selfBuffIDs[204018] = nil
castSelf(makeRule("Protected"), true)
check("cast of a non-self-buff ID stays silent", #ttsMessages == 0)
selfBuffIDs[204018] = true

clearOutput()
local differentID = makeRule("Protected")
differentID.spellIDs = { 31850 }
castSelf(differentID, true)
check("tracked aura ID that differs from the cast ID stays silent", #ttsMessages == 0)

clearOutput()
local doubled = makeRule("Protected")
doubled.spellIDs = { 204018, 204018 }
castSelf(doubled, true)
check("duplicate aura ID in one rule announces once", #ttsMessages == 1)

clearOutput()
C_Spell = nil
castSelf(makeRule("Protected"), true)
check("missing C_Spell.IsSelfBuff stays silent", #ttsMessages == 0)
C_Spell = { IsSelfBuff = function(spellID) return selfBuffIDs[spellID] == true end }

-- Old combat cast map fields are dropped silently when a rule is normalized.
local legacyMap = { combatCastByAuraID = { [31850] = 31850 }, defensiveMappingVersion = 1 }
ns.normalizeTargetRule(legacyMap)
check("legacy combat cast map fields are discarded",
    legacyMap.combatCastByAuraID == nil and legacyMap.defensiveMappingVersion == nil)
check("combat cast map functions are gone", ns._Aura.parseCombatCastMap == nil
    and ns._Aura.formatCombatCastMap == nil and ns._Aura.auraCastMapsEqual == nil
    and ns._Aura.normalizeAuraCastMap == nil and ns._Aura.migrateDefensiveAuraRule == nil)

clearOutput()
C_Secrets = nil
InCombatLockdown = function() return true end
check("aurasAreSecret falls back to combat lockdown", ns._Aura.aurasAreSecret() == true)
InCombatLockdown = function() return false end
check("aurasAreSecret falls back to false outside combat", ns._Aura.aurasAreSecret() == false)

-- Removed foreign-target feature: old saved fields are dropped and no target API remains.
local legacy = { autoAnnounceTarget = true, otherTargetMessage = "x {target}", targetMessage = "y" }
ns.normalizeTargetRule(legacy)
check("legacy target fields are discarded",
    legacy.autoAnnounceTarget == nil and legacy.otherTargetMessage == nil and legacy.targetMessage == nil)
check("target path is gone", ns._Aura.handleTargetCastSent == nil and ns._Aura.resetTargetState == nil)

-- TTS coalescer: same voice/volume/rate in one frame -> one SpeakText, other voices stay separate.
local ttsCalls = {}
local function useRecordingTTS()
    ttsCalls = {}
    C_VoiceChat = {
        SpeakText = function(voiceID, message, rate, volume, overlap)
            table.insert(ttsCalls, { voice = voiceID, text = message, rate = rate, volume = volume, overlap = overlap })
        end,
    }
end

clearOutput()
useRecordingTTS()
check("queueTTS reports accepted/queued", select(2, ns._Aura.queueTTS(8, "One", 100, 100)) == "queued")
ns._Aura.queueTTS(8, "Two", 100, 100)
ns._Aura.queueTTS(9, "Other voice", 100, 100)
ns._Aura.queueTTS(8, "Three!", 100, 100)
ns._Aura.queueTTS(8, "Four", 100, 100)
check("nothing speaks before the frame ends", #ttsCalls == 0)
runTimers()
check("same-frame messages become one call per voice", #ttsCalls == 2, "calls=" .. #ttsCalls)
check("joined in arrival order, no double punctuation",
    ttsCalls[1].text == "One. Two. Three! Four" and ttsCalls[1].voice == 8, ttsCalls[1].text)
check("other voice keeps its own call", ttsCalls[2].text == "Other voice" and ttsCalls[2].voice == 9)
check("coalesced call is not overlapping", ttsCalls[1].overlap == false and ttsCalls[1].volume == 100)
ns._Aura.queueTTS(8, "Later", 100, 100)
runTimers()
check("next frame starts a fresh batch", #ttsCalls == 3 and ttsCalls[3].text == "Later")
check("empty message is rejected synchronously", ns._Aura.queueTTS(8, "  ", 100, 100) == false)
C_VoiceChat = nil
check("missing API is rejected synchronously", ns._Aura.queueTTS(8, "x", 100, 100) == false)

-- Two rules answering the same cast in one frame -> one call.
C_Secrets = { ShouldAurasBeSecret = function() return aurasSecret end }
clearOutput()
useRecordingTTS()
local ruleA, ruleB = makeRule("Protected"), makeRule("Shielded")
ruleB.id = "own2"
WoWraVoxDB = { auras = { ruleA, ruleB } }
ns._Aura.handleCast("player", "guid-multi", 204018)
runTimers()
check("two rules, one frame: single joined call", #ttsCalls == 1 and ttsCalls[1].text == "Protected. Shielded",
    #ttsCalls .. " " .. tostring(ttsCalls[1] and ttsCalls[1].text))

-- A rejected deferred SpeakText is logged and nothing else happens (no addon-side category cue).
clearOutput()
C_VoiceChat = { SpeakText = function() error("rejected") end }
WoWraVoxDB = { auras = { makeRule("Protected") } }
ns._Aura.handleCast("player", "guid-fail", 204018)
runTimers()
check("deferred SpeakText failure is survived silently", #ttsMessages == 0)

-- Debug trace: events registered only with debug on; TTS-CALL / TTS-START delta / FAILED logged.
local logs, registered = {}, {}
ns.AuraSoundFallback.Log = function(category, message) table.insert(logs, category .. " " .. message) end
ns.eventFrame = {
    RegisterEvent = function(_, name) registered[name] = true end,
    UnregisterEvent = function(_, name) registered[name] = nil end,
}
local function countLogs(prefix)
    local n = 0
    for _, line in ipairs(logs) do if line:sub(1, #prefix) == prefix then n = n + 1 end end
    return n
end
clearOutput()
useRecordingTTS()
ns._Aura.queueTTS(8, "Quiet", 100, 100)
runTimers()
check("debug off: no events, no TTS-CALL", next(registered) == nil and countLogs("TTS-CALL") == 0)
ns.AuraSoundFallback.debugEnabled = true
now = 10
ns._Aura.queueTTS(8, "Traced", 100, 100)
runTimers()
check("debug on: playback events registered", registered.VOICE_CHAT_TTS_PLAYBACK_STARTED
    and registered.VOICE_CHAT_TTS_PLAYBACK_FINISHED and registered.VOICE_CHAT_TTS_PLAYBACK_FAILED)
check("debug on: TTS-CALL logged", countLogs("TTS-CALL t=10.000") == 1)
now = 10.25
ns._Aura.onTTSEvent("VOICE_CHAT_TTS_PLAYBACK_STARTED", 3)
check("TTS-START logs delta to the call", countLogs("TTS-START +250 ms") == 1, table.concat(logs, " | "))
now = 11
ns._Aura.onTTSEvent("VOICE_CHAT_TTS_PLAYBACK_FINISHED", 3)
ns._Aura.onTTSEvent("VOICE_CHAT_TTS_PLAYBACK_FAILED", 4, 2)
check("FINISHED and FAILED are logged", countLogs("TTS-FINISHED") == 1 and countLogs("TTS-FAILED utterance=4 status=2") == 1)
ns.AuraSoundFallback.debugEnabled = false
ns._Aura.onTTSEvent("VOICE_CHAT_TTS_PLAYBACK_STARTED", 5)
check("debug turned off: next event unregisters", next(registered) == nil and countLogs("TTS-START") == 1)

-- Item rule re-targeting: no false Ready, message follows only the generated default.
local equipped = { [13] = 111, [14] = 222 }
local itemCooldown = { [13] = { 90, 30 }, [14] = { 0, 0 } }
GetInventoryItemID = function(_, slot) return equipped[slot] end
GetInventoryItemCooldown = function(_, slot) return itemCooldown[slot][1], itemCooldown[slot][2], 1 end
local function makeItemRule()
    return {
        id = "item", enabled = true, itemID = 111, name = "Alpha", message = "Alpha ready",
        readyEnabled = true, alertCategory = "none", voiceID = 8, volume = 100, speechSpeed = 100,
        readySoundEnabled = false, screenProfiles = {},
    }
end
local function itemCycle(retarget)
    clearOutput()
    useRecordingTTS()
    now = 100
    itemCooldown[13] = { 90, 30 }
    local rule = makeItemRule()
    ns.checkItemRule(rule)
    if retarget then ns.retargetItemRule(rule, 222, "Beta", "icon") end
    now = 125
    itemCooldown[13] = { 0, 0 }
    ns.checkItemRule(rule)
    runTimers()
    return rule
end
itemCycle(false)
check("control: cooldown end announces Ready once", #ttsCalls == 1 and ttsCalls[1].text == "Alpha ready")
local retargeted = itemCycle(true)
check("re-targeted rule gets no Ready for the new item", #ttsCalls == 0, ttsCalls[1] and ttsCalls[1].text)
check("rule now points at the new item", retargeted.itemID == 222 and retargeted.name == "Beta" and retargeted.icon == "icon")
check("generated message follows the item", retargeted.message == "Beta ready")
local custom = makeItemRule()
custom.message = "Trinket up!"
ns.retargetItemRule(custom, 222, "Beta")
check("custom message is kept", custom.message == "Trinket up!")
local starter = { starter = "trinket", itemID = 0, name = "Add a trinket", message = "" }
ns.retargetItemRule(starter, 222, "Beta")
check("starter fill sets itemID, message and clears starter",
    starter.itemID == 222 and starter.message == "Beta ready" and starter.starter == nil)

-- Slot mode: the rule watches whatever sits in rule.slotID.
local function makeSlotRule(message)
    local rule = makeItemRule()
    rule.slotID = 13
    rule.message = message or "Trinket 1 ready"
    return rule
end
local function slotSetup()
    clearOutput()
    useRecordingTTS()
    equipped[13], equipped[14] = 111, 222
    itemCooldown[13], itemCooldown[14] = { 0, 0 }, { 0, 0 }
end
local function step(rule, at, cooldown, slotItem)
    now = at
    if slotItem ~= nil then equipped[13] = slotItem or nil end
    itemCooldown[13] = cooldown
    ns.checkItemRule(rule)
    runTimers()
end

slotSetup()
local slotRule = makeSlotRule()
step(slotRule, 100, { 90, 30 })
step(slotRule, 125, { 0, 0 })
check("slot rule announces Ready exactly once after the cooldown", #ttsCalls == 1 and ttsCalls[1].text == "Trinket 1 ready")
step(slotRule, 126, { 0, 0 })
check("slot rule does not repeat Ready", #ttsCalls == 1)

slotSetup()
slotRule = makeSlotRule()
step(slotRule, 100, { 90, 30 })
step(slotRule, 110, { 0, 0 }, 333)
step(slotRule, 125, { 0, 0 })
check("swap mid-cooldown: no Ready for the new item", #ttsCalls == 0, ttsCalls[1] and ttsCalls[1].text)
check("swap updates the last seen item", slotRule.itemID == 333 and slotRule.slotID == 13)
check("slot swap keeps a custom or slot-default message", slotRule.message == "Trinket 1 ready")

slotSetup()
slotRule = makeSlotRule()
step(slotRule, 100, { 90, 30 })
step(slotRule, 110, { 109, 30 }, 333)  -- new item shows its equip lockout
step(slotRule, 141, { 0, 0 })
check("equip lockout of the swapped-in item is never announced", #ttsCalls == 0, ttsCalls[1] and ttsCalls[1].text)
step(slotRule, 150, { 148, 60 })
step(slotRule, 209, { 0, 0 })
check("a real use after the swap is announced once", #ttsCalls == 1 and ttsCalls[1].text == "Trinket 1 ready")

slotSetup()
slotRule = makeSlotRule()
step(slotRule, 100, { 90, 30 })
step(slotRule, 110, { 0, 0 }, 333)
step(slotRule, 125, { 0, 0 })
check("swap to an item without cooldown stays silent", #ttsCalls == 0)

slotSetup()
slotRule = makeSlotRule()
step(slotRule, 100, { 90, 30 })
step(slotRule, 110, { 90, 30 }, false)
step(slotRule, 125, { 0, 0 })
check("empty slot stays silent and drops the state", #ttsCalls == 0)
step(slotRule, 130, { 0, 0 }, 111)
check("refilled slot starts a fresh baseline without Ready", #ttsCalls == 0)

slotSetup()
local idRule = makeItemRule()
step(idRule, 100, { 90, 30 })
equipped[13] = 333
step(idRule, 125, { 0, 0 })
check("ID rule stays tied to its item (not equipped = silent)", #ttsCalls == 0 and idRule.itemID == 111 and idRule.slotID == nil)

slotSetup()
local disabledSlot = makeSlotRule()
disabledSlot.enabled = false
step(disabledSlot, 100, { 90, 30 })
step(disabledSlot, 125, { 0, 0 })
check("disabled slot rule is silent", #ttsCalls == 0)

-- Slot helpers: normalization, duplicates, retarget into / out of slot mode.
check("normalizeSlotID accepts 1..19 integers only",
    ns.normalizeSlotID(13) == 13 and ns.normalizeSlotID("14") == 14 and ns.normalizeSlotID(0) == nil
    and ns.normalizeSlotID(20) == nil and ns.normalizeSlotID(13.5) == nil and ns.normalizeSlotID(nil) == nil
    and ns.normalizeSlotID("x") == nil)
check("slot rule duplicates by slot only", ns.itemRuleIsDuplicate({ slotID = 13, itemID = 5 }, 999, 13, true)
    and not ns.itemRuleIsDuplicate({ slotID = 14, itemID = 5 }, 5, 13, true)
    and not ns.itemRuleIsDuplicate({ itemID = 5 }, 5, 13, true))
check("item rule duplicates by item, ignoring slot rules",
    ns.itemRuleIsDuplicate({ itemID = 5 }, 5, 13, false)
    and not ns.itemRuleIsDuplicate({ slotID = 13, itemID = 5 }, 5, 13, false))
check("slot names for the trinket slots", ns.slotName(13) == "Trinket 1" and ns.slotName(14) == "Trinket 2"
    and ns.slotName(1) == "Slot 1")
local toSlot = makeItemRule()
ns.retargetItemRule(toSlot, 222, "Beta", "icon", 14)
check("retarget into slot mode switches the generated message to the slot default",
    toSlot.slotID == 14 and toSlot.message == "Trinket 2 ready" and toSlot.itemID == 222)
ns.retargetItemRule(toSlot, 111, "Alpha", "icon", nil)
check("retarget out of slot mode restores the item default",
    toSlot.slotID == nil and toSlot.message == "Alpha ready")
check("pickerTracksSlot is off without a picker prompt", ns.pickerTracksSlot(13) == false)

-- Holy Armaments migration: linked pair -> one active chargeGained rule, partner disabled, link fields dropped.
local function holyPair(name, message)
    local main = { id = "rule-1", spellID = 432459, name = name, message = message, enabled = true,
        triggerType = "offCooldown", sharedChargePartnerID = "rule-2", sharedChargeSourceSpellID = 432459,
        fallbackMessage = "x voraussichtlich bereit" }
    local partner = { id = "rule-2", spellID = 432472, name = "Holy Bulwark", message = "Holy Bulwark ready",
        enabled = true, triggerType = "offCooldown", sharedChargePartnerID = "rule-1",
        sharedChargeSourceSpellID = 432459, fallbackMessage = "y" }
    return main, partner, { partner, main }
end
local holyMain, holyPartner, holyRules = holyPair("Sacred Weapon", "Sacred Weapon ready")
ns.migrateSharedChargeRules(holyRules)
check("holy migration renames swapped defaults",
    holyMain.name == "Holy Armaments" and holyMain.message == "Holy Armaments ready")
check("holy migration sets chargeGained and keeps the main rule active",
    holyMain.triggerType == "chargeGained" and holyMain.enabled == true)
check("holy migration disables the partner, not deletes it", holyPartner.enabled == false and #holyRules == 2)
check("holy migration drops link fields and fallbackMessage",
    holyMain.sharedChargePartnerID == nil and holyMain.sharedChargeSourceSpellID == nil
    and holyMain.fallbackMessage == nil and holyPartner.sharedChargePartnerID == nil
    and holyPartner.fallbackMessage == nil)
holyPartner.enabled = true
holyMain.name = "Custom"
ns.migrateSharedChargeRules(holyRules)
check("holy migration is idempotent", holyPartner.enabled == true and holyMain.name == "Custom"
    and holyMain.triggerType == "chargeGained")
local customMain, _, customRules = holyPair("My Hammer", "Hammer time!")
ns.migrateSharedChargeRules(customRules)
check("holy migration keeps custom name and message",
    customMain.name == "My Hammer" and customMain.message == "Hammer time!" and customMain.triggerType == "chargeGained")
local loneMain = { id = "rule-9", spellID = 432459, name = "Holy Bulwark", message = "Holy Bulwark ready",
    enabled = true, triggerType = "offCooldown", sharedChargePartnerID = "gone", fallbackMessage = "z" }
ns.migrateSharedChargeRules({ loneMain })
check("holy migration leaves an unpaired rule alone but drops stale fields",
    loneMain.name == "Holy Bulwark" and loneMain.triggerType == "offCooldown"
    and loneMain.sharedChargePartnerID == nil and loneMain.fallbackMessage == nil)

-- /wvprof: the flag swaps the OnEvent script, counters only move while it is on, output stays compact.
local profScript, profLines = nil, {}
ns.eventFrame = { SetScript = function(_, _, fn) profScript = fn end }
WoWraVoxDB = { items = {}, auras = {}, skills = {} }
local realPrint = print
print = function(line) table.insert(profLines, line) end
ns.Prof.Command("on")
local scriptOn = profScript
profScript(nil, "PLAYER_REGEN_DISABLED")
ns.scanItemRules()
local countedOn = ns.Prof.ev.PLAYER_REGEN_DISABLED and ns.Prof.ev.PLAYER_REGEN_DISABLED.calls == 1
    and ns.Prof.ev.scanItemRules and ns.Prof.ev.scanItemRules.calls == 1
ns.Prof.Command("off")
local scriptOff = profScript
ns.scanItemRules()
local countedOffUnchanged = ns.Prof.ev.scanItemRules.calls == 1
profLines = {}
ns.Prof.Command("")
local shownLines = #profLines
ns.Prof.Command("reset")
local resetEmpty = next(ns.Prof.ev) == nil
print = realPrint
check("wvprof on installs the timing script, off restores the raw handler",
    scriptOn == ns.Prof.onEvent and scriptOff == ns.onEvent)
check("wvprof counts events and scans only while on", countedOn and countedOffUnchanged and resetEmpty)
check("wvprof output stays within 15 lines", shownLines > 0 and shownLines <= 15, tostring(shownLines))
check("wvprof load timings are empty before ADDON_LOADED", ns.Prof.load.total == nil)
