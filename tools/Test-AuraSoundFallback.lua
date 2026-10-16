-- Fengari harness for AuraSoundFallback.lua: which native aura sounds get registered with WoW.
-- Policy: category word on Added (not for own self-buffs), selected media tones on Added/Removed,
-- nothing else. No generic tone, no addon-side cue.

local timers = {}
local added = {}
local removed = {}
local selfBuff = {}
local neverSecret = {}
local inCombat = false
local failRegistration = false
local failRemoval = false
local failRemovalCount = 0
local removalAttempts = 0
local liveSounds = {}
local mediaPaths = { Foo = "media\\foo.ogg", Bar = "media\\bar.ogg" }

local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. detail) or "")) end
    print("PASS " .. name)
end

function wipe(value)
    for key in pairs(value) do value[key] = nil end
end
function date() return "00:00:00" end
function GetTime() return 0 end
function InCombatLockdown() return inCombat end
local restrictionFrame
function CreateFrame()
    local frame = {}
    restrictionFrame = frame
    function frame:RegisterEvent() end
    function frame:SetScript(_, callback) self.onEvent = callback end
    return frame
end
C_Timer = { After = function(_, callback) table.insert(timers, callback) end }
Enum = { UnitAuraSoundTrigger = { Added = 1, Removed = 2 },
    AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5 },
    AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 } }
local restrictionStates = {}
local restrictionQueryError = false
C_RestrictedActions = { GetAddOnRestrictionState = function(kind)
    if restrictionQueryError then error("restriction query unavailable") end
    return restrictionStates[kind] or Enum.AddOnRestrictionState.Inactive
end }
local nextSoundID = 0
C_UnitAuras = {
    AddAuraSound = function(trigger, info)
        if failRegistration then return nil end
        nextSoundID = nextSoundID + 1
        local sound = { id = nextSoundID, trigger = trigger, spellID = info.spellID,
            file = info.soundFileName, channel = info.outputChannel }
        table.insert(added, sound)
        liveSounds[nextSoundID] = sound
        return nextSoundID
    end,
    RemoveAuraSound = function(id)
        removalAttempts = removalAttempts + 1
        if failRemoval or failRemovalCount > 0 then
            if failRemovalCount > 0 then failRemovalCount = failRemovalCount - 1 end
            error("injected removal failure")
        end
        table.insert(removed, id)
        liveSounds[id] = nil
    end,
}
-- LibStub is a function here on purpose: AuraSoundFallback only resolves media when type(LibStub) == "function".
LibStub = function()
    return { Fetch = function(_, _, name) return mediaPaths[name] end }
end

-- ==== MODULE ====

ns._Aura = {
    getSelfBuffStatus = function(spellID) return selfBuff[spellID] and "true" or "false" end,
    castIDFor = function(rule, auraID) return rule and rule.castByAuraID and rule.castByAuraID[auraID] or auraID end,
    addonCanSpeak = function(spellID, rule) return selfBuff[ns._Aura.castIDFor(rule, spellID)] == true end,
    cueFor = function(rule, spellID)
        if type(rule) ~= "table" then return "none" end
        if rule.alertCategory ~= nil and rule.alertCategory ~= "none" then return rule.alertCategory end
        return rule.categoryByAuraID and rule.categoryByAuraID[spellID] or "none"
    end,
    auraSecrecy = function(spellID) return neverSecret[spellID] and "never" or "contextual" end,
}
local fallback = ns.AuraSoundFallback

local function refresh(rules)
    added, removed, timers = {}, {}, {}
    fallback.Refresh(rules, true)
    while #timers > 0 do
        local pending = timers
        timers = {}
        for _, callback in ipairs(pending) do callback() end
    end
end

local function registered(spellID, trigger)
    for _, entry in ipairs(added) do
        if entry.spellID == spellID and entry.trigger == trigger then return entry end
    end
end

local function liveCount()
    local count = 0
    for _ in pairs(liveSounds) do count = count + 1 end
    return count
end

local function rule(fields)
    local result = { enabled = true, alertCategory = "none", spellIDs = { 100 }, applyEnabled = false,
        expireEnabled = false, applySoundEnabled = false, expireSoundEnabled = false,
        applySoundChannel = "Master", expireSoundChannel = "Master", screenProfiles = {} }
    for key, value in pairs(fields) do result[key] = value end
    return result
end

local ADDED, REMOVED = Enum.UnitAuraSoundTrigger.Added, Enum.UnitAuraSoundTrigger.Removed
local DEFENSIVE = fallback.categorySoundFiles.defensive
local LOVE = fallback.categorySoundFiles["somebody-loves-you"]

check("generic tone and addon-side cue are gone", fallback.soundFile == nil and fallback.enabled == nil
    and fallback.SetEnabled == nil and fallback.TestSound == nil and fallback.PlayApplicationCue == nil)

selfBuff = { [200] = true }
refresh({ rule({ alertCategory = "defensive", applyEnabled = true, spellIDs = { 100, 200 } }) })
check("category word registered for a non-self-buff aura",
    registered(100, ADDED) and registered(100, ADDED).file == DEFENSIVE)
check("category word suppressed for a self-buff aura", registered(200, ADDED) == nil)
check("category word is never registered for expiration", registered(100, REMOVED) == nil)

selfBuff = { [201] = true }
refresh({ rule({ alertCategory = "defensive", applyEnabled = true, spellIDs = { 201 } }) })
check("addonCanSpeak suppresses the category word", registered(201, ADDED) == nil)
selfBuff = {}
refresh({ rule({ alertCategory = "defensive", applyEnabled = true, spellIDs = { 201 } }) })
check("without addonCanSpeak the category word stays", registered(201, ADDED) ~= nil)
-- A preset rule bundles aura 389539 with cast 31884: the native word follows the cast's self-buff status.
selfBuff = { [31884] = true }
refresh({ rule({ alertCategory = "defensive", applyEnabled = true, spellIDs = { 389539 },
    castByAuraID = { [389539] = 31884 } }) })
check("category word suppressed when the bundled cast is a self buff", registered(389539, ADDED) == nil)
selfBuff = {}
refresh({ rule({ alertCategory = "defensive", applyEnabled = true, spellIDs = { 389539 },
    castByAuraID = { [389539] = 31884 } }) })
check("category word stays when the bundled cast is not a self buff", registered(389539, ADDED) ~= nil)
selfBuff = { [31884] = true }
refresh({ rule({ alertCategory = "defensive", applyEnabled = true, spellIDs = { 389540 } }) })
check("without the cast map the aura ID alone decides", registered(389540, ADDED) ~= nil)
local realAddonCanSpeak = ns._Aura.addonCanSpeak
ns._Aura.addonCanSpeak = function() error("boom") end
selfBuff = { [9201] = true }
refresh({ rule({ alertCategory = "defensive", applyEnabled = true, spellIDs = { 9201 } }) })
check("a failing addonCanSpeak keeps the category word", registered(9201, ADDED) ~= nil)
ns._Aura.addonCanSpeak = realAddonCanSpeak

-- Per-effect cues: a group on "none" registers the category file of each aura ID; a set group cue wins.
local HEALING = fallback.categorySoundFiles.healing
local OFFENSIVE = fallback.categorySoundFiles.offensive
selfBuff, neverSecret = {}, {}
refresh({ rule({ alertCategory = "none", applyEnabled = true, spellIDs = { 501, 502, 503 },
    categoryByAuraID = { [501] = "defensive", [502] = "healing" } }) })
check("per-effect cues register a different category file per aura ID",
    registered(501, ADDED) and registered(501, ADDED).file == DEFENSIVE
    and registered(502, ADDED) and registered(502, ADDED).file == HEALING)
check("an effect without a cue in a cue-less group registers nothing", registered(503, ADDED) == nil)
refresh({ rule({ alertCategory = "offensive", applyEnabled = true, spellIDs = { 501, 502 },
    categoryByAuraID = { [501] = "defensive", [502] = "healing" } }) })
check("a set group cue still decides for every effect",
    registered(501, ADDED).file == OFFENSIVE and registered(502, ADDED).file == OFFENSIVE)
selfBuff = { [501] = true }
refresh({ rule({ alertCategory = "none", applyEnabled = true, spellIDs = { 501, 502 },
    categoryByAuraID = { [501] = "defensive", [502] = "healing" } }) })
check("the word is suppressed only for the effect the addon speaks itself",
    registered(501, ADDED) == nil and registered(502, ADDED) ~= nil)
selfBuff = {}
refresh({ rule({ alertCategory = "none", applyEnabled = false, spellIDs = { 504 },
    categoryByAuraID = { [504] = "somebody-loves-you" } }) })
check("per-effect word is registered even with application TTS off",
    registered(504, ADDED) and registered(504, ADDED).file == LOVE)
neverSecret = { [505] = true }
refresh({ rule({ alertCategory = "none", applyEnabled = true, spellIDs = { 505, 506 },
    categoryByAuraID = { [505] = "defensive", [506] = "defensive" } }) })
check("per-effect word keeps the readable-aura rule (never-secret + TTS on is spoken, not natively)",
    registered(505, ADDED) == nil and registered(506, ADDED) ~= nil)
neverSecret = {}
refresh({ rule({ alertCategory = "none", expireCategory = "offensive", spellIDs = { 507 },
    categoryByAuraID = { [507] = "defensive" } }) })
check("expiration keeps the group value, the effect map is application only",
    registered(507, ADDED) ~= nil and registered(507, REMOVED) ~= nil
    and registered(507, REMOVED).file == OFFENSIVE)
-- The signature the decision asks for is the one buildDesired registered (for the effect, not the group).
do
    local perEffect = rule({ alertCategory = "none", applyEnabled = true, applySoundEnabled = true,
        applySoundChannel = "SFX", spellIDs = { 508, 509 },
        categoryByAuraID = { [508] = "defensive", [509] = "healing" } })
    refresh({ perEffect })
    local signature508 = fallback.GetNativeSignature(perEffect, "apply", nil, nil, 508)
    local signature509 = fallback.GetNativeSignature(perEffect, "apply", nil, nil, 509)
    check("GetNativeSignature follows the effect's cue", signature508 == DEFENSIVE .. "|SFX"
        and signature509 == HEALING .. "|SFX" and fallback.GetNativeSignature(perEffect, "apply", nil, nil, 510) == nil)
    check("the registered signature equals the effect's signature",
        fallback.GetRegistrationStatus(508, "apply", signature508).status == "registered"
        and fallback.GetRegistrationStatus(509, "apply", signature509).status == "registered"
        and fallback.GetRegistrationStatus(508, "apply", signature509).status ~= "registered")
    local decision = ns.RuleOutput.Decide(perEffect, "apply", { spellID = 508, values = perEffect,
        message = "Shield", native = fallback })
    check("Decide asks for exactly that registration: the word plays, TTS and sound stay silent",
        decision.category == "defensive" and decision.native.status == "registered"
        and decision.native.signature == signature508 and not decision.tts.play and not decision.media.play)
    local other = ns.RuleOutput.Decide(perEffect, "apply", { spellID = 509, values = perEffect,
        message = "Heal", native = fallback })
    check("another effect of the group gets its own word", other.category == "healing"
        and other.native.status == "registered" and other.native.soundFile == HEALING)
    local noCue = ns.RuleOutput.Decide(perEffect, "apply", { spellID = 510, values = perEffect,
        message = "Nothing", native = fallback })
    check("an effect without a cue falls back to TTS", noCue.category == "none" and noCue.tts.play)
    selfBuff = { [508] = true }
    refresh({ perEffect })
    local spoken = ns.RuleOutput.Decide(perEffect, "apply", { spellID = 508, values = perEffect,
        message = "Shield", native = fallback })
    check("an effect the addon speaks itself has no word registered, so the TTS plays",
        registered(508, ADDED) == nil and spoken.native.status ~= "registered" and spoken.tts.play)
    selfBuff = {}
end

refresh({ rule({ alertCategory = "Healing", applyEnabled = true, spellIDs = { 202 } }) })
check("healing category resolves bundled native file",
    registered(202, ADDED) and registered(202, ADDED).file == fallback.categorySoundFiles.healing)

refresh({ rule({ alertCategory = "Somebody loves you", applyEnabled = true, spellIDs = { 204 } }) })
check("love category resolves bundled native file and aliases",
    LOVE and registered(204, ADDED) and registered(204, ADDED).file == LOVE
    and fallback.GetCategorySoundFile("Somebody loves you") == LOVE
    and fallback.GetCategorySoundFile("somebody-loves-you") == LOVE)
check("combined external cues resolve their bundled files and labels",
    fallback.GetCategorySoundFile("offensive-external") == "Interface\\AddOns\\WoWraVox\\Assets\\OffensiveExternal.ogg"
    and fallback.GetCategorySoundFile("defensive-external") == "Interface\\AddOns\\WoWraVox\\Assets\\DefensiveExternal.ogg"
    and fallback.GetCategorySoundFile("Offensive · Somebody loves you") == fallback.categorySoundFiles["offensive-external"]
    and fallback.GetCategorySoundFile("Defensive · Somebody loves you") == fallback.categorySoundFiles["defensive-external"])

selfBuff = {}
neverSecret = { [300] = true }
refresh({ rule({ alertCategory = "defensive", applyEnabled = true, spellIDs = { 101, 300 } }) })
check("category word suppressed for a never-secret aura (spoken by TTS)",
    registered(101, ADDED) ~= nil and registered(300, ADDED) == nil)
refresh({ rule({ alertCategory = "defensive", applyEnabled = true, oneEffect = true, spellIDs = { 102, 300 } }) })
check("one-effect rule with a readable trigger registers the category word for no trigger",
    registered(102, ADDED) == nil and registered(300, ADDED) == nil)
refresh({ rule({ alertCategory = "defensive", applyEnabled = true, oneEffect = true, spellIDs = { 103 } }) })
check("one-effect rule without a readable trigger keeps the category word", registered(103, ADDED) ~= nil)
-- The addon only stays silent for a readable aura while its TTS is on; otherwise the word is the fallback.
refresh({ rule({ alertCategory = "defensive", applyEnabled = false, spellIDs = { 104, 300 } }) })
check("never-secret aura with application TTS off still gets the category word",
    registered(300, ADDED) ~= nil and registered(104, ADDED) ~= nil)
neverSecret[301] = true
refresh({ rule({ alertCategory = "defensive", applyEnabled = false, oneEffect = true, spellIDs = { 105, 301 } }) })
check("one-effect rule with application TTS off keeps the category word for every trigger",
    registered(105, ADDED) ~= nil and registered(301, ADDED) ~= nil)

-- Expiration fallback: the category word on Removed.
refresh({ rule({ expireCategory = "offensive", spellIDs = { 106, 300 } }) })
check("expiration fallback registers the word on Removed",
    registered(106, REMOVED) ~= nil and registered(106, REMOVED).file == fallback.categorySoundFiles.offensive
    and registered(300, REMOVED) ~= nil)
refresh({ rule({ expireCategory = "offensive", expireEnabled = true, spellIDs = { 107, 300 } }) })
check("expiration TTS on: a readable aura is spoken, not announced natively",
    registered(107, REMOVED) ~= nil and registered(300, REMOVED) == nil)
refresh({ rule({ expireCategory = "offensive", oneEffect = true, spellIDs = { 108 } }) })
check("one-effect rules get no expiration word", registered(108, REMOVED) == nil)
refresh({ rule({ expireCategory = "offensive", expireSoundEnabled = true, expireSoundMediaName = "Foo", spellIDs = { 109 } }) })
check("the expiration word wins over an expiration media tone",
    registered(109, REMOVED) ~= nil and registered(109, REMOVED).file == fallback.categorySoundFiles.offensive)
refresh({ rule({ expireCategory = "none", expireSoundEnabled = true, expireSoundMediaName = "Foo", spellIDs = { 110 } }) })
check("no expiration word: the media tone stays", registered(110, REMOVED) ~= nil and registered(110, REMOVED).file == mediaPaths.Foo)

neverSecret = {}
refresh({ rule({ applyEnabled = true, expireEnabled = true }) })
check("TTS-only rule registers no generic tone", #added == 0)

refresh({ rule({ applyEnabled = true, expireEnabled = true, applySoundEnabled = true, expireSoundEnabled = true }) })
check("sound-kit rule registers nothing natively", #added == 0)

refresh({ rule({ expireSoundEnabled = true, expireSoundMediaName = "Foo", expireSoundChannel = "SFX" }) })
check("selected expire media tone is registered on Removed",
    #added == 1 and registered(100, REMOVED) and registered(100, REMOVED).file == mediaPaths.Foo
    and registered(100, REMOVED).channel == "SFX")

refresh({ rule({ applySoundEnabled = true, applySoundMediaName = "Bar" }) })
check("selected apply media tone is registered on Added",
    #added == 1 and registered(100, ADDED) and registered(100, ADDED).file == mediaPaths.Bar)

refresh({ rule({ alertCategory = "defensive", applySoundEnabled = true, applySoundMediaName = "Bar" }) })
check("category word wins over an apply media tone", #added == 1 and registered(100, ADDED).file == DEFENSIVE)

refresh({ rule({ expireEnabled = true, expireSoundEnabled = true, expireSoundMediaName = "Missing" }) })
check("unknown media name registers nothing", #added == 0)

refresh({ rule({ alertCategory = "defensive", applyEnabled = true, enabled = false }) })
check("disabled rule registers nothing", #added == 0)

refresh({ rule({ alertCategory = "defensive", applyEnabled = true }) })
check("status counts the wanted sound", fallback.GetStatus().wanted == 1 and fallback.GetStatus().registered == 1)

local statusRule = rule({ alertCategory = "defensive", applyEnabled = true, spellIDs = { 100 } })
refresh({ statusRule })
local rightSignature = fallback.GetNativeSignature(statusRule, "apply", DEFENSIVE)
local rightStatus = fallback.GetRegistrationStatus(100, "apply", rightSignature)
check("matching native signature reports registered", rightStatus.status == "registered"
    and rightStatus.actualSignature == rightSignature)
local wrongStatus = fallback.GetRegistrationStatus(100, "apply", rightSignature .. "-stale")
check("wrong native signature does not suppress output", wrongStatus.status == "failed"
    and wrongStatus.actualSignature == rightSignature)

inCombat = true
local pendingRule = rule({ alertCategory = "offensive", applyEnabled = true, spellIDs = { 100 } })
local pendingSignature = fallback.GetNativeSignature(pendingRule, "apply", fallback.categorySoundFiles.offensive)
refresh({ pendingRule })
local staleStatus = fallback.GetRegistrationStatus(100, "apply", pendingSignature)
check("combat category change reports pending plus actual stale signature",
    staleStatus.status == "pending" and staleStatus.actualSignature == rightSignature)
inCombat = false
refresh({ pendingRule })
check("pending category change reconciles after combat", fallback.GetRegistrationStatus(100, "apply", pendingSignature).status == "registered")

failRegistration = true
local failedRule = rule({ alertCategory = "defensive", applyEnabled = true, spellIDs = { 203 } })
refresh({ failedRule })
local failedSignature = fallback.GetNativeSignature(failedRule, "apply", DEFENSIVE)
check("registration error reports failed", fallback.GetRegistrationStatus(203, "apply", failedSignature).status == "failed")
failRegistration = false

-- A failed removal retains its handle. Other keys still reconcile; replacement waits for removal success.
refresh({})
check("native mock starts clean for removal recovery", liveCount() == 0)
local oldRule = rule({ alertCategory = "defensive", applyEnabled = true, spellIDs = { 999901 } })
refresh({ oldRule })
local oldID = registered(999901, ADDED).id
local changedRule = rule({ alertCategory = "offensive", applyEnabled = true, spellIDs = { 999901 } })
local otherRule = rule({ alertCategory = "defensive", applyEnabled = true, spellIDs = { 999902 } })
failRemovalCount = 1
added, removed, timers = {}, {}, {}
fallback.Refresh({ changedRule, otherRule }, true)
table.remove(timers, 1)()
local changedSignature = fallback.GetNativeSignature(changedRule, "apply", fallback.categorySoundFiles.offensive)
local removalStatus = fallback.GetRegistrationStatus(999901, "apply", changedSignature)
check("transient remove failure is reported with the retained ID",
    removalStatus.status == "failed" and removalStatus.reason == "removal-failed"
    and removalStatus.actualRegistered and removalStatus.id == oldID
    and fallback.GetStatus().removeFailed == 1)
check("changed category waits for removal while another key registers",
    not registered(999901, ADDED) and registered(999902, ADDED) ~= nil and liveCount() == 2)
table.remove(timers, 1)()
table.remove(timers, 1)()
local changedID = registered(999901, ADDED).id
check("retry removes old ID before adding one replacement",
    changedID ~= oldID and liveSounds[oldID] == nil and liveSounds[changedID] ~= nil
    and liveCount() == 2 and fallback.GetStatus().removeFailed == 0)

-- A persistent failure gets the initial attempt plus five retries, then waits for a later refresh.
local persistentRule = rule({ alertCategory = "defensive", applyEnabled = true, spellIDs = { 999903 } })
refresh({ changedRule, otherRule, persistentRule })
local persistentID = registered(999903, ADDED).id
local persistentReplacement = rule({ alertCategory = "offensive", applyEnabled = true, spellIDs = { 999903 } })
local attemptsBefore = removalAttempts
failRemoval = true
refresh({ changedRule, otherRule, persistentReplacement })
check("persistent removal retries are bounded and retain one old ID",
    removalAttempts - attemptsBefore == 6 and liveSounds[persistentID] ~= nil and liveCount() == 3
    and not registered(999903, ADDED) and fallback.GetStatus().removeFailed == 1)
failRemoval = false
refresh({ changedRule, otherRule, persistentReplacement })
local persistentNewID = registered(999903, ADDED).id
check("later refresh cleans the retained ID without a leak", persistentNewID ~= persistentID
    and liveSounds[persistentID] == nil and liveSounds[persistentNewID] ~= nil and liveCount() == 3)

-- Temporary API loss keeps known handles until the removal API returns.
local apiRule = rule({ alertCategory = "defensive", applyEnabled = true, spellIDs = { 999904 } })
refresh({ apiRule })
local apiOldID = registered(999904, ADDED).id
local apiReplacement = rule({ alertCategory = "offensive", applyEnabled = true, spellIDs = { 999904 } })
local api = C_UnitAuras
C_UnitAuras = nil
refresh({ apiReplacement })
check("API loss retains native handle", liveSounds[apiOldID] ~= nil and liveCount() == 1)
C_UnitAuras = api
refresh({ apiReplacement })
local apiNewID = registered(999904, ADDED).id
check("restored API removes retained handle before replacement", apiNewID ~= apiOldID
    and liveSounds[apiOldID] == nil and liveSounds[apiNewID] ~= nil and liveCount() == 1)

local savedAuraSoundAPI = C_UnitAuras
C_UnitAuras = nil
check("missing native API reports unavailable",
    fallback.GetRegistrationStatus(100, "apply", rightSignature).status == "unavailable")
C_UnitAuras = savedAuraSoundAPI
check("undesired native signature reports suppressed",
    fallback.GetRegistrationStatus(999, "apply", rightSignature).status == "suppressed")

-- An active restriction blocks native changes even with InCombatLockdown()==false.
refresh({})
inCombat = false
local restrictedRule = rule({ alertCategory = "defensive", applyEnabled = true, spellIDs = { 999950 } })
local restrictedTypes = Enum.AddOnRestrictionType
for _, name in ipairs({ "Combat", "Encounter", "ChallengeMode", "PvPMatch", "Map" }) do
    restrictionStates[restrictedTypes[name]] = Enum.AddOnRestrictionState.Active
    refresh({ restrictedRule })
    check(name .. " restriction queues without native calls out of combat",
        #added == 0 and #removed == 0 and fallback.GetStatus().queued)
    restrictionStates[restrictedTypes[name]] = nil
end
restrictionStates[restrictedTypes.Encounter] = Enum.AddOnRestrictionState.Activating
refresh({ restrictedRule })
check("activating restriction is already queued", #added == 0 and fallback.GetStatus().queued)
restrictionStates[restrictedTypes.Encounter] = nil
restrictionFrame.onEvent(restrictionFrame, "ADDON_RESTRICTION_STATE_CHANGED", restrictedTypes.Encounter, 0)
while #timers > 0 do table.remove(timers, 1)() end
check("restriction end resumes pending registration", registered(999950, ADDED) ~= nil and not fallback.GetStatus().queued)

-- A restriction starting between Refresh and its timer preserves the old registration.
local oldRestrictedID = registered(999950, ADDED).id
added, removed, timers = {}, {}, {}
fallback.Refresh({}, true)
restrictionStates[restrictedTypes.ChallengeMode] = Enum.AddOnRestrictionState.Active
table.remove(timers, 1)()
check("timer rechecks restriction and preserves registered handles",
    #removed == 0 and liveSounds[oldRestrictedID] ~= nil and fallback.GetStatus().queued)
restrictionStates[restrictedTypes.ChallengeMode] = nil
restrictionFrame.onEvent(restrictionFrame, "ADDON_RESTRICTION_STATE_CHANGED", restrictedTypes.ChallengeMode, 0)
while #timers > 0 do table.remove(timers, 1)() end
check("deferred removal resumes safely", liveSounds[oldRestrictedID] == nil)
restrictionQueryError = true
refresh({ restrictedRule })
check("failed restriction query does not risk protected calls", #added == 0 and fallback.GetStatus().queued)
restrictionQueryError = false
restrictionStates[restrictedTypes.Chat] = Enum.AddOnRestrictionState.Active
refresh({ restrictedRule })
check("chat-only restriction does not block aura sound registration", registered(999950, ADDED) ~= nil)
restrictionStates[restrictedTypes.Chat] = nil
