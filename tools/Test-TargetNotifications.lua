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

do
    local played
    local oldPlaySoundFile, oldPlaySound = PlaySoundFile, PlaySound
    PlaySoundFile = function(path, channel)
        played = { kind = "file", value = path, channel = channel }
        return true
    end
    PlaySound = function(soundKitID, channel)
        played = { kind = "kit", value = soundKitID, channel = channel }
        return true
    end
    local testRule = {
        applySoundEnabled = true, applySoundKitID = 2468, applySoundChannel = "Dialog",
        alertCategory = "defensive",
    }
    check("sound test plays selected sound despite configured category",
        ns.playNotificationSound(testRule, "apply", true)
            and played.kind == "kit" and played.value == 2468 and played.channel == "Dialog",
        played and (played.kind .. ":" .. tostring(played.value)))
    PlaySoundFile, PlaySound = oldPlaySoundFile, oldPlaySound
end

do
    local oldFallback = ns.AuraSoundFallback
    ns.AuraSoundFallback = {
        GetMediaSoundFile = function() return "selected.ogg" end,
        GetNativeSignature = function() return "selected.ogg|Master" end,
        GetRegistrationStatus = function(_, _, signature)
            return { status = "registered", registered = true, signature = signature }
        end,
    }
    local mediaRule = {
        enabled = true, readyEnabled = true, message = "Ready",
        readySoundEnabled = true, readySoundMediaName = "Selected", readySoundChannel = "Master",
    }
    local decision = ns.RuleOutput.Decide(mediaRule, "ready", {
        spellID = 123, values = mediaRule, preview = true, message = "Ready",
    })
    check("preview native-registered media remains shown as playing",
        decision.media.reason == "native-media-registered" and decision.media.native.status == "registered")
    ns.AuraSoundFallback = oldFallback
end

do
    local oldFallback = ns.AuraSoundFallback
    ns.AuraSoundFallback = {
        GetCategorySoundFile = function() return "defensive.ogg" end,
        GetNativeSignature = function() return "defensive.ogg|Master" end,
        GetRegistrationStatus = function()
            return {
                status = "pending", registered = false, actualRegistered = true,
                actualSignature = "defensive.ogg|SFX", reason = "stale-registration",
            }
        end,
    }
    local pendingRule = {
        enabled = true, applyEnabled = true, applyMessage = "Shield",
        alertCategory = "defensive", spellIDs = { 124 },
    }
    local decision = ns.RuleOutput.Decide(pendingRule, "apply", {
        spellID = 124, values = pendingRule, preview = true, message = "Shield",
    })
    check("preview pending native change keeps old registration visible",
        decision.native.status == "pending" and decision.native.actualRegistered == true
        and decision.native.actualSignature == "defensive.ogg|SFX")
    ns.AuraSoundFallback = oldFallback
end

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

-- addonCanSpeak is the single decision "can the addon speak this aura itself?" (WoW calls the ID a self buff).
-- The cast path (handleCast) and the native-category suppression both use it; no learned-spell or preset mapping.
do
    local oldSpellAPI = C_Spell
    check("addonCanSpeak is true for a self-buff ID", ns._Aura.addonCanSpeak(204018) == true)
    selfBuffIDs[204018] = nil
    check("addonCanSpeak is false for a non-self-buff ID", ns._Aura.addonCanSpeak(204018) == false)
    selfBuffIDs[204018] = true
    C_Spell = nil
    check("addonCanSpeak is false without C_Spell.IsSelfBuff", ns._Aura.addonCanSpeak(204018) == false)
    C_Spell = oldSpellAPI
    check("addonCanSpeak is false for an invalid ID", ns._Aura.addonCanSpeak(nil) == false
        and ns._Aura.addonCanSpeak("x") == false)
    check("the old own-cast-path function is gone", ns._Aura.hasUsableOwnCastPath == nil)
end

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

-- Bundled cast: a preset rule tracks aura 389539 and knows it is started by cast 31884 (rule.castByAuraID).
do
    local function bundledRule()
        local rule = makeRule("Protected")
        rule.spellIDs = { 389539 }
        rule.castByAuraID = { [389539] = 31884 }
        return rule
    end
    local function castID(rule, castSpellID)
        clearOutput()
        WoWraVoxDB = { auras = { rule } }
        C_VoiceChat = { SpeakText = function(_, message) table.insert(ttsMessages, message) end }
        ns._Aura.handleCast("player", "bundle-guid", castSpellID)
        runTimers()
    end
    selfBuffIDs[31884] = true
    castID(bundledRule(), 31884)
    check("cast of the bundled cast ID announces the rule with the aura ID", #ttsMessages == 1 and ttsMessages[1] == "Protected")
    castID(bundledRule(), 389539)
    check("cast of the bare aura ID does not announce a bundled rule", #ttsMessages == 0)
    check("addonCanSpeak follows the cast ID of the bundle", ns._Aura.addonCanSpeak(389539, bundledRule()) == true
        and ns._Aura.addonCanSpeak(389539) == false)
    selfBuffIDs[31884] = nil
    castID(bundledRule(), 31884)
    check("bundled cast stays silent when WoW does not call the cast ID a self buff", #ttsMessages == 0
        and ns._Aura.addonCanSpeak(389539, bundledRule()) == false)
    selfBuffIDs[31884] = true
    local manual = makeRule("Protected")
    manual.spellIDs = { 31884 }
    castID(manual, 31884)
    check("manual rule without a cast map is unchanged: the cast announces its own ID", #ttsMessages == 1)
    selfBuffIDs[31884] = nil
    castID(manual, 31884)
    check("manual rule without a cast map stays silent for a non-self-buff", #ttsMessages == 0)
    clearOutput()
end

-- cueFor: the group cue wins, a group on "none" falls back to the effect's own cue, otherwise "none".
do
    check("cueFor: a set group cue wins over the effect map",
        ns._Aura.cueFor({ alertCategory = "offensive", categoryByAuraID = { [5] = "healing" } }, 5) == "offensive")
    check("cueFor: group none uses the effect's own cue",
        ns._Aura.cueFor({ alertCategory = "none", categoryByAuraID = { [5] = "healing" } }, 5) == "healing")
    check("cueFor: an unlisted effect or a missing map is none",
        ns._Aura.cueFor({ alertCategory = "none", categoryByAuraID = { [5] = "healing" } }, 6) == "none"
        and ns._Aura.cueFor({ alertCategory = "none" }, 5) == "none"
        and ns._Aura.cueFor({ alertCategory = "none", categoryByAuraID = {} }, nil) == "none"
        and ns._Aura.cueFor(nil, 5) == "none")
    check("hasApplyCue: group cue or any per-effect cue",
        ns._Aura.hasApplyCue({ alertCategory = "defensive" }) == true
        and ns._Aura.hasApplyCue({ alertCategory = "none", categoryByAuraID = { [5] = "healing" } }) == true
        and ns._Aura.hasApplyCue({ alertCategory = "none" }) == false
        and ns._Aura.hasApplyCue({ alertCategory = "none", categoryByAuraID = {} }) == false)
end

-- The decision follows the effect's cue: with the native word registered the TTS is suppressed, otherwise it speaks.
do
    local function perEffectRule(group, map)
        local rule = makeRule("Protected")
        rule.alertCategory = group
        rule.categoryByAuraID = map
        return rule
    end
    castSelf(perEffectRule("none", { [204018] = "defensive" }), true)
    check("per-effect cue, word not registered: the addon speaks", #ttsMessages == 1 and ttsMessages[1] == "Protected")
    clearOutput()
    nativeRegistered = true
    castSelf(perEffectRule("none", { [204018] = "defensive" }), true)
    check("per-effect cue, word registered: TTS stays silent", #ttsMessages == 0)
    clearOutput()
    nativeRegistered = true
    castSelf(perEffectRule("none", nil), true)
    check("no group cue and no effect cue: a registered word elsewhere does not mute the addon", #ttsMessages == 1)
    clearOutput()
    nativeRegistered = true
    castSelf(perEffectRule("none", { [999] = "defensive" }), true)
    check("another effect's cue does not mute this effect", #ttsMessages == 1)
    clearOutput()
    nativeRegistered = true
    castSelf(perEffectRule("defensive", { [204018] = "offensive" }), true)
    check("a set group cue still decides for every effect (native word is defensive)", #ttsMessages == 0)
    clearOutput()
end

-- {spell}: the name of the aura that fired; a placeholder without a name stays as typed.
do
    check("format keeps {spell} without a context and fills it from one",
        ns.formatRuleNotificationMessage({}, "{spell} up") == "{spell} up"
        and ns.formatRuleNotificationMessage({}, "{Spell} up", { spell = "Sentinel" }) == "Sentinel up"
        and ns.formatRuleNotificationMessage({}, "{spell} up", {}) == "{spell} up")
    C_Spell.GetSpellName = function(spellID) return spellID == 204018 and "Aura Mastery" or nil end
    clearOutput()
    castSelf((function() local rule = makeRule("{spell} ready"); rule.alertCategory = "none"; return rule end)(), true)
    check("an aura event speaks {spell} as the aura's name", #ttsMessages == 1 and ttsMessages[1] == "Aura Mastery ready",
        tostring(ttsMessages[1]))
    check("spellContext: name, or nil when the name is unreadable",
        ns._Aura.spellContext(204018).spell == "Aura Mastery" and ns._Aura.spellContext(5) == nil
        and ns._Aura.spellContext(nil) == nil)
    check("editor tests resolve {spell} against the first trigger",
        ns.previewContext({ spellIDs = { 204018 } }).spell == "Aura Mastery" and ns.previewContext({}) == nil)
    C_Spell.GetSpellName = nil
    clearOutput()
    castSelf((function() local rule = makeRule("{spell} ready"); rule.alertCategory = "none"; return rule end)(), true)
    check("without a spell name the placeholder stays", #ttsMessages == 1 and ttsMessages[1] == "{spell} ready",
        tostring(ttsMessages[1]))
    clearOutput()
end

clearOutput()
C_Spell = nil
castSelf(makeRule("Protected"), true)
check("missing C_Spell.IsSelfBuff stays silent", #ttsMessages == 0)
C_Spell = { IsSelfBuff = function(spellID) return selfBuffIDs[spellID] == true end }

-- DebugReport is optional: announcing, cast and aura events must work when it is not loaded.
do
    local realReport, realHandleEvent = ns.DebugReport, ns.SkillTracking.HandleEvent
    ns.DebugReport = nil
    ns.SkillTracking.HandleEvent = function() end
    clearOutput()
    local ok, err = pcall(castSelf, makeRule("Protected"), true)
    check("announcing works without DebugReport", ok and #ttsMessages == 1, tostring(err))
    WoWraVoxDB = { auras = { makeRule("Protected") } }
    ok, err = pcall(ns.onEvent, ns.eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "guard-guid", 204018)
    check("cast event works without DebugReport", ok, tostring(err))
    runTimers()
    clearOutput()
    ns.DebugReport = realReport
    ns.SkillTracking.HandleEvent = realHandleEvent
end

-- A report callback that throws must not block spell handling or its announcement.
do
    local realReport, realHandleEvent = ns.DebugReport, ns.SkillTracking.HandleEvent
    local calls = { cast = 0, notify = 0 }
    ns.DebugReport = {
        NoteCast = function() calls.cast = calls.cast + 1; error("injected cast diagnostic failure") end,
        NoteNotify = function() calls.notify = calls.notify + 1; error("injected notification diagnostic failure") end,
        NoteAura = function() error("injected aura diagnostic failure") end,
    }
    ns.SkillTracking.HandleEvent = function() end
    C_Secrets = { ShouldAurasBeSecret = function() return true end }
    selfBuffIDs[204018] = true
    clearOutput()
    WoWraVoxDB = { auras = { makeRule("Protected") } }
    local ok, err = pcall(ns.onEvent, ns.eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "throwing-report-guid", 204018)
    runTimers()
    check("throwing NoteCast and NoteNotify callbacks cannot block announcements",
        ok and calls.cast == 1 and calls.notify == 1 and #ttsMessages == 1 and ttsMessages[1] == "Protected", tostring(err))
    ns.DebugReport = realReport
    ns.SkillTracking.HandleEvent = realHandleEvent
    clearOutput()
end

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
        id = "item", enabled = true, members = { { itemID = 111 } }, name = "Alpha", message = "Alpha ready",
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
    if retarget then ns.retargetItemRule(rule, 1, 222, "Beta", "icon") end
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
check("rule now points at the new item", retargeted.members[1].itemID == 222 and retargeted.name == "Beta" and retargeted.icon == "icon")
check("generated message follows the item", retargeted.message == "Beta ready")
local custom = makeItemRule()
custom.message = "Trinket up!"
ns.retargetItemRule(custom, 1, 222, "Beta")
check("custom message is kept", custom.message == "Trinket up!")
local starter = { starter = "trinket", members = {}, name = "Add a trinket", message = "" }
ns.retargetItemRule(starter, 1, 222, "Beta")
check("starter fill sets itemID, message and clears starter",
    starter.members[1].itemID == 222 and starter.message == "Beta ready" and starter.starter == nil)

-- Slot mode: a slot member watches whatever sits in its slotID.
local function makeSlotRule(message)
    local rule = makeItemRule()
    rule.members = { { itemID = 111, slotID = 13 } }
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
check("swap updates the last seen item", slotRule.members[1].itemID == 333 and slotRule.members[1].slotID == 13)
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
check("ID rule stays tied to its item (not equipped = silent)", #ttsCalls == 0 and idRule.members[1].itemID == 111 and idRule.members[1].slotID == nil)

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
check("slot member duplicates by slot only", ns.itemRuleIsDuplicate({ members = { { slotID = 13, itemID = 5 } } }, 999, 13, true)
    and not ns.itemRuleIsDuplicate({ members = { { slotID = 14, itemID = 5 } } }, 5, 13, true)
    and not ns.itemRuleIsDuplicate({ members = { { itemID = 5 } } }, 5, 13, true))
check("item member duplicates by item, ignoring slot members",
    ns.itemRuleIsDuplicate({ members = { { itemID = 5 } } }, 5, 13, false)
    and not ns.itemRuleIsDuplicate({ members = { { slotID = 13, itemID = 5 } } }, 5, 13, false))
check("slot names for the trinket slots", ns.slotName(13) == "Trinket 1" and ns.slotName(14) == "Trinket 2"
    and ns.slotName(1) == "Slot 1")
local toSlot = makeItemRule()
ns.retargetItemRule(toSlot, 1, 222, "Beta", "icon", 14)
check("retarget into slot mode switches the generated message to the slot default",
    toSlot.members[1].slotID == 14 and toSlot.message == "Trinket 2 ready" and toSlot.members[1].itemID == 222)
ns.retargetItemRule(toSlot, 1, 111, "Alpha", "icon", nil)
check("retarget out of slot mode restores the item default",
    toSlot.members[1].slotID == nil and toSlot.message == "Alpha ready")
check("pickerTracksSlot is off without a picker prompt", ns.pickerTracksSlot(13) == false)

-- Item groups: one rule, several members (fixed items or slots), one cooldown cycle per member.
do
    local itemNames = { [111] = "Alpha", [222] = "Beta", [333] = "Gamma" }
    GetItemInfo = function(id) return itemNames[id] end
    GetInventoryItemTexture = function(_, slot) return equipped[slot] and ("icon" .. equipped[slot]) or nil end
    local screenShown = {}
    local realShowScreenText = ns.showScreenText
    ns.showScreenText = function(_, eventKey, text) table.insert(screenShown, eventKey .. ":" .. text); return true end

    -- Migration of the old one-item/one-slot rule fields.
    local legacyItem = { itemID = 111, name = "Alpha" }
    ns.normalizeItemRule(legacyItem)
    check("migration: item rule becomes one fixed-item member",
        #legacyItem.members == 1 and legacyItem.members[1].itemID == 111 and legacyItem.members[1].slotID == nil
        and legacyItem.itemID == nil and legacyItem.slotID == nil)
    local legacySlot = { itemID = 111, slotID = 13 }
    ns.normalizeItemRule(legacySlot)
    check("migration: slot rule becomes one slot member keeping the last seen item",
        #legacySlot.members == 1 and legacySlot.members[1].slotID == 13 and legacySlot.members[1].itemID == 111
        and legacySlot.slotID == nil)
    local legacyStarter = { starter = "trinket", itemID = 0, name = "Add a trinket" }
    ns.normalizeItemRule(legacyStarter)
    check("migration: unfilled starter keeps an empty member list", #legacyStarter.members == 0
        and ns.isEmptyStarter(legacyStarter) and #ns.itemMembers({}) == 0)
    local again = { members = { { itemID = 111 }, { slotID = 13, itemID = 5 } }, name = "G" }
    ns.normalizeItemRule(again)
    local firstPass = again.members[1]
    ns.normalizeItemRule(again)
    check("migration is idempotent", #again.members == 2 and again.members[1] == firstPass
        and again.members[2].slotID == 13 and again.itemID == nil)
    local messy = { members = { { itemID = 1 }, { itemID = 1 }, { slotID = 13 }, { slotID = 13, itemID = 2 },
        { slotID = 99, itemID = 7 }, { itemID = 0 }, "x" } }
    ns.normalizeItemRule(messy)
    check("normalizing drops duplicates and invalid members, an out-of-range slot becomes a fixed item",
        #messy.members == 3 and messy.members[1].itemID == 1 and messy.members[2].slotID == 13
        and messy.members[3].itemID == 7 and messy.members[3].slotID == nil)

    -- Group of two trinket slots.
    local function makeGroup(message)
        local rule = makeItemRule()
        rule.members = { { itemID = 111, slotID = 13 }, { itemID = 222, slotID = 14 } }
        rule.message = message or "{item} ready"
        return rule
    end
    local function groupSetup()
        clearOutput()
        useRecordingTTS()
        screenShown = {}
        equipped[13], equipped[14] = 111, 222
        itemCooldown[13], itemCooldown[14] = { 0, 0 }, { 0, 0 }
    end
    local function gstep(rule, at, c13, c14, swap13)
        now = at
        if swap13 then equipped[13] = swap13 end
        itemCooldown[13], itemCooldown[14] = c13, c14
        ns.checkItemRule(rule)
        runTimers()
    end

    groupSetup()
    local group = makeGroup()
    gstep(group, 100, { 90, 30 }, { 95, 60 })
    gstep(group, 126, { 0, 0 }, { 95, 60 })
    check("group: first member announces with its own name", #ttsCalls == 1 and ttsCalls[1].text == "Alpha ready",
        ttsCalls[1] and ttsCalls[1].text)
    gstep(group, 127, { 0, 0 }, { 95, 60 })
    gstep(group, 156, { 0, 0 }, { 0, 0 })
    check("group: second member announces separately, once", #ttsCalls == 2 and ttsCalls[2].text == "Beta ready",
        ttsCalls[2] and ttsCalls[2].text)
    gstep(group, 157, { 0, 0 }, { 0, 0 })
    check("group: no repeat after both announced", #ttsCalls == 2)

    groupSetup()
    group = makeGroup()
    gstep(group, 100, { 90, 30 }, { 90, 30 })
    gstep(group, 125, { 0, 0 }, { 0, 0 })
    check("group: members ready in the same frame become one coalesced call",
        #ttsCalls == 1 and ttsCalls[1].text == "Alpha ready. Beta ready", ttsCalls[1] and ttsCalls[1].text)

    -- Wildcards in spoken and on-screen text.
    groupSetup()
    group = makeGroup("{slot} / {SLOT} / {Item} / {foo} / 100%d")
    group.screenProfiles = { ready = { enabled = true, text = "{item} up ({slot})" } }
    gstep(group, 100, { 90, 30 }, { 95, 60 })
    gstep(group, 126, { 0, 0 }, { 95, 60 })
    check("wildcards: case-insensitive, unknown and percent text stay literal",
        #ttsCalls == 1 and ttsCalls[1].text == "Trinket 1 / Trinket 1 / Alpha / {foo} / 100%d", ttsCalls[1] and ttsCalls[1].text)
    check("wildcards: on-screen text resolves with the member that became ready",
        #screenShown == 1 and screenShown[1] == "ready:Alpha up (Trinket 1)", screenShown[1])
    check("wildcards: nil context leaves the text alone",
        ns.formatRuleNotificationMessage(group, "{item} x") == "{item} x"
        and ns.formatRuleNotificationMessage(group, "{item} {slot}", { item = "A" }) == "A {slot}")

    groupSetup()
    group = makeGroup("Trinket ready")
    gstep(group, 100, { 90, 30 }, { 95, 60 })
    gstep(group, 126, { 0, 0 }, { 95, 60 })
    gstep(group, 156, { 0, 0 }, { 0, 0 })
    check("fixed text is spoken once per member without names",
        #ttsCalls == 2 and ttsCalls[1].text == "Trinket ready" and ttsCalls[2].text == "Trinket ready")

    -- A swap in one slot never touches the other member.
    groupSetup()
    group = makeGroup()
    gstep(group, 100, { 90, 30 }, { 95, 60 })
    gstep(group, 110, { 109, 30 }, { 95, 60 }, 333)
    gstep(group, 140, { 0, 0 }, { 95, 60 })
    check("swap in slot A: the new item's equip lockout stays silent", #ttsCalls == 0, ttsCalls[1] and ttsCalls[1].text)
    gstep(group, 156, { 0, 0 }, { 0, 0 })
    check("swap in slot A does not disturb slot B's announcement",
        #ttsCalls == 1 and ttsCalls[1].text == "Beta ready", ttsCalls[1] and ttsCalls[1].text)
    check("swap updates only member A's last seen item",
        group.members[1].itemID == 333 and group.members[2].itemID == 222 and group.name == "Gamma")

    -- Removing a member drops only its cycle.
    groupSetup()
    group = makeGroup()
    gstep(group, 100, { 90, 30 }, { 95, 60 })
    check("removing a member succeeds and keeps the other", ns.removeItemMember(group, 1) == true
        and #group.members == 1 and group.members[1].slotID == 14)
    check("the rule shows the remaining member after removing the first one",
        group.name == "Beta" and group.icon == "icon222", tostring(group.name) .. "/" .. tostring(group.icon))
    gstep(group, 126, { 0, 0 }, { 95, 60 })
    check("removed member is silent", #ttsCalls == 0)
    gstep(group, 156, { 0, 0 }, { 0, 0 })
    check("remaining member keeps its cycle and announces", #ttsCalls == 1 and ttsCalls[1].text == "Beta ready",
        ttsCalls[1] and ttsCalls[1].text)
    local removedLast, why = ns.removeItemMember(group, 1)
    check("the last member cannot be removed", removedLast == false and why == "last" and #group.members == 1)

    -- Add / duplicate / default text.
    local solo = makeItemRule()
    solo.members = { { itemID = 111, slotID = 13 } }
    solo.message = "Trinket 1 ready"
    check("adding a duplicate slot is refused", ns.addItemMember(solo, { slotID = 13, itemID = 999 }) == false
        and #solo.members == 1 and solo.message == "Trinket 1 ready")
    check("adding a second member switches the generated default to {item} ready",
        ns.addItemMember(solo, { slotID = 14, itemID = 222 }) == true and #solo.members == 2 and solo.message == "{item} ready")
    check("a fixed item twice is refused, a slot member's last seen item does not count",
        ns.addItemMember(solo, { itemID = 555 }) == true and ns.addItemMember(solo, { itemID = 555 }) == false
        and ns.addItemMember(solo, { itemID = 111 }) == true and #solo.members == 4)
    local named = makeItemRule()
    check("generated item default switches too", ns.addItemMember(named, { itemID = 222 }) == true and named.message == "{item} ready")
    local custom2 = makeItemRule()
    custom2.message = "Trinket up!"
    ns.addItemMember(custom2, { itemID = 222 })
    check("a custom text stays when a member is added", custom2.message == "Trinket up!")

    -- Item <-> slot per member.
    local modes = makeItemRule()
    modes.members = { { itemID = 111 } }
    equipped[13], equipped[14] = 111, 222
    check("item member to slot mode takes the slot it sits in",
        ns.setItemMemberMode(modes, 1, true) == true and modes.members[1].slotID == 13 and modes.message == "Trinket 1 ready")
    check("slot member back to item mode keeps the carried item",
        ns.setItemMemberMode(modes, 1, false) == true and modes.members[1].slotID == nil
        and modes.members[1].itemID == 111 and modes.message == "Alpha ready")
    equipped[13] = 333
    local okMode, whyMode = ns.setItemMemberMode(modes, 1, true)
    check("item to slot mode needs the item equipped", okMode == false and whyMode == "not-equipped"
        and modes.members[1].slotID == nil)
    equipped[13] = 111

    -- Retarget: only the first member speaks for the rule.
    local multi = makeGroup()
    ns.retargetItemRule(multi, 2, 333, "Gamma", "iconG", 14)
    check("retargeting member 2 leaves rule name, icon and message alone",
        multi.members[2].itemID == 333 and multi.name == "Alpha" and multi.icon == nil and multi.message == "{item} ready")
    ns.retargetItemRule(multi, 1, 333, "Gamma", "iconG", 13)
    check("retargeting member 1 renames the rule after the slot", multi.name == "Trinket 1" and multi.icon == "iconG"
        and multi.members[1].itemID == 333 and multi.message == "{item} ready")

    -- Context helper for previews.
    equipped[13], equipped[14] = 111, 222
    local ctx = ns.itemRuleContext(makeGroup())
    check("preview context resolves the first member", ctx.item == "Alpha" and ctx.slot == "Trinket 1")
    check("rules without members have no preview context", ns.previewContext({ spellIDs = {} }) == nil)
    ns.showScreenText = realShowScreenText
end

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

-- One-line member rows: the name is plain (FontString colour), "· id" and a note are dimmed by a colour code.
check("member row text: name only", ns.memberRowText("Hoof") == "Hoof" and ns.memberRowText("Hoof", nil, "") == "Hoof")
check("member row text: name and id", ns.memberRowText("Hoof", 193762) == "Hoof |cff8c929a\194\183 193762|r")
check("member row text: name, id and note", ns.memberRowText("Unknown ID", 2825, "invalid") == "Unknown ID |cff8c929a\194\183 2825 \194\183 invalid|r")
check("member row text: nil name stays a string", ns.memberRowText(nil, 5) == " |cff8c929a\194\183 5|r")

-- On-screen text anchor: pure helpers.
do
    local function snapped(x, y, grid, free)
        local sx, sy = ns.snapScreenOffset(x, y, grid, free)
        return sx .. "," .. sy
    end
    check("snap: grid of 20, a line catches within 6 px", snapped(23, -47, 20) == "20,-47" and snapped(24, 26, 20) == "20,20")
    check("snap: farther than 6 px from every line stays where it is", snapped(7, -7, 20) == "7,-7" and snapped(27, 13, 20) == "27,13")
    check("snap: centre lines catch within 6 px", snapped(6, -6, 20) == "0,0" and snapped(-5, 5, 20) == "0,0")
    check("snap: each axis snaps on its own", snapped(5, 125, 20) == "0,120" and snapped(98, 3, 20) == "100,0")
    check("snap: exactly on the grid stays", snapped(120, -300, 20) == "120,-300")
    check("snap: free mode only rounds to whole pixels", snapped(23.4, -47.6, 20, true) == "23,-48" and snapped(2, 3, 20, true) == "2,3")
    check("snap: bad input is harmless (default grid 10)", snapped(nil, "x", 0) == "0,0" and snapped(13, 13, 0) == "10,10" and snapped(13, 13) == "10,10")
    check("snap: negative values mirror positive ones", snapped(-23, 47, 20) == "-20,47" and snapped(-5, -4, 20) == "0,0")
    check("snap: a wider grid (40) catches within 6 px of its lines", snapped(37, 50, 40) == "40,50" and snapped(46, 80, 40) == "40,80")
    check("snap: grid of 10 (the default), lines catch within 6 px, the centre wins",
        snapped(23, -47, 10) == "20,-50" and snapped(52, 3, 10) == "50,0" and snapped(6, -6, 10) == "0,0" and snapped(7, -7, 10) == "10,-10"
        and snapped(-14, 26, 10) == "-10,30" and snapped(120, -300, 10) == "120,-300")
    check("snap: grid of 10, Shift places freely", snapped(23.4, -47.6, 10, true) == "23,-48")
    check("grid step: 10 px (about 300 lines on 1920x1080), doubled above 400 lines",
        ns.screenGridStep(1920, 1080) == 10 and ns.screenGridStep(1280, 720) == 10 and ns.screenGridStep(nil, nil) == 10
        and ns.screenGridStep(2560, 1440) == 20 and ns.screenGridStep(3840, 2160) == 20 and ns.screenGridStep(7680, 4320) == 40)

    -- anchor mode ends with the window / combat: ns.endScreenAnchor locks the current target, nothing else
    local realUnlock, ended = ns.setScreenAnchorUnlocked, {}
    ns.setScreenAnchorUnlocked = function(frame, unlocked) ended[#ended + 1] = { frame, unlocked } end
    ns.screenAnchorTarget = nil
    ns.endScreenAnchor()
    check("endScreenAnchor: no target, no call", #ended == 0)
    local target = {}
    ns.screenAnchorTarget = target
    ns.endScreenAnchor()
    check("endScreenAnchor: locks the current target once", #ended == 1 and ended[1][1] == target and ended[1][2] == false)
    ns.setScreenAnchorUnlocked, ns.screenAnchorTarget = realUnlock, nil

    local w, h, wrap = ns.screenTextSize(100, 30, 1536)
    check("text size: padding 16 per side and 4 top/bottom", w == 132 and h == 38 and wrap == false)
    w, h, wrap = ns.screenTextSize(1504, 30, 1536)
    check("text size: exactly the maximum does not wrap", w == 1536 and wrap == false)
    w, h, wrap = ns.screenTextSize(1600, 30, 1536)
    check("text size: wider than 80 % of the screen is capped and wraps", w == 1536 and h == 38 and wrap == true)
    w, h, wrap = ns.screenTextSize(2000, 12, nil)
    check("text size: no maximum never wraps; empty text is just the padding", wrap == false and w == 2032 and select(1, ns.screenTextSize(0, 0, 100)) == 32)

    local cx, cy = ns.screenCenterOffset({ point = "CENTER", relativePoint = "CENTER", x = 12, y = -34 }, 1920, 1080)
    check("anchor CENTER/CENTER is already the frame centre", cx == 12 and cy == -34)
    cx, cy = ns.screenCenterOffset({ point = "TOPLEFT", relativePoint = "TOPLEFT", x = 10, y = -20 }, 1920, 1080)
    check("legacy TOPLEFT anchor of the 800x80 frame becomes a centre offset", cx == -550 and cy == 480, cx .. "," .. cy)
    cx, cy = ns.screenCenterOffset({ point = "BOTTOM", relativePoint = "BOTTOM", x = 0, y = 100 }, 1920, 1080)
    check("legacy BOTTOM anchor", cx == 0 and cy == -540 + 100 + 40, cx .. "," .. cy)
    cx, cy = ns.screenCenterOffset(nil, 1920, 1080)
    check("missing anchor falls back to the default (0, 120)", cx == 0 and cy == 120)
end

-- Screen notification frames are pooled by rule object and stale hide callbacks cannot affect a rebound frame.
do
    local realCreateFrame, realUIParent = CreateFrame, UIParent
    local realAfter = C_Timer.After
    local realGetProfile = ns.getRuleScreenProfile
    local realApplyStyle, realPosition = ns.applyScreenFrameStyle, ns.positionScreenFrame
    local realFrames, realPool = ns.screenFrames, ns.screenFramePool
    local callbacks, created = {}, 0
    local function newUIObject()
        local object = { scripts = {} }
        function object:SetSize() end
        function object:SetFrameStrata() end
        function object:SetFrameLevel() end
        function object:SetClampedToScreen() end
        function object:RegisterForDrag() end
        function object:SetAllPoints() end
        function object:SetBackdrop() end
        function object:SetBackdropColor() end
        function object:SetBackdropBorderColor() end
        function object:SetPoint() end
        function object:SetJustifyH() end
        function object:SetJustifyV() end
        function object:SetWordWrap() end
        function object:SetScript(name, callback) self.scripts[name] = callback end
        function object:EnableMouse(value) self.mouseEnabled = value end
        function object:Hide() self.shown = false end
        function object:Show() self.shown = true end
        function object:SetText(value) self.value = value end
        function object:CreateFontString()
            local font = newUIObject()
            return font
        end
        return object
    end
    CreateFrame = function()
        created = created + 1
        return newUIObject()
    end
    UIParent = {
        GetWidth = function() return 1920 end,
        GetHeight = function() return 1080 end,
    }
    C_Timer.After = function(_, callback) callbacks[#callbacks + 1] = callback end
    ns.screenFrames, ns.screenFramePool = {}, {}
    ns.getRuleScreenProfile = function(rule, eventKey)
        rule.screenProfiles = rule.screenProfiles or {}
        rule.screenProfiles[eventKey] = { enabled = true, text = rule.id }
        return rule.screenProfiles[eventKey]
    end
    ns.applyScreenFrameStyle = function() end
    ns.positionScreenFrame = function() end

    local first, duplicate = { id = "same" }, { id = "same" }
    local firstFrame = ns.getScreenFrame(first, "apply")
    local duplicateFrame = ns.getScreenFrame(duplicate, "apply")
    check("screen frames: duplicate rule IDs keep distinct frames",
        firstFrame ~= duplicateFrame and ns.screenFrames[first].apply == firstFrame
        and ns.screenFrames[duplicate].apply == duplicateFrame)
    ns.hideScreenFramesForRule(first)
    check("screen frames: release clears rule and drag references",
        firstFrame.rule == nil and firstFrame.eventKey == nil and firstFrame.drag == nil
        and firstFrame.mouseEnabled == false and firstFrame.scripts.OnUpdate == nil
        and firstFrame.scripts.OnDragStart == nil and firstFrame.scripts.OnDragStop == nil)

    local rebound = { id = "rebound", screenProfiles = { apply = { enabled = true, text = "old" } } }
    local oldShown = ns.showScreenText(rebound, "apply", "old")
    local oldHide = callbacks[1]
    local reboundFrame = ns.screenFrames[rebound] and ns.screenFrames[rebound].apply
    ns.hideScreenFramesForRule(rebound)
    local current = { id = "current", screenProfiles = { apply = { enabled = true, text = "new" } } }
    local newShown = ns.showScreenText(current, "apply", "new")
    local newHide = callbacks[2]
    local reusedFrame = ns.screenFrames[current] and ns.screenFrames[current].apply
    if oldHide then oldHide() end
    check("screen frames: stale hide callback cannot hide a rebound rule",
        oldShown and newShown and oldHide ~= nil and reusedFrame ~= nil and reusedFrame == reboundFrame
        and reusedFrame.rule == current and reusedFrame.text.value == "new"
        and reusedFrame.active and reusedFrame.shown,
        table.concat({ tostring(oldShown), tostring(newShown), tostring(oldHide ~= nil), tostring(newHide ~= nil),
            tostring(reusedFrame ~= nil), tostring(reusedFrame == reboundFrame),
            tostring(reusedFrame and reusedFrame.rule == current), tostring(reusedFrame and reusedFrame.text.value),
            tostring(reusedFrame and reusedFrame.active), tostring(reusedFrame and reusedFrame.shown) }, ","))
    if newHide then newHide() end
    check("screen frames: current hide callback still hides its own text",
        newHide ~= nil and reusedFrame ~= nil and not reusedFrame.active and not reusedFrame.shown)
    check("screen frames: repeated rule/profile cycles allocate no replacement frames",
        created == 4 and #ns.screenFramePool == 0)

    ns.clearScreenFrames()
    CreateFrame, UIParent, C_Timer.After = realCreateFrame, realUIParent, realAfter
    ns.getRuleScreenProfile = realGetProfile
    ns.applyScreenFrameStyle, ns.positionScreenFrame = realApplyStyle, realPosition
    ns.screenFrames, ns.screenFramePool = realFrames, realPool
end

-- Help tooltips: extra lines in order, a font override only where asked, reset by ns.resetTooltipFonts.
do
    local function newFontString(n)
        local fs = { n = n }
        function fs:SetFont(path, size, flags) self.font = path .. "|" .. size .. "|" .. flags end
        function fs:SetFontObject(object) self.font = nil; self.object = object end
        return fs
    end
    GameTooltipText = "default-tooltip-font"
    for n = 1, 12 do _G["GameTooltipTextLeft" .. n] = newFontString(n) end
    local function newTooltip()
        local tooltip = { lines = {} }
        function tooltip:SetText(text) self.lines = { { text = text } } end
        function tooltip:AddLine(text, r, g, b, wrap) self.lines[#self.lines + 1] = { text = text, r = r, g = g, b = b, wrap = wrap } end
        function tooltip:NumLines() return #self.lines end
        return tooltip
    end
    local brace = { "Fonts\\ARIALN.TTF", 13, "" }
    local tooltip = newTooltip()
    ns.fillHelpTooltip(tooltip, "Title", "Explanation", {
        { text = "{item} - first", font = brace },
        { text = "plain" },
        { text = "{slot} ready", r = 0.624, g = 0.878, b = 1, font = brace },
    })
    check("help tooltip: title, explanation, then the extra lines in order",
        #tooltip.lines == 5 and tooltip.lines[1].text == "Title" and tooltip.lines[2].text == "Explanation"
        and tooltip.lines[3].text == "{item} - first" and tooltip.lines[4].text == "plain" and tooltip.lines[5].text == "{slot} ready")
    check("help tooltip: only lines with a font entry get the override (lines 3 and 5)",
        GameTooltipTextLeft3.font == "Fonts\\ARIALN.TTF|13|" and GameTooltipTextLeft5.font == "Fonts\\ARIALN.TTF|13|"
        and GameTooltipTextLeft1.font == nil and GameTooltipTextLeft2.font == nil and GameTooltipTextLeft4.font == nil)
    check("help tooltip: extra line colour is passed on", tooltip.lines[5].r == 0.624 and tooltip.lines[5].b == 1 and tooltip.lines[4].r == 0.85)
    ns.resetTooltipFonts()
    check("help tooltip: reset hands the overridden lines back to the default font object",
        GameTooltipTextLeft3.font == nil and GameTooltipTextLeft3.object == "default-tooltip-font"
        and GameTooltipTextLeft5.object == "default-tooltip-font" and GameTooltipTextLeft4.object == nil)
    ns.resetTooltipFonts()
    check("help tooltip: reset twice is harmless", ns.tooltipFontLines == nil)
    -- a second tooltip resets the first one's overrides before it adds its own lines
    tooltip = newTooltip()
    ns.fillHelpTooltip(tooltip, "A", nil, { { text = "{x}", font = brace } })
    local overridden = GameTooltipTextLeft2.font ~= nil
    ns.fillHelpTooltip(newTooltip(), "B", "plain only")
    check("help tooltip: the next tooltip clears stale overrides", overridden and GameTooltipTextLeft2.font == nil)
    -- a font that cannot be set is skipped without error
    GameTooltipTextLeft2.SetFont = function() error("bad font") end
    local ok = pcall(ns.fillHelpTooltip, newTooltip(), "C", nil, { { text = "{y}", font = brace } })
    check("help tooltip: a failing SetFont is swallowed", ok and ns.tooltipFontLines == nil)
    check("help tooltip: old three-argument callers still work", pcall(ns.fillHelpTooltip, newTooltip(), "D", "text"))
end

-- Never-secret auras (Sated family): readable in combat, nil is a reliable "absent".
do
    local secrecyLevel = { [57724] = 0, [2825] = 2, [999] = 1 }
    C_Secrets = {
        ShouldAurasBeSecret = function() return true end,
        GetSpellAuraSecrecy = function(spellID) return secrecyLevel[spellID] end,
    }
    C_Spell = {
        IsSelfBuff = function() return false end,
        GetSpellInfo = function(spellID) return { name = "Spell " .. spellID, iconID = 1 } end,
    }
    check("auraSecrecy: 0 is never, 2 contextual, 1 always",
        ns._Aura.auraSecrecy(57724) == "never" and ns._Aura.auraSecrecy(2825) == "contextual"
        and ns._Aura.auraSecrecy(999) == "always")
    check("auraSecrecy: unlisted ID is unknown", ns._Aura.auraSecrecy(12345) == "unknown")
    local savedSecrets = C_Secrets
    C_Secrets = { ShouldAurasBeSecret = savedSecrets.ShouldAurasBeSecret }
    ns._Aura.secrecyCache = {}
    check("auraSecrecy: missing API is unknown", ns._Aura.auraSecrecy(57724) == "unknown")
    C_Secrets = savedSecrets
    ns._Aura.secrecyCache = {}

    C_VoiceChat = { SpeakText = function(_, message) table.insert(ttsMessages, message) end }
    ns.AuraSoundFallback.Refresh = function() end
    ns.AuraSoundFallback.LogAura = function() end
    local present = {}
    C_UnitAuras = {
        GetPlayerAuraBySpellID = function(spellID) return present[spellID] end,
    }
    local function newAuraRule(spellID)
        return {
            id = "sated", enabled = true, applyEnabled = true, applyMessage = "Hammer Time",
            expireEnabled = true, expireMessage = "Bloodlust ready", spellIDs = { spellID },
            alertCategory = "none", voiceID = 8, volume = 100, speechSpeed = 100,
            applySoundEnabled = false, expireSoundEnabled = false,
            applySoundChannel = "Master", expireSoundChannel = "Master", screenProfiles = {},
        }
    end
    local function setup(spellID)
        clearOutput()
        present = {}
        WoWraVoxDB = { auras = { newAuraRule(spellID) } }
        ns._Aura.syncAllAuras(true) -- baseline: nothing active
        runTimers()
        ttsMessages = {}
    end

    -- never secret: apply and expire are spoken although auras are secret (combat)
    setup(57724)
    present[57724] = { spellId = 57724, auraInstanceID = 1, expirationTime = 600 }
    ns._Aura.processAura(57724, false, "UNIT_AURA")
    runTimers()
    check("never-secret aura applies in combat", ttsMessages[1] == "Hammer Time", tostring(ttsMessages[1]))
    ttsMessages = {}
    present[57724] = nil
    now = 100 -- removed long before its expiry moment: early removal stays silent, state is cleared
    ns._Aura.processAura(57724, false, "UNIT_AURA")
    runTimers()
    check("never-secret early removal clears state without Expire", #ttsMessages == 0)
    present[57724] = { spellId = 57724, auraInstanceID = 2, expirationTime = 600 }
    ns._Aura.processAura(57724, false, "UNIT_AURA")
    runTimers()
    check("never-secret aura applies again after clearing", ttsMessages[#ttsMessages] == "Hammer Time")
    ttsMessages = {}
    present[57724] = nil
    now = 600
    ns._Aura.processAura(57724, false, "AURA_TIMER")
    runTimers()
    check("never-secret aura expires in combat", ttsMessages[1] == "Bloodlust ready", tostring(ttsMessages[1]))

    -- contextual: nil in combat stays unknown, nothing is spoken or cleared
    setup(2825)
    present[2825] = { spellId = 2825, auraInstanceID = 3, expirationTime = 600 }
    ns._Aura.processAura(2825, false, "UNIT_AURA")
    runTimers()
    ttsMessages = {}
    present[2825] = nil
    now = 100
    ns._Aura.processAura(2825, false, "UNIT_AURA")
    runTimers()
    check("contextual aura: nil in combat is unknown, no output", #ttsMessages == 0)
end

-- One-effect rules (Bloodlust buffs + Sated debuffs), built-in rules and the /wvdebug sim playback.
do
    local queue = {}
    C_Timer = {
        After = function(delay, callback) table.insert(queue, { at = now + delay, cb = callback }) end,
        NewTimer = function(delay, callback)
            local timer = { at = now + delay, cb = callback, isExpiry = true }
            function timer:Cancel() self.cancelled = true end
            table.insert(queue, timer)
            return timer
        end,
    }
    local function advance(untilTime)
        while true do
            local bestIndex
            for index, item in ipairs(queue) do
                if not item.cancelled and item.at <= untilTime and (not bestIndex or item.at < queue[bestIndex].at) then bestIndex = index end
            end
            if not bestIndex then break end
            local item = table.remove(queue, bestIndex)
            if item.at > now then now = item.at end
            item.cb()
        end
        now = untilTime
    end
    local chat = {}
    DEFAULT_CHAT_FRAME = { AddMessage = function(_, line) table.insert(chat, line) end }
    InCombatLockdown = function() return false end
    C_Secrets = {
        ShouldAurasBeSecret = function() return true end,
        GetSpellAuraSecrecy = function(spellID) return spellID == 57724 and 0 or 2 end,
    }
    C_Spell = { IsSelfBuff = function(spellID) return selfBuffIDs[spellID] == true end,
        GetSpellInfo = function(spellID) return { name = "Spell " .. spellID, iconID = 1 } end }
    C_VoiceChat = { SpeakText = function(_, message) table.insert(ttsMessages, message) end }
    ns.AuraSoundFallback.Refresh = function() end
    ns.AuraSoundFallback.LogAura = function() end
    ns.Defaults = { auras = { {
        presetID = "heroism-bloodlust", builtin = true, oneEffect = true, enabled = true,
        spellIDs = { 2825, 57724 }, applyEnabled = true, applyMessage = "Bloodlust",
        expireEnabled = true, expireMessage = "Bloodlust ready",
    } } }

    local function bloodlustRule(oneEffect)
        return {
            id = "bl", presetID = "heroism-bloodlust", builtin = true, oneEffect = oneEffect, enabled = true,
            spellIDs = { 2825, 57724 }, applyEnabled = true, applyMessage = "Bloodlust",
            expireEnabled = true, expireMessage = "Bloodlust ready", alertCategory = "none",
            voiceID = 8, volume = 100, speechSpeed = 100, applySoundEnabled = false, expireSoundEnabled = false,
            applySoundChannel = "Master", expireSoundChannel = "Master", screenProfiles = {},
        }
    end
    local function reset(rule)
        clearOutput()
        queue = {}
        chat = {}
        ttsMessages = {}
        ns._Aura.sim = nil
        ns._Aura.clearActiveState()
        WoWraVoxDB = { auras = { rule } }
        ns._Aura.syncAllAuras(true)
        ttsMessages = {}
    end
    local function expiryTimers()
        local timers = {}
        for _, timer in ipairs(queue) do
            if timer.isExpiry and not timer.cancelled then timers[#timers + 1] = timer end
        end
        return timers
    end

    -- ensureBuiltinRules
    local list = {}
    ns.ensureBuiltinRules(list)
    check("builtin rule is created when missing",
        #list == 1 and list[1].presetID == "heroism-bloodlust" and list[1].builtin and list[1].oneEffect
        and list[1].enabled == true and list[1].id == "builtin-heroism-bloodlust")
    local old = { presetID = "heroism-bloodlust", enabled = false, spellIDs = { 2825 }, expireMessage = "mine" }
    local oldList = { old }
    ns.ensureBuiltinRules(oldList)
    ns.ensureBuiltinRules(oldList)
    check("existing preset rule gains the missing IDs, keeps the user's settings, stays one rule",
        #oldList == 1 and #old.spellIDs == 2 and old.spellIDs[2] == 57724 and old.expireMessage == "mine"
        and old.enabled == false and old.builtin and old.oneEffect)
    check("builtin trigger lookup", ns.isBuiltinTrigger(old, 57724) and not ns.isBuiltinTrigger(old, 1)
        and not ns.isBuiltinTrigger({ spellIDs = {} }, 57724))

    -- Startup selection: keep a live selection, otherwise prefer stable Bloodlust identity and fall back by category.
    local bloodlust = { presetID = "heroism-bloodlust", builtin = true }
    local firstAura = { name = "First aura" }
    local firstItem = { name = "First item" }
    local firstSkill = { name = "First skill" }
    WoWraVoxDB = { auras = { bloodlust, firstAura }, items = { firstItem }, skills = { firstSkill } }
    local category, aura, item, skill = ns.SelectInitialRule()
    check("startup selects built-in Bloodlust by stable identity",
        category == "auras" and aura == bloodlust and item == firstItem and skill == firstSkill)
    local sameCategory, sameAura = ns.SelectInitialRule()
    check("startup preserves valid aura selection", sameCategory == "auras" and sameAura == bloodlust)

    WoWraVoxDB.auras = { firstAura }
    local fallbackCategory, fallbackAura = ns.SelectInitialRule()
    check("startup falls back to first aura when Bloodlust is missing",
        fallbackCategory == "auras" and fallbackAura == firstAura)

    WoWraVoxDB.auras = {}
    local itemCategory, _, selectedItem = ns.SelectInitialRule()
    check("startup falls back to first item when no aura exists",
        itemCategory == "items" and selectedItem == firstItem)

    WoWraVoxDB.auras = { bloodlust }
    local keptItemCategory, _, keptItem = ns.SelectInitialRule()
    check("startup preserves valid item selection when aura list changes",
        keptItemCategory == "items" and keptItem == firstItem)

    ns.ShowAddRuleView()
    local profileBloodlust = { presetID = "heroism-bloodlust", builtin = true }
    local profileItem = { name = "Profile item" }
    WoWraVoxDB = { auras = { profileBloodlust }, items = { profileItem }, skills = {} }
    local addCategory, addAura, addItem = ns.SelectInitialRule()
    check("profile switch repairs stale selection while add view stays open",
        addCategory == "auras" and addAura == profileBloodlust and addItem == profileItem)
    ns.CancelAddRuleView()
    local cancelCategory, cancelAura = ns.SelectInitialRule()
    check("cancel after add view opens repaired rule", cancelCategory == "auras" and cancelAura == profileBloodlust)

    local present = {}
    C_UnitAuras = { GetPlayerAuraBySpellID = function(spellID) return present[spellID] end }
    C_Secrets.ShouldAurasBeSecret = function() return false end

    -- Expiry scheduling is deduplicated and cancellable when an aura changes or is removed.
    do
        reset(bloodlustRule(false))
        now = 20
        present[2825] = { spellId = 2825, auraInstanceID = 50, expirationTime = 50 }
        ns._Aura.processAura(2825, true, "BASELINE_SYNC")
        local original = expiryTimers()[1]
        ns._Aura.processAura(2825, true, "BASELINE_SYNC")
        check("aura expiry: unchanged instance and expiration reuse one timer",
            original ~= nil and #expiryTimers() == 1 and original.cancelled ~= true)

        present[2825].expirationTime = 51
        ns._Aura.processAura(2825, true, "BASELINE_SYNC")
        local replacement = expiryTimers()[1]
        check("aura expiry: changed expiration cancels and replaces its timer",
            original.cancelled == true and replacement ~= original and #expiryTimers() == 1)

        present[2825] = nil
        ns._Aura.processAura(2825, true, "BASELINE_SYNC")
        check("aura expiry: removal cancels its timer", replacement.cancelled == true and #expiryTimers() == 0)

        present[2825] = { spellId = 2825, auraInstanceID = 51, expirationTime = 70 }
        ns._Aura.processAura(2825, true, "BASELINE_SYNC")
        local beforeRefresh = expiryTimers()[1]
        ns.RefreshRuleActivationState()
        local afterRefresh = expiryTimers()[1]
        check("aura expiry: spec activation cancels stale timer and schedules one current timer",
            beforeRefresh and beforeRefresh.cancelled == true and afterRefresh ~= beforeRefresh and #expiryTimers() == 1)
        present[2825] = nil
        ns._Aura.processAura(2825, true, "BASELINE_SYNC")
    end

    -- core: one effect, both readable
    now = 0
    reset(bloodlustRule(true))
    present[2825] = { spellId = 2825, auraInstanceID = 1, expirationTime = 40 }
    present[57724] = { spellId = 57724, auraInstanceID = 2, expirationTime = 600 }
    ns._Aura.processAura(2825, false, "UNIT_AURA")
    ns._Aura.processAura(57724, false, "UNIT_AURA")
    advance(0.5)
    check("one effect: buff and debuff together announce the start once",
        #ttsMessages == 1 and ttsMessages[1] == "Bloodlust", #ttsMessages)
    ttsMessages = {}
    present[2825] = nil
    advance(40.5)
    check("one effect: the buff ending is silent while the debuff runs", #ttsMessages == 0)
    present[57724] = nil
    advance(601)
    check("one effect: the debuff ending announces the end once",
        #ttsMessages == 1 and ttsMessages[1] == "Bloodlust ready", #ttsMessages)

    -- without the option every trigger announces on its own
    reset(bloodlustRule(false))
    now = 1000
    present = { [2825] = { spellId = 2825, auraInstanceID = 1, expirationTime = 1040 },
        [57724] = { spellId = 57724, auraInstanceID = 2, expirationTime = 1600 } }
    ns._Aura.processAura(2825, false, "UNIT_AURA")
    ns._Aura.processAura(57724, false, "UNIT_AURA")
    advance(1000.5)
    check("without the option both triggers announce (joined into one call)",
        #ttsMessages == 1 and ttsMessages[1] == "Bloodlust. Bloodlust", tostring(ttsMessages[1]))

    -- own cast first, readable debuff a moment later: one start
    present = {}
    reset(bloodlustRule(true))
    now = 2000
    C_Secrets.ShouldAurasBeSecret = function() return true end
    selfBuffIDs[2825] = true
    ns._Aura.handleCast("player", "guid-bl", 2825)
    advance(2000.2)
    present[57724] = { spellId = 57724, auraInstanceID = 2, expirationTime = 2600 }
    ns._Aura.processAura(57724, false, "UNIT_AURA")
    advance(2000.6)
    check("own cast then its Sated debuff: the start is spoken once", #ttsMessages == 1, #ttsMessages)
    selfBuffIDs[2825] = nil

    -- category word: one-effect rule with a readable trigger registers it for no ID (policy lives in AuraSoundFallback)
    -- /wvdebug sim
    present = {}
    reset(bloodlustRule(true))
    now = 3000
    ns.Simulation.Start()
    advance(3040)
    local verdict = chat[#chat] or ""
    check("sim: one-effect rule passes both scenarios", verdict:find("PASS", 1, true) ~= nil, table.concat(chat, " | "))
    check("sim: simulation hook is removed afterwards", ns._Aura.sim == nil)
    reset(bloodlustRule(false))
    now = 4000
    ns.Simulation.Start()
    advance(4040)
    print("INFO sim output: " .. table.concat(chat, " | "))
    check("sim: a rule without one-effect fails the check (double start)",
        (chat[#chat] or ""):find("FAIL", 1, true) ~= nil, table.concat(chat, " | "))
    reset(bloodlustRule(true))
    ns.Simulation.Start()
    ns.Simulation.Stop()
    check("sim: stop aborts and cleans up", ns._Aura.sim == nil)
end

-- Slot rules are named after the slot, not after the trinket that sits there.
do
    local itemNames = { [193762] = "Blazebinder's Hoof", [242395] = "Astral Antenna" }
    GetItemInfo = function(itemID) return itemNames[itemID] end
    GetInventoryItemTexture = function() return 1 end
    local worn = { [13] = 242395 }
    GetInventoryItemID = function(_, slotID) return worn[slotID] end

    local rule = { name = "Blazebinder's Hoof", members = { { itemID = 193762, slotID = 13 } } }
    ns.nameSlotRule(rule)
    check("slot rule saved with the item's name is renamed to the slot", rule.name == "Trinket 1", rule.name)
    ns.nameSlotRule(rule)
    check("renaming a slot rule twice changes nothing", rule.name == "Trinket 1")

    local rewritten = { name = "Astral Antenna", members = { { itemID = 193762, slotID = 13 } } }
    ns.nameSlotRule(rewritten)
    check("the name of the item sitting in the slot now is replaced too", rewritten.name == "Trinket 1")

    local custom = { name = "My trinket", members = { { itemID = 193762, slotID = 13 } } }
    ns.nameSlotRule(custom)
    check("a name the user typed is kept", custom.name == "My trinket")

    local exact = { name = "Blazebinder's Hoof", members = { { itemID = 193762 } } }
    ns.nameSlotRule(exact)
    check("a rule for one exact item keeps the item's name", exact.name == "Blazebinder's Hoof")

    local starter = { starter = "trinket", name = "Add a trinket", members = {} }
    ns.retargetItemRule(starter, 1, 242395, "Astral Antenna", 1, 13)
    check("picking a trinket for the starter names the rule after the slot",
        starter.name == "Trinket 1" and starter.message == "Trinket 1 ready", starter.name .. " / " .. tostring(starter.message))
    local exactPick = { starter = "trinket", name = "Add a trinket", members = {} }
    ns.retargetItemRule(exactPick, 1, 242395, "Astral Antenna", 1, nil)
    check("picking one exact item keeps the item's name", exactPick.name == "Astral Antenna")
end

-- Shipped starter set: Bloodlust, one rule per trinket slot, nothing else.
do
    ns.Defaults = ns.RealDefaults
    local db = ns.CreateStarterDatabase()
    check("starter: exactly one aura rule (Bloodlust)", #db.auras == 1)
    local bl = db.auras[1]
    check("starter: Bloodlust is built in, one effect, with buffs and Sated debuffs",
        bl.presetID == "heroism-bloodlust" and bl.builtin and bl.oneEffect and bl.enabled and #bl.spellIDs == 13)
    check("starter: fallback category is on and no empty defensives rule remains",
        bl.alertCategory == "bloodlust")
    check("starter: no skill rules", #db.skills == 0)
    check("starter: exactly two item rules, one per trinket slot", #db.items == 2
        and db.items[1].members[1].slotID == 13 and db.items[2].members[1].slotID == 14
        and db.items[1].members[1].itemID == nil and #db.items[1].members == 1)
    check("starter: trinket rules are named and worded after the slot",
        db.items[1].name == "Trinket 1" and db.items[1].message == "Trinket 1 ready"
        and db.items[2].name == "Trinket 2" and db.items[2].message == "Trinket 2 ready")
    check("starter: the old 'Add a trinket' placeholder is gone",
        db.items[1].starter == nil and db.items[2].starter == nil)
    local item = db.items[1]
    ns.normalizeItemRule(item)
    check("starter: a slot member without an item survives normalizing",
        #item.members == 1 and item.members[1].slotID == 13 and ns.isEmptyStarter(item) == false)
    ns.nameSlotRule(item)
    check("starter: naming the slot rule keeps the slot name", item.name == "Trinket 1")
end

-- expireCategory normalizing and the one-time category switch for an existing built-in rule.
do
    local rule = { alertCategory = "Bloodlust", expireCategory = "Defensive cooldown" }
    ns.normalizeNotificationSettings(rule, "auras")
    check("expireCategory accepts the same values as alertCategory", rule.alertCategory == "bloodlust" and rule.expireCategory == "defensive")
    local bare = {}
    ns.normalizeNotificationSettings(bare, "auras")
    check("expireCategory defaults to none for aura rules", bare.expireCategory == "none")
    local item = {}
    ns.normalizeNotificationSettings(item, "items")
    check("item rules get no expireCategory", item.expireCategory == nil)
    ns.Defaults = ns.RealDefaults
    local old = { presetID = "heroism-bloodlust", alertCategory = "none", spellIDs = { 2825 } }
    local list = { old }
    ns.ensureBuiltinRules(list)
    check("existing built-in rule gets the fallback cue once", old.alertCategory == "bloodlust" and old.builtinCategorySet == true)
    old.alertCategory = "none" -- the user switched it off on purpose
    ns.ensureBuiltinRules(list)
    check("the user's later choice is kept", old.alertCategory == "none")
end

-- /wvdebug report: bounded copy text contains useful public facts while omitting identity and custom data.
do
    local names = { [264735] = "Survival of the Fittest", [281195] = "Survival of the Fittest", [186265] = "Aspect of the Turtle" }
    C_Spell = {
        IsSelfBuff = function(spellID) return spellID == 264735 or spellID == 186265 end,
        GetSpellName = function(spellID) return names[spellID] end,
        GetSpellInfo = function(spellID) return { name = names[spellID] or ("Spell " .. spellID), iconID = 1 } end,
    }
    C_Secrets = { ShouldAurasBeSecret = function() return true end, GetSpellAuraSecrecy = function() return 2 end }
    InCombatLockdown = function() return true end
    GetBuildInfo = function() return "12.0.5", "99999" end
    UnitClass = function() return "Hunter", "HUNTER" end
    UnitName = function() return "Tester" end
    GetSpecialization = function() return 1 end
    GetSpecializationInfo = function() return 253, "Beast Mastery" end
    IsPlayerSpell = function(spellID) return spellID == 264735 end
    C_UnitAuras = { GetAuraDataByIndex = function() return nil end }
    ns.AuraSoundFallback.IsRegistered = function() return false end
    ns.AuraSoundFallback.GetStatus = function() return { wanted = 2, registered = 1 } end
    ns.AuraSoundFallback.GetLogLines = function() return { "private debug entry" } end
    WoWraVoxDB = { auras = { { name = "Defensives", enabled = true, applyEnabled = true, expireEnabled = false,
        alertCategory = "defensive", spellIDs = { 281195, 186265 } } } }
    WoWraVoxProfilesDB = { privateProfileMarker = "other profile custom message" }

    ns.DebugReport.NoteCast("player", 264735)
    ns.DebugReport.NoteCast("player", 186265)
    ns.DebugReport.NoteCast("target", 777)
    ns.DebugReport.NoteAura(281195)
    ns.DebugReport.NoteNotify(WoWraVoxDB.auras[1], "apply", "custom SecretMessage", 281195,
        "UNIT_SPELLCAST_SUCCEEDED", "apply")
    local text = table.concat(ns.DebugReport.Build(), "\n")
    local lineCount = 1
    for _ in text:gmatch("\n") do lineCount = lineCount + 1 end
    check("report keeps useful aura facts with a pseudonymous rule label",
        text:find("rule%-%d+ · active=true") ~= nil
        and text:find("281195 Survival of the Fittest · secrecy=contextual · selfbuff=false · castable=false", 1, true) ~= nil, text)
    check("a cast with a different ID but the same name is found by name",
        text:find("264735 Survival of the Fittest · selfbuff=true", 1, true) ~= nil
        and text:find("byName=%[rule%-%d+:281195%]") ~= nil)
    check("a cast with the rule's own ID is found by ID", text:find("186265 Aspect of the Turtle · selfbuff=true", 1, true) ~= nil
        and text:find("byID=%[rule%-%d+%]") ~= nil)
    check("casts of other units are not recorded", text:find("777 ", 1, true) == nil)
    table.insert(WoWraVoxDB.auras, { name = "Bundled", enabled = true, spellIDs = { 389539 },
        castByAuraID = { [389539] = 31884 } })
    ns.DebugReport.NoteCast("player", 31884)
    local bundledText = table.concat(ns.DebugReport.Build(), "\n")
    check("a cast of a bundled cast ID is found by ID through the rule's cast map",
        bundledText:find("31884 ? · selfbuff=false · combat=true · secret=true · byID=[rule-", 1, true) ~= nil, bundledText)
    table.remove(WoWraVoxDB.auras)
    check("report anonymizes identity and omits names, messages, profiles, and raw log", text:find("PRIVACY:", 1, true) ~= nil
        and text:find("Tester", 1, true) == nil and text:find("Defensives", 1, true) == nil
        and text:find("SecretMessage", 1, true) == nil and text:find("other profile custom message", 1, true) == nil
        and text:find("private debug entry", 1, true) == nil and text:find("WoWraVox.lua", 1, true) == nil)
    check("report content is bounded", #text <= 14000 and lineCount <= 240, #text .. " chars / " .. lineCount .. " lines")
    local reloaded = false
    ReloadUI = function() reloaded = true end
    local profileDB = WoWraVoxProfilesDB
    local showCalls, realShowText = {}, ns.SkillTracking.ShowText
    ns.SkillTracking.ShowText = function(title, contents)
        showCalls[#showCalls + 1] = { title = title, contents = contents }
        return true
    end
    check("in combat report opens the copy window without saving profiles", ns.DebugReport.Run() == true
        and #showCalls == 1 and showCalls[1].title == "Diagnostic report" and not reloaded
        and WoWraVoxProfilesDB == profileDB and WoWraVoxProfilesDB.privateProfileMarker == "other profile custom message"
        and WoWraVoxProfilesDB.debugReport == nil)
    InCombatLockdown = function() return false end
    check("out of combat report also opens the copy window without reload or profile write", ns.DebugReport.Run() == true
        and #showCalls == 2 and not reloaded and WoWraVoxProfilesDB == profileDB and WoWraVoxProfilesDB.debugReport == nil)
    ns.SkillTracking.ShowText = function() error("UI unavailable") end
    check("report UI failure is contained", ns.DebugReport.Run() == false and not reloaded)
    ns.SkillTracking.ShowText = nil
    check("missing report UI is contained", ns.DebugReport.Run() == false and not reloaded)
    ns.SkillTracking.ShowText = realShowText
    ReloadUI = nil
end

-- report: announcements and hidden aura events are recorded too.
do
    local rule = { name = "Defensives" }
    ns.DebugReport.NoteNotify(rule, "apply", "Protected", 5384, "UNIT_SPELLCAST_SUCCEEDED", "apply")
    ns.DebugReport.NoteAura(nil, "payload hidden")
    ns.DebugReport.NoteAura(nil, "payload hidden")
    local text = table.concat(ns.DebugReport.Build(), "\n")
    check("report lists notification cause without custom rule names or messages",
        text:find("rule=rule%-%d+ event=apply spell=5384 source=UNIT_SPELLCAST_SUCCEEDED via=apply") ~= nil
        and text:find("Defensives", 1, true) == nil and text:find("Protected", 1, true) == nil)
    check("hidden aura events are listed once per burst",
        select(2, text:gsub("%(payload hidden%)", "")) == 1)
end

-- UNIT_AURA also works when DebugReport is not loaded.
do
    local realReport, realHandleEvent = ns.DebugReport, ns.SkillTracking.HandleEvent
    ns.DebugReport = nil
    ns.SkillTracking.HandleEvent = function() end
    local ok, err
    ok, err = pcall(ns.onEvent, ns.eventFrame, "UNIT_AURA", "player", { isFullUpdate = true })
    check("aura event works without DebugReport", ok, tostring(err))
    ok, err = pcall(ns.onEvent, ns.eventFrame, "UNIT_AURA", "player", { isFullUpdate = false, addedAuras = { { spellId = 204018 } },
        updatedAuraInstanceIDs = {}, removedAuraInstanceIDs = {} })
    check("aura delta event works without DebugReport", ok, tostring(err))
    runTimers()
    ns.DebugReport = realReport
    ns.SkillTracking.HandleEvent = realHandleEvent
end

-- An aura applied in combat (hidden: the query answers nil) must not be announced as new once it becomes
-- readable after combat; a genuinely new application later still is.
do
    C_Secrets = { ShouldAurasBeSecret = function() return true end, GetSpellAuraSecrecy = function() return 2 end }
    InCombatLockdown = function() return true end
    C_Spell = { IsSelfBuff = function() return false end,
        GetSpellInfo = function(spellID) return { name = "Spell " .. spellID, iconID = 1 } end }
    C_VoiceChat = { SpeakText = function(_, message) table.insert(ttsMessages, message) end }
    C_Timer = { After = function(_, callback) table.insert(timerCallbacks, callback) end }
    local live = {}
    C_UnitAuras = { GetPlayerAuraBySpellID = function(spellID) return live[spellID] end }
    local sotf = { name = "Defensives", id = "d", enabled = true, applyEnabled = true, applyMessage = "Def CD",
        expireEnabled = false, spellIDs = { 264735 }, alertCategory = "defensive", voiceID = 8, volume = 100,
        speechSpeed = 100, applySoundEnabled = false, expireSoundEnabled = false, applySoundChannel = "Master",
        expireSoundChannel = "Master", screenProfiles = {} }
    clearOutput()
    local spoken = {}
    local realNotify = ns.DebugReport.NoteNotify
    ns.DebugReport.NoteNotify = function(_, _, message, _, source) table.insert(spoken, message .. "@" .. tostring(source)) end
    WoWraVoxDB = { auras = { sotf } }
    ns._Aura.syncAllAuras(true)
    ttsMessages = {}
    now = 100
    -- cast in combat: the aura exists but the query answers nil
    ns._Aura.processAura(264735, false, "FULL_SYNC")
    -- combat ends while the aura is still active and becomes readable
    InCombatLockdown = function() return false end
    C_Secrets.ShouldAurasBeSecret = function() return false end
    live[264735] = { spellId = 264735, auraInstanceID = 7, expirationTime = now + 4 }
    ns._Aura.processAura(264735, false, "FULL_SYNC")
    runTimers(); runTimers(); runTimers()
    check("an aura applied in combat is not announced late when it turns readable", #spoken == 0, tostring(spoken[1]))
    -- it ends, then a new application is announced normally
    live[264735] = nil
    now = 105
    ns._Aura.processAura(264735, false, "AURA_TIMER")
    live[264735] = { spellId = 264735, auraInstanceID = 8, expirationTime = now + 6 }
    now = 120
    ns._Aura.processAura(264735, false, "UNIT_AURA")
    runTimers(); runTimers(); runTimers()
    check("a new application out of combat is announced", #spoken == 1 and spoken[1] == "Def CD@UNIT_AURA", tostring(spoken[1]))
    ns.DebugReport.NoteNotify = realNotify
end

-- WoW's native category word is the announcement: no TTS on top of it (it would come later and confuse).
do
    local spokenTTS = {}
    local realQueue = ns._Aura.queueTTS
    ns._Aura.queueTTS = function(_, message) table.insert(spokenTTS, message); return true, "queued" end
    local rule = { name = "Defensives", id = "d2", enabled = true, applyEnabled = true, applyMessage = "Def CD",
        expireEnabled = true, expireMessage = "Def over", spellIDs = { 264735 }, alertCategory = "defensive",
        expireCategory = "none", voiceID = 8, volume = 100, speechSpeed = 100, applySoundEnabled = false,
        expireSoundEnabled = false, applySoundChannel = "Master", expireSoundChannel = "Master", screenProfiles = {} }
    local registeredNative = { apply = true, expire = false }
    ns.AuraSoundFallback.IsRegistered = function(_, eventKey) return registeredNative[eventKey] == true end
    ns.AuraSoundFallback.GetCategorySoundFile = function(category) return category ~= "none" and "word.ogg" or nil end
    WoWraVoxDB = { auras = { rule } }
    ns._Aura.syncAllAuras(true)
    -- drive the apply through the real path: an aura appears while auras are readable
    C_Secrets = { ShouldAurasBeSecret = function() return false end, GetSpellAuraSecrecy = function() return 2 end }
    local live = { [264735] = { spellId = 264735, auraInstanceID = 31, expirationTime = 0 } }
    C_UnitAuras = { GetPlayerAuraBySpellID = function(spellID) return live[spellID] end }
    ns._Aura.processAura(264735, false, "UNIT_AURA")
    check("the native category word announces the application, no TTS on top", #spokenTTS == 0, tostring(spokenTTS[1]))
    registeredNative.apply = false
    live[264735] = nil
    ns._Aura.processAura(264735, false, "UNIT_AURA")
    live[264735] = { spellId = 264735, auraInstanceID = 32, expirationTime = 0 }
    now = now + 10
    ns._Aura.processAura(264735, false, "UNIT_AURA")
    check("without a registered native word the application is spoken", #spokenTTS == 1 and spokenTTS[1] == "Def CD", tostring(spokenTTS[1]))
    ns._Aura.queueTTS = realQueue
end
