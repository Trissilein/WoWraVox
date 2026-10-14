local _, ns = ...

-- /wvdebug report builds a bounded, anonymized report for the existing copy window.
local report = {}
ns.DebugReport = report

local MAX_CASTS, MAX_AURAS, MAX_NOTIFY = 30, 60, 30
local MAX_REPORT_CHARS, MAX_REPORT_LINES = 14000, 240
local casts, auras, notified = {}, {}, {}
local nameCache = {}
local ruleLabels = setmetatable({}, { __mode = "k" })
local nextRuleLabel = 0

local CATEGORY_SET = {
    defensive = true, offensive = true, healing = true, bloodlust = true,
    ["somebody-loves-you"] = true, ["offensive-external"] = true, ["defensive-external"] = true,
    none = true,
}
local EVENT_SET = { apply = true, expire = true, ready = true }
local SOURCE_SET = {
    UNIT_SPELLCAST_SUCCEEDED = true, UNIT_AURA = true, AURA_TIMER = true,
    BASELINE_SYNC = true, FULL_SYNC = true, ITEM_COOLDOWN_DONE = true,
}
local HIDDEN_NOTE_SET = {
    ["payload hidden"] = true, ["full update"] = true, ["full update (unreadable)"] = true,
    ["lists hidden"] = true, ["added, id hidden"] = true,
}
local STATUS_FIELDS = { "available", "registered", "wanted", "refused", "removeFailed", "queued" }
local TRUNCATION_MARKER = "[truncated]"

local function isSecret(value)
    if type(issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(issecretvalue, value)
    return not ok or secret == true
end

local function readableNumber(value)
    return type(value) == "number" and not isSecret(value)
        and value == value and value >= 1 and value <= 2147483647 and value % 1 == 0
end

local function publicText(value, limit)
    if type(value) ~= "string" or isSecret(value) then return "?" end
    value = value:gsub("[%c]", " "):gsub("%s+", " ")
    if value == "" or #value > (limit or 96) then return "?" end
    return value
end

local function spellName(spellID)
    if not readableNumber(spellID) then return "?" end
    local cached = nameCache[spellID]
    if cached then return cached end
    local name = "?"
    if C_Spell and type(C_Spell.GetSpellName) == "function" then
        local ok, result = pcall(C_Spell.GetSpellName, spellID)
        if ok then name = publicText(result, 96) end
    end
    if name ~= "?" then nameCache[spellID] = name end
    return name
end

local function ruleLabel(rule)
    if type(rule) ~= "table" then return "rule-?" end
    local label = ruleLabels[rule]
    if not label then
        nextRuleLabel = nextRuleLabel + 1
        label = "rule-" .. tostring(nextRuleLabel)
        ruleLabels[rule] = label
    end
    return label
end

local function safeEnum(value, choices, fallback)
    if type(value) ~= "string" or isSecret(value) then return fallback end
    return choices[value] and value or fallback
end

local function safeBool(value)
    return type(value) == "boolean" and tostring(value) or "unknown"
end

local function safeCallBoolean(fn, ...)
    if type(fn) ~= "function" then return "unknown" end
    local ok, result = pcall(fn, ...)
    return ok and safeBool(result) or "unknown"
end

local function auraSecretStatus()
    return ns._Aura and safeCallBoolean(ns._Aura.aurasAreSecret) or "unknown"
end

local function selfBuffStatus(spellID)
    if not (ns._Aura and type(ns._Aura.getSelfBuffStatus) == "function") then return "unavailable" end
    local ok, result = pcall(ns._Aura.getSelfBuffStatus, spellID)
    if not ok or (result ~= "true" and result ~= "false" and result ~= "unavailable") then
        return "unavailable"
    end
    return result
end

local function castIDFor(rule, spellID)
    if ns._Aura and type(ns._Aura.castIDFor) == "function" then
        local ok, result = pcall(ns._Aura.castIDFor, rule, spellID)
        if ok and readableNumber(result) then return result end
    end
    return spellID
end

local function isRegistered(spellID, eventKey)
    local native = ns.AuraSoundFallback
    if not (native and type(native.IsRegistered) == "function") then return "false" end
    local ok, result = pcall(native.IsRegistered, spellID, eventKey)
    return ok and safeBool(result) or "unknown"
end

local function playerRuleList()
    local database = WoWraVoxDB
    return type(database) == "table" and type(database.auras) == "table" and database.auras or {}
end

local function push(list, max, entry)
    list[#list + 1] = entry
    if #list > max then table.remove(list, 1) end
end

local function now()
    if type(GetTime) ~= "function" then return 0 end
    local ok, value = pcall(GetTime)
    return ok and type(value) == "number" and not isSecret(value) and value or 0
end

-- Only public spell IDs and pseudonymous rule labels enter the rolling buffer.
function report.NoteCast(unit, spellID)
    if unit ~= "player" or not readableNumber(spellID) then return end
    local name = spellName(spellID)
    local entry = {
        at = now(), id = spellID, name = name,
        selfbuff = selfBuffStatus(spellID),
        combat = safeCallBoolean(InCombatLockdown),
        secret = auraSecretStatus(),
        byID = {}, byName = {},
    }
    local rules, triggersScanned = playerRuleList(), 0
    for ruleIndex = 1, 80 do
        local rule = rules[ruleIndex]
        if rule == nil or triggersScanned >= 240 then break end
        if type(rule) == "table" then
            local triggers = type(rule.spellIDs) == "table" and rule.spellIDs or {}
            for triggerIndex = 1, 240 - triggersScanned do
                local triggerID = triggers[triggerIndex]
                if triggerID == nil then break end
                triggersScanned = triggersScanned + 1
                if readableNumber(triggerID) then
                    local label = ruleLabel(rule)
                    if castIDFor(rule, triggerID) == spellID then
                        entry.byID[#entry.byID + 1] = label
                    elseif name ~= "?" and spellName(triggerID) == name then
                        entry.byName[#entry.byName + 1] = label .. ":" .. tostring(triggerID)
                    end
                end
            end
        end
    end
    push(casts, MAX_CASTS, entry)
end

function report.NoteAura(spellID, hidden)
    local at = now()
    local last = auras[#auras]
    if readableNumber(spellID) then
        if last and last.id == spellID and at - last.at < 0.5 then return end
        push(auras, MAX_AURAS, { at = at, id = spellID, name = spellName(spellID), secret = auraSecretStatus() })
    else
        local note = type(hidden) == "string" and not isSecret(hidden) and HIDDEN_NOTE_SET[hidden] and hidden or "hidden"
        if last and last.note == note and at - last.at < 0.2 then return end
        push(auras, MAX_AURAS, { at = at, note = note, secret = auraSecretStatus() })
    end
end

-- Free-form rule names, messages, and source text are intentionally not retained.
function report.NoteNotify(rule, eventKey, _, spellID, sourceEvent, detectedEvent)
    push(notified, MAX_NOTIFY, {
        at = now(),
        rule = ruleLabel(rule),
        event = safeEnum(eventKey, EVENT_SET, "other"),
        spell = readableNumber(spellID) and tostring(spellID) or "?",
        source = safeEnum(sourceEvent, SOURCE_SET, "other"),
        detected = safeEnum(detectedEvent, EVENT_SET, "other"),
    })
end

local function ago(at, current)
    return string.format("-%.1fs", math.max(0, current - at))
end

local function category(value)
    return safeEnum(value, CATEGORY_SET, "other")
end

local function ruleEnabled(rule, key)
    return type(rule[key]) == "boolean" and tostring(rule[key]) or "unknown"
end

local function addCurrentAuras(add)
    if auraSecretStatus() == "true" then
        add("  (auras are secret right now; the list cannot be read)")
        return
    end
    if not (C_UnitAuras and type(C_UnitAuras.GetAuraDataByIndex) == "function") then
        add("  (aura API unavailable)")
        return
    end
    for index = 1, 80 do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", index, "HELPFUL")
        if not ok or type(aura) ~= "table" or isSecret(aura) then break end
        if type(issecrettable) == "function" then
            local secretOK, secret = pcall(issecrettable, aura)
            if not secretOK or secret then break end
        end
        local idOK, spellID = pcall(function() return aura.spellId end)
        if idOK and readableNumber(spellID) then
            add(string.format("  %s %s", tostring(spellID), spellName(spellID)))
        end
    end
end

local function reportHeader()
    local version = "?"
    if C_AddOns and type(C_AddOns.GetAddOnMetadata) == "function" then
        local ok, result = pcall(C_AddOns.GetAddOnMetadata, "WoWraVox", "Version")
        if ok then version = publicText(result, 32) end
    end
    local gameVersion, gameBuild = "?", "?"
    if type(GetBuildInfo) == "function" then
        local ok, versionValue, buildValue = pcall(GetBuildInfo)
        if ok then
            gameVersion = publicText(versionValue, 32)
            gameBuild = publicText(buildValue, 32)
        end
    end
    local classFile, specName = "?", "?"
    if type(UnitClass) == "function" then
        local ok, _, result = pcall(UnitClass, "player")
        if ok then
            result = publicText(result, 32)
            if result:match("^[A-Z_]+$") then classFile = result end
        end
    end
    if type(GetSpecialization) == "function" and type(GetSpecializationInfo) == "function" then
        local ok, index = pcall(GetSpecialization)
        if ok and readableNumber(index) then
            local infoOK, _, result = pcall(GetSpecializationInfo, index)
            if infoOK then specName = publicText(result, 48) end
        end
    end
    return string.format("WoWraVox %s · game %s (%s) · %s %s", version, gameVersion, gameBuild, classFile, specName)
end

function report.Build()
    local current = now()
    local lines, used, truncated = {}, 0, false
    local contentLimit = MAX_REPORT_CHARS - #TRUNCATION_MARKER - 1
    local function add(text)
        if truncated then return false end
        text = tostring(text or "")
        local extra = #text + (#lines > 0 and 1 or 0)
        if #lines >= MAX_REPORT_LINES - 1 or used + extra > contentLimit then
            truncated = true
            return false
        end
        lines[#lines + 1] = text
        used = used + extra
        return true
    end
    local function finish()
        if truncated then lines[#lines + 1] = TRUNCATION_MARKER end
        return lines
    end

    add(reportHeader())
    add(string.format("in combat: %s · auras secret now: %s · TTS available: %s",
        safeCallBoolean(InCombatLockdown), auraSecretStatus(),
        safeBool(C_VoiceChat and type(C_VoiceChat.SpeakText) == "function")))
    add("")
    add("PRIVACY: character name, custom rule names/messages, unrelated profiles, custom fields, and raw debug log omitted; active rule summary included.")

    add("")
    add("AURA RULES")
    local rules, totalTriggers = playerRuleList(), 0
    for ruleIndex = 1, 80 do
        if truncated then break end
        local rule = rules[ruleIndex]
        if rule == nil then break end
        if type(rule) == "table" then
            add(string.format("- %s · active=%s · apply=%s · expire=%s · category=%s · perEffectCues=%s · expireCategory=%s · oneEffect=%s",
                ruleLabel(rule), ruleEnabled(rule, "enabled"), ruleEnabled(rule, "applyEnabled"),
                ruleEnabled(rule, "expireEnabled"), category(rule.alertCategory),
                tostring(type(rule.categoryByAuraID) == "table" and next(rule.categoryByAuraID) ~= nil),
                category(rule.expireCategory), ruleEnabled(rule, "oneEffect")))
            local triggers = type(rule.spellIDs) == "table" and rule.spellIDs or {}
            for triggerIndex = 1, 240 - totalTriggers do
                if truncated then break end
                local spellID = triggers[triggerIndex]
                if spellID == nil then break end
                totalTriggers = totalTriggers + 1
                if readableNumber(spellID) then
                    local castable = "unknown"
                    if type(IsPlayerSpell) == "function" then
                        local ok, result = pcall(IsPlayerSpell, spellID)
                        if ok then castable = safeBool(result) end
                    end
                    local secrecy = "unknown"
                    if ns._Aura and type(ns._Aura.auraSecrecy) == "function" then
                        local ok, result = pcall(ns._Aura.auraSecrecy, spellID)
                        if ok then
                            secrecy = safeEnum(result,
                                { never = true, contextual = true, always = true, unavailable = true }, "unknown")
                        end
                    end
                    local selfbuff = selfBuffStatus(castIDFor(rule, spellID))
                    add(string.format("    %s %s · secrecy=%s · selfbuff=%s · castable=%s · native apply/expire=%s/%s",
                        tostring(spellID), spellName(spellID), secrecy, selfbuff, castable,
                        isRegistered(spellID, "apply"), isRegistered(spellID, "expire")))
                end
            end
        end
    end
    if totalTriggers >= 240 then truncated = true end

    add("")
    add("NATIVE SOUNDS")
    local native = ns.AuraSoundFallback
    local status
    if native and type(native.GetStatus) == "function" then
        local ok, result = pcall(native.GetStatus)
        if ok and type(result) == "table" then status = result end
    end
    if status then
        for _, key in ipairs(STATUS_FIELDS) do
            local value = status[key]
            if type(value) == "boolean" or (type(value) == "number" and not isSecret(value)) then
                add(string.format("  %s = %s", key, tostring(value)))
            end
        end
    else
        add("  (unavailable)")
    end

    add("")
    add("OWN CASTS (newest first; byID = matching cast, byName = same public spell name, other ID)")
    for index = #casts, 1, -1 do
        local cast = casts[index]
        add(string.format("%s %s %s · selfbuff=%s · combat=%s · secret=%s · byID=[%s] · byName=[%s]",
            ago(cast.at, current), tostring(cast.id), cast.name, cast.selfbuff, cast.combat, cast.secret,
            table.concat(cast.byID, ", "), table.concat(cast.byName, ", ")))
    end
    if #casts == 0 then add("  (none recorded since login or reload)") end

    add("")
    add("AURA EVENTS ON YOU (newest first; public IDs or hidden-state notes)")
    for index = #auras, 1, -1 do
        local aura = auras[index]
        if aura.id then
            add(string.format("%s %s %s · secret=%s", ago(aura.at, current), tostring(aura.id), aura.name, aura.secret))
        else
            add(string.format("%s (%s) · secret=%s", ago(aura.at, current), aura.note, aura.secret))
        end
    end
    if #auras == 0 then add("  (none recorded)") end

    add("")
    add("ANNOUNCEMENTS THE ADDON MADE (newest first; custom text omitted)")
    for index = #notified, 1, -1 do
        local item = notified[index]
        add(string.format("%s rule=%s event=%s spell=%s source=%s via=%s",
            ago(item.at, current), item.rule, item.event, item.spell, item.source, item.detected))
    end
    if #notified == 0 then add("  (none)") end

    add("")
    add("BUFFS ON YOU NOW")
    addCurrentAuras(add)

    add("")
    add("DEBUG LOG")
    add("  (omitted; it can contain custom rule names and messages)")
    return finish()
end

local function say(text)
    if DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.AddMessage) == "function" then
        pcall(DEFAULT_CHAT_FRAME.AddMessage, DEFAULT_CHAT_FRAME, "|cffd8b65aWoWraVox:|r " .. tostring(text))
    end
end

function report.Run()
    local ok, lines = pcall(report.Build)
    if not ok or type(lines) ~= "table" then
        say(ns.L and ns.L("Could not build the diagnostic report. Try /wvdebug report again.")
            or "Could not build the diagnostic report. Try /wvdebug report again.")
        return false
    end
    local skillTracking = ns.SkillTracking
    local showText = skillTracking and skillTracking.ShowText
    if type(showText) ~= "function" then
        say(ns.L and ns.L("Could not open the diagnostic report. Try /wvdebug report again.")
            or "Could not open the diagnostic report. Try /wvdebug report again.")
        return false
    end
    local title = ns.L and ns.L("Diagnostic report") or "Diagnostic report"
    local shown, result = pcall(showText, title, table.concat(lines, "\n"))
    if not shown or result == false then
        say(ns.L and ns.L("Could not open the diagnostic report. Try /wvdebug report again.")
            or "Could not open the diagnostic report. Try /wvdebug report again.")
        return false
    end
    return true
end
