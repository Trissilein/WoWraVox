local _, ns = ...

local tracking = ns.SkillTracking or {}
ns.SkillTracking = tracking

tracking.states = tracking.states or {}
tracking.debugLog = tracking.debugLog or {}
tracking.debugDedupe = tracking.debugDedupe or {}
tracking.inactiveRules = tracking.inactiveRules or {}
tracking.durationFrames = tracking.durationFrames or {}
tracking.debugEnabled = false
tracking.maxDebugLines = 180
tracking.maxLearningResults = 40
tracking.triggerTypes = {
    { value = "offCooldown", label = "Comes off Cooldown", help = "Announce when this spell's genuine cooldown ends; ignore the global cooldown. WoW may hide cooldown data during combat, so this trigger can miss the event.", kind = "cooldown" },
    { value = "onCooldown", label = "Goes on Cooldown", help = "Announce when this spell starts a genuine cooldown. WoW may hide cooldown data during combat, so this trigger can miss the event.", kind = "cooldown" },
    { value = "chargeGained", label = "Gains a Charge", help = "Announce when this spell recovers a charge. WoW may hide charge data during combat, so this trigger can miss the event.", kind = "charge" },
    { value = "chargeSpent", label = "Spends a Charge", help = "Announce when this spell consumes a charge. WoW may hide charge data during combat, so this trigger can miss the event.", kind = "charge" },
    { value = "castSucceeded", label = "Cast succeeds", help = "Announce after you successfully cast this spell.", kind = "cast" },
}

local triggerTypeByValue = {}
for _, trigger in ipairs(tracking.triggerTypes) do triggerTypeByValue[trigger.value] = trigger end

local function safeNumber(value)
    return not (issecretvalue and issecretvalue(value)) and type(value) == "number"
        and value == value and value ~= math.huge and value ~= -math.huge
end

local function publicInteger(value)
    return safeNumber(value) and value > 0 and value == math.floor(value)
end

local function rawIndex(object, key) return object[key] end

local function safeField(object, key)
    if type(object) ~= "table" or (issecrettable and issecrettable(object)) then return nil, false end
    local ok, value = pcall(rawIndex, object, key)
    if not ok or (issecretvalue and issecretvalue(value)) then return nil, false end
    return value, true
end

function tracking.NormalizeRule(rule)
    if type(rule) ~= "table" or not triggerTypeByValue[rule.triggerType] then
        if type(rule) == "table" then rule.triggerType = "offCooldown" end
    end
end

function tracking.GetTriggerLabel(value)
    local choice = triggerTypeByValue[value]
    return choice and choice.label or "Comes off Cooldown"
end

function tracking.GetTriggerDescription(value)
    local choice = triggerTypeByValue[value]
    return choice and choice.help or tracking.triggerTypes[1].help
end

function tracking.ResetRule(rule)
    local state = tracking.states[rule]
    if state then state.durationGeneration = (state.durationGeneration or 0) + 1 end
    local frame = tracking.durationFrames[rule]
    if frame then
        frame.watchState = nil
        frame.watchGeneration = nil
        pcall(frame.SetCooldown, frame, 0, 0)
    end
    tracking.states[rule] = nil
    tracking.inactiveRules[rule] = nil
end

function tracking.ResetAll()
    for rule in pairs(tracking.durationFrames) do tracking.ResetRule(rule) end
    wipe(tracking.states)
    wipe(tracking.inactiveRules)
end

-- notify receives (rule, cause, sourceEvent); per-rule notification settings stay on rule.
function tracking.Configure(isRuleActive, notify, locale, addAuraRule, applyTrigger)
    tracking.isRuleActive = isRuleActive
    tracking.notify = notify
    tracking.locale = locale
    tracking.addAuraRule = addAuraRule
    tracking.applyTrigger = applyTrigger
end

local function text(key)
    return tracking.locale and tracking.locale(key) or key
end

local function addDebug(rule, event, reason, cooldown, charges)
    if not tracking.debugEnabled or not rule then return end
    local id = rule.id or "?"
    local reasonText = tostring(reason)
    if reasonText:find("unavailable", 1, true) then
        local key = table.concat({ tostring(id), tostring(event), reasonText }, ":")
        local now = GetTime()
        local previous = tracking.debugDedupe[key]
        if previous and now - previous < 2 then return end
        tracking.debugDedupe[key] = now
    end
    local timeText = date("%H:%M:%S")
    local function shown(value)
        if value == nil then return "?" end
        return tostring(value)
    end
    local cd = cooldown and string.format("cd=%s/%s enabled=%s gcd=%s",
        shown(cooldown.startTime), shown(cooldown.duration), shown(cooldown.isEnabled), shown(cooldown.isOnGCD)) or "cd=?"
    local charge = charges and string.format("charges=%s/%s", shown(charges.current), shown(charges.maximum)) or "charges=?"
    local line = string.format("%s rule=%s spell=%s trigger=%s event=%s reason=%s %s %s",
        timeText, tostring(id), tostring(rule.spellID), tostring(rule.triggerType or "offCooldown"), tostring(event), tostring(reason), cd, charge)
    table.insert(tracking.debugLog, line)
    if #tracking.debugLog > tracking.maxDebugLines then table.remove(tracking.debugLog, 1) end
    if ns.AuraSoundFallback then ns.AuraSoundFallback.Log("SPELL", line) end
end

local function readCooldown(spellID)
    if not (C_Spell and C_Spell.GetSpellCooldown) then return nil, false end
    local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
    if not ok or type(info) ~= "table" or (issecrettable and issecrettable(info)) then return nil, false end
    local startTime, startOK = safeField(info, "startTime")
    local duration, durationOK = safeField(info, "duration")
    local isEnabled, enabledOK = safeField(info, "isEnabled")
    local isOnGCD, gcdOK = safeField(info, "isOnGCD")
    if not (startOK and durationOK and enabledOK and safeNumber(startTime) and safeNumber(duration)
        and type(isEnabled) == "boolean") then return nil, false end
    if not gcdOK then isOnGCD = nil end
    return { startTime = startTime, duration = duration, isEnabled = isEnabled, isOnGCD = isOnGCD }, true
end

local function readCharges(spellID)
    if not (C_Spell and C_Spell.GetSpellCharges) then return nil, false end
    local ok, info = pcall(C_Spell.GetSpellCharges, spellID)
    if not ok then return nil, false end
    if info == nil then return { available = false }, true end
    if type(info) ~= "table" or (issecrettable and issecrettable(info)) then return nil, false end
    local current, currentOK = safeField(info, "currentCharges")
    local maximum, maximumOK = safeField(info, "maxCharges")
    if not (currentOK and maximumOK and safeNumber(current) and safeNumber(maximum)) then return nil, false end
    if maximum <= 0 or current < 0 or current > maximum then return { available = false }, true end
    local cooldownStartTime, startOK = safeField(info, "cooldownStartTime")
    local cooldownDuration, durationOK = safeField(info, "cooldownDuration")
    return {
        available = true,
        current = current,
        maximum = maximum,
        cooldownStartTime = startOK and safeNumber(cooldownStartTime) and cooldownStartTime or nil,
        cooldownDuration = durationOK and safeNumber(cooldownDuration) and cooldownDuration or nil,
    }, true
end

function tracking.HasCharges(spellID)
    local charges, ok = readCharges(spellID)
    return ok and charges and charges.available == true or false
end

local function matchesGlobalCooldown(cooldown, event)
    if event == "SPELL_UPDATE_COOLDOWN" and cooldown.isOnGCD == true then return true end
    if event == "SPELL_UPDATE_COOLDOWN" and cooldown.isOnGCD == false then return false end
    if cooldown.duration <= 0 then return false end
    local gcdInfo, ok = readCooldown(61304)
    if not ok or gcdInfo.duration <= 0 or gcdInfo.startTime <= 0 then return false end
    return math.abs(cooldown.startTime - gcdInfo.startTime) <= 0.05
        and math.abs(cooldown.duration - gcdInfo.duration) <= 0.05
end

local function fire(rule, event, cause, cooldown, charges)
    addDebug(rule, event, "announce:" .. cause, cooldown, charges)
    if tracking.notify then tracking.notify(rule, cause, event) end
end

local function invalidateReadyTimer(state)
    state.timerEnd = nil
    state.timerGeneration = (state.timerGeneration or 0) + 1
end

local function scheduleReady(rule, state)
    if not state.cooldownEnd then
        invalidateReadyTimer(state)
        return
    end
    if state.timerEnd == state.cooldownEnd then return end
    state.timerEnd = state.cooldownEnd
    state.timerGeneration = (state.timerGeneration or 0) + 1
    local expectedEnd = state.cooldownEnd
    local expectedGeneration = state.timerGeneration
    C_Timer.After(math.max(0.1, expectedEnd - GetTime() + 0.08), function()
        if tracking.states[rule] == state and state.cooldownEnd == expectedEnd
            and state.timerEnd == expectedEnd and state.timerGeneration == expectedGeneration then
            state.timerEnd = nil
            state.timerGeneration = state.timerGeneration + 1
            tracking.CheckRule(rule, "TIMER", state, expectedEnd)
        else
            addDebug(rule, "TIMER", "stale-timer-ignored", nil, nil)
        end
    end)
end

local function isActiveCooldown(cooldown, now)
    return cooldown.isEnabled ~= false and cooldown.startTime > 0 and cooldown.duration > 0
        and cooldown.startTime + cooldown.duration > now + 0.12
end

local function isActiveRule(rule)
    return rule and rule.enabled ~= false and publicInteger(rule.spellID)
        and tracking.isRuleActive and tracking.isRuleActive(rule)
end

local refreshDurationWatch
local processChargeSnapshot
local shouldScheduleReady

local function clearDurationWatch(rule, state)
    local frame = tracking.durationFrames[rule]
    if state then state.durationGeneration = (state.durationGeneration or 0) + 1 end
    if frame and (not state or frame.watchState == state) then
        frame.watchState = nil
        frame.watchGeneration = nil
        pcall(frame.SetCooldown, frame, 0, 0)
    end
end

local function getDurationFrame(rule)
    local frame = tracking.durationFrames[rule]
    if frame or not (CreateFrame and UIParent) then return frame end
    local ok, created = pcall(CreateFrame, "Cooldown", nil, UIParent)
    if not ok or not created then return nil end
    frame = created
    frame:SetSize(1, 1)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetAlpha(0)
    frame:Show()
    frame:SetScript("OnCooldownDone", function(self)
        local state = self.watchState
        if not state or tracking.states[rule] ~= state or state.durationGeneration ~= self.watchGeneration then
            addDebug(rule, "OnCooldownDone", "stale-duration-callback-ignored")
            return
        end
        self.watchState = nil
        self.watchGeneration = nil
        local cooldown, cooldownOK = readCooldown(rule.spellID)
        local charges, chargesOK = readCharges(rule.spellID)
        if isActiveRule(rule) and rule.triggerType == "chargeGained" then
            if chargesOK and charges and charges.available then
                -- Readable: fires only on a real increase, so a parallel SPELL_UPDATE_CHARGES cannot double it.
                processChargeSnapshot(rule, "OnCooldownDone", state, charges, cooldown, cooldownOK)
            else
                -- Hidden count: the finished recharge itself is the evidence. Forget the stale count so the
                -- next readable snapshot re-baselines silently instead of announcing the same gain again.
                state.charges = nil
                fire(rule, "OnCooldownDone", "chargeGained", cooldown, nil)
            end
            refreshDurationWatch(rule, state, "OnCooldownDone", cooldown, cooldownOK, charges, chargesOK)
            return
        end
        if not isActiveRule(rule) or rule.triggerType ~= "offCooldown" then
            addDebug(rule, "OnCooldownDone", "duration-callback-rule-inactive", cooldown, charges)
            return
        end
        if cooldownOK and cooldown.isEnabled == false then
            addDebug(rule, "OnCooldownDone", "cooldown-held", cooldown, charges)
            return
        end
        local chargeRule = state.chargeTracking == true or (chargesOK and charges and charges.available)
        if chargesOK and charges and charges.available then
            processChargeSnapshot(rule, "OnCooldownDone", state, charges, cooldown, cooldownOK)
        end
        if cooldownOK and matchesGlobalCooldown(cooldown, "SPELL_UPDATE_COOLDOWN") then
            addDebug(rule, "OnCooldownDone", "global-cooldown-ignored", cooldown, charges)
            return
        end
        if cooldownOK and isActiveCooldown(cooldown, GetTime()) then
            state.cooldownActive = true
            state.cooldownEnd = cooldown.startTime + cooldown.duration
            if shouldScheduleReady(rule, state) then scheduleReady(rule, state) end
            refreshDurationWatch(rule, state, "OnCooldownDone", cooldown, cooldownOK, charges, chargesOK)
            addDebug(rule, "OnCooldownDone", "duration-callback-cooldown-still-active", cooldown, charges)
            return
        end
        if chargeRule then
            state.cooldownActive = false
            state.cooldownEnd = nil
            invalidateReadyTimer(state)
            if not chargesOK or not (charges and charges.available) then
                addDebug(rule, "OnCooldownDone", "duration-callback-charges-unavailable", cooldown, charges)
            elseif charges.current == 0 then
                addDebug(rule, "OnCooldownDone", "duration-callback-charge-still-empty", cooldown, charges)
            elseif not state.notified then
                addDebug(rule, "OnCooldownDone", "duration-callback-ready-unconfirmed", cooldown, charges)
            end
            return
        end
        state.cooldownActive = false
        state.cooldownEnd = nil
        invalidateReadyTimer(state)
        if not state.notified then
            state.notified = true
            fire(rule, "OnCooldownDone", "offCooldown", cooldown, chargesOK and charges or nil)
        else
            addDebug(rule, "OnCooldownDone", "duplicate-ready-callback-ignored", cooldown, charges)
        end
    end)
    tracking.durationFrames[rule] = frame
    return frame
end

local function shouldWatchCooldown(rule, state, event, cooldown, cooldownOK, charges, chargesOK)
    if rule.triggerType == "chargeGained" then
        -- A recharge is pending unless a readable snapshot shows full charges.
        local readable = chargesOK and charges and charges.available
        return (state.chargeTracking == true or readable == true)
            and not (readable and charges.current >= charges.maximum)
    end
    if rule.triggerType ~= "offCooldown" then return false end
    if cooldownOK and cooldown.isEnabled == false then return false end
    local cooldownEvent = event == "OnCooldownDone" and "SPELL_UPDATE_COOLDOWN" or event
    if cooldownOK and isActiveCooldown(cooldown, GetTime())
        and not matchesGlobalCooldown(cooldown, cooldownEvent) then
        return true
    end
    -- Charge recovery itself proves a pending first usable transition. It can
    -- remain readable while the spell cooldown snapshot is secret or global.
    return chargesOK and charges and charges.available and charges.current == 0
end

refreshDurationWatch = function(rule, state, event, cooldown, cooldownOK, charges, chargesOK)
    if rule.triggerType ~= "offCooldown" and rule.triggerType ~= "chargeGained" then
        clearDurationWatch(rule, state)
        return
    end
    local currentFrame = tracking.durationFrames[rule]
    local wasArmed = currentFrame and currentFrame.watchState == state
    if not shouldWatchCooldown(rule, state, event, cooldown, cooldownOK, charges, chargesOK) then
        -- Keep a proven watcher through a secret snapshot. Later events or its
        -- callback can retry; an unknown read must not silently disarm it.
        if wasArmed and ((not cooldownOK and (not chargesOK or not (charges and charges.available)))
            or (state.chargeTracking and not chargesOK)
            or (cooldownOK and state.cooldownActive and matchesGlobalCooldown(cooldown, event))) then
            return
        end
        clearDurationWatch(rule, state)
        return
    end
    -- 12.0.0+, AllowedWhenTainted. Charge spells recover through GetSpellChargeDuration.
    local chargeRecovery = rule.triggerType == "chargeGained"
    local durationAPI = C_Spell and (chargeRecovery and C_Spell.GetSpellChargeDuration or C_Spell.GetSpellCooldownDuration)
    if not durationAPI then
        clearDurationWatch(rule, state)
        addDebug(rule, event, "duration-api-unavailable")
        return
    end
    local ok, duration = pcall(durationAPI, rule.spellID, not chargeRecovery)
    if not ok then
        clearDurationWatch(rule, state)
        addDebug(rule, event, "duration-query-unavailable")
        return
    end
    local frame = duration and (currentFrame or getDurationFrame(rule))
    if not duration or not frame then
        local wasArmed = frame and frame.watchState == state
        clearDurationWatch(rule, state)
        if wasArmed then addDebug(rule, event, "duration-cleared") end
        if duration and not frame then addDebug(rule, event, "duration-frame-unavailable") end
        return
    end
    wasArmed = frame.watchState == state
    state.durationGeneration = (state.durationGeneration or 0) + 1
    frame.watchState = state
    frame.watchGeneration = state.durationGeneration
    local setOK = pcall(frame.SetCooldownFromDurationObject, frame, duration, true)
    if not setOK then
        clearDurationWatch(rule, state)
        addDebug(rule, event, "duration-set-unavailable")
    elseif not wasArmed then
        addDebug(rule, event, "duration-armed")
    end
end

local function canAnnounceChargeReady(cooldown, cooldownOK)
    return not cooldownOK or cooldown.isEnabled ~= false
end

processChargeSnapshot = function(rule, event, state, charges, cooldown, cooldownOK)
    if not (charges and charges.available) then return end
    state.chargeTracking = true
    state.notified = state.notified == true
    local previous = state.charges
    local changed = state.initialized and previous ~= nil and previous ~= charges.current
    local current = charges.current

    if current == 0 then
        state.notified = false
        state.chargeReadyPending = false
    elseif rule.triggerType == "offCooldown"
        and (state.chargeReadyPending or (changed and previous == 0)) then
        clearDurationWatch(rule, state)
        invalidateReadyTimer(state)
        if canAnnounceChargeReady(cooldown, cooldownOK) then
            if not state.notified then
                state.notified = true
                state.chargeReadyPending = false
                fire(rule, event, "offCooldown", cooldown, charges)
            else
                state.chargeReadyPending = false
                addDebug(rule, event, "duplicate-charge-ready-ignored", cooldown, charges)
            end
        else
            state.chargeReadyPending = true
            addDebug(rule, event, "charge-ready-held", cooldown, charges)
        end
    end

    if changed and (event == "SPELL_UPDATE_CHARGES" or event == "OnCooldownDone") then
        local change = current > previous and "chargeGained" or "chargeSpent"
        if rule.triggerType == change then
            fire(rule, event, change, cooldown, charges)
        else
            addDebug(rule, event, change .. ":ignored", cooldown, charges)
        end
    end

    state.charges = current
    state.maxCharges = charges.maximum
    state.chargeRecoveryPending = current == 0
end

shouldScheduleReady = function(rule, state)
    return rule.triggerType == "offCooldown"
        and (not state.chargeTracking or state.charges == 0)
end

local function processCooldownSnapshot(rule, event, state, cooldown, cooldownOK, charges, now)
    if not cooldownOK then return end
    local globalCooldown = matchesGlobalCooldown(cooldown, event)
    if globalCooldown then
        if state.cooldownActive == nil then state.cooldownActive = false end
        addDebug(rule, event, "global-cooldown-ignored", cooldown, charges)
        return
    end
    if cooldown.isEnabled == false then
        if state.cooldownActive == nil then state.cooldownActive = false end
        addDebug(rule, event, "cooldown-held", cooldown, charges)
        return
    end

    local active = isActiveCooldown(cooldown, now)
    local baseline = event == "BASELINE" or not state.initialized or state.cooldownActive == nil
    if baseline then
        state.cooldownActive = active
        state.cooldownEnd = active and cooldown.startTime + cooldown.duration or nil
        if not state.chargeTracking then state.notified = false end
        if active and shouldScheduleReady(rule, state) then scheduleReady(rule, state) end
        addDebug(rule, event, state.initialized and "baseline-after-unavailable-data" or "baseline", cooldown, charges)
        return
    end

    if active then
        local newEnd = cooldown.startTime + cooldown.duration
        if not state.cooldownActive then
            state.cooldownActive = true
            if not state.chargeTracking then state.notified = false end
            if event ~= "TIMER" and rule.triggerType == "onCooldown" then
                fire(rule, event, "onCooldown", cooldown, charges)
            end
        elseif not state.cooldownEnd or math.abs(state.cooldownEnd - newEnd) > 0.25 then
            if not state.chargeTracking then state.notified = false end
            addDebug(rule, event, "cooldown-end-changed", cooldown, charges)
        end
        state.cooldownEnd = newEnd
        if shouldScheduleReady(rule, state) then
            scheduleReady(rule, state)
        else
            invalidateReadyTimer(state)
        end
    elseif state.cooldownActive then
        state.cooldownActive = false
        state.cooldownEnd = nil
        invalidateReadyTimer(state)
        if not state.chargeTracking and rule.triggerType == "offCooldown" and not state.notified then
            clearDurationWatch(rule, state)
            state.notified = true
            fire(rule, event, "offCooldown", cooldown, charges)
        else
            addDebug(rule, event, "cooldown-ended", cooldown, charges)
        end
    end
end

function tracking.CheckRule(rule, event, expectedState, expectedEnd)
    if not isActiveRule(rule) then
        if not tracking.inactiveRules[rule] then
            local reason = rule and rule.enabled == false and "rule-disabled" or "rule-outside-specialization-or-invalid"
            addDebug(rule, event or "BASELINE", reason, nil, nil)
            tracking.inactiveRules[rule] = true
        end
        tracking.ResetRule(rule)
        tracking.inactiveRules[rule] = true
        return
    end
    tracking.inactiveRules[rule] = nil
    local state = tracking.states[rule]
    if expectedState and (state ~= expectedState or state.cooldownEnd ~= expectedEnd) then
        addDebug(rule, event, "stale-timer-ignored", nil, nil)
        return
    end
    if not state then
        state = { initialized = false }
        tracking.states[rule] = state
    end

    local eventName = event or "BASELINE"
    local charges, chargesOK = readCharges(rule.spellID)
    local cooldown, cooldownOK = readCooldown(rule.spellID)
    if not cooldownOK or not chargesOK then
        local unavailable = {}
        if not cooldownOK then table.insert(unavailable, "cooldown") end
        if not chargesOK then table.insert(unavailable, "charges") end
        local reason = #unavailable == 2 and "cooldown-and-charges-unavailable" or (unavailable[1] .. "-unavailable")
        addDebug(rule, eventName, reason, cooldown, charges)
    elseif eventName == "SPELL_UPDATE_COOLDOWN" then
        addDebug(rule, eventName, "snapshot", cooldown, charges)
    end

    if eventName ~= "TIMER" then
        refreshDurationWatch(rule, state, eventName, cooldown, cooldownOK, charges, chargesOK)
    end
    if chargesOK and charges and charges.available then
        processChargeSnapshot(rule, eventName, state, charges, cooldown, cooldownOK)
    end

    processCooldownSnapshot(rule, eventName, state, cooldown, cooldownOK, charges, GetTime())
    state.initialized = true
end

function tracking.Scan(rules, event)
    if type(rules) ~= "table" then return end
    for _, rule in ipairs(rules) do tracking.CheckRule(rule, event) end
end

function tracking.OnCast(spellID, castGUID, rules)
    if castGUID ~= nil and issecretvalue and issecretvalue(castGUID) then castGUID = nil end
    if not publicInteger(spellID) or type(rules) ~= "table" then return end
    for _, rule in ipairs(rules) do
        if rule.spellID == spellID then
            if not isActiveRule(rule) then
                addDebug(rule, "UNIT_SPELLCAST_SUCCEEDED", "cast-ignored-rule-inactive", nil, nil)
            else
                local state = tracking.states[rule] or {}
                tracking.states[rule] = state
                if castGUID == nil or state.lastCastGUID ~= castGUID then
                    state.lastCastGUID = castGUID
                    local cooldown, cooldownOK = readCooldown(rule.spellID)
                    local charges, chargesOK = readCharges(rule.spellID)
                    if rule.triggerType == "offCooldown" or rule.triggerType == "chargeGained" then
                        refreshDurationWatch(rule, state, "UNIT_SPELLCAST_SUCCEEDED",
                            cooldown, cooldownOK, charges, chargesOK)
                    end
                    addDebug(rule, "UNIT_SPELLCAST_SUCCEEDED", "cast-succeeded", cooldown, charges)
                    if rule.triggerType == "castSucceeded" then
                        fire(rule, "UNIT_SPELLCAST_SUCCEEDED", "castSucceeded", cooldown, charges)
                    else
                        addDebug(rule, "UNIT_SPELLCAST_SUCCEEDED", "cast-ignored-trigger-" .. tostring(rule.triggerType), cooldown, charges)
                    end
                else
                    addDebug(rule, "UNIT_SPELLCAST_SUCCEEDED", "duplicate-cast-ignored", nil, nil)
                end
            end
        end
    end
    tracking.ObserveLearningCast(spellID, castGUID)
end

function tracking.SetDebugEnabled(enabled)
    tracking.debugEnabled = enabled == true
    if ns.AuraSoundFallback then ns.AuraSoundFallback.SetDebugEnabled(tracking.debugEnabled) end
    if tracking.debugEnabled then wipe(tracking.inactiveRules) end
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd8b65aWoWraVox:|r " .. text(tracking.debugEnabled and "Spell and aura debug enabled." or "Spell debug disabled."))
    end
end

function tracking.ClearDebug()
    wipe(tracking.debugLog)
    wipe(tracking.debugDedupe)
    wipe(tracking.inactiveRules)
    if ns.AuraSoundFallback then ns.AuraSoundFallback.ClearLog() end
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffd8b65aWoWraVox:|r " .. text("Combat debug log cleared.")) end
end

function tracking.CreateDebugWindow()
    if tracking.debugWindow then return tracking.debugWindow end
    local frame = CreateFrame("Frame", "WoWraVoxDebugLogWindow", UIParent, "BackdropTemplate")
    frame:SetSize(760, 480)
    frame:SetPoint("CENTER")
    -- Above the options window (DIALOG): inside one strata only frame levels order the children, which
    -- interleaved the two windows' buttons, texts and scroll frames.
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetToplevel(true)
    frame:SetFrameLevel(100)
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "WoWraVoxDebugLogWindow") end
    frame:Hide()
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
    frame:SetBackdropColor(0.025, 0.03, 0.04, 0.98)
    frame:SetBackdropBorderColor(0.7, 0.55, 0.2, 1)
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -14)
    title:SetText(text("Combat debug log"))
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    hint:SetText(text("Click Select all, then press Ctrl+C to copy."))
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -58)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -32, 48)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(GameFontHighlightSmall)
    edit:SetWidth(700)
    edit:SetHeight(360)
    edit:SetTextInsets(4, 4, 4, 4)
    scroll:SetScrollChild(edit)
    frame.edit = edit
    local select = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    select:SetSize(96, 26)
    select:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 12)
    select:SetText(text("Select all"))
    select:SetScript("OnClick", function()
        edit:SetFocus()
        edit:HighlightText()
    end)
    tracking.debugWindow = frame
    return frame
end

function tracking.ShowDebug()
    local frame = tracking.CreateDebugWindow()
    local lines = ns.AuraSoundFallback and ns.AuraSoundFallback.GetLogLines() or tracking.debugLog
    frame.edit:SetText(#lines > 0 and table.concat(lines, "\n") or text("No combat debug entries yet. Enable logging, then reproduce the issue."))
    frame.edit:SetHeight(math.max(360, #lines * 16))
    frame.edit:SetCursorPosition(0)
    frame:Show()
end

function tracking.HandleDebugCommand(command)
    command = (command or ""):lower():match("^%s*(.-)%s*$")
    if command == "on" then tracking.SetDebugEnabled(true)
    elseif command == "off" then tracking.SetDebugEnabled(false)
    elseif command == "show" or command == "" then tracking.ShowDebug()
    elseif command == "clear" then tracking.ClearDebug()
    else
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cffd8b65aWoWraVox:|r " .. text("Use /wvdebug on, off, show, or clear."))
        end
    end
end

local function getAuraSnapshot()
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return nil end
    local snapshot = { byInstance = {}, counts = {} }
    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        for index = 1, 255 do
            local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", index, filter)
            if not ok then return nil end
            if (issecretvalue and issecretvalue(aura)) or (type(aura) == "table" and issecrettable and issecrettable(aura)) then return nil end
            if not aura then break end
            local spellID, idOK = safeField(aura, "spellId")
            local instanceID, instanceOK = safeField(aura, "auraInstanceID")
            if not (idOK and instanceOK and publicInteger(spellID) and publicInteger(instanceID)) then return nil end
            snapshot.byInstance[instanceID] = spellID
            snapshot.counts[spellID] = (snapshot.counts[spellID] or 0) + 1
        end
    end
    return snapshot
end

local function spellName(spellID)
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
        if ok and type(info) == "table" and not (issecrettable and issecrettable(info)) then
            local name, nameOK = safeField(info, "name")
            if nameOK and type(name) == "string" and name ~= "" then return name end
        end
    end
    return text("Spell ID") .. " " .. tostring(spellID)
end

local function addLearningResult(session, kind, triggerType, spellID, event, source, elapsed)
    if #session.results >= tracking.maxLearningResults then return end
    local result = {
        kind = kind,
        triggerType = triggerType,
        spellID = spellID,
        name = spellName(spellID),
        event = event,
        source = source,
        elapsed = elapsed or 0,
    }
    table.insert(session.results, result)
    session.selected = result
    tracking.RenderLearningResults(session)
end

local function currentSession()
    local session = tracking.learning
    if session and session.phase == "observing" and GetTime() <= session.deadline then return session end
end

local function updateLearningCooldown(session, event)
    local cooldown, cdOK = readCooldown(session.spellID)
    local charges, chargesOK = readCharges(session.spellID)
    if cdOK then
        local now = GetTime()
        local active = isActiveCooldown(cooldown, now) and not matchesGlobalCooldown(cooldown, event)
        if active ~= session.cooldownActive then
            local triggerType = active and "onCooldown" or "offCooldown"
            addLearningResult(session, "trigger", triggerType, session.spellID,
                active and "Cooldown started" or "Cooldown ended or reset", event, now - session.castAt)
        end
        session.cooldownActive = active
        session.cooldownEnd = active and (cooldown.startTime + cooldown.duration) or nil
    end
    if chargesOK and charges and charges.available then
        local previous = session.chargeCount
        if previous ~= nil and charges.current ~= previous then
            local gained = charges.current > previous
            addLearningResult(session, "trigger", gained and "chargeGained" or "chargeSpent", session.spellID,
                gained and "Charge gained" or "Charge spent", event, GetTime() - session.castAt)
        end
        session.chargeCount = charges.current
    end
end

function tracking.StartLearning(rule)
    if type(rule) ~= "table" or not publicInteger(rule.spellID) then return false end
    tracking.CancelLearning("restarted", false)
    if tracking.learningWindow then tracking.learningWindow:Hide() end
    tracking.learningSerial = (tracking.learningSerial or 0) + 1
    local session = {
        serial = tracking.learningSerial,
        rule = rule,
        spellID = rule.spellID,
        spellName = rule.name or spellName(rule.spellID),
        phase = "waiting",
        deadline = GetTime() + 20,
        results = {},
        auraSnapshot = getAuraSnapshot(),
    }
    local cooldown, cdOK = readCooldown(rule.spellID)
    local charges, chargesOK = readCharges(rule.spellID)
    session.cooldownActive = cdOK and isActiveCooldown(cooldown, GetTime())
        and not matchesGlobalCooldown(cooldown, "BASELINE") or false
    session.cooldownEnd = session.cooldownActive and (cooldown.startTime + cooldown.duration) or nil
    session.chargeCount = chargesOK and charges and charges.available and charges.current or nil
    tracking.learning = session
    tracking.RenderLearningResults(session)
    tracking.learningWindow:Show()
    if tracking.onLearningChanged then tracking.onLearningChanged(session) end
    tracking.ScheduleLearningTick(session)
    return true
end

function tracking.ScheduleLearningTick(session)
    local serial = session.serial
    C_Timer.After(1, function()
        local active = tracking.learning
        if not (active and active.serial == serial) then return end
        local remaining = math.max(0, math.ceil(active.deadline - GetTime()))
        if remaining == 0 then
            tracking.FinishLearning(active.phase == "waiting" and text("No matching cast was observed.")
                or text("Observation window ended."))
            return
        end
        tracking.RenderLearningResults(active)
        if tracking.onLearningChanged then tracking.onLearningChanged(active, nil, remaining) end
        tracking.ScheduleLearningTick(active)
    end)
end

function tracking.StopLearning()
    if not tracking.learning then return end
    tracking.FinishLearning(text("Learning stopped."))
end

function tracking.CancelLearning(reason, hideResults)
    if not tracking.learning then
        if hideResults and tracking.learningWindow then tracking.learningWindow:Hide() end
        return
    end
    local session = tracking.learning
    session.phase = "cancelled"
    session.status = reason or "Learning cancelled."
    tracking.learning = nil
    if hideResults and tracking.learningWindow then tracking.learningWindow:Hide() end
    if tracking.onLearningChanged then tracking.onLearningChanged(nil, session.status) end
end

function tracking.FinishLearning(status)
    local session = tracking.learning
    if not session then return end
    session.phase = "complete"
    session.status = status or text("Learning complete.")
    session.deadline = GetTime()
    tracking.learning = nil
    tracking.RenderLearningResults(session)
    if tracking.onLearningChanged then tracking.onLearningChanged(session) end
    if tracking.learningWindow then tracking.learningWindow:Show() end
end

function tracking.ObserveLearningCast(spellID, castGUID)
    local session = tracking.learning
    if not (session and session.phase == "waiting" and session.spellID == spellID) then return end
    session.phase = "observing"
    session.castAt = GetTime()
    session.deadline = session.castAt + 8
    session.castGUID = castGUID
    session.auraSnapshot = getAuraSnapshot()
    addLearningResult(session, "trigger", "castSucceeded", spellID, "Cast succeeded", "UNIT_SPELLCAST_SUCCEEDED", 0)
    if tracking.onLearningChanged then tracking.onLearningChanged(session) end
    local serial = session.serial
    C_Timer.After(0.15, function()
        if tracking.learning and tracking.learning.serial == serial and tracking.learning.phase == "observing" then
            updateLearningCooldown(session, "POST_CAST_SAMPLE")
        end
    end)
    tracking.ScheduleLearningTick(session)
end

function tracking.ObserveLearningSpell(event)
    local session = currentSession()
    if session then updateLearningCooldown(session, event) end
end

local function replaceLearningAuraSnapshot(session)
    local current = getAuraSnapshot()
    if not current then session.auraSnapshot = nil; return false end
    local old = session.auraSnapshot
    if old then
        for spellID, count in pairs(current.counts) do
            if count > 0 and not old.counts[spellID] then
                addLearningResult(session, "aura", nil, spellID, "Aura gained", "UNIT_AURA:player", GetTime() - session.castAt)
            end
        end
        for spellID, count in pairs(old.counts) do
            if count > 0 and not current.counts[spellID] then
                addLearningResult(session, "aura", nil, spellID, "Aura lost", "UNIT_AURA:player", GetTime() - session.castAt)
            end
        end
    end
    session.auraSnapshot = current
    return true
end

function tracking.ObserveLearningAuras(updateInfo)
    local session = currentSession()
    if not session then return end
    if not session.auraSnapshot then
        replaceLearningAuraSnapshot(session)
        return
    end
    local old = session.auraSnapshot
    local fullUpdate, fullOK = safeField(updateInfo, "isFullUpdate")
    if not fullOK or fullUpdate then
        replaceLearningAuraSnapshot(session)
        return
    end

    local added, addedOK = safeField(updateInfo, "addedAuras")
    local removed, removedOK = safeField(updateInfo, "removedAuraInstanceIDs")
    if not (addedOK and removedOK and type(added) == "table" and type(removed) == "table") then
        replaceLearningAuraSnapshot(session)
        return
    end
    for _, instanceID in ipairs(removed) do
        if not publicInteger(instanceID) then session.auraSnapshot = nil; return end
        local spellID = old.byInstance[instanceID]
        if spellID then
            old.byInstance[instanceID] = nil
            old.counts[spellID] = math.max(0, (old.counts[spellID] or 1) - 1)
            if old.counts[spellID] == 0 then
                addLearningResult(session, "aura", nil, spellID, "Aura lost", "UNIT_AURA:player", GetTime() - session.castAt)
            end
        else
            session.auraSnapshot = nil
            return
        end
    end
    for _, aura in ipairs(added) do
        local spellID, idOK = safeField(aura, "spellId")
        local instanceID, instanceOK = safeField(aura, "auraInstanceID")
        if not (idOK and instanceOK and publicInteger(spellID) and publicInteger(instanceID)) then
            session.auraSnapshot = nil
            return
        end
        local oldCount = old.counts[spellID] or 0
        old.byInstance[instanceID] = spellID
        old.counts[spellID] = oldCount + 1
        if oldCount == 0 then
            addLearningResult(session, "aura", nil, spellID, "Aura gained", "UNIT_AURA:player", GetTime() - session.castAt)
        end
    end
end

function tracking.CreateLearningWindow()
    if tracking.learningWindow then return tracking.learningWindow end
    local frame = CreateFrame("Frame", "WoWraVoxLearningWindow", UIParent, "BackdropTemplate")
    frame:SetSize(620, 430)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetToplevel(true)
    frame:SetFrameLevel(100)
    frame:Hide()
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
    frame:SetBackdropColor(0.025, 0.03, 0.04, 0.98)
    frame:SetBackdropBorderColor(0.7, 0.55, 0.2, 1)
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -14)
    frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.status:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 0, -8)
    frame.status:SetWidth(570)
    frame.status:SetJustifyH("LEFT")
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    frame.scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    frame.scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -54)
    frame.scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 52)
    frame.child = CreateFrame("Frame", nil, frame.scroll)
    frame.child:SetSize(560, 1)
    frame.scroll:SetScrollChild(frame.child)
    frame.rows = {}
    frame.useButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.useButton:SetSize(130, 28)
    frame.useButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 12)
    frame.useButton:SetText(text("Use trigger"))
    frame.useButton:SetScript("OnClick", function()
        local session = frame.session
        local result = session and session.selected
        if result and result.triggerType and tracking.applyTrigger then
            if tracking.learning == session then tracking.FinishLearning(text("Learning complete.")) end
            tracking.applyTrigger(session.rule, result.triggerType)
        end
    end)
    frame.addAuraButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.addAuraButton:SetSize(160, 28)
    frame.addAuraButton:SetPoint("LEFT", frame.useButton, "RIGHT", 8, 0)
    frame.addAuraButton:SetText(text("Create Aura Rule"))
    frame.addAuraButton:SetScript("OnClick", function()
        local result = frame.session and frame.session.selected
        if result and result.kind == "aura" and tracking.addAuraRule then
            tracking.CancelLearning(nil, true)
            tracking.addAuraRule(result.spellID, result.name)
        end
    end)
    frame.closeButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.closeButton:SetSize(90, 28)
    frame.closeButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 12)
    frame.closeButton:SetText(text("Close"))
    frame.closeButton:SetScript("OnClick", function() frame:Hide() end)
    for index = 1, tracking.maxLearningResults do
        local row = CreateFrame("Button", nil, frame.child)
        row:SetHeight(46)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -4)
        row.text:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -8, 4)
        row.text:SetJustifyH("LEFT")
        row.text:SetJustifyV("MIDDLE")
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.selection = row:CreateTexture(nil, "BACKGROUND")
        row.selection:SetAllPoints()
        row.selection:SetColorTexture(0.72, 0.52, 0.12, 0.18)
        row.selection:Hide()
        row:SetScript("OnClick", function(self)
            frame.session.selected = self.result
            tracking.RenderLearningResults(frame.session)
        end)
        row:Hide()
        frame.rows[index] = row
    end
    tracking.learningWindow = frame
    return frame
end

function tracking.RenderLearningResults(session)
    if not session then return end
    local frame = tracking.CreateLearningWindow()
    frame.session = session
    frame.title:SetText(text("Learning results") .. " · " .. tostring(session.spellName or spellName(session.spellID)))
    frame.status:SetText((session.status or (session.phase == "waiting" and text("Cast the selected spell within 20 seconds.")
        or session.phase == "observing" and text("Watching player cooldown, charges, buffs, and debuffs for 8 seconds.")
        or text("Choose a result, then apply it."))) .. "  " .. text("Aura timing shows correlation, not proof of cause."))
    frame.useButton:SetEnabled(session.selected ~= nil and session.selected.triggerType ~= nil)
    frame.addAuraButton:SetEnabled(session.selected ~= nil and session.selected.kind == "aura")
    for index, result in ipairs(session.results) do
        local row = frame.rows[index]
        row.result = result
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame.child, "TOPLEFT", 0, -(index - 1) * 46)
        row:SetPoint("TOPRIGHT", frame.child, "TOPRIGHT", 0, -(index - 1) * 46)
        row.text:SetText(string.format(text("%s · ID %d\n%s · +%.2fs · %s"), result.name, result.spellID,
            text(result.event), result.elapsed, text(result.source)))
        row.selection:SetShown(result == session.selected)
        row:Show()
    end
    for index = #session.results + 1, #frame.rows do frame.rows[index].result = nil; frame.rows[index]:Hide() end
    frame.child:SetHeight(math.max(1, #session.results * 46))
end

function tracking.HandleEvent(event, ...)
    if event == "SPELL_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_CHARGES" then
        tracking.Scan(WoWraVoxDB and WoWraVoxDB.skills, event)
        tracking.ObserveLearningSpell(event)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellID = ...
        if unit == "player" then tracking.OnCast(spellID, castGUID, WoWraVoxDB and WoWraVoxDB.skills) end
    elseif event == "UNIT_AURA" then
        local unit, updateInfo = ...
        if unit == "player" then tracking.ObserveLearningAuras(updateInfo) end
    end
end
