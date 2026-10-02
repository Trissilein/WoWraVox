local _, ns = ...

local fallback = ns.AuraSoundFallback or {}
ns.AuraSoundFallback = fallback

-- Bundled 2026-09-30 via Windows SAPI Microsoft David en-US; Ogg Vorbis mono 22050 Hz.
fallback.categorySoundFiles = {
    defensive = "Interface\\AddOns\\WoWraVox\\Assets\\Defensive.ogg",
    offensive = "Interface\\AddOns\\WoWraVox\\Assets\\Offensive.ogg",
    bloodlust = "Interface\\AddOns\\WoWraVox\\Assets\\Bloodlust.ogg",
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
local lastStatus = { available = false, registered = 0, wanted = 0, refused = 0, queued = false }

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

function fallback.IsRegistered(spellID, eventKey)
    local event
    if eventKey == "apply" then event = "Added"
    elseif eventKey == "expire" then event = "Removed"
    else return false end
    local trigger = Enum and Enum.UnitAuraSoundTrigger and Enum.UnitAuraSoundTrigger[event]
    if not trigger then return false end
    return registered[tostring(spellID) .. ":" .. tostring(trigger)] ~= nil
end

function fallback.GetCategorySoundFile(category)
    if category == "Defensive cooldown" then category = "defensive"
    elseif category == "Offensive cooldown" then category = "offensive"
    elseif category == "Bloodlust" then category = "bloodlust" end
    return fallback.categorySoundFiles[category]
end

-- Native sounds WoW plays itself (also when the addon cannot read the aura): the category word on Added for
-- auras that are not own self-buffs, and the selected LibSharedMedia tones for Added/Removed.
local function buildDesired(rules)
    wipe(desired)
    if not available() then return end
    local nativeCategoryBlocked = {}
    for _, rule in ipairs(type(rules) == "table" and rules or {}) do
        if rule.enabled and rule.applyEnabled
            and (not ns.Profiles or not ns.Profiles.RuleMatchesCurrentSpecialization
            or ns.Profiles.RuleMatchesCurrentSpecialization(rule))
            and fallback.GetCategorySoundFile(rule.alertCategory) then
            for _, spellID in ipairs(type(rule.spellIDs) == "table" and rule.spellIDs or {}) do
                if type(spellID) == "number" and spellID > 0 and spellID == math.floor(spellID)
                    and ns._Aura and ns._Aura.getSelfBuffStatus
                    and ns._Aura.getSelfBuffStatus(spellID) == "true" then
                    -- Guaranteed self-cast: the cast path speaks the TTS even in combat, so the category word
                    -- is only a fallback for auras without such a path (e.g. Blessing of Protection).
                    nativeCategoryBlocked[spellID] = true
                end
            end
        end
    end
    for _, rule in ipairs(type(rules) == "table" and rules or {}) do
        if rule.enabled and (not ns.Profiles or not ns.Profiles.RuleMatchesCurrentSpecialization
            or ns.Profiles.RuleMatchesCurrentSpecialization(rule)) then
            local categoryConfigured = fallback.GetCategorySoundFile(rule.alertCategory)
            local applyMediaSound = rule.applySoundEnabled and selectedMediaSound(rule, "apply")
            local expireMediaSound = rule.expireSoundEnabled and selectedMediaSound(rule, "expire")
            for _, spellID in ipairs(type(rule.spellIDs) == "table" and rule.spellIDs or {}) do
                if type(spellID) == "number" and spellID > 0 and spellID == math.floor(spellID) then
                    local categorySoundFile = not nativeCategoryBlocked[spellID] and categoryConfigured or nil
                    local applySound = categorySoundFile or (not categoryConfigured and applyMediaSound) or nil
                    if applySound then
                        local trigger = Enum.UnitAuraSoundTrigger.Added
                        local key = tostring(spellID) .. ":" .. tostring(trigger)
                        local channel = rule.applySoundEnabled and rule.applySoundChannel or "Master"
                        local current = desired[key]
                        if not current or (categorySoundFile and not current.category)
                            or (applyMediaSound and not current.category and current.soundFile ~= applyMediaSound)
                            or (not current.category and current.channel == "Master" and channel ~= "Master") then
                            desired[key] = { spellID = spellID, trigger = trigger, channel = channel,
                                soundFile = applySound, category = categorySoundFile ~= nil,
                                signature = applySound .. "|" .. channel }
                        end
                    end
                    if expireMediaSound then
                        local trigger = Enum.UnitAuraSoundTrigger.Removed
                        local key = tostring(spellID) .. ":" .. tostring(trigger)
                        local channel = rule.expireSoundEnabled and rule.expireSoundChannel or "Master"
                        local current = desired[key]
                        if not current or current.soundFile ~= expireMediaSound
                            or (current.channel == "Master" and channel ~= "Master") then
                            desired[key] = { spellID = spellID, trigger = trigger, channel = channel,
                                soundFile = expireMediaSound, signature = expireMediaSound .. "|" .. channel }
                        end
                    end
                end
            end
        end
    end
end

local function reconcile(force)
    scheduled = false
    if InCombatLockdown and InCombatLockdown() then
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
                if not ok then appendLog("NATIVE", "remove-failed key=" .. key) end
                registered[key] = nil
            end
        end

        for key, entry in pairs(desired) do
            wantedCount = wantedCount + 1
            local current = registered[key]
            if current and current.signature == entry.signature then
                failed[key] = nil
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
    else
        for key in pairs(registered) do registered[key] = nil end
    end

    local registeredCount = 0
    for _ in pairs(registered) do registeredCount = registeredCount + 1 end
    lastStatus = {
        available = apiAvailable,
        registered = registeredCount,
        wanted = wantedCount,
        refused = refused,
        queued = false,
    }
    updateStatus()
    if refused > 0 and retryCount < 5 and not retryScheduled then
        retryCount = retryCount + 1
        retryScheduled = true
        C_Timer.After(3, function()
            retryScheduled = false
            if InCombatLockdown and InCombatLockdown() then
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
    if InCombatLockdown and InCombatLockdown() then
        queued = true
        lastStatus.queued = true
        updateStatus()
        return
    end
    buildDesired(lastRules)
    scheduleReconcile(force == true)
end

local regenFrame = CreateFrame("Frame")
regenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
regenFrame:SetScript("OnEvent", function()
    if queued then
        wipe(failed)
        retryCount = 0
        fallback.Refresh(lastRules, true)
    end
end)
