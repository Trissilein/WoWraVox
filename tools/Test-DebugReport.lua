local fakeTime = 100
local secretSpellID = 777
local secretSpellName = "SECRET SPELL NAME"
local playerName = "PRIVATE CHARACTER NAME"
local profileName = "PRIVATE PROFILE NAME"
local customName = "PRIVATE RULE NAME"
local customMessage = "PRIVATE MESSAGE TEXT"
local rawAuraName = "PRIVATE RAW AURA NAME"
local rawLogLine = "PRIVATE RAW DEBUG LOG"
local chatMessages = {}
local reloaded = false
local secretAuraMode, secretAuraKind, secretAuraFieldReads = false, nil, 0
local secretAuraTable = setmetatable({}, {
    __index = function()
        secretAuraFieldReads = secretAuraFieldReads + 1
        error("secret aura table was indexed")
    end,
})
local savedVariables = { profiles = { private = profileName }, customText = customMessage }

GetTime = function() return fakeTime end
issecretvalue = function(value)
    return value == secretSpellID or value == secretSpellName
        or (secretAuraMode and secretAuraKind == "value" and value == secretAuraTable)
end
issecrettable = function(value)
    return secretAuraMode and secretAuraKind == "table" and value == secretAuraTable
end
UnitName = function() error("diagnostic must not read character name") end
UnitClass = function() return "Hunter", "HUNTER" end
GetBuildInfo = function() return "12.1.0", "12345" end
GetSpecialization = function() return 1 end
GetSpecializationInfo = function() return 253, "Beast Mastery" end
C_AddOns = { GetAddOnMetadata = function() return "0.12.0" end }
InCombatLockdown = function() return false end
C_VoiceChat = { SpeakText = function() end }
C_Spell = {
    GetSpellName = function(spellID)
        if spellID == secretSpellID then return secretSpellName end
        return spellID == 42 and "Public Spell" or nil
    end,
}
C_UnitAuras = {
    GetAuraDataByIndex = function(_, index)
        if secretAuraMode and index == 1 then return secretAuraTable end
        if index == 1 then return { spellId = 42, name = rawAuraName } end
        return nil
    end,
}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) chatMessages[#chatMessages + 1] = text end }
ReloadUI = function() reloaded = true end

ns._Aura = {
    aurasAreSecret = function() return false end,
    getSelfBuffStatus = function(spellID) return spellID == 42 and "true" or "false" end,
    castIDFor = function(_, spellID) return spellID end,
    auraSecrecy = function() return "never" end,
}
local logReads = 0
ns.AuraSoundFallback = {
    IsRegistered = function() return true end,
    GetStatus = function() return { available = true, registered = 1, wanted = 1, private = profileName } end,
    GetLogLines = function()
        logReads = logReads + 1
        return { rawLogLine }
    end,
}
ns.L = function(key) return key end

WoWraVoxDB = {
    auras = {
        {
            id = "private-id",
            name = customName,
            enabled = true,
            applyEnabled = true,
            expireEnabled = false,
            oneEffect = false,
            alertCategory = profileName,
            expireCategory = "none",
            applyMessage = customMessage,
            spellIDs = { 42, secretSpellID },
            categoryByAuraID = {},
        },
    },
    privateField = profileName,
}
WoWraVoxProfilesDB = savedVariables

-- ==== MODULE ====

local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. detail) or "")) end
    print("PASS " .. name)
end

local rule = WoWraVoxDB.auras[1]
ns.DebugReport.NoteCast("player", 42)
ns.DebugReport.NoteCast("target", 99)
ns.DebugReport.NoteAura(42)
ns.DebugReport.NoteAura(secretSpellID)
ns.DebugReport.NoteNotify(rule, "apply", customMessage, 42, "UNIT_AURA", "apply")
ns.DebugReport.NoteNotify(rule, profileName, customMessage, 42, profileName, profileName)
local text = table.concat(ns.DebugReport.Build(), "\n")

check("public spell evidence stays useful", text:find("42 Public Spell", 1, true) ~= nil
    and text:find("secrecy=never", 1, true) ~= nil and text:find("byID=[rule-1]", 1, true) ~= nil, text)
check("rule identity is pseudonymous", text:find("rule-1", 1, true) ~= nil and not text:find(customName, 1, true))
check("private text and player identity are omitted",
    not text:find(customMessage, 1, true) and not text:find(playerName, 1, true)
    and not text:find(profileName, 1, true) and not text:find("private-id", 1, true))
check("secret IDs and raw aura names are omitted",
    not text:find(secretSpellName, 1, true) and not text:find(rawAuraName, 1, true))
check("raw debug log is never read or copied", logReads == 0 and not text:find(rawLogLine, 1, true))
check("unknown categories and event fields are replaced",
    text:find("category=other", 1, true) ~= nil and text:find("source=UNIT_AURA", 1, true) ~= nil
    and text:find("event=other spell=42 source=other via=other", 1, true) ~= nil)
check("copy payload has a hard size bound", #text <= 14000)
for _, kind in ipairs({ "value", "table" }) do
    secretAuraMode, secretAuraKind, secretAuraFieldReads = true, kind, 0
    local ok, secretReport = pcall(function() return table.concat(ns.DebugReport.Build(), "\n") end)
    check("secret aura " .. kind .. " is rejected before field access",
        ok and secretAuraFieldReads == 0 and not secretReport:find(rawAuraName, 1, true))
end
secretAuraMode, secretAuraKind = false, nil

local showCalls, createdViews, reusedViews = 0, 0, 0
local view
ns.SkillTracking = {
    ShowText = function(title, content)
        showCalls = showCalls + 1
        if view then reusedViews = reusedViews + 1
        else
            view = {}
            createdViews = createdViews + 1
        end
        view.title, view.content = title, content
        return true
    end,
}
local savedBefore = WoWraVoxProfilesDB
check("Run opens copy view without saving or reloading", ns.DebugReport.Run()
    and WoWraVoxProfilesDB == savedBefore and savedVariables.debugReport == nil
    and not reloaded and view.content:find("PRIVACY:", 1, true))
local diagnosticFixture = { at = "keep", lines = { "private fixture" } }
savedVariables.debugReport = diagnosticFixture
check("repeated Run delegates to the reusable view", ns.DebugReport.Run()
    and showCalls == 2 and createdViews == 1 and reusedViews == 1
    and savedVariables.debugReport == diagnosticFixture and diagnosticFixture.lines[1] == "private fixture")

ns.SkillTracking.ShowText = function() error("mock UI failure") end
check("UI failure is handled without saving or reload", ns.DebugReport.Run() == false
    and WoWraVoxProfilesDB == savedBefore and savedVariables.debugReport == diagnosticFixture
    and diagnosticFixture.lines[1] == "private fixture" and not reloaded and #chatMessages > 0)
ns.SkillTracking.ShowText = nil
check("missing UI reports failure safely", ns.DebugReport.Run() == false
    and WoWraVoxProfilesDB == savedBefore and savedVariables.debugReport == diagnosticFixture and not reloaded)

local manyRules = {}
for index = 1, 80 do
    manyRules[index] = {
        enabled = true, applyEnabled = true, expireEnabled = true, oneEffect = false,
        alertCategory = "defensive", expireCategory = "offensive",
        spellIDs = { 42, 42, 42, 42 },
    }
end
WoWraVoxDB.auras = manyRules
local bounded = table.concat(ns.DebugReport.Build(), "\n")
check("large rule sets truncate within output and line bounds",
    #bounded <= 14000 and select(2, bounded:gsub("\n", "")) < 240 and bounded:find("[truncated]", 1, true) ~= nil)

local ruleReads = 0
local manyInvalidRules = setmetatable({}, {
    __index = function(_, index)
        ruleReads = ruleReads + 1
        if index <= 10000 then return false end
    end,
})
WoWraVoxDB.auras = manyInvalidRules
ns.DebugReport.NoteCast("player", 42)
check("cast rule scan is capped even on malformed rows", ruleReads == 80)
ruleReads = 0
ns.DebugReport.Build()
check("report rule scan is capped even on malformed rows", ruleReads == 80)

local matchReads = 0
local endlessMatches = setmetatable({}, {
    __index = function(_, index)
        matchReads = matchReads + 1
        if index <= 10000 then return 42 end
    end,
})
WoWraVoxDB.auras = { { spellIDs = endlessMatches } }
ns.DebugReport.NoteCast("player", 42)
check("cast trigger and match scan is capped", matchReads == 240)

local triggerReads = 0
local endlessInvalidTriggers = setmetatable({}, {
    __index = function(_, index)
        triggerReads = triggerReads + 1
        if index <= 10000 then return secretSpellID end
    end,
})
WoWraVoxDB.auras = { { spellIDs = endlessInvalidTriggers } }
local cappedText = table.concat(ns.DebugReport.Build(), "\n")
check("report trigger scan counts invalid IDs toward its cap",
    triggerReads == 240 and cappedText:find("[truncated]", 1, true) ~= nil)
