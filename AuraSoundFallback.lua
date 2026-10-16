local _, ns = ...

local fallback = ns.AuraSoundFallback or {}
ns.AuraSoundFallback = fallback

-- Bundled 2026-09-30 via Windows SAPI Microsoft David en-US; Ogg Vorbis mono 22050 Hz.
fallback.categorySoundFiles = {
    defensive = "Interface\\AddOns\\WoWraVox\\Assets\\Defensive.ogg",
    offensive = "Interface\\AddOns\\WoWraVox\\Assets\\Offensive.ogg",
    bloodlust = "Interface\\AddOns\\WoWraVox\\Assets\\Bloodlust.ogg",
    healing = "Interface\\AddOns\\WoWraVox\\Assets\\Healing.ogg",
    ["somebody-loves-you"] = "Interface\\AddOns\\WoWraVox\\Assets\\Love.ogg",
    ["offensive-external"] = "Interface\\AddOns\\WoWraVox\\Assets\\OffensiveExternal.ogg",
    ["defensive-external"] = "Interface\\AddOns\\WoWraVox\\Assets\\DefensiveExternal.ogg",
}
fallback.debugEnabled = false
fallback.log = fallback.log or {}
fallback.maxLogLines = 180

local registered = {}
local desired = {}
local failed = {}
local lastRules
local queued = false
local scheduled = false
local scheduledForce = false
local retryCount = 0
local retryScheduled = false
local statusCallback
local lastStatus = { available = false, registered = 0, wanted = 0, refused = 0, removeFailed = 0, queued = false }

local function fetchSharedMediaSound(name)
    if type(name) ~= "string" or name == "" or not (type(LibStub) == "function" or type(LibStub) == "table") then return nil end
    local ok, library = pcall(LibStub, "LibSharedMedia-3.0", true)
    if not (ok and type(library) == "table" and type(library.Fetch) == "function") then return nil end
    local fetched, path = pcall(library.Fetch, library, "sound", name, true)
    if fetched and type(path) == "string" and path ~= "" then return path end
end

local function selectedMediaSound(rule, eventKey)
    return rule and fetchSharedMediaSound(rule[eventKey .. "SoundMediaName"])
end

local function available()
    return C_UnitAuras and C_UnitAuras.AddAuraSound and C_UnitAuras.RemoveAuraSound
        and Enum and Enum.UnitAuraSoundTrigger and Enum.UnitAuraSoundTrigger.Added
        and Enum.UnitAuraSoundTrigger.Removed
end

local function updateStatus()
    if statusCallback then statusCallback(lastStatus) end
end

local function appendLog(category, message)
    if not fallback.debugEnabled then return end
    local line = string.format("%s %s %s", date("%H:%M:%S"), tostring(category), tostring(message))
    table.insert(fallback.log, line)
    if #fallback.log > fallback.maxLogLines then table.remove(fallback.log, 1) end
end

function fallback.Log(category, message)
    appendLog(category, message)
end

function fallback.LogAura(spellID, result, sourceEvent)
    if not fallback.debugEnabled then return end
    local now = GetTime()
    fallback.lastAuraLog = fallback.lastAuraLog or {}
    local key = tostring(spellID) .. ":" .. tostring(result) .. ":" .. tostring(sourceEvent)
    local last = fallback.lastAuraLog[key] or 0
    if now - last < 2 then return end
    fallback.lastAuraLog[key] = now
    local ruleIDs = {}
    for _, rule in ipairs(lastRules or {}) do
        for _, id in ipairs(type(rule.spellIDs) == "table" and rule.spellIDs or {}) do
            if id == spellID then table.insert(ruleIDs, tostring(rule.id or "?")); break end
        end
    end
    appendLog("AURA", string.format("rules=%s spell=%s event=%s result=%s",
        #ruleIDs > 0 and table.concat(ruleIDs, ",") or "?", tostring(spellID), tostring(sourceEvent or "?"), tostring(result)))
end

function fallback.GetLogLines()
    return fallback.log
end

function fallback.ClearLog()
    wipe(fallback.log)
    wipe(fallback.lastAuraLog or {})
end

function fallback.SetDebugEnabled(enabled)
    fallback.debugEnabled = enabled == true
    updateStatus()
end

function fallback.SetStatusCallback(callback)
    statusCallback = callback
    updateStatus()
end

function fallback.GetStatus()
    return lastStatus
end

local CATEGORY_ALIASES = {
    ["Defensive cooldown"] = "defensive",
    ["Offensive cooldown"] = "offensive",
    ["Bloodlust"] = "bloodlust",
    ["Healing"] = "healing",
    ["Healing cooldown"] = "healing",
    ["Somebody loves you"] = "somebody-loves-you",
    ["Offensive · Somebody loves you"] = "offensive-external",
    ["Defensive · Somebody loves you"] = "defensive-external",
    defensive = "defensive", offensive = "offensive", bloodlust = "bloodlust", healing = "healing",
    ["somebody-loves-you"] = "somebody-loves-you",
    ["offensive-external"] = "offensive-external", ["defensive-external"] = "defensive-external",
}

local function eventTrigger(eventKey)
    local name = eventKey == "apply" and "Added" or eventKey == "expire" and "Removed"
    return name and Enum and Enum.UnitAuraSoundTrigger and Enum.UnitAuraSoundTrigger[name]
end

local function validSpellID(spellID)
    if type(spellID) ~= "number" then return false end
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, spellID)
        if not ok or secret then return false end
    end
    return spellID > 0 and spellID == math.floor(spellID)
end

local function eventPrefix(eventKey)
    if eventKey == "apply" or eventKey == "expire" or eventKey == "ready" then return eventKey end
end

local function ruleSoundChannel(rule, eventKey, values)
    local prefix = eventPrefix(eventKey)
    local source = values and prefix and values[prefix .. "SoundEnabled"] ~= nil and values or rule
    local channel = source and prefix and source[prefix .. "SoundEnabled"] and source[prefix .. "SoundChannel"] or "Master"
    return type(channel) == "string" and channel ~= "" and channel or "Master"
end

local function normalizeCategory(category)
    if type(category) ~= "string" then return nil end
    return CATEGORY_ALIASES[category] or category
end

-- The same decision the cast path uses (WoWraVox.lua handleCast): can the addon speak this aura itself?
local function addonCanSpeak(spellID, rule)
    local callback = ns._Aura and ns._Aura.addonCanSpeak
    if type(callback) ~= "function" then return false end
    local ok, usable = pcall(callback, spellID, rule)
    return ok and usable == true
end

-- The application cue of one trigger: the group's cue, else the effect's own (rule.categoryByAuraID). One
-- resolution (ns._Aura.cueFor) for registration here and for the decision in RuleOutput.
local function applyCue(rule, spellID)
    local callback = ns._Aura and ns._Aura.cueFor
    if type(callback) == "function" then
        local ok, cue = pcall(callback, rule, spellID)
        if ok and type(cue) == "string" then return cue end
    end
    return rule and rule.alertCategory
end

function fallback.IsRegistered(spellID, eventKey, signature)
    local trigger = eventTrigger(eventKey)
    if not trigger then return false end
    local entry = registered[tostring(spellID) .. ":" .. tostring(trigger)]
    return entry ~= nil and (signature == nil or entry.signature == signature)
end

function fallback.GetCategorySoundFile(category)
    return fallback.categorySoundFiles[normalizeCategory(category)]
end

function fallback.GetMediaSoundFile(name)
    return fetchSharedMediaSound(name)
end

function fallback.GetNativeSignature(rule, eventKey, soundFile, values, spellID)
    soundFile = soundFile or fallback.GetCategorySoundFile(rule and (eventKey == "expire" and rule.expireCategory or applyCue(rule, spellID)))
    if type(soundFile) ~= "string" or soundFile == "" then return nil end
    return soundFile .. "|" .. ruleSoundChannel(rule, eventKey, values)
end

local function registrationStatus(status, reason, signature, entry)
    return {
        status = status,
        registered = status == "registered",
        pending = status == "pending",
        failed = status == "failed",
        signature = signature,
        actualSignature = entry and entry.signature or nil,
        actualRegistered = entry ~= nil,
        reason = reason,
        id = entry and entry.id or nil,
    }
end

function fallback.GetRegistrationStatus(spellID, eventKey, signature)
    local trigger = eventTrigger(eventKey)
    if not trigger or not validSpellID(spellID) or type(signature) ~= "string" or signature == "" then
        return registrationStatus("suppressed", "invalid-request", signature)
    end
    if not available() then return registrationStatus("unavailable", "api-unavailable", signature) end

    local key = tostring(spellID) .. ":" .. tostring(trigger)
    local current = registered[key]
    local wanted = desired[key]
    if current and current.removeFailed then
        return registrationStatus("failed", "removal-failed", signature, current)
    end
    if failed[key] == signature then return registrationStatus("failed", "registration-failed", signature, current) end
    if current and wanted and current.signature == signature and wanted.signature == signature then
        return registrationStatus("registered", "signature-match", signature, current)
    end
    if current and current.signature ~= signature then
        if queued or scheduled or (wanted and wanted.signature == signature) then
            return registrationStatus("pending", "stale-registration", signature, current)
        end
        return registrationStatus("failed", "stale-registration", signature, current)
    end
    if current and current.signature == signature then
        return registrationStatus("failed", "stale-registration", signature, current)
    end
    if wanted and wanted.signature == signature then
        return registrationStatus("pending", queued and "restriction-queued" or "registration-pending", signature)
    end
    return registrationStatus("suppressed", "not-desired", signature)
end

-- Native sounds WoW plays itself (also when the addon cannot read the aura): the category word on Added for
-- auras that are neither own self-buffs nor spoken by the addon (readable in combat and TTS on), the category
-- word on Removed (expireCategory) for rules that are not one-effect, and the selected LibSharedMedia tones.
local function buildDesired(rules)
    wipe(desired)
    if not available() then return end
    local nativeCategoryBlocked = {}
    for _, rule in ipairs(type(rules) == "table" and rules or {}) do
        if rule.enabled and rule.applyEnabled
            and (not ns.Profiles or not ns.Profiles.RuleMatchesCurrentSpecialization
            or ns.Profiles.RuleMatchesCurrentSpecialization(rule)) then
            for _, spellID in ipairs(type(rule.spellIDs) == "table" and rule.spellIDs or {}) do
                if type(spellID) == "number" and spellID > 0 and spellID == math.floor(spellID)
                    and fallback.GetCategorySoundFile(applyCue(rule, spellID)) and addonCanSpeak(spellID, rule) then
                    -- The cast path speaks the TTS even in combat, so the category word is only a fallback
                    -- for auras without such a path (e.g. Blessing of Protection).
                    nativeCategoryBlocked[spellID] = true
                end
            end
        end
    end
    for _, rule in ipairs(type(rules) == "table" and rules or {}) do
        if rule.enabled and (not ns.Profiles or not ns.Profiles.RuleMatchesCurrentSpecialization
            or ns.Profiles.RuleMatchesCurrentSpecialization(rule)) then
            -- The category word on Removed only for rules whose end is one aura's end: a one-effect rule ends
            -- with its last trigger, which WoW cannot express natively (the readable debuff speaks it).
            local expireCategoryConfigured = not rule.oneEffect and fallback.GetCategorySoundFile(rule.expireCategory) or nil
            -- One-effect rule with a readable trigger: the addon speaks the start itself for every trigger,
            -- as long as application TTS is on; otherwise the category word is the fallback.
            local oneEffectReadable = false
            if rule.oneEffect and rule.applyEnabled and ns._Aura and ns._Aura.auraSecrecy then
                for _, spellID in ipairs(type(rule.spellIDs) == "table" and rule.spellIDs or {}) do
                    if ns._Aura.auraSecrecy(spellID) == "never" then oneEffectReadable = true; break end
                end
            end
            local applyMediaSound = rule.applySoundEnabled and selectedMediaSound(rule, "apply")
            local expireMediaSound = rule.expireSoundEnabled and selectedMediaSound(rule, "expire")
            for _, spellID in ipairs(type(rule.spellIDs) == "table" and rule.spellIDs or {}) do
                if type(spellID) == "number" and spellID > 0 and spellID == math.floor(spellID) then
                    -- Never-secret auras stay readable in combat, so the addon speaks them itself (TTS on).
                    local neverSecret = ns._Aura and ns._Aura.auraSecrecy and ns._Aura.auraSecrecy(spellID) == "never"
                    local readable = oneEffectReadable or (rule.applyEnabled and neverSecret)
                    -- The category word of this effect: the group's, or its own when the group has none.
                    local categoryConfigured = fallback.GetCategorySoundFile(applyCue(rule, spellID))
                    local categorySoundFile = not nativeCategoryBlocked[spellID] and not readable and categoryConfigured or nil
                    local applySound = categorySoundFile or (not categoryConfigured and applyMediaSound) or nil
                    if applySound then
                        local trigger = Enum.UnitAuraSoundTrigger.Added
                        local key = tostring(spellID) .. ":" .. tostring(trigger)
                        local channel = ruleSoundChannel(rule, "apply")
                        local current = desired[key]
                        if not current or (categorySoundFile and not current.category)
                            or (applyMediaSound and not current.category and current.soundFile ~= applyMediaSound)
                            or (not current.category and current.channel == "Master" and channel ~= "Master") then
                            desired[key] = { spellID = spellID, trigger = trigger, channel = channel,
                                soundFile = applySound, category = categorySoundFile ~= nil,
                                signature = applySound .. "|" .. channel }
                        end
                    end
                    -- The category word on Removed, unless the addon speaks the end itself (readable aura, TTS on).
                    local expireCategoryFile = not (rule.expireEnabled and neverSecret) and expireCategoryConfigured or nil
                    local expireSound = expireCategoryFile or (not expireCategoryConfigured and expireMediaSound) or nil
                    if expireSound then
                        local trigger = Enum.UnitAuraSoundTrigger.Removed
                        local key = tostring(spellID) .. ":" .. tostring(trigger)
                        local channel = ruleSoundChannel(rule, "expire")
                        local current = desired[key]
                        if not current or current.soundFile ~= expireSound
                            or (current.channel == "Master" and channel ~= "Master") then
                            desired[key] = { spellID = spellID, trigger = trigger, channel = channel,
                                soundFile = expireSound, signature = expireSound .. "|" .. channel }
                        end
                    end
                end
            end
        end
    end
end

-- Registration is restricted throughout encounters/keys/PvP as well as direct combat.
-- Query the state (including Activating), not IsAddOnRestrictionActive: that predicate
-- deliberately returns false while ADDON_RESTRICTION_STATE_CHANGED is being dispatched.
function fallback.IsRegistrationRestricted()
    if InCombatLockdown and InCombatLockdown() then return true end
    local api = C_RestrictedActions
    local types = Enum and Enum.AddOnRestrictionType
    if not (api and type(api.GetAddOnRestrictionState) == "function" and types) then return false end
    local inactive = Enum.AddOnRestrictionState and Enum.AddOnRestrictionState.Inactive or 0
    for _, name in ipairs({ "Combat", "Encounter", "ChallengeMode", "PvPMatch", "Map" }) do
        if types[name] ~= nil then
            local ok, state = pcall(api.GetAddOnRestrictionState, types[name])
            if not ok or type(state) ~= "number" or (issecretvalue and issecretvalue(state)) then return true end
            if state ~= inactive then return true end
        end
    end
    return false
end

local function reconcile(force)
    scheduled = false
    if fallback.IsRegistrationRestricted() then
        queued = true
        lastStatus.queued = true
        updateStatus()
        return
    end

    queued = false
    local apiAvailable = not not available()
    local wantedCount, refused = 0, 0
    if apiAvailable then
        for key, entry in pairs(registered) do
            local nextEntry = desired[key]
            if not nextEntry or nextEntry.signature ~= entry.signature then
                local ok = pcall(C_UnitAuras.RemoveAuraSound, entry.id)
                if ok then
                    registered[key] = nil
                else
                    entry.removeFailed = true
                    refused = refused + 1
                    appendLog("NATIVE", "remove-failed key=" .. key)
                end
            end
        end

        for key, entry in pairs(desired) do
            wantedCount = wantedCount + 1
            local current = registered[key]
            if current and current.signature == entry.signature then
                current.removeFailed = nil
                failed[key] = nil
            elseif current then
                -- Keep the old handle and retry removal before adding a replacement for this key.
                if not current.removeFailed then refused = refused + 1 end
            elseif force or failed[key] ~= entry.signature then
                local ok, soundID = pcall(C_UnitAuras.AddAuraSound, entry.trigger, {
                    unitToken = "player",
                    spellID = entry.spellID,
                    soundFileName = entry.soundFile,
                    outputChannel = entry.channel,
                })
                if ok and soundID then
                    registered[key] = { id = soundID, signature = entry.signature }
                    failed[key] = nil
                    appendLog("NATIVE", "registered spell=" .. entry.spellID .. " trigger=" .. tostring(entry.trigger))
                else
                    failed[key] = entry.signature
                    refused = refused + 1
                    appendLog("NATIVE", "registration-refused spell=" .. entry.spellID .. " trigger=" .. tostring(entry.trigger))
                end
            else
                refused = refused + 1
            end
        end
    end

    local registeredCount, removeFailed = 0, 0
    for _, entry in pairs(registered) do
        registeredCount = registeredCount + 1
        if entry.removeFailed then removeFailed = removeFailed + 1 end
    end
    lastStatus = {
        available = apiAvailable,
        registered = registeredCount,
        wanted = wantedCount,
        refused = refused,
        removeFailed = removeFailed,
        queued = false,
    }
    updateStatus()
    if refused > 0 and retryCount < 5 and not retryScheduled then
        retryCount = retryCount + 1
        retryScheduled = true
        C_Timer.After(3, function()
            retryScheduled = false
            if fallback.IsRegistrationRestricted() then
                queued = true
                lastStatus.queued = true
                updateStatus()
                return
            end
            fallback.Refresh(lastRules, true)
        end)
    elseif refused == 0 then
        retryCount = 0
    end
end

local function scheduleReconcile(force)
    scheduledForce = scheduledForce or force == true
    if scheduled then return end
    scheduled = true
    C_Timer.After(0, function()
        local retry = scheduledForce
        scheduledForce = false
        reconcile(retry)
    end)
end

function fallback.Refresh(rules, force)
    if type(rules) == "table" then lastRules = rules end
    buildDesired(lastRules)
    if fallback.IsRegistrationRestricted() then
        queued = true
        lastStatus.queued = true
        updateStatus()
        return
    end
    scheduleReconcile(force == true)
end

local regenFrame = CreateFrame("Frame")
regenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
if C_RestrictedActions and type(C_RestrictedActions.GetAddOnRestrictionState) == "function" then
    regenFrame:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
end
regenFrame:SetScript("OnEvent", function()
    if queued then
        wipe(failed)
        retryCount = 0
        fallback.Refresh(lastRules, true)
    end
end)
