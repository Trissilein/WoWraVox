local _, ns = ...

local output = ns.RuleOutput or {}
ns.RuleOutput = output

local EVENTS = {
    apply = {
        category = "alertCategory", enabled = "applyEnabled", message = "applyMessage",
        sound = "applySoundEnabled", media = "applySoundMediaName", kit = "applySoundKitID",
        channel = "applySoundChannel", screenEnabled = "applyScreenEnabled", screenText = "applyScreenText",
    },
    expire = {
        category = "expireCategory", enabled = "expireEnabled", message = "expireMessage",
        sound = "expireSoundEnabled", media = "expireSoundMediaName", kit = "expireSoundKitID",
        channel = "expireSoundChannel", screenEnabled = "expireScreenEnabled", screenText = "expireScreenText",
    },
    ready = {
        -- Ready cues use the legacy ready output path; alertCategory is only
        -- registered for aura apply/expire and must not suppress this output.
        category = nil, enabled = "readyEnabled", message = "message",
        sound = "readySoundEnabled", media = "readySoundMediaName", kit = "readySoundKitID",
        channel = "readySoundChannel", screenEnabled = "screenEnabled", screenText = "screenText",
    },
}

local VALID_NATIVE_STATUS = {
    registered = true, pending = true, failed = true, unavailable = true, suppressed = true,
}

local function value(values, rule, key)
    if values and values[key] ~= nil then return values[key] end
    return rule and rule[key]
end

local function nonEmpty(text)
    return type(text) == "string" and text:match("%S") ~= nil
end

local function publicSpellID(spellID)
    if type(spellID) ~= "number" then return false end
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, spellID)
        if not ok or secret then return false end
    end
    return spellID > 0 and spellID == math.floor(spellID)
end

-- The category of one event. Application: the group's cue, else the effect's own (ns._Aura.cueFor, the same
-- resolution AuraSoundFallback registers with). Expiration and ready keep their group value.
local function eventCategory(rule, values, fields, eventKey, spellID)
    local category = value(values, rule, fields.category)
    category = type(category) == "string" and category or "none"
    if eventKey ~= "apply" or category ~= "none" or not publicSpellID(spellID) then return category end
    local callback = ns._Aura and ns._Aura.cueFor
    if type(callback) ~= "function" then return category end
    local ok, cue = pcall(callback, { alertCategory = category, categoryByAuraID = rule.categoryByAuraID }, spellID)
    return ok and type(cue) == "string" and cue or category
end

local function screenValues(rule, values, fields, eventKey)
    local profiles = values and values.screenProfiles
    local profile = type(profiles) == "table" and profiles[eventKey] or nil
    if type(profile) ~= "table" then
        profiles = rule and rule.screenProfiles
        profile = type(profiles) == "table" and profiles[eventKey] or nil
    end
    local enabled = value(values, rule, fields.screenEnabled)
    local text = value(values, rule, fields.screenText)
    if enabled == nil and profile then enabled = profile.enabled end
    if text == nil and profile then text = profile.text end
    return enabled == true, type(text) == "string" and text or ""
end

local function channelFor(rule, values, fields)
    if value(values, rule, fields.sound) ~= true then return "Master" end
    local channel = value(values, rule, fields.channel)
    return type(channel) == "string" and channel ~= "" and channel or "Master"
end

local function nativeStatus(native, spellID, eventKey, signature, selected, preview)
    if not selected then return { status = "suppressed", reason = "no-category", registered = false } end
    if preview and not publicSpellID(spellID) then
        return { status = "suppressed", reason = "preview-only", registered = false, playback = false }
    end
    if not publicSpellID(spellID) then
        return { status = "unavailable", reason = "no-public-spell-id", registered = false }
    end
    if type(signature) ~= "string" or signature == "" then
        return { status = "unavailable", reason = "no-signature", registered = false }
    end
    if not native then return { status = "unavailable", reason = "native-api-missing", registered = false } end

    local result
    if type(native.GetRegistrationStatus) == "function" then
        local ok, returned = pcall(native.GetRegistrationStatus, spellID, eventKey, signature)
        if ok then result = returned end
    elseif type(native.IsRegistered) == "function" then
        local ok, registered = pcall(native.IsRegistered, spellID, eventKey, signature)
        if ok then
            result = { status = registered and "registered" or "failed", registered = registered == true,
                reason = registered and "legacy-match" or "legacy-not-registered" }
        end
    end
    if type(result) ~= "table" then
        return { status = "unavailable", reason = "registration-status-missing", registered = false }
    end
    local status = VALID_NATIVE_STATUS[result.status] and result.status or "failed"
    result.status = status
    result.registered = status == "registered"
    result.pending = status == "pending"
    result.failed = status == "failed"
    result.signature = result.signature or signature
    return result
end

local function channelDecision(enabled, categorySelected, preview, reason)
    local selected = enabled == true
    local blocked = categorySelected and selected
    local status = selected and (blocked and "suppressed" or "ready") or "suppressed"
    return {
        requested = selected,
        selected = selected and not blocked,
        suppressed = blocked or not selected,
        status = status,
        reason = blocked and reason or (selected and nil or "disabled"),
        play = selected and not blocked,
        playback = selected and not blocked and not preview,
    }
end

function output.Decide(rule, eventKey, options)
    options = type(options) == "table" and options or {}
    local fields = EVENTS[eventKey]
    if type(rule) ~= "table" or not fields then
        return { valid = false, reason = "invalid-rule-or-event", native = { status = "suppressed" },
            tts = { status = "suppressed" }, media = { status = "suppressed" }, screen = { status = "suppressed" } }
    end

    local values = type(options.values) == "table" and options.values or nil
    local preview = options.preview == true
    local native = options.native or ns.AuraSoundFallback
    local category = eventCategory(rule, values, fields, eventKey, options.spellID)
    local categoryFile
    if type(options.categorySoundFile) == "string" and options.categorySoundFile ~= "" then
        categoryFile = options.categorySoundFile
    elseif native and type(native.GetCategorySoundFile) == "function" then
        local ok, file = pcall(native.GetCategorySoundFile, category)
        if ok and type(file) == "string" and file ~= "" then categoryFile = file end
    end
    local categorySelected = categoryFile ~= nil and category ~= "none"
    local expectedSignature = options.nativeSignature
    if not expectedSignature and categorySelected then
        if native and type(native.GetNativeSignature) == "function" then
            local ok, signature = pcall(native.GetNativeSignature, rule, eventKey, categoryFile, values, options.spellID)
            if ok then expectedSignature = signature end
        else
            expectedSignature = categoryFile .. "|" .. channelFor(rule, values, fields)
        end
    end
    local nativeResult = nativeStatus(native, options.spellID, eventKey, expectedSignature, categorySelected, preview)
    nativeResult.selected = categorySelected
    nativeResult.category = category
    nativeResult.soundFile = categoryFile
    nativeResult.signature = expectedSignature
    nativeResult.play = nativeResult.status == "registered" and not preview
    nativeResult.playback = nativeResult.play

    local enabled = eventKey == "ready" and value(values, rule, fields.enabled) ~= false
        or value(values, rule, fields.enabled) == true
    local message = type(options.message) == "string" and options.message or value(values, rule, fields.message)
    message = type(message) == "string" and message or ""
    local ttsRequested = enabled and nonEmpty(message)
    local ttsSuppressed = nativeResult.status == "registered"
    local tts = {
        requested = ttsRequested,
        selected = ttsRequested and not ttsSuppressed,
        suppressed = not ttsRequested or ttsSuppressed,
        status = ttsRequested and (ttsSuppressed and "suppressed" or "ready") or "suppressed",
        reason = ttsSuppressed and "native-category-registered" or (ttsRequested and nil or (enabled and "empty-message" or "disabled")),
        text = message,
        play = ttsRequested and not ttsSuppressed,
        playback = ttsRequested and not ttsSuppressed and not preview,
    }

    local mediaName = value(values, rule, fields.media)
    local soundKitID = value(values, rule, fields.kit)
    local media = channelDecision(value(values, rule, fields.sound), categorySelected, preview, "category-selected")
    media.mediaName = type(mediaName) == "string" and mediaName or nil
    media.soundKitID = soundKitID
    media.channel = channelFor(rule, values, fields)
    media.kind = media.mediaName and "media" or "sound-kit"
    media.native = { status = "suppressed", reason = categorySelected and "category-selected" or "no-shared-media-path" }
    if not categorySelected and media.requested and media.mediaName then
        local mediaPath = options.mediaSoundFile
        if not mediaPath and native and type(native.GetMediaSoundFile) == "function" then
            local ok, fetched = pcall(native.GetMediaSoundFile, media.mediaName)
            if ok and type(fetched) == "string" and fetched ~= "" then mediaPath = fetched end
        end
        if mediaPath then
            local mediaSignature = options.mediaNativeSignature
            if not mediaSignature and native and type(native.GetNativeSignature) == "function" then
                local ok, signature = pcall(native.GetNativeSignature, rule, eventKey, mediaPath, values)
                if ok then mediaSignature = signature end
            elseif not mediaSignature then
                mediaSignature = mediaPath .. "|" .. media.channel
            end
            media.native = nativeStatus(native, options.spellID, eventKey, mediaSignature, true, preview)
            media.native.soundFile = mediaPath
            media.native.signature = mediaSignature
            if media.native.status == "registered" then
                media.selected = false
                media.suppressed = true
                media.status = "suppressed"
                media.reason = "native-media-registered"
                media.play = false
                media.playback = false
            end
        end
    end

    local screenEnabled, screenText = screenValues(rule, values, fields, eventKey)
    local screenRequested = screenEnabled and nonEmpty(options.screenText or screenText)
    local screen = {
        requested = screenRequested,
        selected = screenRequested,
        suppressed = not screenRequested,
        status = screenRequested and "ready" or "suppressed",
        reason = screenRequested and nil or (screenEnabled and "empty-text" or "disabled"),
        text = type(options.screenText) == "string" and options.screenText or screenText,
        show = screenRequested,
        playback = screenRequested,
    }

    return {
        valid = true,
        preview = preview,
        eventKey = eventKey,
        category = category,
        native = nativeResult,
        tts = tts,
        media = media,
        screen = screen,
        shouldSpeak = tts.play,
        shouldPlaySound = media.play,
        shouldShowText = screen.show,
    }
end

output.Build = output.Decide
