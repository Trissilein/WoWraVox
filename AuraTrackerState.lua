local _, ns = ...

local AuraTrackerState = {}
ns.AuraTrackerState = AuraTrackerState

local function isSecret(value)
    if type(issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(issecretvalue, value)
    return not ok or secret == true
end

local function finiteNumber(value)
    if type(value) ~= "number" or isSecret(value) then return false end
    return value == value and value ~= math.huge and value ~= -math.huge
end

local function publicID(value)
    return finiteNumber(value) and value > 0 and value == math.floor(value) and value or nil
end

local function publicString(value)
    return type(value) == "string" and not isSecret(value) and value or nil
end

local function warningSeconds(value)
    if not finiteNumber(value) then return 5 end
    return math.max(1, math.min(60, value))
end

local function warningPercent(value)
    if not finiteNumber(value) then return nil end
    return math.max(0, math.min(100, math.floor(value + 0.5)))
end

local function snapshot(state)
    if not state then return nil end
    return {
        ruleID = state.ruleID,
        spellID = state.spellID,
        presence = state.presence,
        instanceID = state.instanceID,
        expirationTime = state.expirationTime,
        icon = state.icon,
        stacks = state.stacks,
        source = state.source,
        beforeExpireEnabled = state.beforeExpireEnabled,
        warningPercent = state.warningPercent,
        warningSeconds = state.warningSeconds,
        warningFired = state.warningFired,
    }
end

function AuraTrackerState.Create(api)
    assert(type(api) == "table", "api must be a table")
    assert(type(api.now) == "function", "api.now must be a function")
    assert(type(api.schedule) == "function", "api.schedule must be a function")
    assert(type(api.cancel) == "function", "api.cancel must be a function")
    assert(type(api.emit) == "function", "api.emit must be a function")

    local rules = {}
    local generation = 0

    local function nextGeneration()
        generation = generation + 1
        return generation
    end

    local function cancelTimer(state)
        if state and state.timer ~= nil then
            api.cancel(state.timer)
            state.timer = nil
        end
    end

    local function warningAt(state)
        if not state.beforeExpireEnabled or not state.expirationTime then return nil end
        if state.warningPercent ~= nil then
            if not finiteNumber(state.duration) or state.duration <= 0 then return nil end
            local advance = state.duration * state.warningPercent / 100
            -- Zero means the last safe moment before the separate natural-expiration event.
            if state.warningPercent == 0 then advance = math.min(0.25, state.duration) end
            return state.expirationTime - advance
        end
        return state.expirationTime - state.warningSeconds
    end

    local function contextFor(state, now)
        return {
            ruleID = state.ruleID,
            spellID = state.spellID,
            instanceID = state.instanceID,
            expirationTime = state.expirationTime,
            remaining = math.max(0, state.expirationTime - now),
            warningPercent = state.warningPercent,
            warningSeconds = state.warningSeconds,
            icon = state.icon,
            stacks = state.stacks,
            source = state.source,
        }
    end

    local armWarning
    armWarning = function(state)
        if state.presence ~= "active" or state.warningFired or state.timer ~= nil then return end
        local target = warningAt(state)
        if not target then return end

        local now = api.now()
        if not finiteNumber(now) or state.expirationTime <= now then return end

        local capturedGeneration = state.generation
        local capturedInstanceID = state.instanceID
        local capturedExpiration = state.expirationTime
        local delay = math.max(0, target - now)
        state.timer = api.schedule(delay, function()
            local bucket = rules[state.ruleID]
            if not bucket or bucket[state.spellID] ~= state
                or state.generation ~= capturedGeneration
                or state.instanceID ~= capturedInstanceID
                or state.expirationTime ~= capturedExpiration
                or state.presence ~= "active"
                or not state.beforeExpireEnabled
                or state.warningFired then
                return
            end

            state.timer = nil
            local firedAt = api.now()
            if not finiteNumber(firedAt) or firedAt >= capturedExpiration then return end
            local currentTarget = warningAt(state)
            if not currentTarget then return end
            if firedAt < currentTarget then
                armWarning(state)
                return
            end

            state.warningFired = true
            api.emit(state.ruleID, "beforeExpire", contextFor(state, firedAt))
        end)
    end

    local manager = {}

    function manager:Update(ruleID, spellID, observation, options)
        local validSpellID = publicID(spellID)
        local safeRuleID = publicString(ruleID) or (finiteNumber(ruleID) and ruleID or nil)
        if safeRuleID == nil or not validSpellID or type(observation) ~= "table" then return nil end
        ruleID = safeRuleID

        local bucket = rules[ruleID]
        if not bucket then
            bucket = {}
            rules[ruleID] = bucket
        end

        local previous = bucket[validSpellID]
        local presence = publicString(observation.presence)
        if presence ~= "active" and presence ~= "inactive" then presence = "unknown" end

        options = type(options) == "table" and options or {}
        local enabled = not isSecret(options.beforeExpireEnabled) and options.beforeExpireEnabled == true
        local baseline = not isSecret(options.baseline) and options.baseline == true
        local source = publicString(observation.source)
        local percent = warningPercent(options.warningPercent)
        local seconds = warningSeconds(options.warningSeconds)
        local instanceID = publicID(observation.instanceID)
        local expirationTime = finiteNumber(observation.expirationTime) and observation.expirationTime > 0
            and observation.expirationTime or nil
        local duration = finiteNumber(observation.duration) and observation.duration > 0 and observation.duration or nil
        if source == "cdm" and previous
            and (previous.presence == "active" or previous.presence == "unknown") then
            instanceID = instanceID or previous.instanceID
            expirationTime = expirationTime or previous.expirationTime
            duration = duration or previous.duration
        elseif duration == nil and previous and previous.instanceID == instanceID
            and previous.expirationTime == expirationTime then
            duration = previous.duration
        end

        if presence ~= "active" then
            cancelTimer(previous)
            bucket[validSpellID] = {
                ruleID = ruleID,
                spellID = validSpellID,
                presence = presence,
                instanceID = presence == "unknown" and (instanceID or previous and previous.instanceID) or nil,
                expirationTime = presence == "unknown" and (expirationTime or previous and previous.expirationTime) or nil,
                durationObject = presence == "unknown" and (observation.durationObject or previous and previous.durationObject) or nil,
                duration = presence == "unknown" and (duration or previous and previous.duration) or nil,
                icon = publicString(observation.icon) or (finiteNumber(observation.icon) and observation.icon)
                    or previous and previous.icon,
                stacks = publicID(observation.stacks) or previous and previous.stacks,
                source = source,
                generation = nextGeneration(),
                warningFired = presence == "unknown" and previous and previous.warningFired == true or false,
                beforeExpireEnabled = enabled,
                warningPercent = percent,
                warningSeconds = seconds,
            }
            return snapshot(bucket[validSpellID])
        end

        local sameAura = previous and (previous.presence == "active" or previous.presence == "unknown")
            and previous.instanceID == instanceID
            and previous.expirationTime == expirationTime
        local sameWindow = sameAura
            and previous.beforeExpireEnabled == enabled
            and previous.warningPercent == percent
            and previous.warningSeconds == seconds
            and previous.duration == duration

        if sameWindow then
            previous.presence = "active"
            previous.icon = publicString(observation.icon) or (finiteNumber(observation.icon) and observation.icon)
                or previous.icon
            previous.stacks = publicID(observation.stacks) or (source == "cdm" and previous.stacks or nil)
            previous.source = source
            previous.durationObject = observation.durationObject or (source == "cdm" and previous.durationObject or nil)
            previous.duration = duration
            local target = warningAt(previous)
            local now = api.now()
            if baseline and target and finiteNumber(now) and now >= target
                and not previous.warningFired then
                cancelTimer(previous)
                previous.warningFired = true
            elseif not previous.warningFired and previous.timer == nil then
                armWarning(previous)
            end
            return snapshot(previous)
        end

        cancelTimer(previous)
        local state = {
            ruleID = ruleID,
            spellID = validSpellID,
            presence = "active",
            instanceID = instanceID,
            expirationTime = expirationTime,
            durationObject = observation.durationObject or (source == "cdm" and previous and previous.durationObject or nil),
            duration = duration,
            icon = publicString(observation.icon) or (finiteNumber(observation.icon) and observation.icon)
                or (source == "cdm" and previous and previous.icon or nil),
            stacks = publicID(observation.stacks) or (source == "cdm" and previous and previous.stacks or nil),
            source = source,
            beforeExpireEnabled = enabled,
            warningPercent = percent,
            warningSeconds = seconds,
            warningFired = sameAura and previous.warningFired or false,
            generation = nextGeneration(),
        }
        bucket[validSpellID] = state

        local target = warningAt(state)
        local now = api.now()
        if baseline and target and finiteNumber(now) and now >= target
            and not state.warningFired then
            state.warningFired = true
        else
            armWarning(state)
        end
        return snapshot(state)
    end

    function manager:Get(ruleID, spellID)
        ruleID = publicString(ruleID) or (finiteNumber(ruleID) and ruleID or nil)
        if ruleID == nil then return nil end
        local bucket = rules[ruleID]
        if not bucket then return nil end
        if spellID ~= nil then
            spellID = publicID(spellID)
            return spellID and snapshot(bucket[spellID]) or nil
        end

        local result
        for id, state in pairs(bucket) do
            result = result or {}
            result[id] = snapshot(state)
        end
        return result
    end

    function manager:GetDurationObject(ruleID, spellID)
        ruleID = publicString(ruleID) or (finiteNumber(ruleID) and ruleID or nil)
        spellID = publicID(spellID)
        if ruleID == nil or not spellID then return nil end
        local bucket = rules[ruleID]
        local state = bucket and bucket[spellID]
        return state and state.durationObject or nil
    end

    function manager:ResetRule(ruleID)
        ruleID = publicString(ruleID) or (finiteNumber(ruleID) and ruleID or nil)
        if ruleID == nil then return false end
        local bucket = rules[ruleID]
        if not bucket then return false end
        for _, state in pairs(bucket) do
            cancelTimer(state)
            state.generation = nextGeneration()
        end
        rules[ruleID] = nil
        return true
    end

    function manager:Reset()
        for _, bucket in pairs(rules) do
            for _, state in pairs(bucket) do
                cancelTimer(state)
                state.generation = nextGeneration()
            end
        end
        rules = {}
    end

    return manager
end
