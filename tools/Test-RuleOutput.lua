local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. detail) or "")) end
    print("PASS " .. name)
end

local nativeStatuses = {}
local function statusKey(spellID, signature) return tostring(spellID) .. "|" .. signature end
local categoryFiles = {
    defensive = "Interface\\AddOns\\WoWraVox\\Assets\\Defensive.ogg",
    healing = "Interface\\AddOns\\WoWraVox\\Assets\\Healing.ogg",
    ["somebody-loves-you"] = "Interface\\AddOns\\WoWraVox\\Assets\\Love.ogg",
}
local mediaFiles = { Foo = "media\\foo.ogg" }
local seenDraftValues = false

local function signature(rule, eventKey, soundFile, values)
    local enabled = values and values[eventKey .. "SoundEnabled"]
    if enabled == nil then enabled = rule[eventKey .. "SoundEnabled"] end
    local channel = enabled and ((values and values[eventKey .. "SoundChannel"]) or rule[eventKey .. "SoundChannel"]) or "Master"
    return soundFile .. "|" .. (channel or "Master")
end

local native = {
    GetCategorySoundFile = function(category)
        local aliases = { Healing = "healing", ["Somebody loves you"] = "somebody-loves-you" }
        return categoryFiles[aliases[category] or category]
    end,
    GetMediaSoundFile = function(name) return mediaFiles[name] end,
    GetNativeSignature = function(rule, eventKey, soundFile, values)
        if values then seenDraftValues = true end
        return signature(rule, eventKey, soundFile, values)
    end,
    GetRegistrationStatus = function(spellID, _, wanted)
        return nativeStatuses[statusKey(spellID, wanted)] or { status = "failed", reason = "test-missing", actualSignature = nil }
    end,
}

local function rule(fields)
    local result = {
        enabled = true, alertCategory = "none", expireCategory = "none",
        applyEnabled = false, applyMessage = "", applySoundEnabled = false,
        applySoundChannel = "Master", applySoundMediaName = nil, applySoundKitID = 1,
        applyScreenEnabled = false, applyScreenText = "",
        expireEnabled = false, expireMessage = "", expireSoundEnabled = false,
        expireSoundChannel = "Master", expireSoundMediaName = nil, expireSoundKitID = 1,
        expireScreenEnabled = false, expireScreenText = "",
        readyEnabled = false, message = "", readySoundEnabled = false,
        readySoundChannel = "Master", readySoundMediaName = nil, readySoundKitID = 1,
        screenEnabled = false, screenText = "",
    }
    for key, value in pairs(fields or {}) do result[key] = value end
    return result
end

local output = ns.RuleOutput
local defensiveFile = categoryFiles.defensive
local healingFile = categoryFiles.healing
local loveFile = categoryFiles["somebody-loves-you"]

local categoryOnly = rule({ alertCategory = "defensive", applyEnabled = false, spellIDs = { 100 } })
local categoryOnlySignature = signature(categoryOnly, "apply", defensiveFile)
nativeStatuses[statusKey(100, categoryOnlySignature)] = { status = "registered", actualSignature = categoryOnlySignature }
local preview = output.Decide(categoryOnly, "apply", { spellID = 100, native = native, preview = true })
check("category-only preview inspects native registration", preview.native.status == "registered")
check("category-only preview never claims native playback", preview.native.playback == false and preview.native.play == false
    and preview.shouldSpeak == false and preview.shouldPlaySound == false)

local categoryRule = rule({ alertCategory = "defensive", applyEnabled = true, applyMessage = "Defensive",
    applySoundEnabled = true, spellIDs = { 101 } })
local categorySignature = signature(categoryRule, "apply", defensiveFile)
nativeStatuses[statusKey(101, categorySignature)] = { status = "registered", actualSignature = categorySignature }
local categoryDecision = output.Decide(categoryRule, "apply", { spellID = 101, native = native })
check("registered category suppresses TTS", categoryDecision.native.status == "registered" and not categoryDecision.tts.play)
check("registered category suppresses normal media", categoryDecision.media.suppressed and not categoryDecision.media.play)

local fallbackRule = rule({ alertCategory = "defensive", applyEnabled = true, applyMessage = "Defensive",
    applySoundEnabled = true, spellIDs = { 102 } })
local fallbackDecision = output.Decide(fallbackRule, "apply", { spellID = 102, native = native })
check("missing category registration keeps TTS fallback", fallbackDecision.native.status == "failed" and fallbackDecision.tts.play)
check("missing category registration keeps manual media suppressed", not fallbackDecision.media.play
    and fallbackDecision.media.reason == "category-selected")

local mediaRule = rule({ applyEnabled = true, applyMessage = "Sound", applySoundEnabled = true,
    applySoundMediaName = "Foo", applySoundChannel = "SFX", spellIDs = { 103 } })
local mediaSignature = signature(mediaRule, "apply", mediaFiles.Foo)
nativeStatuses[statusKey(103, mediaSignature)] = { status = "registered", actualSignature = mediaSignature }
local mediaDecision = output.Decide(mediaRule, "apply", { spellID = 103, native = native })
check("registered SharedMedia tone suppresses duplicate manual playback", mediaDecision.media.native.status == "registered"
    and not mediaDecision.media.play)
check("registered SharedMedia tone does not suppress TTS", mediaDecision.tts.play)

local manualMedia = output.Decide(rule({ applySoundEnabled = true, applySoundMediaName = "Foo", spellIDs = { 104 } }),
    "apply", { spellID = 104, native = native })
check("unregistered SharedMedia tone stays manual", manualMedia.media.native.status == "failed" and manualMedia.media.play)

local textDecision = output.Decide(rule({ applyScreenEnabled = true, applyScreenText = "Protected" }), "apply",
    { native = native })
check("screen text is selected independently", textDecision.screen.show and textDecision.screen.text == "Protected")

local healingRule = rule({ alertCategory = "Healing", applyEnabled = true, applyMessage = "Healing", spellIDs = { 105 } })
local healingSignature = signature(healingRule, "apply", healingFile)
nativeStatuses[statusKey(105, healingSignature)] = { status = "registered", actualSignature = healingSignature }
local healingDecision = output.Decide(healingRule, "apply", { spellID = 105, native = native })
check("healing category uses native Healing asset", healingDecision.native.soundFile == healingFile
    and healingDecision.native.status == "registered")

local loveRule = rule({ alertCategory = "Somebody loves you", applyEnabled = true, applyMessage = "Somebody loves you",
    applySoundEnabled = true, spellIDs = { 111 } })
local loveSignature = signature(loveRule, "apply", loveFile)
nativeStatuses[statusKey(111, loveSignature)] = { status = "registered", actualSignature = loveSignature }
local loveDecision = output.Decide(loveRule, "apply", { spellID = 111, native = native })
check("love category maps asset and suppresses duplicate TTS/media", loveDecision.native.soundFile == loveFile
    and loveDecision.native.status == "registered" and not loveDecision.tts.play
    and loveDecision.media.suppressed and not loveDecision.media.play)

local draftRule = rule({ alertCategory = "defensive", applyEnabled = true, applyMessage = "Draft", spellIDs = { 106 } })
local draftSignature = signature(draftRule, "apply", defensiveFile, { applySoundEnabled = true, applySoundChannel = "SFX" })
nativeStatuses[statusKey(106, draftSignature)] = { status = "registered", actualSignature = draftSignature }
local draftDecision = output.Decide(draftRule, "apply", {
    spellID = 106, native = native,
    values = { applyEnabled = true, applyMessage = "Draft", applySoundEnabled = true, applySoundChannel = "SFX" },
})
check("draft channel participates in native signature", seenDraftValues and draftDecision.native.signature == draftSignature
    and draftDecision.native.status == "registered")

local staleRule = rule({ alertCategory = "defensive", applyEnabled = true, applyMessage = "New", spellIDs = { 107 } })
local staleSignature = signature(staleRule, "apply", defensiveFile)
local staleActual = defensiveFile .. "|SFX"
nativeStatuses[statusKey(107, staleSignature)] = { status = "pending", actualSignature = staleActual, reason = "stale-registration" }
local staleDecision = output.Decide(staleRule, "apply", { spellID = 107, native = native })
check("stale native signature stays visible", staleDecision.native.status == "pending"
    and staleDecision.native.actualSignature == staleActual and staleDecision.tts.play)

local previewRegistered = output.Decide(categoryRule, "apply", { spellID = 101, native = native, preview = true })
check("preview native registration suppresses duplicate TTS", previewRegistered.native.status == "registered"
    and not previewRegistered.tts.play and previewRegistered.native.playback == false)

local readyDecision = output.Decide(rule({ alertCategory = "defensive", readyEnabled = true, message = "Ready",
    readySoundEnabled = true, readySoundChannel = "SFX", screenEnabled = true, screenText = "Ready now" }), "ready",
    { native = native })
check("ready ignores aura category and keeps legacy outputs", readyDecision.native.status == "suppressed"
    and readyDecision.native.reason == "no-category" and readyDecision.tts.play
    and readyDecision.media.play and readyDecision.screen.show)

-- Per-effect cues (rule.categoryByAuraID): ns._Aura.cueFor decides the application category of one trigger.
ns._Aura = {
    cueFor = function(r, spellID)
        if r.alertCategory ~= nil and r.alertCategory ~= "none" then return r.alertCategory end
        return r.categoryByAuraID and r.categoryByAuraID[spellID] or "none"
    end,
}
local askedSpellIDs = {}
local spyNative = {
    GetCategorySoundFile = native.GetCategorySoundFile,
    GetMediaSoundFile = native.GetMediaSoundFile,
    GetNativeSignature = function(r, eventKey, soundFile, values, spellID)
        askedSpellIDs[#askedSpellIDs + 1] = spellID
        return signature(r, eventKey, soundFile, values)
    end,
    GetRegistrationStatus = native.GetRegistrationStatus,
}
local perEffect = rule({ alertCategory = "none", applyEnabled = true, applyMessage = "Shield",
    categoryByAuraID = { [120] = "defensive", [121] = "healing" }, spellIDs = { 120, 121, 122 } })
local perEffectSignature = signature(perEffect, "apply", defensiveFile)
nativeStatuses[statusKey(120, perEffectSignature)] = { status = "registered", actualSignature = perEffectSignature }
local effectDecision = output.Decide(perEffect, "apply", { spellID = 120, native = spyNative })
check("a cue-less group uses the effect's cue: its word, its signature, TTS suppressed",
    effectDecision.category == "defensive" and effectDecision.native.selected == true
    and effectDecision.native.soundFile == defensiveFile and effectDecision.native.signature == perEffectSignature
    and effectDecision.native.status == "registered" and not effectDecision.tts.play
    and askedSpellIDs[1] == 120)
local healingEffect = output.Decide(perEffect, "apply", { spellID = 121, native = spyNative })
check("another effect of the same group has its own category", healingEffect.category == "healing"
    and healingEffect.native.soundFile == healingFile and healingEffect.native.status == "failed"
    and healingEffect.tts.play)
local cueless = output.Decide(perEffect, "apply", { spellID = 122, native = spyNative })
check("an effect without a cue has no native word", cueless.category == "none" and cueless.native.status == "suppressed"
    and cueless.native.reason == "no-category" and cueless.tts.play)
local groupCue = rule({ alertCategory = "healing", applyEnabled = true, applyMessage = "Heal",
    categoryByAuraID = { [120] = "defensive" }, spellIDs = { 120 } })
check("a set group cue overrides the effect cue", output.Decide(groupCue, "apply",
    { spellID = 120, native = spyNative }).category == "healing")
check("a draft group value overrides the effect cue", output.Decide(perEffect, "apply",
    { spellID = 120, native = spyNative, values = { alertCategory = "healing" } }).category == "healing")
check("expiration keeps the group cue and ignores the effect map", output.Decide(
    rule({ expireCategory = "none", expireEnabled = true, expireMessage = "Gone", categoryByAuraID = { [120] = "defensive" } }),
    "expire", { spellID = 120, native = spyNative }).category == "none")
check("without a readable spell ID the effect map is not consulted", output.Decide(perEffect, "apply",
    { native = spyNative }).category == "none")
ns._Aura = nil
check("without ns._Aura.cueFor the group value decides", output.Decide(perEffect, "apply",
    { spellID = 120, native = spyNative }).category == "none")
