-- /wvdebug sim: plays a Bloodlust through the real aura code path with fake aura data, so the rule
-- "Heroism / Bloodlust" can be checked without a second player.  Nothing here runs unless the command is used.
-- getAura() and aurasAreSecret() in WoWraVox.lua consult ns._Aura.sim while a simulation is active.
local _, ns = ...

local sim = {}
ns.Simulation = sim

local PRESET_ID = "heroism-bloodlust"
local BUFF_ID, DEBUFF_ID = 2825, 57724 -- Bloodlust and Sated
local BUFF_SECONDS, DEBUFF_SECONDS = 6, 14 -- real life: 40 s and 10 min
local SETTLE_SECONDS = 1.5 -- grace after the debuff ends before the result is judged
local GAP_SECONDS = 3

local running, session = false, 0

local function say(line)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffd8b65aWoWraVox sim:|r " .. line) end
end

local function findRule()
    for _, rule in ipairs(WoWraVoxDB and WoWraVoxDB.auras or {}) do
        if rule.presetID == PRESET_ID then return rule end
    end
end

local function hasID(rule, spellID)
    for _, id in ipairs(rule.spellIDs or {}) do
        if id == spellID then return true end
    end
    return false
end

-- Fake aura source for getAura(): hidden auras read as "unreadable", finished ones as absent.
local function makeSource(hiddenIDs, expiry, secret)
    local source = { secret = secret }
    function source.getAura(spellID)
        local endsAt = expiry[spellID]
        if not endsAt or GetTime() >= endsAt then return nil, true end
        if hiddenIDs[spellID] then return nil, false end
        return { spellId = spellID, auraInstanceID = 900000 + spellID, expirationTime = endsAt }, true
    end
    return source
end

local function finish()
    running = false
    ns._Aura.sim = nil
    if sim.originalQueueTTS then
        ns._Aura.queueTTS = sim.originalQueueTTS
        sim.originalQueueTTS = nil
    end
    if ns._Aura.syncAllAuras then ns._Aura.syncAllAuras(true) end
end

local function judge(rule, label, spoken)
    local expectApply = rule.applyEnabled and rule.applyMessage ~= ""
    local expectExpire = rule.expireEnabled and rule.expireMessage ~= ""
    local applyCount, expireCount, strays = 0, 0, 0
    local expireAt
    for _, entry in ipairs(spoken) do
        if entry.at < SETTLE_SECONDS then applyCount = applyCount + 1
        elseif entry.at >= DEBUFF_SECONDS - 0.5 then expireCount = expireCount + 1; expireAt = entry.at
        else strays = strays + 1 end
    end
    local okApply = applyCount == (expectApply and 1 or 0)
    local okExpire = expireCount == (expectExpire and 1 or 0)
    local okStray = strays == 0
    say(string.format("%s: start %d/%d %s | buff end (t=%ds) silent %s | end %d/%d%s %s", label,
        applyCount, expectApply and 1 or 0, okApply and "OK" or "FAIL",
        BUFF_SECONDS, okStray and "OK" or ("FAIL (" .. strays .. " stray)"),
        expireCount, expectExpire and 1 or 0, expireAt and string.format(" at %.1fs", expireAt) or "",
        okExpire and "OK" or "FAIL"))
    return okApply and okExpire and okStray
end

local function runScenario(rule, label, secret, onDone)
    local token = session
    local start = GetTime()
    local expiry = { [BUFF_ID] = start + BUFF_SECONDS, [DEBUFF_ID] = start + DEBUFF_SECONDS }
    -- In combat the buff is hidden from addons; the Sated debuff is marked readable by Blizzard.
    local hidden = secret and { [BUFF_ID] = true } or {}
    ns._Aura.sim = makeSource(hidden, expiry, secret)

    local spoken = {}
    sim.originalQueueTTS = sim.originalQueueTTS or ns._Aura.queueTTS
    local original = sim.originalQueueTTS
    ns._Aura.queueTTS = function(voiceID, message, volume, speedPercent)
        table.insert(spoken, { text = message, at = GetTime() - start })
        return original(voiceID, message, volume, speedPercent)
    end

    ns._Aura.clearEventState(BUFF_ID)
    ns._Aura.clearEventState(DEBUFF_ID)
    ns._Aura.processAura(BUFF_ID, false, "SIM")
    ns._Aura.processAura(DEBUFF_ID, false, "SIM")
    -- The buff's end comes with a UNIT_AURA event in the real game.
    C_Timer.After(BUFF_SECONDS + 0.2, function()
        if token == session and running then ns._Aura.processAura(BUFF_ID, false, "SIM") end
    end)
    C_Timer.After(DEBUFF_SECONDS + SETTLE_SECONDS, function()
        if token ~= session or not running then return end
        local passed = judge(rule, label, spoken)
        onDone(passed)
    end)
end

function sim.Stop()
    if not running then return end
    session = session + 1
    finish()
    say("stopped.")
end

function sim.Start()
    if running then say("already running (/wvdebug sim stop to abort)."); return end
    if InCombatLockdown and InCombatLockdown() then say("not available in combat."); return end
    local rule = findRule()
    if not (rule and rule.enabled and hasID(rule, BUFF_ID) and hasID(rule, DEBUFF_ID)) then
        say("the rule \"Heroism / Bloodlust\" must be active and contain " .. BUFF_ID .. " and " .. DEBUFF_ID .. ".")
        return
    end
    if not (rule.applyEnabled or rule.expireEnabled) then
        say("switch on Application or Expiration text-to-speech for the rule first.")
        return
    end
    running = true
    session = session + 1
    local token = session
    say(string.format("playing a Bloodlust: buff %ds, Sated %ds (about %ds in total). Listen for one start and one end.",
        BUFF_SECONDS, DEBUFF_SECONDS, 2 * (DEBUFF_SECONDS + SETTLE_SECONDS) + GAP_SECONDS))
    runScenario(rule, "A in combat (buff hidden)", true, function(passedA)
        if token ~= session then return end
        ns._Aura.sim = nil
        C_Timer.After(GAP_SECONDS, function()
            if token ~= session or not running then return end
            runScenario(rule, "B out of combat (both readable)", false, function(passedB)
                if token ~= session then return end
                finish()
                say((passedA and passedB) and "PASS" or "FAIL")
            end)
        end)
    end)
end
