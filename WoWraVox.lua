local addonName, ns = ...
local DB_VERSION = 5

local DEFAULT_HERO_IDS = { 2825, 32182, 80353, 90355, 264667, 390386, 466904 }
local DEFAULT_HERO_ID_SET = {}
for _, spellID in ipairs(DEFAULT_HERO_IDS) do DEFAULT_HERO_ID_SET[spellID] = true end
local activeAuras = {}
local auraByInstanceID = {}
local auraWatchBySpellID = {}
local spellInfoCache = {}
local spellLoadRequests = {}
local itemCooldownStates = {}
local skillCooldownStates = {}
local optionsFrame
local listScroll
local listChild
local listEmptyText
local detailPanel
local editorScroll
local auraEditor
local itemEditor
local creationView
local selectedCategory = "auras"
local selectedAuraRule
local selectedItemRule
local selectedSkillRule
local listRows = {}
local editorLoading = false
local itemScanPending = false
local pickerActive = false
local pickerRetries = 0
local pickerOverlays = {}
local characterFrameHooked = false
local pickerPrompt
local statusText
local ruleNameBox
local ruleEnabledCheck
local applyEnabledCheck
local applyMessageBox
local expireEnabledCheck
local expireMessageBox
local voiceDropdown
local volumeSlider
local volumeValue
local readyMessageBox
local testApplyButton
local testExpireButton
local testItemButton
local deleteRuleButton
local triggerInputBox
local triggerAddButton
local triggerStatus
local triggerLabel
local triggerPlaceholder
local triggerScroll
local triggerChild
local triggerRows = {}
local itemSourceText
local applyLabel
local expireLabel
local readyLabel
local searchPopup
local searchRows = {}
local skillSearchBox
local skillSearchStatus
local skillSearchPopup
local skillSearchRows = {}
local skillSearchGeneration = 0
local settingsPanel
local observedSpellIDs = {}
local updatePreviewButtons
local auraBaselineComplete = false
local addRuleMode = false
local searchGeneration = 0
local lastRenderedRule
local lastRenderedCategory
local showAddRuleView
ns.screenControls = {}
ns.screenFrames = {}
ns.screenAnchorUnlocked = false
ns.screenAnchorTarget = nil
local SCREEN_FONT_FALLBACKS = {
    { key = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
    { key = "Arial Narrow", path = "Fonts\\ARIALN.TTF" },
    { key = "Morpheus", path = "Fonts\\MORPHEUS.TTF" },
}
local SCREEN_FONT_CHOICES = {}
local SCREEN_SIZE_CHOICES = { 16, 32, 48, 64, 80, 96, 112, 128 }
local SCREEN_STYLE_CHOICES = {
    { key = "NONE", label = "None", flags = "", shadow = false },
    { key = "SOFT_SHADOW", label = "Soft shadow", flags = "", shadow = true, shadowAlpha = 0.85, shadowX = 1, shadowY = -1 },
    { key = "SHADOW", label = "Shadow", flags = "", shadow = true },
    { key = "OUTLINE", label = "Outline", flags = "OUTLINE", shadow = false },
    { key = "THICKOUTLINE", label = "Thick outline", flags = "THICKOUTLINE", shadow = false },
    { key = "OUTLINE_SHADOW", label = "Outline + shadow", flags = "OUTLINE", shadow = true },
}

function ns.refreshScreenFontChoices()
    for index = #SCREEN_FONT_CHOICES, 1, -1 do
        SCREEN_FONT_CHOICES[index] = nil
    end

    local known = {}
    for _, choice in ipairs(SCREEN_FONT_FALLBACKS) do
        table.insert(SCREEN_FONT_CHOICES, choice)
        known[choice.key] = true
    end

    local lsm
    if type(LibStub) == "function" then
        local ok, library = pcall(LibStub, "LibSharedMedia-3.0", true)
        if ok and type(library) == "table" then lsm = library end
    end
    if not (lsm and type(lsm.List) == "function" and type(lsm.Fetch) == "function") then return end

    local ok, names = pcall(lsm.List, lsm, "font")
    if not ok or type(names) ~= "table" then return end
    for _, name in ipairs(names) do
        local fetched, path = pcall(lsm.Fetch, lsm, "font", name, true)
        if fetched and type(name) == "string" and name ~= "" and type(path) == "string" and path ~= "" and not known[name] then
            table.insert(SCREEN_FONT_CHOICES, { key = name, path = path })
            known[name] = true
        end
    end
end

ns.refreshScreenFontChoices()
local DEFAULT_SCREEN_ANCHOR = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 120 }
ns.DEFAULT_SCREEN_COLOR = { r = 1, g = 0.82, b = 0.2, a = 1 }
local locale = GetLocale and GetLocale() or "enUS"
local function L(text)
    local locales = ns.Locales or {}
    local messages = locales[locale] or locales.enUS
    return (messages and messages[text]) or text
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s*(.-)%s*$", "%1"))
end

local function copyIDs(ids)
    local result = {}
    for _, id in ipairs(ids or {}) do
        if type(id) == "number" and id > 0 and id == math.floor(id) then
            table.insert(result, id)
        end
    end
    return result
end

local function parseSpellIDs(text)
    text = trim(text)
    if text == "" then return {}, true end
    if text:match("^,") or text:match(",$") or text:find(",,", 1, true) or text:find("[^%d,%s]") then return nil, false end

    local ids, seen = {}, {}
    for token in text:gmatch("[^,]+") do
        token = trim(token)
        if not token:match("^%d+$") then return nil, false end
        local id = tonumber(token)
        if not id or id <= 0 then return nil, false end
        if not seen[id] then
            seen[id] = true
            table.insert(ids, id)
        end
    end
    return ids, true
end

local function getVoices()
    if C_VoiceChat and C_VoiceChat.GetTtsVoices then
        local ok, voices = pcall(C_VoiceChat.GetTtsVoices)
        if ok and type(voices) == "table" then return voices end
    end
    return {}
end

local function getDefaultVoiceID()
    if C_TTSSettings and C_TTSSettings.GetVoiceOptionID and Enum and Enum.TtsVoiceType then
        local ok, voiceID = pcall(C_TTSSettings.GetVoiceOptionID, Enum.TtsVoiceType.Standard)
        if ok and type(voiceID) == "number" then return voiceID end
    end
    local voices = getVoices()
    return voices[1] and voices[1].voiceID or 0
end

function ns.copyScreenAnchor(anchor)
    anchor = type(anchor) == "table" and anchor or DEFAULT_SCREEN_ANCHOR
    return {
        point = type(anchor.point) == "string" and anchor.point or DEFAULT_SCREEN_ANCHOR.point,
        relativePoint = type(anchor.relativePoint) == "string" and anchor.relativePoint or DEFAULT_SCREEN_ANCHOR.relativePoint,
        x = math.max(-10000, math.min(10000, tonumber(anchor.x) or DEFAULT_SCREEN_ANCHOR.x)),
        y = math.max(-10000, math.min(10000, tonumber(anchor.y) or DEFAULT_SCREEN_ANCHOR.y)),
    }
end

function ns.copyScreenColor(color)
    color = type(color) == "table" and color or ns.DEFAULT_SCREEN_COLOR
    return {
        r = math.max(0, math.min(1, tonumber(color.r) or ns.DEFAULT_SCREEN_COLOR.r)),
        g = math.max(0, math.min(1, tonumber(color.g) or ns.DEFAULT_SCREEN_COLOR.g)),
        b = math.max(0, math.min(1, tonumber(color.b) or ns.DEFAULT_SCREEN_COLOR.b)),
        a = math.max(0, math.min(1, tonumber(color.a) or ns.DEFAULT_SCREEN_COLOR.a)),
    }
end

function ns.newScreenProfile(enabled, text)
    return {
        enabled = enabled == true,
        text = type(text) == "string" and text or "",
        font = SCREEN_FONT_CHOICES[1].key,
        size = 32,
        style = "SOFT_SHADOW",
        color = ns.copyScreenColor(),
        anchor = ns.copyScreenAnchor(),
    }
end

local function newAuraRule()
    return {
        name = L("New aura group"),
        spellIDs = {},
        enabled = true,
        applyEnabled = false,
        applyMessage = "",
        applyScreenEnabled = false,
        applyScreenText = "",
        expireEnabled = false,
        expireMessage = "",
        expireScreenEnabled = false,
        expireScreenText = "",
        screenProfiles = {
            apply = ns.newScreenProfile(false, ""),
            expire = ns.newScreenProfile(false, ""),
        },
        voiceID = getDefaultVoiceID(),
        volume = 80,
    }
end

local function newItemRule(itemID, name, icon)
    return {
        itemID = itemID,
        name = name or ("Item " .. tostring(itemID or "")),
        icon = icon,
        enabled = true,
        message = (name or "Item") .. " " .. L("ready"),
        screenEnabled = false,
        screenText = "",
        screenProfiles = { ready = ns.newScreenProfile(false, "") },
        voiceID = getDefaultVoiceID(),
        volume = 80,
    }
end

local function newSkillRule(spellID, name, icon)
    return {
        spellID = tonumber(spellID) or 0,
        name = name or ("Spell " .. tostring(spellID or "")),
        icon = icon,
        enabled = true,
        message = (name or "Spell") .. " " .. L("ready"),
        screenEnabled = false,
        screenText = "",
        screenProfiles = { ready = ns.newScreenProfile(false, "") },
        voiceID = getDefaultVoiceID(),
        volume = 80,
    }
end

local function oldRulesMatch(a, b)
    return a.message == b.message
        and a.voiceID == b.voiceID
        and a.volume == b.volume
        and a.enabled == b.enabled
end

local function migrateLegacyDatabase(legacy)
    local auraRules, itemRules = {}, {}
    local candidates, consumed = {}, {}
    local legacyRules = type(legacy) == "table" and type(legacy.rules) == "table" and legacy.rules or {}

    for index, oldRule in ipairs(legacyRules) do
        local spellID = tonumber(oldRule.spellID) or 0
        if spellID > 0 then
            oldRule.spellID = spellID
            oldRule.message = type(oldRule.message) == "string" and oldRule.message or ""
            oldRule.voiceID = tonumber(oldRule.voiceID) or getDefaultVoiceID()
            oldRule.volume = math.max(0, math.min(100, tonumber(oldRule.volume) or 100))
            if oldRule.enabled == nil then oldRule.enabled = true end
            if DEFAULT_HERO_ID_SET[spellID] then
                candidates[spellID] = { index = index, rule = oldRule }
            end
        end
    end

    local groupedIDs, commonRule = {}, nil
    local allKnownMatch = true
    for _, spellID in ipairs(DEFAULT_HERO_IDS) do
        local entry = candidates[spellID]
        if entry then
            if commonRule and not oldRulesMatch(commonRule, entry.rule) then allKnownMatch = false end
            commonRule = commonRule or entry.rule
            table.insert(groupedIDs, spellID)
        end
    end
    if #groupedIDs > 1 and allKnownMatch then
        local auraRule = newAuraRule()
        auraRule.name = "Heroism / Bloodlust"
        auraRule.spellIDs = groupedIDs
        auraRule.enabled = commonRule.enabled ~= false
        auraRule.expireEnabled = auraRule.enabled and commonRule.message ~= ""
        auraRule.expireMessage = commonRule.message
        auraRule.applyScreenEnabled = commonRule.applyScreenEnabled == true
        auraRule.applyScreenText = type(commonRule.applyScreenText) == "string" and commonRule.applyScreenText or ""
        auraRule.expireScreenEnabled = commonRule.expireScreenEnabled == true
        auraRule.expireScreenText = type(commonRule.expireScreenText) == "string" and commonRule.expireScreenText or ""
        auraRule.screenProfiles.apply.enabled = auraRule.applyScreenEnabled
        auraRule.screenProfiles.apply.text = auraRule.applyScreenText
        auraRule.screenProfiles.expire.enabled = auraRule.expireScreenEnabled
        auraRule.screenProfiles.expire.text = auraRule.expireScreenText
        auraRule.voiceID = commonRule.voiceID
        auraRule.volume = commonRule.volume
        table.insert(auraRules, auraRule)
        for _, spellID in ipairs(groupedIDs) do consumed[candidates[spellID].index] = true end
    end

    for index, oldRule in ipairs(legacyRules) do
        local spellID = tonumber(oldRule.spellID) or 0
        if spellID > 0 and not consumed[index] then
            local auraRule = newAuraRule()
            auraRule.name = oldRule.name or ("Spell " .. tostring(spellID))
            auraRule.spellIDs = { spellID }
            auraRule.enabled = oldRule.enabled ~= false
            auraRule.expireEnabled = auraRule.enabled and oldRule.message ~= ""
            auraRule.expireMessage = oldRule.message
            auraRule.applyScreenEnabled = oldRule.applyScreenEnabled == true
            auraRule.applyScreenText = type(oldRule.applyScreenText) == "string" and oldRule.applyScreenText or ""
            auraRule.expireScreenEnabled = oldRule.expireScreenEnabled == true
            auraRule.expireScreenText = type(oldRule.expireScreenText) == "string" and oldRule.expireScreenText or ""
            auraRule.screenProfiles.apply.enabled = auraRule.applyScreenEnabled
            auraRule.screenProfiles.apply.text = auraRule.applyScreenText
            auraRule.screenProfiles.expire.enabled = auraRule.expireScreenEnabled
            auraRule.screenProfiles.expire.text = auraRule.expireScreenText
            auraRule.voiceID = tonumber(oldRule.voiceID) or getDefaultVoiceID()
            auraRule.volume = math.max(0, math.min(100, tonumber(oldRule.volume) or 100))
            table.insert(auraRules, auraRule)
        end
    end

    return { version = DB_VERSION, auras = auraRules, items = itemRules, skills = {} }
end

local function copyDefault(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copyDefault(child) end
    return result
end

local function createStarterDatabase()
    local defaults = ns.Defaults or {}
    return {
        version = DB_VERSION,
        starterPresetVersion = tonumber(defaults.version) or 1,
        auras = copyDefault(defaults.auras or {}),
        items = copyDefault(defaults.items or {}),
        skills = {},
    }
end

function ns.getScreenFontChoiceByKey(key)
    for _, choice in ipairs(SCREEN_FONT_CHOICES) do
        if choice.key == key then return choice end
    end
    return SCREEN_FONT_CHOICES[1]
end

function ns.getScreenStyleChoice(key)
    for _, choice in ipairs(SCREEN_STYLE_CHOICES) do
        if choice.key == key then return choice end
    end
    return SCREEN_STYLE_CHOICES[2]
end

function ns.getScreenSizeValue(value)
    value = tonumber(value)
    for _, size in ipairs(SCREEN_SIZE_CHOICES) do
        if size == value then return size end
    end
    return 32
end

function ns.normalizeScreenProfile(raw, fallbackEnabled, fallbackText, settings)
    local profile = type(raw) == "table" and raw or {}
    if profile.enabled == nil then profile.enabled = fallbackEnabled == true end
    profile.enabled = profile.enabled == true
    if type(profile.text) ~= "string" then profile.text = type(fallbackText) == "string" and fallbackText or "" end
    profile.font = ns.getScreenFontChoiceByKey(profile.font or settings.screenFont).key
    profile.size = ns.getScreenSizeValue(profile.size or settings.screenSize)
    profile.style = ns.getScreenStyleChoice(profile.style).key
    profile.color = ns.copyScreenColor(profile.color)
    profile.anchor = ns.copyScreenAnchor(profile.anchor or settings.screenAnchor)
    return profile
end

function ns.ensureRuleID(rule, usedIDs, nextID)
    local id = type(rule.id) == "string" and trim(rule.id) or ""
    if id == "" or usedIDs[id] then
        repeat
            nextID = nextID + 1
            id = "rule-" .. tostring(nextID)
        until not usedIDs[id]
        rule.id = id
    else
        local numericID = tonumber(id:match("^rule%-(%d+)$"))
        if numericID and numericID > nextID then nextID = numericID end
    end
    usedIDs[id] = true
    return nextID
end

function ns.normalizeRuleScreenProfiles(rule, category, settings)
    rule.screenProfiles = type(rule.screenProfiles) == "table" and rule.screenProfiles or {}
    if category == "auras" then
        rule.screenProfiles.apply = ns.normalizeScreenProfile(
            rule.screenProfiles.apply, rule.applyScreenEnabled, rule.applyScreenText, settings)
        rule.screenProfiles.expire = ns.normalizeScreenProfile(
            rule.screenProfiles.expire, rule.expireScreenEnabled, rule.expireScreenText, settings)
        rule.applyScreenEnabled = rule.screenProfiles.apply.enabled
        rule.applyScreenText = rule.screenProfiles.apply.text
        rule.expireScreenEnabled = rule.screenProfiles.expire.enabled
        rule.expireScreenText = rule.screenProfiles.expire.text
    else
        rule.screenProfiles.ready = ns.normalizeScreenProfile(
            rule.screenProfiles.ready, rule.screenEnabled, rule.screenText, settings)
        rule.screenEnabled = rule.screenProfiles.ready.enabled
        rule.screenText = rule.screenProfiles.ready.text
    end
end

function ns.registerNewRule(rule, category)
    local usedIDs = {}
    for _, rules in ipairs({ WoWraVoxDB.auras, WoWraVoxDB.items, WoWraVoxDB.skills }) do
        for _, existing in ipairs(rules or {}) do usedIDs[existing.id] = true end
    end
    local nextRuleID = ns.ensureRuleID(rule, usedIDs, tonumber(WoWraVoxDB.nextRuleID) or 0)
    WoWraVoxDB.nextRuleID = nextRuleID
    ns.normalizeRuleScreenProfiles(rule, category, WoWraVoxDB.settings)
end

local function initializeDatabase()
    if type(WoWraVoxDB) ~= "table" and type(AuraVoxDB) == "table" then
        WoWraVoxDB = AuraVoxDB
        AuraVoxDB = nil
        print("|cffd8b65aWoWraVox:|r existing AuraVox settings were adopted.")
    end
    if type(WoWraVoxDB) ~= "table" then
        if type(AuraExpiryTTSDB) == "table" then
            WoWraVoxDB = migrateLegacyDatabase(AuraExpiryTTSDB)
            AuraExpiryTTSDB = nil
            print("|cffd8b65aWoWraVox:|r legacy aura rules were adopted.")
        else
            WoWraVoxDB = createStarterDatabase()
        end
    elseif WoWraVoxDB.version == 1 and type(WoWraVoxDB.rules) == "table" then
        WoWraVoxDB = migrateLegacyDatabase(WoWraVoxDB)
    end

    if WoWraVoxDB.version == 2 or WoWraVoxDB.version == 3 or WoWraVoxDB.version == 4 then
        WoWraVoxDB.version = DB_VERSION
    end

    if WoWraVoxDB.version ~= DB_VERSION
        or type(WoWraVoxDB.auras) ~= "table"
        or type(WoWraVoxDB.items) ~= "table" then
        print("|cffff4040WoWraVox:|r gespeicherte Konfiguration nicht erkannt; Add-on pausiert.")
        return false
    end

    WoWraVoxDB.settings = type(WoWraVoxDB.settings) == "table" and WoWraVoxDB.settings or {}
    local settings = WoWraVoxDB.settings
    settings.tooltipIDs = settings.tooltipIDs ~= false
    settings.showMinimap = settings.showMinimap ~= false
    settings.showTitan = true
    local validFont = false
    for _, choice in ipairs(SCREEN_FONT_CHOICES) do
        if settings.screenFont == choice.key then validFont = true; break end
    end
    if not validFont then settings.screenFont = SCREEN_FONT_CHOICES[1].key end
    settings.screenSize = ns.getScreenSizeValue(settings.screenSize)
    local anchor = type(settings.screenAnchor) == "table" and settings.screenAnchor or {}
    settings.screenAnchor = {
        point = type(anchor.point) == "string" and anchor.point or "CENTER",
        relativePoint = type(anchor.relativePoint) == "string" and anchor.relativePoint or "CENTER",
        x = math.max(-10000, math.min(10000, tonumber(anchor.x) or 0)),
        y = math.max(-10000, math.min(10000, tonumber(anchor.y) or 120)),
    }
    WoWraVoxDB.minimap = type(WoWraVoxDB.minimap) == "table" and WoWraVoxDB.minimap or {}
    WoWraVoxDB.skills = type(WoWraVoxDB.skills) == "table" and WoWraVoxDB.skills or {}
    local usedRuleIDs = {}
    local nextRuleID = tonumber(WoWraVoxDB.nextRuleID) or 0

    for _, rule in ipairs(WoWraVoxDB.auras) do
        nextRuleID = ns.ensureRuleID(rule, usedRuleIDs, nextRuleID)
        rule.name = type(rule.name) == "string" and rule.name or "Aura"
        rule.spellIDs = copyIDs(rule.spellIDs or (rule.spellID and { tonumber(rule.spellID) } or {}))
        rule.enabled = rule.enabled ~= false
        rule.applyEnabled = rule.applyEnabled == true
        rule.applyMessage = type(rule.applyMessage) == "string" and rule.applyMessage or ""
        rule.applyScreenEnabled = rule.applyScreenEnabled == true
        rule.applyScreenText = type(rule.applyScreenText) == "string" and rule.applyScreenText or ""
        rule.expireEnabled = rule.expireEnabled == true
        rule.expireMessage = type(rule.expireMessage) == "string" and rule.expireMessage or ""
        rule.expireScreenEnabled = rule.expireScreenEnabled == true
        rule.expireScreenText = type(rule.expireScreenText) == "string" and rule.expireScreenText or ""
        rule.voiceID = tonumber(rule.voiceID) or getDefaultVoiceID()
        rule.volume = math.max(0, math.min(100, tonumber(rule.volume) or 100))
        ns.normalizeRuleScreenProfiles(rule, "auras", settings)
    end

    for _, rule in ipairs(WoWraVoxDB.items) do
        nextRuleID = ns.ensureRuleID(rule, usedRuleIDs, nextRuleID)
        rule.itemID = tonumber(rule.itemID) or 0
        rule.name = type(rule.name) == "string" and rule.name or ("Item " .. tostring(rule.itemID))
        rule.message = type(rule.message) == "string" and rule.message or ""
        rule.enabled = rule.enabled ~= false
        rule.screenEnabled = rule.screenEnabled == true
        rule.screenText = type(rule.screenText) == "string" and rule.screenText or ""
        rule.voiceID = tonumber(rule.voiceID) or getDefaultVoiceID()
        rule.volume = math.max(0, math.min(100, tonumber(rule.volume) or 100))
        ns.normalizeRuleScreenProfiles(rule, "items", settings)
    end

    for _, rule in ipairs(WoWraVoxDB.skills) do
        nextRuleID = ns.ensureRuleID(rule, usedRuleIDs, nextRuleID)
        rule.spellID = tonumber(rule.spellID) or 0
        rule.name = type(rule.name) == "string" and rule.name or ("Spell " .. tostring(rule.spellID))
        rule.message = type(rule.message) == "string" and rule.message or ""
        rule.enabled = rule.enabled ~= false
        rule.screenEnabled = rule.screenEnabled == true
        rule.screenText = type(rule.screenText) == "string" and rule.screenText or ""
        rule.voiceID = tonumber(rule.voiceID) or getDefaultVoiceID()
        rule.volume = math.max(0, math.min(100, tonumber(rule.volume) or 100))
        ns.normalizeRuleScreenProfiles(rule, "skills", settings)
    end

    WoWraVoxDB.nextRuleID = nextRuleID

    return true
end

local function getSpellInfo(spellID)
    if type(spellID) ~= "number" or spellID <= 0 or spellID ~= math.floor(spellID) then
        return nil, "invalid"
    end
    if not (C_Spell and C_Spell.GetSpellInfo) then return nil, "unavailable" end

    local cached = spellInfoCache[spellID]
    if type(cached) == "table" then return cached, "valid" end
    if cached == "invalid" then return nil, "invalid" end

    local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
    if ok and type(info) == "table" and (not issecrettable or not issecrettable(info)) then
        local nameOK, name = pcall(function() return info.name end)
        if nameOK and (not issecretvalue or not issecretvalue(name)) and type(name) == "string" and name ~= "" then
            spellInfoCache[spellID] = info
            return info, "valid"
        end
    end

    if C_Spell.IsSpellDataCached then
        local cacheOK, isCached = pcall(C_Spell.IsSpellDataCached, spellID)
        if cacheOK and isCached then
            spellInfoCache[spellID] = "invalid"
            return nil, "invalid"
        end
    end

    if C_Spell.RequestLoadSpellData and not spellLoadRequests[spellID] then
        spellInfoCache[spellID] = "pending"
        spellLoadRequests[spellID] = true
        local requestOK = pcall(C_Spell.RequestLoadSpellData, spellID)
        if not requestOK then
            spellLoadRequests[spellID] = nil
            spellInfoCache[spellID] = "unavailable"
            return nil, "unavailable"
        end
        return nil, "pending"
    end

    if spellInfoCache[spellID] == "pending" then return nil, "pending" end
    spellInfoCache[spellID] = "invalid"
    return nil, "invalid"
end

local function isPublicNumber(value)
    return (not issecretvalue or not issecretvalue(value))
        and type(value) == "number" and value > 0 and value == math.floor(value)
end

function ns.ObserveSpell(spellID, origin)
    if isPublicNumber(spellID) then observedSpellIDs[spellID] = origin or "Seen" end
end

local function collectPlayerAuras(candidates)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        for index = 1, 255 do
            local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", index, filter)
            if not ok then break end
            if (issecretvalue and issecretvalue(aura))
                or (type(aura) == "table" and issecrettable and issecrettable(aura)) then break end
            if not aura then break end
            local idOK, spellID = pcall(function() return aura.spellId end)
            if idOK and isPublicNumber(spellID) then
                candidates[spellID] = candidates[spellID] or "Active aura"
            end
        end
    end
end

local function collectSpellbook(candidates, needle, matchNumericID)
    if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines
        and C_SpellBook.GetSpellBookSkillLineInfo and C_SpellBook.GetSpellBookItemType
        and C_SpellBook.GetSpellBookItemName
        and Enum and Enum.SpellBookSpellBank) then return end
    local ok, count = pcall(C_SpellBook.GetNumSpellBookSkillLines)
    if not ok or type(count) ~= "number" then return end
    for line = 1, count do
        local lineOK, info = pcall(C_SpellBook.GetSpellBookSkillLineInfo, line)
        local fieldsOK, offset, numberOfItems = pcall(function()
            return info.itemIndexOffset, info.numSpellBookItems
        end)
        if lineOK and fieldsOK and type(offset) == "number" and type(numberOfItems) == "number"
            and (not issecretvalue or (not issecretvalue(offset) and not issecretvalue(numberOfItems))) then
            for slot = offset + 1, offset + numberOfItems do
                local itemOK, _, _, spellID = pcall(C_SpellBook.GetSpellBookItemType, slot, Enum.SpellBookSpellBank.Player)
                if itemOK and isPublicNumber(spellID) then
                    local nameOK, name = pcall(C_SpellBook.GetSpellBookItemName, slot, Enum.SpellBookSpellBank.Player)
                    local nameMatches = nameOK and (not issecretvalue or not issecretvalue(name))
                        and type(name) == "string" and name:lower():find(needle, 1, true)
                    local idMatches = matchNumericID and tonumber(needle) == spellID
                    if nameMatches or idMatches then
                        candidates[spellID] = candidates[spellID] or "Spellbook"
                    end
                end
            end
        end
    end
end

local function searchLocalSpells(query)
    query = trim(query)
    if query == "" then return {} end
    local needle = query:lower()
    local numericID = tonumber(query)
    local candidates = {}
    for id, origin in pairs(observedSpellIDs) do candidates[id] = origin end
    for _, rule in ipairs(WoWraVoxDB.auras) do
        for _, id in ipairs(rule.spellIDs) do candidates[id] = "WoWraVox rule" end
    end
    if numericID and numericID > 0 and numericID == math.floor(numericID) then
        candidates[numericID] = candidates[numericID] or "Spell ID"
    end
    collectPlayerAuras(candidates)
    collectSpellbook(candidates, needle, true)
    if C_Spell and C_Spell.GetSpellIDForSpellIdentifier then
        local ok, exactID = pcall(C_Spell.GetSpellIDForSpellIdentifier, query)
        if ok and isPublicNumber(exactID) then candidates[exactID] = candidates[exactID] or "Exact name" end
    end
    local results = {}
    for id, origin in pairs(candidates) do
        local info, status = getSpellInfo(id)
        if status == "valid" and (id == numericID or info.name:lower():find(needle, 1, true)) then
            local nameLower = info.name:lower()
            local rank = nameLower == needle and 0 or (nameLower:sub(1, #needle) == needle and 1 or 2)
            table.insert(results, { id = id, name = info.name, icon = info.iconID, origin = origin, rank = rank })
        end
    end
    table.sort(results, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.name ~= b.name then return a.name < b.name end
        return a.id < b.id
    end)
    return results
end

local function searchSpellbookSkills(query)
    query = trim(query)
    if query == "" then return {} end
    local needle = query:lower()
    local candidates = {}
    collectSpellbook(candidates, needle, true)
    local numericID = tonumber(query)
    local results = {}
    for id in pairs(candidates) do
        local info, status = getSpellInfo(id)
        if status == "valid" and (id == numericID or info.name:lower():find(needle, 1, true)) then
            local nameLower = info.name:lower()
            local rank = nameLower == needle and 0 or (nameLower:sub(1, #needle) == needle and 1 or 2)
            table.insert(results, { id = id, name = info.name, icon = info.iconID, origin = "Spellbook", rank = rank })
        end
    end
    table.sort(results, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.name ~= b.name then return a.name < b.name end
        return a.id < b.id
    end)
    return results
end

local function safeAuraField(aura, key)
    if not aura then return nil, true end
    local ok, value = pcall(function() return aura[key] end)
    if not ok or (issecretvalue and issecretvalue(value))
        or (type(value) == "table" and issecrettable and issecrettable(value)) then
        return nil, false
    end
    return value, true
end

local function getAura(spellID)
    if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return nil, false end
    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
    if not ok or (issecretvalue and issecretvalue(aura))
        or (type(aura) == "table" and issecrettable and issecrettable(aura)) then
        return nil, false
    end
    return aura, true
end

local function playTTS(voiceID, message, volume)
    if not (C_VoiceChat and C_VoiceChat.SpeakText)
        or type(message) ~= "string"
        or not message:match("%S") then
        return false
    end
    local ok = pcall(C_VoiceChat.SpeakText, voiceID, message, 0, volume, false)
    return ok
end

function ns.getRuleScreenProfile(rule, eventKey)
    if not (rule and type(eventKey) == "string") then return nil end
    local profiles = type(rule.screenProfiles) == "table" and rule.screenProfiles or {}
    local profile = profiles[eventKey]
    if type(profile) ~= "table" then
        local fallbackEnabled, fallbackText = false, ""
        if eventKey == "apply" then
            fallbackEnabled, fallbackText = rule.applyScreenEnabled, rule.applyScreenText
        elseif eventKey == "expire" then
            fallbackEnabled, fallbackText = rule.expireScreenEnabled, rule.expireScreenText
        elseif eventKey == "ready" then
            fallbackEnabled, fallbackText = rule.screenEnabled, rule.screenText
        end
        profile = ns.normalizeScreenProfile(nil, false, "", WoWraVoxDB and WoWraVoxDB.settings or {
            screenFont = SCREEN_FONT_CHOICES[1].key,
            screenSize = 32,
            screenAnchor = DEFAULT_SCREEN_ANCHOR,
        })
        profile.enabled = fallbackEnabled == true
        profile.text = type(fallbackText) == "string" and fallbackText or ""
        profiles[eventKey] = profile
        rule.screenProfiles = profiles
    end
    return profile
end

function ns.getScreenFrameKey(rule, eventKey)
    return tostring(rule and rule.id or rule) .. ":" .. tostring(eventKey)
end

function ns.applyScreenFrameStyle(frame, profile)
    if not (frame and frame.text and profile) then return end
    local font = ns.getScreenFontChoiceByKey(profile.font)
    local style = ns.getScreenStyleChoice(profile.style)
    frame.text:SetFont(font.path, ns.getScreenSizeValue(profile.size), style.flags or "")
    local color = ns.copyScreenColor(profile.color)
    frame.text:SetTextColor(color.r, color.g, color.b, color.a)
    if style.shadow then
        frame.text:SetShadowColor(0, 0, 0, style.shadowAlpha or 1)
        frame.text:SetShadowOffset(style.shadowX or 2, style.shadowY or -2)
    else
        frame.text:SetShadowColor(0, 0, 0, 0)
        frame.text:SetShadowOffset(0, 0)
    end
end

function ns.positionScreenFrame(frame, profile)
    if not (frame and profile) then return end
    frame:ClearAllPoints()
    local anchor = ns.copyScreenAnchor(profile.anchor)
    frame:SetPoint(anchor.point, UIParent, anchor.relativePoint, anchor.x, anchor.y)
end

function ns.updateScreenAnchorButtons()
    for _, row in pairs(ns.screenControls) do
        if row.anchor then
            row.anchor:SetText(ns.screenAnchorUnlocked and ns.screenAnchorTarget == row.frame
                and L("Lock") or L("Anchor"))
        end
    end
end

function ns.setScreenPreviewButtonState(row, enabled, hovered)
    if not (row and row.preview) then return end
    row.preview:SetEnabled(enabled)
    local label = row.preview:GetFontString()
    if label then
        if not enabled then
            label:SetTextColor(0.42, 0.42, 0.42)
        elseif hovered then
            label:SetTextColor(1, 0.9, 0.35)
        else
            label:SetTextColor(1, 0.82, 0.2)
        end
    end
end

function ns.saveScreenFrameAnchor(frame)
    if not (frame and frame.rule and frame.eventKey) then return end
    local profile = ns.getRuleScreenProfile(frame.rule, frame.eventKey)
    if not profile then return end
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    profile.anchor = ns.copyScreenAnchor({
        point = point,
        relativePoint = relativePoint,
        x = x,
        y = y,
    })
end

function ns.createScreenFrame(rule, eventKey)
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:SetSize(800, 80)
    frame:SetFrameStrata("TOOLTIP")
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if ns.screenAnchorUnlocked and ns.screenAnchorTarget == self then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        if ns.screenAnchorUnlocked and ns.screenAnchorTarget == self then
            self:StopMovingOrSizing()
            ns.saveScreenFrameAnchor(self)
        end
    end)
    frame.anchorBorder = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    frame.anchorBorder:SetAllPoints()
    frame.anchorBorder:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    frame.anchorBorder:SetBackdropColor(0, 0, 0, 0)
    frame.anchorBorder:SetBackdropBorderColor(0.95, 0.72, 0.25, 1)
    frame.anchorBorder:Hide()
    frame.text = frame:CreateFontString(nil, "OVERLAY")
    frame.text:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -4)
    frame.text:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 4)
    frame.text:SetJustifyH("CENTER")
    frame.text:SetJustifyV("MIDDLE")
    frame.text:SetWordWrap(true)
    frame.rule = rule
    frame.eventKey = eventKey
    frame.active = false
    frame:EnableMouse(false)
    frame:Hide()
    return frame
end

function ns.getScreenFrame(rule, eventKey)
    local key = ns.getScreenFrameKey(rule, eventKey)
    local frame = ns.screenFrames[key]
    if not frame then
        frame = ns.createScreenFrame(rule, eventKey)
        ns.screenFrames[key] = frame
    end
    return frame
end

function ns.setScreenAnchorUnlocked(frame, unlocked)
    if unlocked then
        if ns.screenAnchorTarget and ns.screenAnchorTarget ~= frame then
            ns.screenAnchorTarget:SetMovable(false)
            ns.screenAnchorTarget:EnableMouse(false)
            ns.screenAnchorTarget.anchorBorder:Hide()
            if not ns.screenAnchorTarget.active then ns.screenAnchorTarget:Hide() end
        end
        ns.screenAnchorTarget = frame
        ns.screenAnchorUnlocked = true
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame.anchorBorder:Show()
        local profile = ns.getRuleScreenProfile(frame.rule, frame.eventKey)
        ns.applyScreenFrameStyle(frame, profile)
        ns.positionScreenFrame(frame, profile)
        frame.text:SetText(trim(profile and profile.text or "") ~= "" and profile.text or "WoWraVox")
        frame:Show()
    elseif not frame or ns.screenAnchorTarget == frame then
        ns.screenAnchorUnlocked = false
        ns.screenAnchorTarget = nil
        if frame then
            frame:SetMovable(false)
            frame:EnableMouse(false)
            frame.anchorBorder:Hide()
            if not frame.active then frame:Hide() end
        end
    end
    ns.updateScreenAnchorButtons()
end

function ns.showScreenText(rule, eventKey, message, force)
    if not (rule and type(message) == "string") then return false end
    message = trim(message)
    if message == "" then return false end
    local profile = ns.getRuleScreenProfile(rule, eventKey)
    if not profile or (not force and not profile.enabled) then return false end
    local frame = ns.getScreenFrame(rule, eventKey)
    frame.generation = (frame.generation or 0) + 1
    local generation = frame.generation
    frame.active = true
    ns.applyScreenFrameStyle(frame, profile)
    ns.positionScreenFrame(frame, profile)
    frame.text:SetText(message)
    frame:Show()
    C_Timer.After(3, function()
        if frame.generation == generation then
            frame.active = false
            if not (ns.screenAnchorUnlocked and ns.screenAnchorTarget == frame) then frame:Hide() end
        end
    end)
    return true
end

function ns.hideScreenTextPreview(rule, eventKey)
    if not (rule and eventKey) then return end
    local frame = ns.screenFrames[ns.getScreenFrameKey(rule, eventKey)]
    if not frame then return end
    frame.generation = (frame.generation or 0) + 1
    frame.active = false
    if not (ns.screenAnchorUnlocked and ns.screenAnchorTarget == frame) then frame:Hide() end
end

function ns.hideScreenFramesForRule(rule)
    if not rule then return end
    local prefix = tostring(rule.id or rule) .. ":"
    for key, frame in pairs(ns.screenFrames) do
        if key:sub(1, #prefix) == prefix then
            frame.active = false
            if ns.screenAnchorTarget == frame then ns.setScreenAnchorUnlocked(frame, false) end
            frame:Hide()
            ns.screenFrames[key] = nil
        end
    end
end

local function notifyRule(rule, eventKey, message)
    local ttsShown = false
    local screenShown = false
    local profile = ns.getRuleScreenProfile(rule, eventKey)
    if type(message) == "string" and trim(message) ~= "" then
        ttsShown = playTTS(rule.voiceID, message, rule.volume)
    end
    if profile and profile.enabled and type(profile.text) == "string" and trim(profile.text) ~= "" then
        screenShown = ns.showScreenText(rule, eventKey, profile.text)
    end
    return ttsShown or screenShown
end

local function sayAura(spellID, eventKind)
    for _, rule in ipairs(WoWraVoxDB.auras) do
        if rule.enabled then
            local matches = false
            for _, configuredID in ipairs(rule.spellIDs) do
                if configuredID == spellID then matches = true; break end
            end
            if matches then
                local enabled, message
                if eventKind == "apply" then
                    enabled, message = rule.applyEnabled, rule.applyMessage
                else
                    enabled, message = rule.expireEnabled, rule.expireMessage
                end
                local profile = ns.getRuleScreenProfile(rule, eventKind)
                if enabled or (profile and profile.enabled) then notifyRule(rule, eventKind, enabled and message or "") end
            end
        end
    end
end

local function rebuildAuraWatches()
    wipe(auraWatchBySpellID)
    for _, rule in ipairs(WoWraVoxDB.auras) do
        if rule.enabled and (rule.applyEnabled or rule.expireEnabled or rule.applyScreenEnabled or rule.expireScreenEnabled) then
            for _, spellID in ipairs(rule.spellIDs) do
                local _, status = getSpellInfo(spellID)
                if status == "valid" then auraWatchBySpellID[spellID] = true end
            end
        end
    end

    for spellID in pairs(activeAuras) do
        if not auraWatchBySpellID[spellID] then
            local state = activeAuras[spellID]
            if state and state.auraInstanceID then auraByInstanceID[state.auraInstanceID] = nil end
            activeAuras[spellID] = nil
        end
    end
end

local processAura
local function scheduleAuraExpiry(spellID, state, delay)
    state.timerGeneration = (state.timerGeneration or 0) + 1
    local generation = state.timerGeneration
    C_Timer.After(math.max(0.05, delay), function()
        if activeAuras[spellID] == state and state.timerGeneration == generation then
            processAura(spellID, false)
        end
    end)
end

processAura = function(spellID, isBaseline)
    if not auraWatchBySpellID[spellID] then return end
    local aura, queryOK = getAura(spellID)
    local state = activeAuras[spellID]
    if not queryOK then
        if state and state.expirationTime > 0 and GetTime() >= state.expirationTime - 0.25 then
            state.queryFailures = (state.queryFailures or 0) + 1
            if state.queryFailures <= 4 then scheduleAuraExpiry(spellID, state, 0.5) end
        end
        return
    end

    if aura then
        local expirationTime, expirationOK = safeAuraField(aura, "expirationTime")
        local auraInstanceID, instanceOK = safeAuraField(aura, "auraInstanceID")
        if not expirationOK or not instanceOK then
            if state and state.expirationTime > 0 and GetTime() >= state.expirationTime - 0.25 then
                state.queryFailures = (state.queryFailures or 0) + 1
                if state.queryFailures <= 4 then scheduleAuraExpiry(spellID, state, 0.5) end
            end
            return
        end
        if type(expirationTime) ~= "number" then expirationTime = 0 end

        if not state then
            state = { expirationTime = expirationTime, auraInstanceID = auraInstanceID }
            activeAuras[spellID] = state
            if auraInstanceID then auraByInstanceID[auraInstanceID] = spellID end
            if not isBaseline and auraBaselineComplete then sayAura(spellID, "apply") end
        else
            state.queryFailures = 0
            if state.auraInstanceID and state.auraInstanceID ~= auraInstanceID then
                auraByInstanceID[state.auraInstanceID] = nil
            end
            state.auraInstanceID = auraInstanceID
            state.expirationTime = expirationTime
            if auraInstanceID then auraByInstanceID[auraInstanceID] = spellID end
            state.timerGeneration = (state.timerGeneration or 0) + 1
        end

        if expirationTime > 0 then
            scheduleAuraExpiry(spellID, state, expirationTime - GetTime())
        end
        return
    end

    if state then
        activeAuras[spellID] = nil
        if state.auraInstanceID then auraByInstanceID[state.auraInstanceID] = nil end
        if state.expirationTime > 0 and GetTime() >= state.expirationTime - 0.5 then
            sayAura(spellID, "expire")
        end
    end
end

local function syncAllAuras(isBaseline)
    rebuildAuraWatches()
    for spellID in pairs(auraWatchBySpellID) do processAura(spellID, isBaseline) end
    if isBaseline then auraBaselineComplete = true end
end

local auraSyncPending = false
local function queueAuraSync()
    if auraSyncPending then return end
    auraSyncPending = true
    C_Timer.After(0.15, function()
        auraSyncPending = false
        syncAllAuras(not auraBaselineComplete)
    end)
end

local function onUnitAuraUpdate(updateInfo)
    if type(updateInfo) ~= "table" or (issecrettable and issecrettable(updateInfo)) then
        queueAuraSync()
        return
    end

    local isFullUpdate, fullOK = safeAuraField(updateInfo, "isFullUpdate")
    if not fullOK or isFullUpdate then queueAuraSync(); return end
    local added, addedOK = safeAuraField(updateInfo, "addedAuras")
    local updated, updatedOK = safeAuraField(updateInfo, "updatedAuraInstanceIDs")
    local removed, removedOK = safeAuraField(updateInfo, "removedAuraInstanceIDs")
    if not (addedOK and updatedOK and removedOK) then queueAuraSync(); return end

    local affected = {}
    for _, aura in ipairs(type(added) == "table" and added or {}) do
        local spellID, ok = safeAuraField(aura, "spellId")
        if ok and isPublicNumber(spellID) and auraWatchBySpellID[spellID] then
            affected[spellID] = true
        elseif not ok then
            queueAuraSync()
        end
    end
    for _, instanceID in ipairs(type(updated) == "table" and updated or {}) do
        local spellID = isPublicNumber(instanceID) and auraByInstanceID[instanceID]
        if spellID then affected[spellID] = true end
    end
    for _, instanceID in ipairs(type(removed) == "table" and removed or {}) do
        local spellID = isPublicNumber(instanceID) and auraByInstanceID[instanceID]
        if spellID then affected[spellID] = true end
    end

    for spellID in pairs(affected) do processAura(spellID, false) end
end

local function getEquippedItemID(slotID)
    if not GetInventoryItemID then return nil end
    local ok, itemID = pcall(GetInventoryItemID, "player", slotID)
    if ok and isPublicNumber(itemID) then return itemID end
    return nil
end

local function findEquippedItemSlot(itemID)
    for slotID = 1, 19 do
        if getEquippedItemID(slotID) == itemID then return slotID end
    end
    return nil
end

local function getInventoryCooldown(slotID)
    if not GetInventoryItemCooldown then return nil, nil, false end
    local ok, startTime, duration, enabled = pcall(function()
        local start, length, isEnabled = GetInventoryItemCooldown("player", slotID)
        if type(start) ~= "number" or type(length) ~= "number" then return nil, nil, isEnabled end
        return start, length, isEnabled
    end)
    if not ok then return nil, nil, false end
    if (issecretvalue and (issecretvalue(startTime) or issecretvalue(duration)))
        or type(startTime) ~= "number" or type(duration) ~= "number" then return nil, nil, false end
    return startTime, duration, true
end

local checkItemRule
local function scheduleItemReady(rule, state)
    if state.timerEnd == state.cooldownEnd then return end
    state.timerEnd = state.cooldownEnd
    local expectedEnd = state.cooldownEnd
    C_Timer.After(math.max(0.1, expectedEnd - GetTime() + 0.1), function()
        if itemCooldownStates[rule] == state and state.cooldownEnd == expectedEnd then
            state.timerEnd = nil
            checkItemRule(rule)
        end
    end)
end

checkItemRule = function(rule)
    if not rule.enabled or rule.itemID <= 0 then
        itemCooldownStates[rule] = nil
        return
    end
    local slotID = findEquippedItemSlot(rule.itemID)
    if not slotID then
        itemCooldownStates[rule] = nil
        return
    end

    local startTime, duration, queryOK = getInventoryCooldown(slotID)
    if not queryOK then return end
    local now = GetTime()
    local state = itemCooldownStates[rule]

    if duration > 0 and startTime > 0 then
        local cooldownEnd = startTime + duration
        if cooldownEnd > now + 0.15 then
            if not state or math.abs(state.cooldownEnd - cooldownEnd) > 0.25 then
                state = { cooldownEnd = cooldownEnd, notified = false }
                itemCooldownStates[rule] = state
            end
            scheduleItemReady(rule, state)
            return
        end
    end

    if state then
        if not state.notified and now >= state.cooldownEnd - 0.35 then
            state.notified = true
            notifyRule(rule, "ready", rule.message)
        end
        itemCooldownStates[rule] = nil
    end
end

local function scanItemRules()
    itemScanPending = false
    for _, rule in ipairs(WoWraVoxDB.items) do checkItemRule(rule) end
end

local function queueItemScan(delay)
    if itemScanPending then return end
    itemScanPending = true
    C_Timer.After(delay or 0.1, scanItemRules)
end

local function getSpellCooldown(spellID)
    if not (C_Spell and C_Spell.GetSpellCooldown) then return nil, nil, false end
    local ok, cooldown = pcall(C_Spell.GetSpellCooldown, spellID)
    if not ok or type(cooldown) ~= "table" then return nil, nil, false end
    local fieldsOK, startTime, duration, isEnabled = pcall(function()
        return cooldown.startTime, cooldown.duration, cooldown.isEnabled
    end)
    if not fieldsOK
        or (issecretvalue and (issecretvalue(startTime) or issecretvalue(duration)))
        or type(startTime) ~= "number" or type(duration) ~= "number" then
        return nil, nil, false
    end
    return startTime, duration, isEnabled ~= false
end

local checkSkillRule
local function scheduleSkillReady(rule, state)
    if state.timerEnd == state.cooldownEnd then return end
    state.timerEnd = state.cooldownEnd
    local expectedEnd = state.cooldownEnd
    C_Timer.After(math.max(0.1, expectedEnd - GetTime() + 0.1), function()
        if skillCooldownStates[rule] == state and state.cooldownEnd == expectedEnd then
            state.timerEnd = nil
            checkSkillRule(rule)
        end
    end)
end

checkSkillRule = function(rule)
    if not rule.enabled or rule.spellID <= 0 then
        skillCooldownStates[rule] = nil
        return
    end

    local startTime, duration, queryOK = getSpellCooldown(rule.spellID)
    if not queryOK then return end
    local now = GetTime()
    local state = skillCooldownStates[rule]
    if duration > 0 and startTime > 0 then
        local cooldownEnd = startTime + duration
        if cooldownEnd > now + 0.15 then
            if not state or math.abs(state.cooldownEnd - cooldownEnd) > 0.25 then
                state = { cooldownEnd = cooldownEnd, notified = false }
                skillCooldownStates[rule] = state
            end
            scheduleSkillReady(rule, state)
            return
        end
    end

    if state then
        if not state.notified then
            state.notified = true
            notifyRule(rule, "ready", rule.message)
        end
        skillCooldownStates[rule] = nil
    end
end

local function scanSkillRules()
    if not WoWraVoxDB or type(WoWraVoxDB.skills) ~= "table" then return end
    for _, rule in ipairs(WoWraVoxDB.skills) do checkSkillRule(rule) end
end

local function getItemInfo(itemID, slotID)
    local name, icon
    if slotID and GetInventoryItemTexture then
        local ok, texture = pcall(GetInventoryItemTexture, "player", slotID)
        if ok then icon = texture end
    end
    if GetItemInfo then
        local ok, itemName, _, _, _, _, _, _, _, itemIcon = pcall(GetItemInfo, itemID)
        if ok then
            name = itemName
            icon = icon or itemIcon
        end
    end
    if not name and C_Item and C_Item.GetItemNameByID then
        local ok, itemName = pcall(C_Item.GetItemNameByID, itemID)
        if ok then name = itemName end
    end
    if not icon and C_Item and C_Item.GetItemIconByID then
        local ok, itemIcon = pcall(C_Item.GetItemIconByID, itemID)
        if ok then icon = itemIcon end
    end
    if C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
    return name or ("Item " .. tostring(itemID)), icon
end

local function voiceName(voiceID)
    for _, voice in ipairs(getVoices()) do
        if voice.voiceID == voiceID then return voice.name end
    end
        return L("System voice")
end

local function setStatus(message, isError)
    if not statusText then return end
    statusText:SetText(L(message or ""))
    if isError then
        statusText:SetTextColor(1, 0.35, 0.25)
    else
        statusText:SetTextColor(0.55, 0.86, 0.62)
    end
end

updatePreviewButtons = function()
    if not testApplyButton then return end
    local canSpeak = C_VoiceChat and C_VoiceChat.SpeakText ~= nil
    testApplyButton:SetEnabled(canSpeak and trim(applyMessageBox:GetText()) ~= "")
    testExpireButton:SetEnabled(canSpeak and trim(expireMessageBox:GetText()) ~= "")
    local choosingStarterItem = selectedCategory == "items" and selectedItemRule
        and selectedItemRule.starter == "trinket" and (tonumber(selectedItemRule.itemID) or 0) <= 0
    testItemButton:SetEnabled(choosingStarterItem or (canSpeak and trim(readyMessageBox:GetText()) ~= ""))
    for _, row in pairs(ns.screenControls) do
        if row.preview and row.text then
            ns.setScreenPreviewButtonState(row, trim(row.text:GetText()) ~= "")
        end
    end
end

local function createLabel(parent, text, template)
    local label = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    label:SetText(L(text or ""))
    return label
end

local function addHelpTooltip(widget, title, explanation)
    widget:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L(title), 1, 0.82, 0.2)
        GameTooltip:AddLine(L(explanation), 0.85, 0.88, 0.94, true)
        GameTooltip:Show()
    end)
    widget:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function stylePanel(panel, r, g, b)
    panel.bg = panel:CreateTexture(nil, "BACKGROUND")
    panel.bg:SetAllPoints()
    panel.bg:SetColorTexture(r, g, b, 1)
    local borderColor = { 0.52, 0.41, 0.2, 1 }
    for _, edge in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local line = panel:CreateTexture(nil, "BORDER")
        if edge == "TOP" or edge == "BOTTOM" then
            line:SetTexture("Interface\\Buttons\\WHITE8X8")
            if line.SetGradientAlpha then
                line:SetGradientAlpha("HORIZONTAL", 0.88, 0.68, 0.24, 1, 0.88, 0.68, 0.24, 0)
            else
                line:SetColorTexture(unpack(borderColor))
            end
            line:SetPoint(edge .. "LEFT")
            line:SetPoint(edge .. "RIGHT")
            line:SetHeight(1)
        else
            line:SetColorTexture(0.35, 0.29, 0.18, 0.7)
            line:SetPoint("TOP" .. edge)
            line:SetPoint("BOTTOM" .. edge)
            line:SetWidth(1)
        end
    end
end

local function createEditBox(parent, width, height)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetAutoFocus(false)
    box:SetSize(width, height or 24)
    box:SetTextInsets(6, 6, 0, 0)
    box:SetMaxLetters(240)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", function()
        if not editorLoading then saveDetails() end
    end)
    return box
end

local function createVoiceDropdown(parent, point, relativeTo, x, y, onChange)
    local dropdown = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
    dropdown:SetPoint(point, relativeTo, point, x, y)
    UIDropDownMenu_SetWidth(dropdown, 145)
    UIDropDownMenu_Initialize(dropdown, function(menu, level)
        local voices = getVoices()
        if #voices == 0 then
            local info = UIDropDownMenu_CreateInfo()
            info.text = L("No voice available")
            info.disabled = true
            UIDropDownMenu_AddButton(info, level)
            return
        end
        for _, voice in ipairs(voices) do
            local chosen = voice
            local info = UIDropDownMenu_CreateInfo()
            info.text = chosen.name
            info.value = chosen.voiceID
            info.checked = (selectedCategory == "auras" and selectedAuraRule and selectedAuraRule.voiceID == chosen.voiceID)
                or (selectedCategory == "items" and selectedItemRule and selectedItemRule.voiceID == chosen.voiceID)
                or (selectedCategory == "skills" and selectedSkillRule and selectedSkillRule.voiceID == chosen.voiceID)
            info.func = function()
                onChange(chosen.voiceID)
                UIDropDownMenu_SetSelectedValue(dropdown, chosen.voiceID)
                UIDropDownMenu_SetText(dropdown, chosen.name)
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    return dropdown
end

local function makeVolumeSlider(parent, point, relativeTo, x, y, onChange)
    local slider = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
    slider:SetPoint(point, relativeTo, point, x, y)
    slider:SetSize(150, 18)
    slider:SetMinMaxValues(0, 100)
    slider:SetValueStep(5)
    slider:SetObeyStepOnDrag(true)
    slider:SetScript("OnValueChanged", function(self, value)
        if editorLoading then return end
        onChange(math.max(0, math.min(100, math.floor(value + 0.5))))
    end)
    return slider
end

local function ruleDisplay(rule, category)
    if category == "items" then return rule.name or (L("Item") .. " " .. tostring(rule.itemID)) end
    if category == "skills" then return rule.name or ("Spell " .. tostring(rule.spellID)) end
    if rule.name and rule.name ~= "" then return rule.name end
    local info = rule.spellIDs[1] and getSpellInfo(rule.spellIDs[1])
    local name = info and info.name or L("New aura")
    if #rule.spellIDs > 1 then name = name .. "  +" .. (#rule.spellIDs - 1) end
    return name
end

local function currentRules()
    if selectedCategory == "auras" then return WoWraVoxDB.auras end
    if selectedCategory == "items" then return WoWraVoxDB.items end
    return WoWraVoxDB.skills
end

local function selectRule(rule, category)
    saveDetails()
    addRuleMode = false
    selectedCategory = category
    if category == "auras" then
        selectedAuraRule = rule
    elseif category == "items" then
        selectedItemRule = rule
    else
        selectedSkillRule = rule
    end
    refreshList()
    updateDetails()
end

local function removeSelectedRule()
    local rules = currentRules()
    local selected
    if selectedCategory == "auras" then selected = selectedAuraRule
    elseif selectedCategory == "items" then selected = selectedItemRule
    else selected = selectedSkillRule end
    if not selected then return end
    ns.hideScreenFramesForRule(selected)
    local removedIndex
    for index, rule in ipairs(rules) do
        if rule == selected then
            table.remove(rules, index)
            removedIndex = index
            break
        end
    end
    if selectedCategory == "auras" then
        activeAuras = {}
        auraByInstanceID = {}
        selectedAuraRule = rules[math.min(removedIndex or 1, #rules)]
        rebuildAuraWatches()
        syncAllAuras(true)
        if not selectedAuraRule and WoWraVoxDB.items[1] then
            selectedCategory = "items"
            selectedItemRule = WoWraVoxDB.items[1]
        elseif not selectedAuraRule and WoWraVoxDB.skills[1] then
            selectedCategory = "skills"
            selectedSkillRule = WoWraVoxDB.skills[1]
        end
    elseif selectedCategory == "items" then
        itemCooldownStates[selected] = nil
        selectedItemRule = rules[math.min(removedIndex or 1, #rules)]
        if not selectedItemRule and WoWraVoxDB.auras[1] then
            selectedCategory = "auras"
            selectedAuraRule = WoWraVoxDB.auras[1]
        elseif not selectedItemRule and WoWraVoxDB.skills[1] then
            selectedCategory = "skills"
            selectedSkillRule = WoWraVoxDB.skills[1]
        end
    else
        skillCooldownStates[selected] = nil
        selectedSkillRule = rules[math.min(removedIndex or 1, #rules)]
        if not selectedSkillRule then
            if WoWraVoxDB.auras[1] then
                selectedCategory = "auras"
                selectedAuraRule = WoWraVoxDB.auras[1]
            elseif WoWraVoxDB.items[1] then
                selectedCategory = "items"
                selectedItemRule = WoWraVoxDB.items[1]
            end
        end
    end
    refreshList()
    updateDetails()
end

function refreshList()
    if not (listScroll and listChild and WoWraVoxDB) then return end
    local rules = {}
    for _, rule in ipairs(WoWraVoxDB.auras) do table.insert(rules, { rule = rule, category = "auras" }) end
    for _, rule in ipairs(WoWraVoxDB.items) do table.insert(rules, { rule = rule, category = "items" }) end
    for _, rule in ipairs(WoWraVoxDB.skills) do table.insert(rules, { rule = rule, category = "skills" }) end
    local width = math.max(180, listChild:GetWidth() - 6)
    local rowHeight = 76

    for index, entry in ipairs(rules) do
        local rule, category = entry.rule, entry.category
        local row = listRows[index]
        if not row then
            row = CreateFrame("Button", nil, listChild, "BackdropTemplate")
            row:SetHeight(rowHeight)
            row:RegisterForClicks("LeftButtonUp")
            row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
            row:SetBackdropBorderColor(0.22, 0.24, 0.28, 1)
            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -1)
            row.bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -1, 1)
            row.bottomEdge = row:CreateTexture(nil, "BORDER")
            row.bottomEdge:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 1, 1)
            row.bottomEdge:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -1, 1)
            row.bottomEdge:SetHeight(1)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(36, 36)
            row.icon:SetPoint("LEFT", row, "LEFT", 12, 0)
            row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 58, -10)
            row.title:SetPoint("RIGHT", row, "RIGHT", -42, 0)
            row.title:SetHeight(30)
            row.title:SetJustifyH("LEFT")
            row.title:SetMaxLines(2)
            row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.sub:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 58, 10)
            row.sub:SetPoint("RIGHT", row, "RIGHT", -42, 0)
            row.sub:SetJustifyH("LEFT")
            row.sub:SetMaxLines(1)
            row.toggle = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            row.toggle:SetSize(25, 25)
            row.toggle:SetPoint("TOPRIGHT", row, "TOPRIGHT", -5, -6)
            row.remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
            row.remove:SetSize(24, 24)
            row.remove:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -5, 6)
            addHelpTooltip(row, "Edit rule", "Select this rule and show its settings.")
            addHelpTooltip(row.toggle, "Enable or disable rule", "Toggle this rule without deleting it.")
            addHelpTooltip(row.remove, "Remove rule", "Delete this rule.")
            listRows[index] = row
        end

        row.rule, row.category = rule, category
        row:SetWidth(width)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", listChild, "TOPLEFT", 6, -((index - 1) * (rowHeight + 8)))
        local selected = (selectedCategory == category)
            and ((category == "auras" and selectedAuraRule == rule)
                or (category == "items" and selectedItemRule == rule)
                or (category == "skills" and selectedSkillRule == rule))
        if selected then
            row.bg:SetColorTexture(0.31, 0.23, 0.10, 0.95)
            row:SetBackdropColor(0.31, 0.23, 0.10, 0.95)
            row:SetBackdropBorderColor(0.72, 0.55, 0.22, 1)
            row.bottomEdge:SetColorTexture(0.72, 0.55, 0.22, 1)
        else
            row.bg:SetColorTexture(0.125, 0.125, 0.13, 1)
            row:SetBackdropColor(0.125, 0.125, 0.13, 1)
            row:SetBackdropBorderColor(0.22, 0.24, 0.28, 1)
            row.bottomEdge:SetColorTexture(0.22, 0.24, 0.28, 1)
        end
        local muted = rule.enabled == false
        row.icon:SetDesaturated(muted)
        row.icon:SetAlpha(muted and 0.48 or 1)
        row.title:SetTextColor(muted and 0.43 or 1, muted and 0.43 or 1, muted and 0.43 or 1)
        row.sub:SetTextColor(muted and 0.5 or 1, muted and 0.5 or 0.82, muted and 0.5 or 0.2)
        row.toggle:SetAlpha(muted and 0.5 or 1)
        row.remove:SetAlpha(muted and 0.5 or 1)
        if muted then
            row.bg:SetColorTexture(0.075, 0.075, 0.08, 0.95)
            row:SetBackdropColor(0.075, 0.075, 0.08, 0.95)
            row:SetBackdropBorderColor(0.18, 0.19, 0.22, 1)
            row.bottomEdge:SetColorTexture(0.18, 0.19, 0.22, 1)
        end
        if category == "auras" then
            local info = rule.spellIDs[1] and getSpellInfo(rule.spellIDs[1])
            row.icon:SetTexture(info and info.iconID or "Interface\\Icons\\INV_Misc_QuestionMark")
            local triggerText = (rule.applyEnabled and L("Apply") or "")
            if rule.expireEnabled then triggerText = triggerText .. (triggerText ~= "" and " · " or "") .. L("Expire") end
            row.sub:SetText(#rule.spellIDs .. " " .. L("triggers") .. " · " .. (triggerText ~= "" and triggerText or L("No trigger")))
        elseif category == "items" then
            row.icon:SetTexture(rule.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            if rule.starter == "trinket" and rule.itemID <= 0 then
                row.sub:SetText(L("Choose an equipped item"))
            else
                row.sub:SetText("Item " .. tostring(rule.itemID) .. " · " .. L("Ready"))
            end
        else
            local info = rule.spellID and getSpellInfo(rule.spellID)
            row.icon:SetTexture(rule.icon or (info and info.iconID) or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.sub:SetText("Spell ID " .. tostring(rule.spellID) .. " · " .. L("Ready"))
        end
        row.title:SetText(ruleDisplay(rule, category))
        row.toggle:SetChecked(rule.enabled)
        row:SetScript("OnClick", function(self)
            selectRule(self.rule, self.category)
            if self.category == "items" and self.rule.starter == "trinket" and self.rule.itemID <= 0
                and ns.BeginItemPicker then
                ns.BeginItemPicker()
            end
        end)
        row.toggle:SetScript("OnClick", function(self)
            local target = self:GetParent().rule
            local checked = self:GetChecked()
            target.enabled = checked == true or checked == 1
            if self:GetParent().category == "auras" then
                rebuildAuraWatches()
                syncAllAuras(true)
            elseif self:GetParent().category == "items" then
                itemCooldownStates[target] = nil
                queueItemScan(0.1)
            else
                skillCooldownStates[target] = nil
                scanSkillRules()
            end
            refreshList()
            updateDetails()
        end)
        row.remove:SetScript("OnClick", function(self)
            local parent = self:GetParent()
            selectRule(parent.rule, parent.category)
            removeSelectedRule()
        end)
        row:Show()
    end

    for index = #rules + 1, #listRows do listRows[index]:Hide() end
    listChild:SetHeight(math.max(1, #rules * (rowHeight + 8)))
    if listEmptyText then
        listEmptyText:SetText(L("No rules yet. Use + to add an aura group or item."))
        listEmptyText:SetShown(#rules == 0)
    end
end

function saveDetails()
    if editorLoading then return end
    if selectedCategory == "auras" and selectedAuraRule and auraNameBox then
        local rule = selectedAuraRule
        rule.name = trim(auraNameBox:GetText())
        local applyChecked = applyEnabledCheck:GetChecked()
        rule.applyEnabled = applyChecked == true or applyChecked == 1
        rule.applyMessage = applyMessageBox:GetText()
        local expireChecked = expireEnabledCheck:GetChecked()
        rule.expireEnabled = expireChecked == true or expireChecked == 1
        rule.expireMessage = expireMessageBox:GetText()
        local ids, valid = parseSpellIDs(auraIDsBox:GetText())
        if valid then
            local changed = #ids ~= #rule.spellIDs
            if not changed then
                for index, id in ipairs(ids) do
                    if id ~= rule.spellIDs[index] then changed = true; break end
                end
            end
            rule.spellIDs = ids
            auraIDsStatus:SetText(#ids .. " IDs · " .. L("Checking spell data…"))
            auraIDsStatus:SetTextColor(0.72, 0.78, 0.86)
            if changed then
                rebuildAuraWatches()
                syncAllAuras(true)
            end
        else
            auraIDsStatus:SetText(L("Separate IDs with commas."))
            auraIDsStatus:SetTextColor(1, 0.35, 0.25)
        end
    elseif selectedCategory == "items" and selectedItemRule and itemNameText then
        selectedItemRule.name = trim(itemNameText:GetText())
        selectedItemRule.message = itemMessageBox:GetText()
    end
    refreshList()
end

local function layoutScreenRow(row, y)
    if not row then return end
    row.enabled:ClearAllPoints()
    row.enabled:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 6, y)
    row.text:ClearAllPoints()
    row.text:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 154, y + 1)
    row.preview:ClearAllPoints()
    row.preview:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", -16, y + 1)
    row.text:SetPoint("RIGHT", row.preview, "LEFT", -8, 0)
    row.font:ClearAllPoints()
    row.font:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 126, y - 27)
    row.size:ClearAllPoints()
    row.size:SetPoint("LEFT", row.font, "RIGHT", -12, 0)
    row.style:ClearAllPoints()
    row.style:SetPoint("LEFT", row.size, "RIGHT", -12, 0)
    row.color:ClearAllPoints()
    row.color:SetPoint("LEFT", row.style, "RIGHT", -8, 0)
    row.anchor:ClearAllPoints()
    row.anchor:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", -16, y - 27)
end

local function showScreenRow(row, shown)
    if not row then return end
    local checked = row.enabled:GetChecked()
    local detailsShown = shown and (checked == true or checked == 1)
    row.enabled:SetShown(shown)
    row.label:SetShown(shown)
    row.text:SetShown(detailsShown)
    row.preview:SetShown(detailsShown)
    row.font:SetShown(detailsShown)
    row.size:SetShown(detailsShown)
    row.style:SetShown(detailsShown)
    row.color:SetShown(detailsShown)
    row.anchor:SetShown(detailsShown)
end

local function layoutSharedEditor(isAura)
    local notificationY = isAura and -255 or -151
    local firstMessageY = notificationY - 21
    local screenApplyY = firstMessageY - 34
    local applyScreenCheck = ns.screenControls.apply and ns.screenControls.apply.enabled:GetChecked()
    local applyScreenEnabled = applyScreenCheck == true or applyScreenCheck == 1
    local expireMessageY = firstMessageY - (isAura and (applyScreenEnabled and 112 or 85) or 74)
    local screenExpireY = expireMessageY - 34
    local expireScreenCheck = ns.screenControls.expire and ns.screenControls.expire.enabled:GetChecked()
    local readyScreenCheck = ns.screenControls.ready and ns.screenControls.ready.enabled:GetChecked()
    local expireScreenEnabled = expireScreenCheck == true or expireScreenCheck == 1
    local readyScreenEnabled = readyScreenCheck == true or readyScreenCheck == 1
    local voiceY = isAura and (expireMessageY - (expireScreenEnabled and 107 or 80))
        or (firstMessageY - (readyScreenEnabled and 107 or 80))
    auraEditor.notificationsHeading:ClearAllPoints()
    auraEditor.notificationsHeading:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 16, notificationY)
    applyEnabledCheck:ClearAllPoints()
    applyEnabledCheck:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 6, firstMessageY)
    expireEnabledCheck:ClearAllPoints()
    expireEnabledCheck:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 6, expireMessageY)
    applyMessageBox:ClearAllPoints()
    applyMessageBox:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 154, firstMessageY + 1)
    testApplyButton:ClearAllPoints()
    testApplyButton:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", -16, firstMessageY + 1)
    applyMessageBox:SetPoint("RIGHT", testApplyButton, "LEFT", -8, 0)
    layoutScreenRow(ns.screenControls.apply, screenApplyY)
    expireMessageBox:ClearAllPoints()
    expireMessageBox:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 154, expireMessageY + 1)
    testExpireButton:ClearAllPoints()
    testExpireButton:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", -16, expireMessageY + 1)
    expireMessageBox:SetPoint("RIGHT", testExpireButton, "LEFT", -8, 0)
    layoutScreenRow(ns.screenControls.expire, screenExpireY)
    readyMessageBox:ClearAllPoints()
    readyMessageBox:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 154, firstMessageY + 1)
    testItemButton:ClearAllPoints()
    testItemButton:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", -16, firstMessageY + 1)
    readyMessageBox:SetPoint("RIGHT", testItemButton, "LEFT", -8, 0)
    layoutScreenRow(ns.screenControls.ready, screenApplyY)
    auraEditor.voiceHeading:ClearAllPoints()
    auraEditor.voiceHeading:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 16, voiceY)
    auraEditor.voiceLabel:ClearAllPoints()
    auraEditor.voiceLabel:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 60, voiceY - 22)
    auraEditor.volumeLabel:ClearAllPoints()
    auraEditor.volumeLabel:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 365, voiceY - 22)
    voiceDropdown:ClearAllPoints()
    voiceDropdown:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 60, voiceY - 42)
    volumeSlider:ClearAllPoints()
    volumeSlider:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 365, voiceY - 42)
end

function updateDetails()
    if not detailPanel then return end
    if searchPopup then searchPopup:Hide() end
    editorLoading = true
    local isAura = selectedCategory == "auras"
    local rule
    if isAura then rule = selectedAuraRule else rule = selectedItemRule end
    detailPanel.emptyText:SetShown(not rule)
    detailPanel.emptyText:SetText(isAura and "Select an aura group or add a new one." or "Select an item rule or add an equipped item.")
    auraEditor:SetShown(isAura and rule ~= nil)
    itemEditor:SetShown(not isAura and rule ~= nil)
    deleteRuleButton:SetShown(false)

    if not rule then
        editorLoading = false
        return
    end

    if isAura then
        auraNameBox:SetText(rule.name or "")
        auraSearchBox:SetText("")
        auraIDsBox:SetText(table.concat(rule.spellIDs, ", "))
        auraEnabledCheck:SetChecked(rule.enabled)
        applyEnabledCheck:SetChecked(rule.applyEnabled)
        applyMessageBox:SetText(rule.applyMessage)
        expireEnabledCheck:SetChecked(rule.expireEnabled)
        expireMessageBox:SetText(rule.expireMessage)
        UIDropDownMenu_SetSelectedValue(auraVoiceDropdown, rule.voiceID)
        UIDropDownMenu_SetText(auraVoiceDropdown, voiceName(rule.voiceID))
        auraVolumeSlider:SetValue(rule.volume)
        auraVolumeValue:SetText(tostring(rule.volume))
        local validCount, invalidCount, pendingCount = 0, 0, 0
        for _, id in ipairs(rule.spellIDs) do
            local _, status = getSpellInfo(id)
            if status == "valid" then validCount = validCount + 1
            elseif status == "pending" then pendingCount = pendingCount + 1
            else invalidCount = invalidCount + 1 end
        end
        local summary = string.format(L("%d valid"), validCount)
        if pendingCount > 0 then summary = summary .. " · " .. string.format(L("%d loading"), pendingCount) end
        if invalidCount > 0 then summary = summary .. " · " .. string.format(L("%d invalid"), invalidCount) end
        auraIDsStatus:SetText(summary)
        auraIDsStatus:SetTextColor(invalidCount > 0 and 1 or 0.72, invalidCount > 0 and 0.35 or 0.78, invalidCount > 0 and 0.25 or 0.86)
        updateAuraIDPreview()
        updateAuraIDPills()
    else
        itemNameText:SetText(rule.name or "")
        itemIconTexture:SetTexture(rule.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        itemEnabledCheck:SetChecked(rule.enabled)
        itemMessageBox:SetText(rule.message)
        UIDropDownMenu_SetSelectedValue(itemVoiceDropdown, rule.voiceID)
        UIDropDownMenu_SetText(itemVoiceDropdown, voiceName(rule.voiceID))
        itemVolumeSlider:SetValue(rule.volume)
        itemVolumeValue:SetText(tostring(rule.volume))
        local slotID = findEquippedItemSlot(rule.itemID)
        itemEditor.equippedText:SetText(slotID and string.format(L("Equipped · Slot %d"), slotID) or L("Not equipped"))
        itemEditor.equippedText:SetTextColor(slotID and 0.55 or 1, slotID and 0.86 or 0.65, slotID and 0.62 or 0.25)
    end

    editorLoading = false
    updateRulePreviewFromEditor()
    updatePreviewButtons()
end

local function makeSectionLabel(parent, text, x, y)
    local label = createLabel(parent, text, "GameFontNormal")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    label:SetTextColor(1, 0.82, 0.2)
    return label
end

local function runAuraSearch()
    if not (auraSearchBox and searchPopup) then return end
    local query = trim(auraSearchBox:GetText())
    if query == "" then searchPopup:Hide(); return end
    local results = searchLocalSpells(query)
    local visible = math.min(#results, #searchRows)
    for index, row in ipairs(searchRows) do
        local result = results[index]
        row.result = result
        if result then
            row.icon:SetTexture(result.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.title:SetText(result.name .. "  |cffffd268" .. result.id .. "|r")
            row.origin:SetText(result.origin)
            row:Show()
        else
            row:Hide()
        end
    end
    searchPopup.empty:SetShown(visible == 0)
    searchPopup:SetHeight(math.max(36, visible * 40 + 8))
    searchPopup:Show()
    if visible > 0 then
        setStatus(string.format(L("%d of %d matches shown"), visible, #results))
    else
        setStatus("No local matches. Enter a known spell ID directly.")
    end
end

local function createSearchPopup()
    searchPopup = CreateFrame("Frame", nil, auraEditor, "BackdropTemplate")
    searchPopup:SetPoint("TOPRIGHT", auraSearchBox, "BOTTOMRIGHT", 0, -4)
    searchPopup:SetSize(440, 36)
    searchPopup:SetFrameStrata("DIALOG")
    searchPopup:SetFrameLevel(auraEditor:GetFrameLevel() + 20)
    searchPopup:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    searchPopup.empty = createLabel(searchPopup, "No matching local auras.", "GameFontHighlightSmall")
    searchPopup.empty:SetPoint("CENTER")
    for index = 1, 6 do
        local row = CreateFrame("Button", nil, searchPopup)
        row:SetPoint("TOPLEFT", searchPopup, "TOPLEFT", 5, -5 - (index - 1) * 40)
        row:SetSize(430, 38)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(30, 30)
        row.icon:SetPoint("LEFT", row, "LEFT", 5, 0)
        row.title = createLabel(row, "", "GameFontHighlightSmall")
        row.title:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -3)
        row.origin = createLabel(row, "", "GameFontDisableSmall")
        row.origin:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 3)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        addHelpTooltip(row, "Add to group", "Add this spell ID to the group without duplicates.")
        row:SetScript("OnClick", function(self)
            if not (selectedAuraRule and self.result) then return end
            saveDetails()
            local id = self.result.id
            for _, existing in ipairs(selectedAuraRule.spellIDs) do
                if existing == id then
                    searchPopup:Hide()
                    setStatus("This spell ID is already in the group.")
                    return
                end
            end
            table.insert(selectedAuraRule.spellIDs, id)
            auraIDsBox:SetText(table.concat(selectedAuraRule.spellIDs, ", "))
            rebuildAuraWatches()
            syncAllAuras(true)
            refreshList()
            updateAuraIDPreview()
            searchPopup:Hide()
            setStatus(L("Spell added to group") .. ": " .. self.result.name .. " (" .. id .. ")")
        end)
        searchRows[index] = row
    end
    searchPopup:Hide()
end

local function createEditorWidgets()
    detailPanel = CreateFrame("Frame", nil, optionsFrame)
    detailPanel:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 312, -64)
    detailPanel:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -16, 16)
    stylePanel(detailPanel, 0.155, 0.155, 0.15)
    detailPanel.emptyText = createLabel(detailPanel, "Select a rule or add an aura group or item.", "GameFontHighlight")
    detailPanel.emptyText:SetPoint("CENTER")
    detailPanel.emptyText:SetWidth(330)
    detailPanel.emptyText:SetJustifyH("CENTER")

    auraEditor = CreateFrame("Frame", nil, detailPanel)
    auraEditor:SetAllPoints()
    itemEditor = CreateFrame("Frame", nil, detailPanel)
    itemEditor:SetAllPoints()

    makeSectionLabel(auraEditor, "AURA GROUP", 16, -14)
    local nameLabel = createLabel(auraEditor, "Name", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 16, -43)
    auraNameBox = createEditBox(auraEditor, 190, 24)
    auraNameBox:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 80, -37)
    local searchLabel = createLabel(auraEditor, "Aura or spell ID", "GameFontNormalSmall")
    searchLabel:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 285, -43)
    auraSearchBox = createEditBox(auraEditor, 145, 24)
    auraSearchBox:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 395, -37)
    auraSearchBox:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", -16, -37)
    auraSearchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); runAuraSearch() end)
    auraSearchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); if searchPopup then searchPopup:Hide() end end)
    auraSearchBox:HookScript("OnTextChanged", function(self)
        if editorLoading then return end
        local query = trim(self:GetText())
        if #query < 3 and not tonumber(query) then
            if searchPopup then searchPopup:Hide() end
            return
        end
        local expected = query
        C_Timer.After(0.2, function()
            if auraSearchBox and trim(auraSearchBox:GetText()) == expected then runAuraSearch() end
        end)
    end)
    createSearchPopup()

    local idsLabel = createLabel(auraEditor, "Spell IDs", "GameFontNormalSmall")
    idsLabel:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 16, -77)
    auraIDsBox = createEditBox(auraEditor, 350, 24)
    auraIDsBox:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 80, -71)
    auraIDsBox:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", -16, -71)
    auraIDsStatus = createLabel(auraEditor, "", "GameFontNormalSmall")
    auraIDsStatus:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 80, -100)
    auraIDPreviewIcon = auraEditor:CreateTexture(nil, "ARTWORK")
    auraIDPreviewIcon:Hide()
    auraIDPreviewText = createLabel(auraEditor, "", "GameFontHighlightSmall")
    auraIDPreviewText:Hide()
    for index = 1, 7 do
        local pill = CreateFrame("Button", nil, auraEditor)
        pill:SetSize(68, 20)
        pill:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 80 + (index - 1) * 70, -120)
        pill.bg = pill:CreateTexture(nil, "BACKGROUND")
        pill.bg:SetAllPoints()
        pill.bg:SetColorTexture(0.08, 0.08, 0.075, 1)
        pill.icon = pill:CreateTexture(nil, "ARTWORK")
        pill.icon:SetSize(16, 16)
        pill.icon:SetPoint("LEFT", pill, "LEFT", 2, 0)
        pill.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        pill.label = createLabel(pill, "", "GameFontHighlightSmall")
        pill.label:SetPoint("LEFT", pill.icon, "RIGHT", 3, 0)
        pill.label:SetPoint("RIGHT", pill, "RIGHT", -2, 0)
        pill.label:SetJustifyH("LEFT")
        pill.label:SetMaxLines(1)
        pill:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
        pill:SetScript("OnEnter", function(self)
            if not self.id then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local ok = pcall(GameTooltip.SetSpellByID, GameTooltip, self.id)
            if not ok then GameTooltip:SetText(L("Spell IDs") .. ": " .. self.id) end
            GameTooltip:AddLine("ID: " .. self.id, 0.72, 0.78, 0.86)
            GameTooltip:Show()
        end)
        pill:SetScript("OnLeave", function() GameTooltip:Hide() end)
        pill:Hide()
        auraIDPills[index] = pill
    end
    auraIDsBox:HookScript("OnTextChanged", function()
        updateAuraIDPreview()
        updateAuraIDPills()
    end)

    auraEnabledCheck = CreateFrame("CheckButton", nil, auraEditor, "UICheckButtonTemplate")
    auraEnabledCheck:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", -14, -5)
    local auraEnabledLabel = createLabel(auraEditor, "Active", "GameFontNormalSmall")
    auraEnabledLabel:SetPoint("RIGHT", auraEnabledCheck, "LEFT", -2, 0)

    makeSectionLabel(auraEditor, "NOTIFICATIONS", 16, -153)
    applyEnabledCheck = CreateFrame("CheckButton", nil, auraEditor, "UICheckButtonTemplate")
    applyEnabledCheck:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 6, -175)
    local applyLabel = createLabel(auraEditor, "Apply", "GameFontNormalSmall")
    applyLabel:SetPoint("LEFT", applyEnabledCheck, "RIGHT", 0, 0)
    applyMessageBox = createEditBox(auraEditor, 280, 24)
    applyMessageBox:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 80, -174)
    testApplyButton = CreateFrame("Button", nil, auraEditor, "UIPanelButtonTemplate")
    testApplyButton:SetSize(72, 24)
    testApplyButton:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", -16, -174)
    applyMessageBox:SetPoint("RIGHT", testApplyButton, "LEFT", -8, 0)
    testApplyButton:SetText(L("Test"))

    expireEnabledCheck = CreateFrame("CheckButton", nil, auraEditor, "UICheckButtonTemplate")
    expireEnabledCheck:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 6, -218)
    local expireLabel = createLabel(auraEditor, "Expire", "GameFontNormalSmall")
    expireLabel:SetPoint("LEFT", expireEnabledCheck, "RIGHT", 0, 0)
    expireMessageBox = createEditBox(auraEditor, 280, 24)
    expireMessageBox:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 80, -217)
    testExpireButton = CreateFrame("Button", nil, auraEditor, "UIPanelButtonTemplate")
    testExpireButton:SetSize(72, 24)
    testExpireButton:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", -16, -217)
    expireMessageBox:SetPoint("RIGHT", testExpireButton, "LEFT", -8, 0)
    testExpireButton:SetText(L("Test"))

    makeSectionLabel(auraEditor, "VOICE", 16, -262)
    local voiceLabel = createLabel(auraEditor, "Voice", "GameFontNormalSmall")
    voiceLabel:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 16, -297)
    auraVoiceDropdown = createVoiceDropdown(auraEditor, "TOPLEFT", auraEditor, 60, -286, function(voiceID)
        if selectedAuraRule then selectedAuraRule.voiceID = voiceID end
    end)
    local volumeLabel = createLabel(auraEditor, "Volume", "GameFontNormalSmall")
    volumeLabel:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 300, -297)
    auraVolumeSlider = makeVolumeSlider(auraEditor, "TOPLEFT", auraEditor, 365, -293, function(value)
        if selectedAuraRule then selectedAuraRule.volume = value; auraVolumeValue:SetText(tostring(value)) end
    end)
    auraVolumeValue = createLabel(auraEditor, "80", "GameFontHighlight")
    auraVolumeValue:SetPoint("LEFT", auraVolumeSlider, "RIGHT", 8, 0)

    makeSectionLabel(itemEditor, "ITEM READY", 16, -14)
    itemIconTexture = itemEditor:CreateTexture(nil, "ARTWORK")
    itemIconTexture:SetSize(42, 42)
    itemIconTexture:SetPoint("TOPLEFT", itemEditor, "TOPLEFT", 17, -43)
    itemIconTexture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    itemNameText = createEditBox(itemEditor, 320, 24)
    itemNameText:SetPoint("TOPLEFT", itemEditor, "TOPLEFT", 72, -47)
    itemEditor.equippedText = createLabel(itemEditor, "", "GameFontNormalSmall")
    itemEditor.equippedText:SetPoint("TOPLEFT", itemEditor, "TOPLEFT", 72, -75)

    itemEnabledCheck = CreateFrame("CheckButton", nil, itemEditor, "UICheckButtonTemplate")
    itemEnabledCheck:SetPoint("TOPRIGHT", itemEditor, "TOPRIGHT", -14, -43)
    itemNameText:SetPoint("RIGHT", itemEnabledCheck, "LEFT", -70, 0)
    local itemEnabledLabel = createLabel(itemEditor, "Active", "GameFontNormalSmall")
    itemEnabledLabel:SetPoint("RIGHT", itemEnabledCheck, "LEFT", -2, 0)

    local itemMessageLabel = createLabel(itemEditor, "READY MESSAGE", "GameFontNormalSmall")
    itemMessageLabel:SetPoint("TOPLEFT", itemEditor, "TOPLEFT", 16, -118)
    itemMessageBox = createEditBox(itemEditor, 325, 24)
    itemMessageBox:SetPoint("TOPLEFT", itemEditor, "TOPLEFT", 16, -139)
    testItemButton = CreateFrame("Button", nil, itemEditor, "UIPanelButtonTemplate")
    testItemButton:SetSize(72, 24)
    testItemButton:SetPoint("TOPRIGHT", itemEditor, "TOPRIGHT", -16, -139)
    itemMessageBox:SetPoint("RIGHT", testItemButton, "LEFT", -8, 0)
    testItemButton:SetText(L("Test"))
    applyMessageBox:HookScript("OnTextChanged", updatePreviewButtons)
    expireMessageBox:HookScript("OnTextChanged", updatePreviewButtons)
    itemMessageBox:HookScript("OnTextChanged", updatePreviewButtons)

    makeSectionLabel(itemEditor, "VOICE", 16, -190)
    local itemVoiceLabel = createLabel(itemEditor, "Voice", "GameFontNormalSmall")
    itemVoiceLabel:SetPoint("TOPLEFT", itemEditor, "TOPLEFT", 16, -221)
    itemVoiceDropdown = createVoiceDropdown(itemEditor, "TOPLEFT", itemEditor, 60, -210, function(voiceID)
        if selectedItemRule then selectedItemRule.voiceID = voiceID end
    end)
    local itemVolumeLabel = createLabel(itemEditor, "Volume", "GameFontNormalSmall")
    itemVolumeLabel:SetPoint("TOPLEFT", itemEditor, "TOPLEFT", 300, -221)
    itemVolumeSlider = makeVolumeSlider(itemEditor, "TOPLEFT", itemEditor, 365, -217, function(value)
        if selectedItemRule then selectedItemRule.volume = value; itemVolumeValue:SetText(tostring(value)) end
    end)
    itemVolumeValue = createLabel(itemEditor, "80", "GameFontHighlight")
    itemVolumeValue:SetPoint("LEFT", itemVolumeSlider, "RIGHT", 8, 0)

    local notes = createLabel(itemEditor, "Announce once when this equipped item is ready after its cooldown.", "GameFontHighlightSmall")
    notes:SetPoint("TOPLEFT", itemEditor, "TOPLEFT", 16, -260)
    notes:SetWidth(440)
    notes:SetJustifyH("LEFT")
    notes:SetTextColor(0.72, 0.78, 0.86)

    deleteRuleButton = CreateFrame("Button", nil, detailPanel)
    deleteRuleButton:SetSize(28, 28)
    deleteRuleButton.icon = deleteRuleButton:CreateTexture(nil, "ARTWORK")
    deleteRuleButton.icon:SetTexture("Interface\\Buttons\\UI-StopButton")
    deleteRuleButton.icon:SetAllPoints()
    deleteRuleButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")

    for _, box in ipairs({ auraNameBox, auraIDsBox, applyMessageBox, expireMessageBox, itemNameText, itemMessageBox }) do
        box:HookScript("OnEditFocusLost", function()
            if not editorLoading then
                saveDetails()
            end
        end)
    end

    local function onAuraToggle()
        if editorLoading or not selectedAuraRule then return end
        saveDetails()
        local checked = auraEnabledCheck:GetChecked()
        selectedAuraRule.enabled = checked == true or checked == 1
        rebuildAuraWatches()
        syncAllAuras(true)
        refreshList()
    end
    auraEnabledCheck:SetScript("OnClick", onAuraToggle)
    applyEnabledCheck:SetScript("OnClick", onAuraToggle)
    expireEnabledCheck:SetScript("OnClick", onAuraToggle)
    itemEnabledCheck:SetScript("OnClick", function()
        if editorLoading or not selectedItemRule then return end
        local checked = itemEnabledCheck:GetChecked()
        selectedItemRule.enabled = checked == true or checked == 1
        itemCooldownStates[selectedItemRule] = nil
        queueItemScan(0.1)
        refreshList()
    end)

    testApplyButton:SetScript("OnClick", function()
        saveDetails()
        if selectedAuraRule and not playTTS(selectedAuraRule.voiceID, selectedAuraRule.applyMessage, selectedAuraRule.volume) then
            setStatus("TTS test could not be sent to WoW.", true)
        else
            setStatus("TTS test sent to WoW. Check audio in game.")
        end
    end)
    testExpireButton:SetScript("OnClick", function()
        saveDetails()
        if selectedAuraRule and not playTTS(selectedAuraRule.voiceID, selectedAuraRule.expireMessage, selectedAuraRule.volume) then
            setStatus("TTS test could not be sent to WoW.", true)
        else
            setStatus("TTS test sent to WoW. Check audio in game.")
        end
    end)
    testItemButton:SetScript("OnClick", function()
        saveDetails()
        if selectedItemRule and not playTTS(selectedItemRule.voiceID, selectedItemRule.message, selectedItemRule.volume) then
            setStatus("TTS test could not be sent to WoW.", true)
        else
            setStatus("TTS test sent to WoW. Check audio in game.")
        end
    end)
    deleteRuleButton:SetScript("OnClick", removeSelectedRule)
    addHelpTooltip(auraNameBox, "Group name", "A rule name used for display; it does not select the monitored aura.")
    addHelpTooltip(auraSearchBox, "Search auras", "Type at least three letters or an ID. Matching local spells appear automatically; click one to add its ID.")
    addHelpTooltip(auraIDsBox, "Spell IDs", "A comma-separated list of spell IDs to monitor.")
    addHelpTooltip(auraEnabledCheck, "Aura rule", "Enable this aura group.")
    addHelpTooltip(applyEnabledCheck, "On apply", "Announce when the aura appears.")
    addHelpTooltip(applyMessageBox, "Notification message", "Message spoken when the aura appears.")
    addHelpTooltip(testApplyButton, "Test notification", "Preview this message with the selected voice and volume.")
    addHelpTooltip(expireEnabledCheck, "On expire", "Announce when the aura expires naturally.")
    addHelpTooltip(expireMessageBox, "Notification message", "Message spoken when the aura expires naturally.")
    addHelpTooltip(testExpireButton, "Test notification", "Preview this message with the selected voice and volume.")
    addHelpTooltip(auraVoiceDropdown.Button or auraVoiceDropdown, "Voice", "Select the voice for this aura group.")
    addHelpTooltip(auraVolumeSlider, "Volume", "Set the speech volume from 0 to 100.")
    addHelpTooltip(itemNameText, "Item name", "Display name for this item rule.")
    addHelpTooltip(itemEnabledCheck, "Item rule", "Enable or disable this item rule.")
    addHelpTooltip(itemMessageBox, "Ready notification", "Message spoken when the observed item cooldown is ready.")
    addHelpTooltip(testItemButton, "Test notification", "Preview this message with the selected voice and volume.")
    addHelpTooltip(itemVoiceDropdown.Button or itemVoiceDropdown, "Voice", "Select the voice for this item rule.")
    addHelpTooltip(itemVolumeSlider, "Volume", "Set the speech volume from 0 to 100.")
    addHelpTooltip(deleteRuleButton, "Remove rule", "Delete the selected rule.")
    updatePreviewButtons()
end

local function selectedAura()
    return selectedCategory == "auras" and selectedAuraRule or nil
end

local function selectedItem()
    return selectedCategory == "items" and selectedItemRule or nil
end

local function selectedSkill()
    return selectedCategory == "skills" and selectedSkillRule or nil
end

local function selectedRule()
    return selectedAura() or selectedItem() or selectedSkill()
end

function ns.updateScreenColorSwatch(row, color)
    if not (row and row.color and row.color.fill) then return end
    color = ns.copyScreenColor(color)
    row.color.fill:SetColorTexture(color.r, color.g, color.b, color.a)
end

function ns.openScreenColorPicker(row)
    local rule = selectedRule()
    if not (rule and row and row.eventKey and ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow) then return end
    saveDetails()
    local profile = ns.getRuleScreenProfile(rule, row.eventKey)
    if not profile then return end
    local original = ns.copyScreenColor(profile.color)
    local message = trim(row.text:GetText()) ~= "" and row.text:GetText() or "WoWraVox"

    local function applyColor(r, g, b)
        profile.color = ns.copyScreenColor({ r = r, g = g, b = b, a = original.a })
        ns.updateScreenColorSwatch(row, profile.color)
        ns.applyScreenFrameStyle(row.frame, profile)
        ns.showScreenText(rule, row.eventKey, message, true)
    end
    local function closePreview()
        ns.hideScreenTextPreview(rule, row.eventKey)
    end

    if not ColorPickerFrame.wowraVoxColorHooked then
        ColorPickerFrame.wowraVoxColorHooked = true
        ColorPickerFrame:HookScript("OnHide", function(self)
            local onClose = self.wowraVoxColorClose
            self.wowraVoxColorClose = nil
            if onClose then onClose() end
        end)
    end
    if ColorPickerFrame:IsShown() then ColorPickerFrame:Hide() end
    ColorPickerFrame:SetupColorPickerAndShow({
        r = original.r,
        g = original.g,
        b = original.b,
        hasOpacity = false,
        swatchFunc = function()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            applyColor(r, g, b)
        end,
        cancelFunc = function()
            applyColor(original.r, original.g, original.b)
        end,
    })
    ColorPickerFrame.wowraVoxColorClose = closePreview
end

local function saveScreenRowProfile(row, rule)
    if not (row and rule and row.eventKey) then return end
    local profile = ns.getRuleScreenProfile(rule, row.eventKey)
    if not profile then return end
    profile.enabled = row.enabled:GetChecked() == true or row.enabled:GetChecked() == 1
    profile.text = row.text:GetText()
    profile.font = row.fontValue or profile.font
    profile.size = ns.getScreenSizeValue(row.sizeValue or profile.size)
    profile.style = ns.getScreenStyleChoice(row.styleValue or profile.style).key
    if selectedCategory == "auras" then
        if row.eventKey == "apply" then
            rule.applyScreenEnabled, rule.applyScreenText = profile.enabled, profile.text
        else
            rule.expireScreenEnabled, rule.expireScreenText = profile.enabled, profile.text
        end
    else
        rule.screenEnabled, rule.screenText = profile.enabled, profile.text
    end
end

local function loadScreenRowProfile(row, rule)
    if not (row and rule and row.eventKey) then return end
    local profile = ns.getRuleScreenProfile(rule, row.eventKey)
    row.fontValue = profile.font
    row.sizeValue = profile.size
    row.styleValue = profile.style
    row.font.screenValue = profile.font
    row.size.screenValue = tostring(profile.size)
    row.style.screenValue = profile.style
    row.frame = ns.getScreenFrame(rule, row.eventKey)
    UIDropDownMenu_SetSelectedValue(row.font, profile.font)
    UIDropDownMenu_SetText(row.font, L(ns.getScreenFontChoiceByKey(profile.font).key))
    UIDropDownMenu_SetSelectedValue(row.size, tostring(profile.size))
    UIDropDownMenu_SetText(row.size, tostring(profile.size))
    UIDropDownMenu_SetSelectedValue(row.style, profile.style)
    UIDropDownMenu_SetText(row.style, L(ns.getScreenStyleChoice(profile.style).label))
    ns.updateScreenColorSwatch(row, profile.color)
    row.enabled:SetChecked(profile.enabled)
    row.text:SetText(profile.text or "")
    row.anchor:SetText(ns.screenAnchorUnlocked and ns.screenAnchorTarget == row.frame
        and L("Lock") or L("Anchor"))
    ns.applyScreenFrameStyle(row.frame, profile)
    ns.positionScreenFrame(row.frame, profile)
end

local function previewTriggerName(rule, category)
    if category == "items" then return rule.name or ("Item " .. tostring(rule.itemID or 0)) end
    if category == "skills" then
        local info = rule.spellID and getSpellInfo(rule.spellID)
        return info and info.name or ("Spell ID " .. tostring(rule.spellID or 0))
    end
    local firstID = rule.spellIDs and rule.spellIDs[1]
    local info = firstID and getSpellInfo(firstID)
    local name = info and info.name or ("Spell ID " .. tostring(firstID or 0))
    local count = #(rule.spellIDs or {})
    if count > 1 then name = name .. " and " .. (count - 1) .. " more" end
    return name
end

local function buildPreviewLine(trigger, eventText, ttsEnabled, ttsMessage, screenEnabled, screenText)
    local actions = {}
    if ttsEnabled and type(ttsMessage) == "string" and trim(ttsMessage) ~= "" then
        table.insert(actions, 'speak "' .. trim(ttsMessage) .. '"')
    end
    if screenEnabled and type(screenText) == "string" and trim(screenText) ~= "" then
        table.insert(actions, 'show "' .. trim(screenText) .. '"')
    end
    if #actions == 0 then return nil end
    return "When " .. trigger .. " " .. eventText .. ", " .. table.concat(actions, " and ")
end

local function buildRulePreview(rule, category, values)
    if not rule then return "" end
    values = values or rule
    local trigger = previewTriggerName(rule, category)
    local lines = {}
    if category == "auras" then
        local apply = buildPreviewLine(trigger, "applies", values.applyEnabled, values.applyMessage,
            values.applyScreenEnabled, values.applyScreenText)
        local expire = buildPreviewLine(trigger, "expires", values.expireEnabled, values.expireMessage,
            values.expireScreenEnabled, values.expireScreenText)
        if apply then table.insert(lines, apply) end
        if expire then table.insert(lines, expire) end
    else
        local ready = buildPreviewLine(trigger, "is ready", values.enabled ~= false, values.message,
            values.screenEnabled, values.screenText)
        if ready then table.insert(lines, ready) end
    end
    if #lines == 0 then table.insert(lines, L("No notification configured")) end
    if rule.enabled == false then table.insert(lines, 1, L("Rule disabled")) end
    return table.concat(lines, "  ")
end

local function updateRulePreviewFromEditor()
    if editorLoading or not (detailPanel and detailPanel.rulePreviewText) then return end
    local rule = selectedAura() or selectedItem() or selectedSkill()
    if not rule then detailPanel.rulePreviewText:SetText(""); return end
    local values
    if selectedCategory == "auras" then
        values = {
            applyEnabled = applyEnabledCheck:GetChecked() == true or applyEnabledCheck:GetChecked() == 1,
            applyMessage = applyMessageBox:GetText(),
            applyScreenEnabled = ns.screenControls.apply and (ns.screenControls.apply.enabled:GetChecked() == true or ns.screenControls.apply.enabled:GetChecked() == 1),
            applyScreenText = ns.screenControls.apply and ns.screenControls.apply.text:GetText() or "",
            expireEnabled = expireEnabledCheck:GetChecked() == true or expireEnabledCheck:GetChecked() == 1,
            expireMessage = expireMessageBox:GetText(),
            expireScreenEnabled = ns.screenControls.expire and (ns.screenControls.expire.enabled:GetChecked() == true or ns.screenControls.expire.enabled:GetChecked() == 1),
            expireScreenText = ns.screenControls.expire and ns.screenControls.expire.text:GetText() or "",
        }
    else
        values = {
            enabled = rule.enabled,
            message = readyMessageBox:GetText(),
            screenEnabled = ns.screenControls.ready and (ns.screenControls.ready.enabled:GetChecked() == true or ns.screenControls.ready.enabled:GetChecked() == 1),
            screenText = ns.screenControls.ready and ns.screenControls.ready.text:GetText() or "",
        }
    end
    detailPanel.rulePreviewText:SetText(buildRulePreview(rule, selectedCategory, values))
end

local function updateSelectedTriggers()
    local rule = selectedAura()
    if not (triggerScroll and triggerChild and rule) then return end

    local validCount, pendingCount, invalidCount = 0, 0, 0
    for index, spellID in ipairs(rule.spellIDs or {}) do
        local info, state = getSpellInfo(spellID)
        if state == "valid" then validCount = validCount + 1
        elseif state == "pending" then pendingCount = pendingCount + 1
        else invalidCount = invalidCount + 1 end

        local row = triggerRows[index]
        if not row then
            row = CreateFrame("Frame", nil, triggerChild)
            row:SetHeight(27)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(20, 20)
            row.icon:SetPoint("LEFT", row, "LEFT", 3, 0)
            row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.title:SetPoint("LEFT", row.icon, "RIGHT", 7, 3)
            row.title:SetPoint("RIGHT", row, "RIGHT", -58, 0)
            row.title:SetJustifyH("LEFT")
            row.title:SetMaxLines(1)
            row.idText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            row.idText:SetPoint("LEFT", row.icon, "RIGHT", 7, -8)
            row.idText:SetPoint("RIGHT", row, "RIGHT", -58, 0)
            row.idText:SetJustifyH("LEFT")
            row.remove = CreateFrame("Button", nil, row)
            row.remove:SetSize(22, 22)
            row.remove:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.remove.mark = row.remove:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            row.remove.mark:SetPoint("CENTER", row.remove, "CENTER", 0, 0)
            row.remove.mark:SetText("×")
            row.remove.mark:SetTextColor(0.92, 0.38, 0.32)
            row.remove:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
            row.remove:SetScript("OnClick", function(self)
                local parent = self:GetParent()
                local auraRule = selectedAura()
                if not (auraRule and parent.spellID) then return end
                for triggerIndex, existingID in ipairs(auraRule.spellIDs) do
                    if existingID == parent.spellID then
                        table.remove(auraRule.spellIDs, triggerIndex)
                        break
                    end
                end
                rebuildAuraWatches()
                syncAllAuras(true)
                updateSelectedTriggers()
                refreshList()
            end)
            row:SetScript("OnEnter", function(self)
                if not self.spellID then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local ok = pcall(GameTooltip.SetSpellByID, GameTooltip, self.spellID)
                if not ok then GameTooltip:SetText(self.spellName or L("Unknown ID")) end
                GameTooltip:AddLine("ID: " .. self.spellID, 0.72, 0.78, 0.86)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            addHelpTooltip(row.remove, "Remove trigger", "Remove this spell ID from the aura rule.")
            triggerRows[index] = row
        end

        row.spellID = spellID
        row.spellName = info and info.name or (state == "pending" and L("Loading…") or L("Unknown ID"))
        row.icon:SetTexture(info and info.iconID or "Interface\\Icons\\INV_Misc_QuestionMark")
        row.title:SetText(row.spellName)
        row.title:SetTextColor(state == "valid" and 0.93 or 1, state == "valid" and 0.93 or 0.65, state == "valid" and 0.96 or 0.38)
        row.idText:SetText(tostring(spellID) .. (state == "pending" and (" · " .. L("loading")) or state == "valid" and "" or (" · " .. L("invalid"))))
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", triggerChild, "TOPLEFT", 2, -((index - 1) * 27))
        row:SetPoint("RIGHT", triggerChild, "RIGHT", -2, 0)
        row:Show()
    end
    for index = #(rule.spellIDs or {}) + 1, #triggerRows do triggerRows[index]:Hide() end
    triggerChild:SetHeight(math.max(1, #(rule.spellIDs or {}) * 27))
    triggerScroll:SetVerticalScroll(math.min(triggerScroll:GetVerticalScroll(), math.max(0, triggerChild:GetHeight() - triggerScroll:GetHeight())))

    local count = #(rule.spellIDs or {})
    local summary = count == 1 and L("1 trigger") or string.format(L("%d triggers"), count)
    if pendingCount > 0 then summary = summary .. " · " .. string.format(L("%d loading"), pendingCount) end
    if invalidCount > 0 then summary = summary .. " · " .. string.format(L("%d invalid"), invalidCount) end
    if count > 0 and validCount + pendingCount + invalidCount == count and pendingCount == 0 and invalidCount == 0 then
        summary = summary .. " · " .. string.format(L("%d valid"), validCount)
    end
    triggerStatus:SetText(summary)
    triggerStatus:SetTextColor(invalidCount > 0 and 1 or 0.72, invalidCount > 0 and 0.4 or 0.78, invalidCount > 0 and 0.3 or 0.86)
end

local function addTriggerIDs(ids)
    local rule = selectedAura()
    if not rule then return false end
    if type(ids) ~= "table" or #ids == 0 then
        setStatus("Enter one or more spell IDs.", true)
        return false
    end

    local known = {}
    for _, id in ipairs(rule.spellIDs) do known[id] = true end
    local additions = {}
    for _, id in ipairs(ids) do
        if not known[id] then
            known[id] = true
            table.insert(additions, id)
        end
    end
    if #additions == 0 then
        setStatus("All entered spell IDs are already in this rule.")
        return false
    end

    for _, id in ipairs(additions) do table.insert(rule.spellIDs, id) end
    triggerInputBox:SetText("")
    triggerInputBox:ClearFocus()
    if searchPopup then searchPopup:Hide() end
    rebuildAuraWatches()
    syncAllAuras(true)
    updateSelectedTriggers()
    refreshList()
    setStatus(#additions == 1 and L("1 trigger added") or string.format(L("%d triggers added"), #additions))
    return true
end

local function runTriggerSearch(expectedGeneration)
    if not (triggerInputBox and searchPopup and selectedAura()) then return end
    if expectedGeneration and expectedGeneration ~= searchGeneration then return end
    local query = trim(triggerInputBox:GetText())
    if query == "" then searchPopup:Hide(); return end
    local ids, isIDList = parseSpellIDs(query)
    local results
    local emptyText = L("No matching local spells.")
    if isIDList and #ids > 0 then
        triggerAddButton:SetEnabled(true)
        if #ids > 1 then
            searchPopup:Hide()
            triggerStatus:SetText(L("Press Enter or Add to include these IDs."))
            triggerStatus:SetTextColor(0.72, 0.78, 0.86)
            return
        end
        results = searchLocalSpells(query)
        local _, spellState = getSpellInfo(ids[1])
        if #results == 0 and spellState == "pending" then
            emptyText = L("Checking spell data…")
        end
        triggerStatus:SetText(L("Press Enter or Add to include these IDs."))
        triggerStatus:SetTextColor(0.72, 0.78, 0.86)
    elseif query:find(",", 1, true) or tonumber(query) then
        searchPopup:Hide()
        triggerAddButton:SetEnabled(false)
        triggerStatus:SetText(L("Invalid ID list"))
        triggerStatus:SetTextColor(1, 0.35, 0.25)
        return
    else
        triggerAddButton:SetEnabled(false)
        if #query < 3 then searchPopup:Hide(); return end
        results = searchLocalSpells(query)
    end
    local visible = math.min(#results, #searchRows, 6)
    for index, row in ipairs(searchRows) do
        local result = results[index]
        row.result = result
        if result and index <= 6 then
            row.icon:SetTexture(result.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.title:SetText(result.name)
            row.idText:SetText(tostring(result.id) .. " · " .. L(result.origin))
            row:Show()
        else
            row:Hide()
        end
    end
    searchPopup.empty:SetText(emptyText)
    searchPopup.empty:SetShown(visible == 0)
    searchPopup:SetHeight(math.max(36, visible * 36 + 8))
    searchPopup:Show()
    if isIDList and #ids == 1 then
        triggerStatus:SetText(L("Press Enter or Add to include these IDs."))
        triggerStatus:SetTextColor(0.72, 0.78, 0.86)
    elseif visible > 0 then
        triggerStatus:SetText(string.format(L("%d matches"), #results))
        triggerStatus:SetTextColor(0.72, 0.78, 0.86)
    else
        triggerStatus:SetText(L("No local matches. Try a spell ID."))
        triggerStatus:SetTextColor(0.72, 0.78, 0.86)
    end
end

local function createTriggerSearchPopup()
    searchPopup = CreateFrame("Frame", nil, detailPanel, "BackdropTemplate")
    searchPopup:SetPoint("TOPLEFT", triggerInputBox, "BOTTOMLEFT", -3, -3)
    searchPopup:SetPoint("TOPRIGHT", triggerAddButton, "BOTTOMRIGHT", 3, -3)
    searchPopup:SetSize(400, 36)
    searchPopup:SetFrameStrata("DIALOG")
    searchPopup:SetFrameLevel(detailPanel:GetFrameLevel() + 20)
    searchPopup:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    searchPopup:SetBackdropColor(0.045, 0.05, 0.065, 0.99)
    searchPopup:SetBackdropBorderColor(0.57, 0.45, 0.22, 1)
    searchPopup.empty = createLabel(searchPopup, "No matching local spells.", "GameFontHighlightSmall")
    searchPopup.empty:SetPoint("CENTER")
    for index = 1, 6 do
        local row = CreateFrame("Button", nil, searchPopup)
        row:SetPoint("TOPLEFT", searchPopup, "TOPLEFT", 5, -4 - (index - 1) * 36)
        row:SetPoint("TOPRIGHT", searchPopup, "TOPRIGHT", -5, -4 - (index - 1) * 36)
        row:SetHeight(34)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(26, 26)
        row.icon:SetPoint("LEFT", row, "LEFT", 5, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.title = createLabel(row, "", "GameFontHighlightSmall")
        row.title:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -2)
        row.title:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.title:SetJustifyH("LEFT")
        row.title:SetMaxLines(1)
        row.idText = createLabel(row, "", "GameFontDisableSmall")
        row.idText:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
        row.idText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.idText:SetJustifyH("LEFT")
        row.idText:SetMaxLines(1)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        addHelpTooltip(row, "Add trigger", "Add this spell to the rule.")
        row:SetScript("OnClick", function(self)
            if not (self.result and selectedAura()) then return end
            addTriggerIDs({ self.result.id })
        end)
        searchRows[index] = row
    end
    searchPopup:Hide()
end

function saveDetails()
    if editorLoading or addRuleMode then return end
    local auraRule = selectedAura()
    if auraRule and ruleNameBox then
        auraRule.name = trim(ruleNameBox:GetText())
        local applyChecked = applyEnabledCheck:GetChecked()
        auraRule.applyEnabled = applyChecked == true or applyChecked == 1
        auraRule.applyMessage = applyMessageBox:GetText()
        saveScreenRowProfile(ns.screenControls.apply, auraRule)
        local expireChecked = expireEnabledCheck:GetChecked()
        auraRule.expireEnabled = expireChecked == true or expireChecked == 1
        auraRule.expireMessage = expireMessageBox:GetText()
        saveScreenRowProfile(ns.screenControls.expire, auraRule)
    else
        local readyRule = selectedItem() or selectedSkill()
        if readyRule and ruleNameBox then
            readyRule.name = trim(ruleNameBox:GetText())
            readyRule.message = readyMessageBox:GetText()
            saveScreenRowProfile(ns.screenControls.ready, readyRule)
        end
    end
    refreshList()
    updateRulePreviewFromEditor()
end

function updateDetails()
    if not detailPanel then return end
    searchGeneration = searchGeneration + 1
    if searchPopup then searchPopup:Hide() end

    local auraRule = selectedAura()
    local itemRule = selectedItem()
    local skillRule = selectedSkill()
    local rule = auraRule or itemRule or skillRule
    if ns.screenAnchorTarget and ns.screenAnchorTarget.rule ~= rule then ns.setScreenAnchorUnlocked(ns.screenAnchorTarget, false) end
    detailPanel.emptyText:SetShown(not rule and not addRuleMode)
    local emptyText = selectedCategory == "auras" and "Select an aura group or add a new one."
        or selectedCategory == "items" and "Select an item rule or add an equipped item."
        or "Select a spell cooldown rule or add a spell from your spellbook."
    detailPanel.emptyText:SetText(L(emptyText))
    creationView:SetShown(addRuleMode)
    auraEditor:SetShown(not addRuleMode and rule ~= nil)
    if editorScroll then editorScroll:SetShown(not addRuleMode and rule ~= nil) end
    detailPanel.rulePreviewPanel:SetShown(not addRuleMode and rule ~= nil)
    deleteRuleButton:SetShown(false)
    if addRuleMode then return end
    if not rule then
        lastRenderedRule = nil
        lastRenderedCategory = nil
        return
    end

    local unchangedRule = lastRenderedRule == rule and lastRenderedCategory == selectedCategory
    local keepTriggerQuery = unchangedRule and triggerInputBox:HasFocus()
    local query = keepTriggerQuery and triggerInputBox:GetText() or ""
    editorLoading = true
    ruleNameBox:SetText(rule.name or "")
    ruleEnabledCheck:SetChecked(rule.enabled)
    if auraRule then
        local firstID = auraRule.spellIDs[1]
        local info = firstID and getSpellInfo(firstID)
        auraEditor.ruleIcon:SetTexture(info and info.iconID or "Interface\\Icons\\Spell_Nature_Rejuvenation")
        auraEditor.heading:SetText(L("AURA RULE"))
        itemSourceText:Hide()
        triggerLabel:Show()
        triggerInputBox:Show()
        triggerPlaceholder:SetShown(not keepTriggerQuery or trim(query) == "")
        triggerAddButton:Show()
        triggerStatus:Show()
        triggerScroll.backdrop:Show()
        triggerScroll:Show()
        applyEnabledCheck:Show()
        applyLabel:Show()
        applyMessageBox:Show()
        testApplyButton:Show()
        expireEnabledCheck:Show()
        expireLabel:Show()
        expireMessageBox:Show()
        testExpireButton:Show()
        showScreenRow(ns.screenControls.apply, true)
        showScreenRow(ns.screenControls.expire, true)
        showScreenRow(ns.screenControls.ready, false)
        readyLabel:Hide()
        readyMessageBox:Hide()
        testItemButton:Hide()
        applyEnabledCheck:SetChecked(auraRule.applyEnabled)
        applyMessageBox:SetText(auraRule.applyMessage)
        loadScreenRowProfile(ns.screenControls.apply, auraRule)
        expireEnabledCheck:SetChecked(auraRule.expireEnabled)
        expireMessageBox:SetText(auraRule.expireMessage)
        loadScreenRowProfile(ns.screenControls.expire, auraRule)
        showScreenRow(ns.screenControls.apply, true)
        showScreenRow(ns.screenControls.expire, true)
        layoutSharedEditor(true)
        if not keepTriggerQuery then triggerInputBox:SetText("") end
        updateSelectedTriggers()
    elseif itemRule or skillRule then
        local readyRule = itemRule or skillRule
        local skillInfo = skillRule and getSpellInfo(skillRule.spellID)
        auraEditor.ruleIcon:SetTexture(readyRule.icon or (skillInfo and skillInfo.iconID) or "Interface\\Icons\\INV_Misc_QuestionMark")
        auraEditor.heading:SetText(L(itemRule and "ITEM READY" or "SPELL READY"))
        triggerLabel:Hide()
        triggerInputBox:Hide()
        triggerPlaceholder:Hide()
        triggerAddButton:Hide()
        triggerStatus:Hide()
        triggerScroll.backdrop:Hide()
        triggerScroll:Hide()
        itemSourceText:Show()
        applyEnabledCheck:Hide()
        applyLabel:Hide()
        applyMessageBox:Hide()
        testApplyButton:Hide()
        expireEnabledCheck:Hide()
        expireLabel:Hide()
        expireMessageBox:Hide()
        testExpireButton:Hide()
        showScreenRow(ns.screenControls.apply, false)
        showScreenRow(ns.screenControls.expire, false)
        showScreenRow(ns.screenControls.ready, true)
        readyLabel:Show()
        readyMessageBox:Show()
        testItemButton:Show()
        readyMessageBox:SetText(readyRule.message or "")
        loadScreenRowProfile(ns.screenControls.ready, readyRule)
        showScreenRow(ns.screenControls.ready, true)
        layoutSharedEditor(false)
        itemSourceText:Show()
        if itemRule then
            if itemRule.starter == "trinket" and itemRule.itemID <= 0 then
                itemSourceText:SetText(L("Choose an equipped item"))
                itemSourceText:SetTextColor(1, 0.82, 0.2)
                testItemButton:SetText(L("Choose item"))
                testItemButton:SetEnabled(true)
                testItemButton:SetScript("OnClick", function() if ns.BeginItemPicker then ns.BeginItemPicker() end end)
            else
                local slotID = findEquippedItemSlot(itemRule.itemID)
                itemSourceText:SetText(slotID and string.format(L("Equipped · Slot %d"), slotID) or L("Not equipped"))
                itemSourceText:SetTextColor(slotID and 0.55 or 1, slotID and 0.86 or 0.65, slotID and 0.62 or 0.25)
                testItemButton:SetText(L("Test"))
                if ns.TestCurrentReady then testItemButton:SetScript("OnClick", ns.TestCurrentReady) end
            end
        else
            itemSourceText:SetText(string.format(L("Spellbook · ID %d"), skillRule.spellID))
            itemSourceText:SetTextColor(0.55, 0.86, 0.62)
        end
    end

    UIDropDownMenu_SetSelectedValue(voiceDropdown, rule.voiceID)
    UIDropDownMenu_SetText(voiceDropdown, voiceName(rule.voiceID))
    volumeSlider:SetValue(rule.volume)
    volumeValue:SetText(tostring(rule.volume))
    if keepTriggerQuery then
        triggerInputBox:SetText(query)
    end
    editorLoading = false
    lastRenderedRule = rule
    lastRenderedCategory = selectedCategory
    if keepTriggerQuery then
        searchGeneration = searchGeneration + 1
        local generation = searchGeneration
        C_Timer.After(0.18, function()
            if optionsFrame and optionsFrame:IsShown() and selectedAura() == rule
                and triggerInputBox:HasFocus() and trim(triggerInputBox:GetText()) == trim(query) then
                runTriggerSearch(generation)
            end
        end)
    end
    updateRulePreviewFromEditor()
    updatePreviewButtons()
end

local function resetSkillCreationSearch()
    skillSearchGeneration = skillSearchGeneration + 1
    if skillSearchPopup then skillSearchPopup:Hide() end
    if skillSearchBox then
        skillSearchBox:SetText("")
        skillSearchBox:ClearFocus()
        skillSearchBox:Hide()
    end
    if skillSearchStatus then skillSearchStatus:Hide() end
    if creationView then
        creationView.auraButton:Show()
        creationView.itemButton:Show()
        creationView.skillButton:Show()
    end
end

local function selectSkillSearchResult(result)
    if not result then return end
    for _, rule in ipairs(WoWraVoxDB.skills) do
        if rule.spellID == result.id then
            addRuleMode = false
            resetSkillCreationSearch()
            selectedCategory, selectedSkillRule = "skills", rule
            refreshList()
            updateDetails()
            return
        end
    end
    local rule = newSkillRule(result.id, result.name, result.icon)
    ns.registerNewRule(rule, "skills")
    table.insert(WoWraVoxDB.skills, rule)
    addRuleMode = false
    resetSkillCreationSearch()
    selectedCategory, selectedSkillRule = "skills", rule
    refreshList()
    updateDetails()
    scanSkillRules()
end

local function runSkillSearch(expectedGeneration)
    if not (skillSearchBox and skillSearchPopup) then return end
    if expectedGeneration and expectedGeneration ~= skillSearchGeneration then return end
    local query = trim(skillSearchBox:GetText())
    if query == "" then
        skillSearchPopup:Hide()
        skillSearchStatus:SetText(L("Type a spell name or ID from your spellbook."))
        return
    end
    local results = searchSpellbookSkills(query)
    local visible = math.min(#results, #skillSearchRows)
    for index, row in ipairs(skillSearchRows) do
        local result = results[index]
        row.result = result
        if result then
            row.icon:SetTexture(result.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.title:SetText(result.name)
            row.idText:SetText(tostring(result.id) .. " · " .. L("Spellbook"))
            row:Show()
        else
            row:Hide()
        end
    end
    skillSearchPopup.empty:SetShown(visible == 0)
    skillSearchPopup:SetHeight(math.max(36, visible * 36 + 8))
    skillSearchPopup:Show()
    skillSearchStatus:SetText(visible > 0 and string.format(L("%d matches"), #results) or L("No spellbook matches."))
end

showAddRuleView = function()
    addRuleMode = true
    searchGeneration = searchGeneration + 1
    if searchPopup then searchPopup:Hide() end
    resetSkillCreationSearch()
    updateDetails()
end

local function buildEditorShell()
detailPanel = CreateFrame("Frame", nil, optionsFrame)
detailPanel:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 312, -64)
detailPanel:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -16, 16)
stylePanel(detailPanel, 0.155, 0.155, 0.15)

detailPanel.emptyText = createLabel(detailPanel, "Select a rule or add an aura group or item.", "GameFontHighlight")
detailPanel.emptyText:SetPoint("CENTER")
detailPanel.emptyText:SetWidth(360)
detailPanel.emptyText:SetJustifyH("CENTER")

detailPanel.rulePreviewPanel = CreateFrame("Frame", nil, detailPanel, "BackdropTemplate")
detailPanel.rulePreviewPanel:SetPoint("BOTTOMLEFT", detailPanel, "BOTTOMLEFT", 12, 12)
detailPanel.rulePreviewPanel:SetPoint("BOTTOMRIGHT", detailPanel, "BOTTOMRIGHT", -12, 12)
detailPanel.rulePreviewPanel:SetHeight(84)
detailPanel.rulePreviewPanel:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 2,
})
detailPanel.rulePreviewPanel:SetBackdropColor(0.045, 0.05, 0.06, 1)
detailPanel.rulePreviewPanel:SetBackdropBorderColor(0.88, 0.43, 0.12, 1)
detailPanel.rulePreviewHeading = makeSectionLabel(detailPanel.rulePreviewPanel, "RULE PREVIEW", 12, -9)
detailPanel.rulePreviewText = createLabel(detailPanel.rulePreviewPanel, "", "GameFontHighlightSmall")
detailPanel.rulePreviewText:SetPoint("TOPLEFT", detailPanel.rulePreviewPanel, "TOPLEFT", 12, -31)
detailPanel.rulePreviewText:SetPoint("TOPRIGHT", detailPanel.rulePreviewPanel, "TOPRIGHT", -12, -31)
detailPanel.rulePreviewText:SetHeight(44)
detailPanel.rulePreviewText:SetJustifyH("LEFT")
detailPanel.rulePreviewText:SetJustifyV("TOP")
detailPanel.rulePreviewText:SetWordWrap(true)

editorScroll = CreateFrame("ScrollFrame", nil, detailPanel, "UIPanelScrollFrameTemplate")
editorScroll:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", 8, -8)
editorScroll:SetPoint("BOTTOMRIGHT", detailPanel, "BOTTOMRIGHT", -32, 108)
auraEditor = CreateFrame("Frame", nil, editorScroll)
auraEditor:SetSize(1, 620)
editorScroll:SetScrollChild(auraEditor)
local function resizeEditorChild()
    auraEditor:SetWidth(math.max(1, editorScroll:GetWidth() - 4))
    auraEditor:SetHeight(math.max(620, editorScroll:GetHeight()))
end
editorScroll:HookScript("OnSizeChanged", resizeEditorChild)
C_Timer.After(0, resizeEditorChild)
itemEditor = auraEditor
auraEditor.heading = makeSectionLabel(auraEditor, "AURA RULE", 16, -14)
auraEditor.ruleIcon = auraEditor:CreateTexture(nil, "ARTWORK")
auraEditor.ruleIcon:SetSize(38, 38)
auraEditor.ruleIcon:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 16, -39)
auraEditor.ruleIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

ruleNameBox = createEditBox(auraEditor, 280, 24)
ruleNameBox:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 66, -45)
ruleNameBox:SetPoint("RIGHT", auraEditor, "RIGHT", -112, 0)
ruleEnabledCheck = CreateFrame("CheckButton", nil, auraEditor, "UICheckButtonTemplate")
ruleEnabledCheck:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", -14, -42)
local enabledLabel = createLabel(auraEditor, "Active", "GameFontNormalSmall")
enabledLabel:SetPoint("RIGHT", ruleEnabledCheck, "LEFT", -2, 0)

end

local function buildTriggerControls()
triggerLabel = makeSectionLabel(auraEditor, "TRIGGERS", 16, -91)
triggerInputBox = createEditBox(auraEditor, 300, 24)
triggerInputBox:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 16, -108)
triggerInputBox:SetPoint("RIGHT", auraEditor, "RIGHT", -75, 0)
triggerInputBox:SetMaxLetters(180)
triggerPlaceholder = createLabel(auraEditor, "Search name or paste spell IDs", "GameFontDisableSmall")
triggerPlaceholder:SetPoint("LEFT", triggerInputBox, "LEFT", 8, 0)
triggerPlaceholder:SetPoint("RIGHT", triggerInputBox, "RIGHT", -8, 0)
triggerPlaceholder:SetJustifyH("LEFT")
triggerPlaceholder:SetTextColor(0.46, 0.5, 0.58)
triggerInputBox:SetScript("OnTextChanged", function(self)
    if editorLoading then return end
    searchGeneration = searchGeneration + 1
    local generation = searchGeneration
    local query = trim(self:GetText())
    triggerPlaceholder:SetShown(query == "")
    local ids, valid = parseSpellIDs(query)
    triggerAddButton:SetEnabled(valid and #ids > 0)
    if query == "" then
        searchPopup:Hide()
        return
    end
    if valid and #ids > 0 then
        triggerStatus:SetText(L("Press Enter or Add to include these IDs."))
        triggerStatus:SetTextColor(0.72, 0.78, 0.86)
        if #ids == 1 then
            searchPopup:Hide()
            local ownerRule = selectedAura()
            C_Timer.After(0.18, function()
                if generation == searchGeneration and selectedAura() == ownerRule
                    and triggerInputBox:HasFocus() and trim(triggerInputBox:GetText()) == query
                    and optionsFrame:IsShown() then
                    runTriggerSearch(generation)
                end
            end)
        else
            searchPopup:Hide()
        end
        return
    end
    if tonumber(query) or query:find(",", 1, true) then
        searchPopup:Hide()
        triggerStatus:SetText(L("Invalid ID list"))
        triggerStatus:SetTextColor(1, 0.35, 0.25)
        return
    end
    if #query < 3 then
        searchPopup:Hide()
        return
    end
    local ownerRule = selectedAura()
    C_Timer.After(0.18, function()
        if generation == searchGeneration and selectedAura() == ownerRule
            and triggerInputBox:HasFocus() and trim(triggerInputBox:GetText()) == query
            and optionsFrame:IsShown() then
            runTriggerSearch(generation)
        end
    end)
end)
triggerInputBox:SetScript("OnEnterPressed", function(self)
    local ids, valid = parseSpellIDs(self:GetText())
    if valid and #ids > 0 then addTriggerIDs(ids); return end
    if searchPopup:IsShown() and searchRows[1] and searchRows[1].result then
        addTriggerIDs({ searchRows[1].result.id })
        return
    end
    self:ClearFocus()
end)
triggerInputBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
    searchGeneration = searchGeneration + 1
    searchPopup:Hide()
end)
triggerAddButton = CreateFrame("Button", nil, auraEditor, "UIPanelButtonTemplate")
triggerAddButton:SetSize(54, 24)
triggerAddButton:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", -16, -108)
triggerAddButton:SetText(L("Add"))
triggerAddButton:SetEnabled(false)
triggerAddButton:SetScript("OnClick", function()
    local ids, valid = parseSpellIDs(triggerInputBox:GetText())
    if not valid then
        triggerStatus:SetText(L("Enter valid spell IDs separated by commas."))
        triggerStatus:SetTextColor(1, 0.35, 0.25)
        return
    end
    addTriggerIDs(ids)
end)
triggerStatus = createLabel(auraEditor, "", "GameFontNormalSmall")
triggerStatus:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 16, -136)

local triggerPanel = CreateFrame("Frame", nil, auraEditor, "BackdropTemplate")
triggerPanel:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 12, -148)
triggerPanel:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", -16, -148)
triggerPanel:SetHeight(98)
triggerPanel:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
})
triggerPanel:SetBackdropColor(0.07, 0.075, 0.085, 1)
triggerPanel:SetBackdropBorderColor(0.28, 0.3, 0.34, 1)
triggerScroll = CreateFrame("ScrollFrame", nil, auraEditor, "UIPanelScrollFrameTemplate")
triggerScroll:SetPoint("TOPLEFT", triggerPanel, "TOPLEFT", 4, -4)
triggerScroll:SetPoint("BOTTOMRIGHT", triggerPanel, "BOTTOMRIGHT", -27, 4)
triggerScroll.backdrop = triggerPanel
triggerChild = CreateFrame("Frame", nil, triggerScroll)
triggerChild:SetSize(1, 1)
triggerScroll:SetScrollChild(triggerChild)
triggerScroll:HookScript("OnSizeChanged", function(self, width)
    triggerChild:SetWidth(math.max(1, width - 4))
    updateSelectedTriggers()
end)
itemSourceText = createLabel(auraEditor, "", "GameFontNormalSmall")
itemSourceText:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 16, -103)

end

local function createScreenChoiceDropdown(parent, width, choices, valueOf, textOf, onChange)
    local dropdown = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(dropdown, width)
    UIDropDownMenu_Initialize(dropdown, function(menu, level)
        for _, choice in ipairs(choices) do
            local chosen = choice
            local value = valueOf(chosen)
            local info = UIDropDownMenu_CreateInfo()
            info.text = textOf(chosen)
            info.value = value
            info.checked = dropdown.screenValue == value
            info.func = function()
                dropdown.screenValue = value
                onChange(value)
                UIDropDownMenu_SetSelectedValue(dropdown, value)
                UIDropDownMenu_SetText(dropdown, textOf(chosen))
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    return dropdown
end

local function buildScreenRow(parent, labelText, y, eventKey)
    local row = {}
    row.eventKey = eventKey
    row.enabled = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    row.enabled:SetPoint("TOPLEFT", parent, "TOPLEFT", 6, y)
    row.label = createLabel(parent, labelText, "GameFontNormalSmall")
    row.label:SetPoint("LEFT", row.enabled, "RIGHT", 0, 0)
    row.label:SetMaxLines(1)
    row.text = createEditBox(parent, 280, 24)
    row.text:SetPoint("TOPLEFT", parent, "TOPLEFT", 154, y + 1)
    row.preview = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    row.preview:SetSize(72, 24)
    row.preview:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -16, y + 1)
    row.preview:SetText(L("Preview"))
    row.text:SetPoint("RIGHT", row.preview, "LEFT", -8, 0)
    row.label:SetPoint("RIGHT", row.text, "LEFT", -8, 0)
    row.font = createScreenChoiceDropdown(parent, 100, SCREEN_FONT_CHOICES,
        function(choice) return choice.key end,
        function(choice) return L(choice.key) end,
        function(value)
            row.fontValue = value
            saveDetails()
            local profile = selectedRule() and ns.getRuleScreenProfile(selectedRule(), row.eventKey)
            if profile then profile.font = value; ns.applyScreenFrameStyle(row.frame, profile) end
        end)
    row.size = createScreenChoiceDropdown(parent, 42, SCREEN_SIZE_CHOICES,
        function(size) return tostring(size) end,
        function(size) return tostring(size) end,
        function(value)
            row.sizeValue = tonumber(value)
            saveDetails()
            local profile = selectedRule() and ns.getRuleScreenProfile(selectedRule(), row.eventKey)
            if profile then profile.size = ns.getScreenSizeValue(row.sizeValue); ns.applyScreenFrameStyle(row.frame, profile) end
        end)
    row.style = createScreenChoiceDropdown(parent, 108, SCREEN_STYLE_CHOICES,
        function(choice) return choice.key end,
        function(choice) return L(choice.label) end,
        function(value)
            row.styleValue = value
            saveDetails()
            local profile = selectedRule() and ns.getRuleScreenProfile(selectedRule(), row.eventKey)
            if profile then profile.style = value; ns.applyScreenFrameStyle(row.frame, profile) end
        end)
    row.font:SetPoint("TOPLEFT", parent, "TOPLEFT", 126, y - 27)
    row.size:SetPoint("LEFT", row.font, "RIGHT", -12, 0)
    row.style:SetPoint("LEFT", row.size, "RIGHT", -12, 0)
    row.color = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row.color:SetSize(22, 22)
    row.color:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    row.color:SetBackdropColor(0.05, 0.05, 0.06, 1)
    row.color:SetBackdropBorderColor(0.72, 0.55, 0.22, 1)
    row.color.fill = row.color:CreateTexture(nil, "ARTWORK")
    row.color.fill:SetPoint("TOPLEFT", row.color, "TOPLEFT", 3, -3)
    row.color.fill:SetPoint("BOTTOMRIGHT", row.color, "BOTTOMRIGHT", -3, 3)
    row.color:SetPoint("LEFT", row.style, "RIGHT", -8, 0)
    row.color:SetScript("OnClick", function() ns.openScreenColorPicker(row) end)
    row.anchor = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    row.anchor:SetSize(72, 24)
    row.anchor:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -16, y - 27)
    row.anchor:SetText(L("Anchor"))
    row.anchor:SetScript("OnClick", function()
        saveDetails()
        local rule = selectedRule()
        if not rule then return end
        local frame = ns.getScreenFrame(rule, row.eventKey)
        if ns.screenAnchorUnlocked and ns.screenAnchorTarget == frame then
            ns.setScreenAnchorUnlocked(frame, false)
        else
            ns.setScreenAnchorUnlocked(frame, true)
        end
    end)
    return row
end

local function buildMessageControls()
auraEditor.notificationsHeading = makeSectionLabel(auraEditor, "NOTIFICATIONS", 16, -255)
applyEnabledCheck = CreateFrame("CheckButton", nil, auraEditor, "UICheckButtonTemplate")
applyEnabledCheck:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 6, -277)
    applyLabel = createLabel(auraEditor, "TTS on Application", "GameFontNormalSmall")
    applyLabel:SetPoint("LEFT", applyEnabledCheck, "RIGHT", 0, 0)
    applyLabel:SetMaxLines(1)
    applyMessageBox = createEditBox(auraEditor, 300, 24)
    applyMessageBox:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 154, -276)
    testApplyButton = CreateFrame("Button", nil, auraEditor, "UIPanelButtonTemplate")
    testApplyButton:SetSize(72, 24)
testApplyButton:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", -16, -276)
    applyMessageBox:SetPoint("RIGHT", testApplyButton, "LEFT", -8, 0)
    applyLabel:SetPoint("RIGHT", applyMessageBox, "LEFT", -8, 0)
testApplyButton:SetText(L("Test"))
    ns.screenControls.apply = buildScreenRow(auraEditor, "On-screen text", -309, "apply")

expireEnabledCheck = CreateFrame("CheckButton", nil, auraEditor, "UICheckButtonTemplate")
expireEnabledCheck:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 6, -319)
    expireLabel = createLabel(auraEditor, "TTS on Expiration", "GameFontNormalSmall")
    expireLabel:SetPoint("LEFT", expireEnabledCheck, "RIGHT", 0, 0)
    expireLabel:SetMaxLines(1)
    expireMessageBox = createEditBox(auraEditor, 300, 24)
    expireMessageBox:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 154, -318)
    testExpireButton = CreateFrame("Button", nil, auraEditor, "UIPanelButtonTemplate")
    testExpireButton:SetSize(72, 24)
testExpireButton:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", -16, -318)
    expireMessageBox:SetPoint("RIGHT", testExpireButton, "LEFT", -8, 0)
    expireLabel:SetPoint("RIGHT", expireMessageBox, "LEFT", -8, 0)
testExpireButton:SetText(L("Test"))
    ns.screenControls.expire = buildScreenRow(auraEditor, "On-screen text", -375, "expire")

    readyLabel = createLabel(auraEditor, "Ready", "GameFontNormalSmall")
    readyLabel:SetPoint("LEFT", applyEnabledCheck, "RIGHT", 0, 0)
    readyLabel:SetMaxLines(1)
    readyMessageBox = createEditBox(auraEditor, 300, 24)
    readyMessageBox:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 154, -276)
    testItemButton = CreateFrame("Button", nil, auraEditor, "UIPanelButtonTemplate")
    testItemButton:SetSize(72, 24)
testItemButton:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", -16, -276)
    readyMessageBox:SetPoint("RIGHT", testItemButton, "LEFT", -8, 0)
    readyLabel:SetPoint("RIGHT", readyMessageBox, "LEFT", -8, 0)
testItemButton:SetText(L("Test"))
    ns.screenControls.ready = buildScreenRow(auraEditor, "On-screen text", -309, "ready")

    auraEditor.voiceHeading = makeSectionLabel(auraEditor, "VOICE", 16, -470)
    auraEditor.voiceLabel = createLabel(auraEditor, "Voice", "GameFontNormalSmall")
    auraEditor.voiceLabel:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 60, -492)
    voiceDropdown = createVoiceDropdown(auraEditor, "TOPLEFT", auraEditor, 60, -379, function(voiceID)
    local rule = selectedAura() or selectedItem() or selectedSkill()
    if rule then rule.voiceID = voiceID end
    end)
    auraEditor.volumeLabel = createLabel(auraEditor, "Volume", "GameFontNormalSmall")
    auraEditor.volumeLabel:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 365, -492)
    volumeSlider = makeVolumeSlider(auraEditor, "TOPLEFT", auraEditor, 365, -386, function(value)
    local rule = selectedAura() or selectedItem() or selectedSkill()
    if rule then rule.volume = value; volumeValue:SetText(tostring(value)) end
end)
volumeValue = createLabel(auraEditor, "80", "GameFontHighlight")
volumeValue:SetPoint("LEFT", volumeSlider, "RIGHT", 8, 0)

end

local function buildCreationView()
creationView = CreateFrame("Frame", nil, detailPanel, "BackdropTemplate")
creationView:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", 16, -16)
creationView:SetPoint("BOTTOMRIGHT", detailPanel, "BOTTOMRIGHT", -16, 16)
    stylePanel(creationView, 0.105, 0.115, 0.13)
    creationView.heading = makeSectionLabel(creationView, "ADD RULE", 16, -15)
    creationView.auraButton = CreateFrame("Button", nil, creationView, "BackdropTemplate")
    creationView.itemButton = CreateFrame("Button", nil, creationView, "BackdropTemplate")
    creationView.skillButton = CreateFrame("Button", nil, creationView, "BackdropTemplate")
local function styleCreationOption(button, iconPath, title, description, y)
    button:SetSize(360, 76)
    button:SetPoint("TOP", creationView, "TOP", 0, y)
    button:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    button:SetBackdropColor(0.14, 0.155, 0.18, 1)
    button:SetBackdropBorderColor(0.42, 0.37, 0.25, 1)
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetTexture(iconPath)
    button.icon:SetSize(36, 36)
    button.icon:SetPoint("LEFT", button, "LEFT", 12, 0)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.title = createLabel(button, title, "GameFontNormal")
    button.title:SetPoint("TOPLEFT", button.icon, "TOPRIGHT", 12, -14)
    button.description = createLabel(button, description, "GameFontHighlightSmall")
    button.description:SetPoint("TOPLEFT", button.title, "BOTTOMLEFT", 0, -5)
    button.description:SetPoint("RIGHT", button, "RIGHT", -12, 0)
    button.description:SetJustifyH("LEFT")
    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    button:SetScript("OnEnter", function(self) self:SetBackdropColor(0.2, 0.19, 0.14, 1) end)
    button:SetScript("OnLeave", function(self) self:SetBackdropColor(0.14, 0.155, 0.18, 1) end)
    end
    styleCreationOption(creationView.auraButton, "Interface\\Icons\\Spell_Nature_Rejuvenation", "Aura", "Track buff, debuff, or item-effect auras.", -64)
    styleCreationOption(creationView.itemButton, "Interface\\Icons\\INV_Misc_Bag_10", "Equipped item", "Announce when this item's cooldown is ready.", -150)
    styleCreationOption(creationView.skillButton, "Interface\\Icons\\Spell_Holy_MindVision", "Spell cooldown", "Announce when this spell's cooldown is ready.", -236)

    skillSearchBox = createEditBox(creationView, 330, 24)
    skillSearchBox:SetPoint("TOP", creationView, "TOP", 0, -60)
    skillSearchBox:SetMaxLetters(120)
    skillSearchBox:Hide()
    skillSearchStatus = createLabel(creationView, "Type a spell name or ID from your spellbook.", "GameFontNormalSmall")
    skillSearchStatus:SetPoint("TOPLEFT", creationView, "TOPLEFT", 22, -92)
    skillSearchStatus:SetPoint("RIGHT", creationView, "RIGHT", -22, 0)
    skillSearchStatus:SetJustifyH("LEFT")
    skillSearchStatus:SetTextColor(0.72, 0.78, 0.86)
    skillSearchStatus:Hide()
    skillSearchPopup = CreateFrame("Frame", nil, creationView, "BackdropTemplate")
    skillSearchPopup:SetPoint("TOPLEFT", skillSearchBox, "BOTTOMLEFT", -4, -4)
    skillSearchPopup:SetPoint("TOPRIGHT", skillSearchBox, "BOTTOMRIGHT", 4, -4)
    skillSearchPopup:SetHeight(36)
    skillSearchPopup:SetFrameStrata("DIALOG")
    skillSearchPopup:SetFrameLevel(creationView:GetFrameLevel() + 20)
    skillSearchPopup:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    skillSearchPopup:SetBackdropColor(0.045, 0.05, 0.065, 0.99)
    skillSearchPopup:SetBackdropBorderColor(0.57, 0.45, 0.22, 1)
    skillSearchPopup.empty = createLabel(skillSearchPopup, "No spellbook matches.", "GameFontHighlightSmall")
    skillSearchPopup.empty:SetPoint("CENTER")
    for index = 1, 6 do
        local row = CreateFrame("Button", nil, skillSearchPopup)
        row:SetPoint("TOPLEFT", skillSearchPopup, "TOPLEFT", 5, -4 - (index - 1) * 36)
        row:SetPoint("TOPRIGHT", skillSearchPopup, "TOPRIGHT", -5, -4 - (index - 1) * 36)
        row:SetHeight(34)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(26, 26)
        row.icon:SetPoint("LEFT", row, "LEFT", 5, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.title = createLabel(row, "", "GameFontHighlightSmall")
        row.title:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -2)
        row.title:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.title:SetJustifyH("LEFT")
        row.title:SetMaxLines(1)
        row.idText = createLabel(row, "", "GameFontDisableSmall")
        row.idText:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
        row.idText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.idText:SetJustifyH("LEFT")
        row.idText:SetMaxLines(1)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row:SetScript("OnClick", function(self) selectSkillSearchResult(self.result) end)
        skillSearchRows[index] = row
    end
    skillSearchPopup:Hide()

    skillSearchBox:SetScript("OnTextChanged", function(self)
        local query = trim(self:GetText())
        skillSearchGeneration = skillSearchGeneration + 1
        local generation = skillSearchGeneration
        if query == "" then
            skillSearchPopup:Hide()
            return
        end
        C_Timer.After(0.15, function()
            if generation == skillSearchGeneration and skillSearchBox:IsShown()
                and trim(skillSearchBox:GetText()) == query then
                runSkillSearch(generation)
            end
        end)
    end)
    skillSearchBox:SetScript("OnEnterPressed", function(self)
        if skillSearchPopup:IsShown() and skillSearchRows[1] then
            selectSkillSearchResult(skillSearchRows[1].result)
        end
    end)
    skillSearchBox:SetScript("OnEscapePressed", resetSkillCreationSearch)
    creationView.skillButton:SetScript("OnClick", function()
        creationView.auraButton:Hide()
        creationView.itemButton:Hide()
        creationView.skillButton:Hide()
        skillSearchBox:Show()
        skillSearchStatus:Show()
        skillSearchBox:SetFocus()
    end)
    creationView.cancelButton = CreateFrame("Button", nil, creationView, "UIPanelButtonTemplate")
creationView.cancelButton:SetSize(100, 26)
creationView.cancelButton:SetPoint("BOTTOMRIGHT", creationView, "BOTTOMRIGHT", -12, 10)
    creationView.cancelButton:SetText(L("Cancel"))
    creationView.cancelButton:SetScript("OnClick", function()
        addRuleMode = false
        resetSkillCreationSearch()
        updateDetails()
end)
creationView:Hide()

end

local function wireScreenRow(row, helpText)
    row.text:HookScript("OnTextChanged", updateRulePreviewFromEditor)
    row.text:HookScript("OnTextChanged", updatePreviewButtons)
    row.enabled:SetScript("OnClick", function()
        saveDetails()
        showScreenRow(row, true)
        layoutSharedEditor(selectedCategory == "auras")
        if selectedAura() then
            rebuildAuraWatches()
            syncAllAuras(true)
        end
        updateRulePreviewFromEditor()
        updatePreviewButtons()
    end)
    row.preview:SetScript("OnClick", function()
        saveDetails()
        local rule = selectedRule()
        if rule and ns.showScreenText(rule, row.eventKey, row.text:GetText(), true) then
            setStatus("On-screen preview shown.")
        end
    end)
    row.preview:HookScript("OnEnter", function()
        ns.setScreenPreviewButtonState(row, row.preview:IsEnabled(), true)
    end)
    row.preview:HookScript("OnLeave", function()
        ns.setScreenPreviewButtonState(row, row.preview:IsEnabled(), false)
    end)
    addHelpTooltip(row.enabled, "On-screen text", helpText)
    addHelpTooltip(row.text, "On-screen text", helpText)
    addHelpTooltip(row.preview, "Preview", helpText)
    addHelpTooltip(row.font, "Font", "Choose the font for this on-screen text.")
    addHelpTooltip(row.size, "Font size", "Choose the size for this on-screen text.")
    addHelpTooltip(row.style, "Style", "Choose the outline and shadow style for this on-screen text.")
    addHelpTooltip(row.color, "Text color", "Choose the color for this on-screen text.")
    addHelpTooltip(row.anchor, "Anchor", "Unlock and drag this text to a separate screen position.")
end

local function wireEditorControls()
searchPopup = nil
createTriggerSearchPopup()
for _, box in ipairs({ ruleNameBox, applyMessageBox, expireMessageBox, readyMessageBox, triggerInputBox }) do
    box:HookScript("OnEditFocusLost", function()
        if not editorLoading then saveDetails() end
    end)
end
applyMessageBox:HookScript("OnTextChanged", updatePreviewButtons)
expireMessageBox:HookScript("OnTextChanged", updatePreviewButtons)
readyMessageBox:HookScript("OnTextChanged", updatePreviewButtons)
for _, row in pairs(ns.screenControls) do
    wireScreenRow(row, "Show this text on screen when the event fires.")
end

local function onAuraToggle()
    if editorLoading or not selectedAura() then return end
    saveDetails()
    local checked = ruleEnabledCheck:GetChecked()
    selectedAuraRule.enabled = checked == true or checked == 1
    rebuildAuraWatches()
    syncAllAuras(true)
    refreshList()
    updateRulePreviewFromEditor()
end
ruleEnabledCheck:SetScript("OnClick", function()
    if selectedAura() then
        onAuraToggle()
    elseif selectedItem() and not editorLoading then
        local checked = ruleEnabledCheck:GetChecked()
        selectedItemRule.enabled = checked == true or checked == 1
        itemCooldownStates[selectedItemRule] = nil
        queueItemScan(0.1)
        refreshList()
        updateRulePreviewFromEditor()
    elseif selectedSkill() and not editorLoading then
        local checked = ruleEnabledCheck:GetChecked()
        selectedSkillRule.enabled = checked == true or checked == 1
        skillCooldownStates[selectedSkillRule] = nil
        scanSkillRules()
        refreshList()
        updateRulePreviewFromEditor()
    end
end)
applyEnabledCheck:SetScript("OnClick", onAuraToggle)
expireEnabledCheck:SetScript("OnClick", onAuraToggle)

testApplyButton:SetScript("OnClick", function()
    saveDetails()
    if selectedAuraRule and not playTTS(selectedAuraRule.voiceID, selectedAuraRule.applyMessage, selectedAuraRule.volume) then
        setStatus("TTS test could not be sent to WoW.", true)
    else
        setStatus("TTS test sent to WoW. Check audio in game.")
    end
end)
testExpireButton:SetScript("OnClick", function()
    saveDetails()
    if selectedAuraRule and not playTTS(selectedAuraRule.voiceID, selectedAuraRule.expireMessage, selectedAuraRule.volume) then
        setStatus("TTS test could not be sent to WoW.", true)
    else
        setStatus("TTS test sent to WoW. Check audio in game.")
    end
end)
function ns.TestCurrentReady()
    saveDetails()
    local readyRule = selectedItem() or selectedSkill()
    if readyRule and not playTTS(readyRule.voiceID, readyRule.message, readyRule.volume) then
        setStatus("TTS test could not be sent to WoW.", true)
    else
        setStatus("TTS test sent to WoW. Check audio in game.")
    end
end
testItemButton:SetScript("OnClick", ns.TestCurrentReady)
deleteRuleButton = CreateFrame("Button", nil, detailPanel)
deleteRuleButton:SetSize(28, 28)
deleteRuleButton.icon = deleteRuleButton:CreateTexture(nil, "ARTWORK")
deleteRuleButton.icon:SetTexture("Interface\\Buttons\\UI-StopButton")
deleteRuleButton.icon:SetAllPoints()
deleteRuleButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
deleteRuleButton:SetScript("OnClick", removeSelectedRule)

addHelpTooltip(ruleNameBox, "Rule name", "Display name for this rule.")
addHelpTooltip(ruleEnabledCheck, "Active", "Enable or disable this rule.")
addHelpTooltip(triggerInputBox, "Triggers", "Search by spell name or enter one or more comma-separated spell IDs.")
addHelpTooltip(triggerAddButton, "Add triggers", "Add the spell IDs entered in the trigger field.")
addHelpTooltip(applyEnabledCheck, "TTS on Application", "Announce when the aura appears.")
addHelpTooltip(applyMessageBox, "Notification message", "Message spoken when the aura appears.")
addHelpTooltip(testApplyButton, "Test notification", "Preview this message with the selected voice and volume.")
addHelpTooltip(expireEnabledCheck, "TTS on Expiration", "Announce when the aura expires naturally.")
addHelpTooltip(expireMessageBox, "Notification message", "Message spoken when the aura expires naturally.")
addHelpTooltip(testExpireButton, "Test notification", "Preview this message with the selected voice and volume.")
addHelpTooltip(readyMessageBox, "Ready notification", "Message spoken when the observed item cooldown is ready.")
addHelpTooltip(testItemButton, "Test notification", "Preview this message with the selected voice and volume.")
addHelpTooltip(voiceDropdown.Button or voiceDropdown, "Voice", "Select the voice for this rule.")
addHelpTooltip(volumeSlider, "Volume", "Set the speech volume from 0 to 100.")
addHelpTooltip(creationView.auraButton, "Aura", "Track buff, debuff, or item-effect auras.")
addHelpTooltip(creationView.itemButton, "Equipped item", "Choose an equipped item and announce when its cooldown is ready.")
addHelpTooltip(creationView.skillButton, "Spell cooldown", "Choose a spell from your spellbook and announce when its cooldown is ready.")
addHelpTooltip(creationView.cancelButton, "Cancel", "Return to the selected rule without creating a new one.")
updatePreviewButtons()
end

createEditorWidgets = function()
    buildEditorShell()
    buildTriggerControls()
    buildMessageControls()
    buildCreationView()
    wireEditorControls()
end

local SLOT_BUTTONS = {
    "CharacterHeadSlot", "CharacterNeckSlot", "CharacterShoulderSlot",
    "CharacterBackSlot", "CharacterChestSlot", "CharacterShirtSlot",
    "CharacterTabardSlot", "CharacterWristSlot", "CharacterHandsSlot",
    "CharacterWaistSlot", "CharacterLegsSlot", "CharacterFeetSlot",
    "CharacterFinger0Slot", "CharacterFinger1Slot",
    "CharacterTrinket0Slot", "CharacterTrinket1Slot",
    "CharacterMainHandSlot", "CharacterSecondaryHandSlot",
}

local function stopItemPicker()
    if not pickerActive then return end
    pickerActive = false
    for _, overlay in pairs(pickerOverlays) do overlay:Hide() end
    if pickerPrompt and pickerPrompt:IsShown() then pickerPrompt:Hide() end
    setStatus("Item selection ended.")
    if addRuleMode and optionsFrame then
        optionsFrame:Show()
        updateDetails()
    end
end

local function addPickedItem(slotID)
    local itemID = getEquippedItemID(slotID)
    if not itemID then
        setStatus("No item in this equipment slot.", true)
        return
    end
    local starterRule = selectedItemRule and selectedItemRule.starter == "trinket" and selectedItemRule or nil
    for _, rule in ipairs(WoWraVoxDB.items) do
        if rule.itemID == itemID then
            addRuleMode = false
            stopItemPicker()
            selectedCategory = "items"
            selectedItemRule = rule
            refreshList()
            updateDetails()
            optionsFrame:Show()
            return
        end
    end

    local name, icon = getItemInfo(itemID, slotID)
    local rule = starterRule
    if rule then
        rule.itemID = itemID
        rule.name = name
        rule.icon = icon
        rule.starter = nil
        rule.message = (name or L("Item")) .. " " .. L("ready")
    else
        rule = newItemRule(itemID, name, icon)
        ns.registerNewRule(rule, "items")
        table.insert(WoWraVoxDB.items, rule)
    end
    addRuleMode = false
    stopItemPicker()
    selectedCategory = "items"
    selectedItemRule = rule
    refreshList()
    updateDetails()
    queueItemScan(0.1)
    optionsFrame:Show()
end

local function refreshPickerOverlays()
    if not pickerActive then return end
    if InCombatLockdown and InCombatLockdown() then
        stopItemPicker()
        setStatus("Item selection is blocked in combat.", true)
        return
    end

    local found = 0
    for _, buttonName in ipairs(SLOT_BUTTONS) do
        local slotButton = _G[buttonName]
        if slotButton and slotButton.GetID and slotButton:IsShown() then
            found = found + 1
            local overlay = pickerOverlays[buttonName]
            if not overlay then
                overlay = CreateFrame("Button", nil, UIParent)
                overlay:RegisterForClicks("LeftButtonUp")
                overlay:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
                overlay:SetScript("OnClick", function(self)
                    addPickedItem(self.slotID)
                end)
                overlay:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(L("Select this item for WoWraVox"))
                    GameTooltip:Show()
                end)
                overlay:SetScript("OnLeave", function() GameTooltip:Hide() end)
                pickerOverlays[buttonName] = overlay
            end
            overlay.slotID = slotButton:GetID()
            overlay:ClearAllPoints()
            overlay:SetAllPoints(slotButton)
            overlay:SetFrameStrata("DIALOG")
            overlay:SetFrameLevel(slotButton:GetFrameLevel() + 10)
            overlay:Show()
        end
    end

    if found == 0 and pickerRetries < 8 then
        pickerRetries = pickerRetries + 1
        C_Timer.After(0.25, refreshPickerOverlays)
    elseif found == 0 then
        stopItemPicker()
        setStatus("No equipment slots found in the character window.", true)
    end
end

local function beginItemPicker()
    if InCombatLockdown and InCombatLockdown() then
        setStatus("Item selection is blocked in combat.", true)
        return
    end
    pickerActive = true
    pickerRetries = 0
    if pickerPrompt then pickerPrompt:Show() end

    if not _G.CharacterFrame and LoadAddOn then
        pcall(LoadAddOn, "Blizzard_CharacterUI")
        pcall(LoadAddOn, "Blizzard_UIPanels_Game")
    end
    if _G.CharacterFrame and not characterFrameHooked then
        characterFrameHooked = true
        CharacterFrame:HookScript("OnShow", function() C_Timer.After(0.1, refreshPickerOverlays) end)
        CharacterFrame:HookScript("OnHide", function()
            if pickerActive then stopItemPicker() end
        end)
    end

    if ToggleCharacter then
        local paperDollShown = _G.PaperDollFrame and PaperDollFrame:IsShown()
        if not (_G.CharacterFrame and CharacterFrame:IsShown() and paperDollShown) then
            pcall(ToggleCharacter, "PaperDollFrame")
        end
    elseif _G.CharacterFrame and ShowUIPanel then
        ShowUIPanel(CharacterFrame)
    end
    C_Timer.After(0.25, refreshPickerOverlays)
    setStatus("Click an equipped item slot.")
end
ns.BeginItemPicker = beginItemPicker

local function createPickerPrompt()
    pickerPrompt = CreateFrame("Frame", "WoWraVoxPickerPrompt", UIParent, "BackdropTemplate")
    pickerPrompt:SetSize(400, 90)
    pickerPrompt:SetPoint("TOP", UIParent, "TOP", 0, -140)
    pickerPrompt:SetFrameStrata("DIALOG")
    pickerPrompt:EnableMouse(true)
    pickerPrompt:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    pickerPrompt:SetBackdropColor(0.055, 0.065, 0.08, 0.98)
    pickerPrompt:SetBackdropBorderColor(0.76, 0.58, 0.22, 1)
    local accent = pickerPrompt:CreateTexture(nil, "BORDER")
    accent:SetPoint("TOPLEFT", pickerPrompt, "TOPLEFT", 10, -30)
    accent:SetPoint("TOPRIGHT", pickerPrompt, "TOPRIGHT", -10, -30)
    accent:SetHeight(1)
    accent:SetColorTexture(0.83, 0.64, 0.2, 1)
    local title = createLabel(pickerPrompt, "WoWraVox  ·  " .. L("Item selection"), "GameFontNormal")
    title:SetPoint("TOPLEFT", pickerPrompt, "TOPLEFT", 14, -10)
    title:SetTextColor(1, 0.82, 0.2)
    pickerPrompt:Hide()
    table.insert(UISpecialFrames, "WoWraVoxPickerPrompt")

    local message = createLabel(pickerPrompt, "Click an equipped slot in the character window. Press Esc to cancel.", "GameFontHighlightSmall")
    message:SetPoint("TOPLEFT", pickerPrompt, "TOPLEFT", 15, -42)
    message:SetWidth(270)
    message:SetJustifyH("LEFT")
    local cancel = CreateFrame("Button", nil, pickerPrompt, "UIPanelButtonTemplate")
    cancel:SetSize(65, 24)
    cancel:SetPoint("BOTTOMRIGHT", pickerPrompt, "BOTTOMRIGHT", -12, 12)
    cancel:SetText(L("Cancel"))
    cancel:SetScript("OnClick", stopItemPicker)
    addHelpTooltip(cancel, "Cancel item selection", "Cancel without creating an item rule.")
    pickerPrompt:HookScript("OnHide", function()
        if pickerActive then stopItemPicker() end
    end)
end

local function createSettingsPanel()
    settingsPanel = CreateFrame("Frame", nil, optionsFrame, "BackdropTemplate")
    settingsPanel:SetPoint("TOPRIGHT", optionsFrame.settingsButton, "BOTTOMRIGHT", 0, -5)
    settingsPanel:SetSize(300, 98)
    settingsPanel:SetFrameStrata("DIALOG")
    settingsPanel:SetFrameLevel(optionsFrame:GetFrameLevel() + 20)
    settingsPanel:SetClampedToScreen(true)
    stylePanel(settingsPanel, 0.19, 0.19, 0.18)
    local title = createLabel(settingsPanel, "DISPLAY OPTIONS", "GameFontNormal")
    title:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", 14, -12)
    local definitions = {
        { key = "tooltipIDs", text = "IDs in game tooltips", help = "Shows spell IDs for auras and spells, plus item and available effect IDs for items." },
        { key = "showMinimap", text = "Minimap button", help = "Shows or hides the WoWraVox button on the minimap." },
    }
    for index, definition in ipairs(definitions) do
        local check = CreateFrame("CheckButton", nil, settingsPanel, "UICheckButtonTemplate")
        check:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", 10, -26 - (index - 1) * 31)
        check:SetChecked(WoWraVoxDB.settings[definition.key])
        local label = createLabel(settingsPanel, definition.text, "GameFontHighlightSmall")
        label:SetPoint("LEFT", check, "RIGHT", 1, 0)
        check:SetScript("OnClick", function(self)
            local checked = self:GetChecked()
            local enabled = checked == true or checked == 1
            WoWraVoxDB.settings[definition.key] = enabled
            if definition.key == "showMinimap" then
                local button = _G.WoWraVoxMinimapButton
                if button then button:SetShown(enabled) end
            end
            if definition.key ~= "tooltipIDs" and ns.UpdateLaunchers then ns.UpdateLaunchers() end
        end)
        addHelpTooltip(check, definition.text, definition.help)
        settingsPanel[definition.key] = check
    end
    settingsPanel:Hide()
end

local function createOptions()
    optionsFrame = CreateFrame("Frame", "WoWraVoxOptions", UIParent, "BackdropTemplate")
    optionsFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    optionsFrame:SetBackdropColor(0.035, 0.04, 0.05, 0.98)
    optionsFrame:SetBackdropBorderColor(0.4, 0.43, 0.49, 1)
    local maxWidth = math.max(480, UIParent:GetWidth() - 24)
    local maxHeight = math.max(360, UIParent:GetHeight() - 24)
    optionsFrame:SetResizable(true)
    optionsFrame:SetResizeBounds(math.min(940, maxWidth), math.min(560, maxHeight), maxWidth, maxHeight)
    optionsFrame:SetSize(math.min(1000, maxWidth), math.min(640, maxHeight))
    optionsFrame:SetPoint("CENTER")
    optionsFrame:SetFrameStrata("DIALOG")
    optionsFrame:SetClampedToScreen(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:SetMovable(true)
    optionsFrame:Hide()
    table.insert(UISpecialFrames, "WoWraVoxOptions")
    local header = CreateFrame("Frame", nil, optionsFrame)
    header:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -1, -1)
    header:SetHeight(48)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() optionsFrame:StartMoving() end)
    header:SetScript("OnDragStop", function() optionsFrame:StopMovingOrSizing() end)

    local headerBackground = header:CreateTexture(nil, "BACKGROUND")
    headerBackground:SetAllPoints()
    headerBackground:SetColorTexture(0.105, 0.12, 0.15, 1)
    local headerAccent = header:CreateTexture(nil, "ARTWORK")
    headerAccent:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
    headerAccent:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
    headerAccent:SetHeight(1)
    headerAccent:SetTexture("Interface\\Buttons\\WHITE8X8")
    if headerAccent.SetGradientAlpha then
        headerAccent:SetGradientAlpha("HORIZONTAL", 0.88, 0.68, 0.24, 1, 0.88, 0.68, 0.24, 0)
    else
        headerAccent:SetColorTexture(0.62, 0.48, 0.22, 1)
    end

    local brandIcon = header:CreateTexture(nil, "ARTWORK")
    brandIcon:SetSize(32, 32)
    brandIcon:SetPoint("LEFT", header, "LEFT", 9, 0)
    brandIcon:SetTexture("Interface\\AddOns\\WoWraVox\\Assets\\WoWraVoxIcon.tga")

    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", header, "CENTER", 0, 0)
    title:SetText("WoWraVox")

    local closeButton = CreateFrame("Button", nil, header, "BackdropTemplate")
    closeButton:SetSize(28, 28)
    closeButton:SetPoint("RIGHT", header, "RIGHT", -8, 0)
    closeButton:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    closeButton:SetBackdropColor(0.17, 0.19, 0.23, 1)
    closeButton:SetBackdropBorderColor(0.34, 0.37, 0.42, 1)
    local closeMarkA = closeButton:CreateTexture(nil, "ARTWORK")
    closeMarkA:SetColorTexture(0.92, 0.93, 0.96, 1)
    closeMarkA:SetSize(14, 2)
    closeMarkA:SetPoint("CENTER")
    closeMarkA:SetRotation(math.rad(45))
    local closeMarkB = closeButton:CreateTexture(nil, "ARTWORK")
    closeMarkB:SetColorTexture(0.92, 0.93, 0.96, 1)
    closeMarkB:SetSize(14, 2)
    closeMarkB:SetPoint("CENTER")
    closeMarkB:SetRotation(math.rad(-45))
    closeButton:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.42, 0.13, 0.13, 1)
        self:SetBackdropBorderColor(0.76, 0.3, 0.27, 1)
    end)
    closeButton:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.17, 0.19, 0.23, 1)
        self:SetBackdropBorderColor(0.34, 0.37, 0.42, 1)
    end)
    closeButton:SetScript("OnClick", function()
        saveDetails()
        optionsFrame:Hide()
    end)
    addHelpTooltip(closeButton, "Close", "Close the WoWraVox window.")

    optionsFrame.settingsButton = CreateFrame("Button", nil, header, "BackdropTemplate")
    optionsFrame.settingsButton:SetSize(28, 28)
    optionsFrame.settingsButton:SetPoint("RIGHT", closeButton, "LEFT", -6, 0)
    optionsFrame.settingsButton:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    optionsFrame.settingsButton:SetBackdropColor(0.17, 0.19, 0.23, 1)
    optionsFrame.settingsButton:SetBackdropBorderColor(0.34, 0.37, 0.42, 1)
    optionsFrame.settingsButton.icon = optionsFrame.settingsButton:CreateTexture(nil, "ARTWORK")
    optionsFrame.settingsButton.icon:SetTexture("Interface\\Buttons\\UI-OptionsButton")
    optionsFrame.settingsButton.icon:SetPoint("CENTER")
    optionsFrame.settingsButton.icon:SetSize(20, 20)
    optionsFrame.settingsButton:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.28, 0.25, 0.16, 1)
        self:SetBackdropBorderColor(0.72, 0.55, 0.22, 1)
    end)
    optionsFrame.settingsButton:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.17, 0.19, 0.23, 1)
        self:SetBackdropBorderColor(0.34, 0.37, 0.42, 1)
    end)
    createSettingsPanel()
    optionsFrame.settingsButton:SetScript("OnClick", function()
        if settingsPanel:IsShown() then settingsPanel:Hide() else settingsPanel:Show() end
    end)
    addHelpTooltip(optionsFrame.settingsButton, "Display options", "Configure tooltip IDs and the minimap button.")

    local listPanel = CreateFrame("Frame", nil, optionsFrame)
    listPanel:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 16, -64)
    listPanel:SetPoint("BOTTOMLEFT", optionsFrame, "BOTTOMLEFT", 16, 16)
    listPanel:SetWidth(280)
    stylePanel(listPanel, 0.115, 0.115, 0.11)
    local listHeading = createLabel(listPanel, "RULES", "GameFontNormalSmall")
    listHeading:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 11, -8)
    local listSeparator = listPanel:CreateTexture(nil, "ARTWORK")
    listSeparator:SetColorTexture(0.46, 0.36, 0.16, 0.7)
    listSeparator:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 9, -25)
    listSeparator:SetPoint("TOPRIGHT", listPanel, "TOPRIGHT", -25, -25)
    listSeparator:SetHeight(1)
    listScroll = CreateFrame("ScrollFrame", nil, listPanel, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 3, -30)
    listScroll:SetPoint("BOTTOMRIGHT", listPanel, "BOTTOMRIGHT", -25, 38)
    listChild = CreateFrame("Frame", nil, listScroll)
    listChild:SetSize(1, 1)
    listScroll:SetScrollChild(listChild)
    listEmptyText = createLabel(listPanel, "", "GameFontHighlightSmall")
    listEmptyText:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 14, -47)
    listEmptyText:SetWidth(210)
    listEmptyText:SetJustifyH("LEFT")
    listScroll:HookScript("OnSizeChanged", function(self, width)
        listChild:SetWidth(math.max(1, width))
        refreshList()
    end)

    createEditorWidgets()

    optionsFrame.addButton = CreateFrame("Button", nil, listPanel, "UIPanelButtonTemplate")
    optionsFrame.addButton:SetHeight(28)
    optionsFrame.addButton:SetPoint("BOTTOMLEFT", listPanel, "BOTTOMLEFT", 9, 5)
    optionsFrame.addButton:SetPoint("BOTTOMRIGHT", listPanel, "BOTTOMRIGHT", -25, 5)
    optionsFrame.addButton:SetText("+ " .. L("Add rule"))
    addHelpTooltip(optionsFrame.addButton, "Add rule", "Choose an aura group or an equipped item.")

    creationView.auraButton:SetScript("OnClick", function()
        saveDetails()
        local rule = newAuraRule()
        ns.registerNewRule(rule, "auras")
        table.insert(WoWraVoxDB.auras, rule)
        selectedCategory, selectedAuraRule = "auras", rule
        addRuleMode = false
        rebuildAuraWatches()
        syncAllAuras(true)
        refreshList()
        updateDetails()
    end)
    creationView.itemButton:SetScript("OnClick", function()
        saveDetails()
        beginItemPicker()
    end)
    optionsFrame.addButton:SetScript("OnClick", function()
        saveDetails()
        showAddRuleView()
    end)

    statusText = createLabel(optionsFrame, "", "GameFontNormalSmall")
    statusText:SetPoint("BOTTOMLEFT", optionsFrame, "BOTTOMLEFT", 312, 24)
    statusText:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -24, 25)
    statusText:SetJustifyH("LEFT")

    local resizeGrip = CreateFrame("Button", nil, optionsFrame)
    resizeGrip:SetSize(16, 16)
    resizeGrip:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -7, 7)
    resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeGrip:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then optionsFrame:StartSizing("BOTTOMRIGHT") end
    end)
    resizeGrip:SetScript("OnMouseUp", function() optionsFrame:StopMovingOrSizing() end)
    addHelpTooltip(resizeGrip, "Resize window", "Drag this corner to resize WoWraVox.")
    optionsFrame:HookScript("OnShow", function()
        refreshList()
        updateDetails()
    end)
    optionsFrame:HookScript("OnHide", function()
        if settingsPanel then settingsPanel:Hide() end
        if searchPopup then searchPopup:Hide() end
        addRuleMode = false
        if creationView then creationView:Hide() end
    end)
    optionsFrame:HookScript("OnSizeChanged", function()
        if listScroll then
            listChild:SetWidth(math.max(1, listScroll:GetWidth()))
            refreshList()
        end
    end)
    createPickerPrompt()
end

function ns.ToggleOptions()
    if not optionsFrame then return end
    if optionsFrame:IsShown() then
        saveDetails()
        optionsFrame:Hide()
    else
        optionsFrame:Show()
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName ~= addonName then return end
        self:UnregisterEvent("ADDON_LOADED")
        if not initializeDatabase() then return end
        createOptions()
        selectedAuraRule = WoWraVoxDB.auras[1]
        selectedItemRule = WoWraVoxDB.items[1]
        selectedSkillRule = WoWraVoxDB.skills[1]
        if not selectedAuraRule and selectedItemRule then selectedCategory = "items"
        elseif not selectedAuraRule and not selectedItemRule and selectedSkillRule then selectedCategory = "skills" end
        refreshList()
        updateDetails()
        SLASH_WOWRAVOX1 = "/wowravox"
        SLASH_WOWRAVOX2 = "/wvr"
        SLASH_WOWRAVOX3 = "/auravox"
        SLASH_WOWRAVOX4 = "/avox"
        SLASH_WOWRAVOX5 = "/aetts"
        SlashCmdList.WOWRAVOX = ns.ToggleOptions
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterUnitEvent("UNIT_AURA", "player")
        self:RegisterEvent("SPELL_DATA_LOAD_RESULT")
        self:RegisterEvent("VOICE_CHAT_TTS_VOICES_UPDATE")
        self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
        self:RegisterEvent("UNIT_INVENTORY_CHANGED")
        self:RegisterEvent("BAG_UPDATE_COOLDOWN")
        self:RegisterEvent("SPELL_UPDATE_COOLDOWN")
        self:RegisterEvent("PLAYER_REGEN_DISABLED")
        rebuildAuraWatches()
        queueItemScan(0.5)
        scanSkillRules()
    elseif event == "PLAYER_ENTERING_WORLD" then
        ns.refreshScreenFontChoices()
        if optionsFrame and optionsFrame:IsShown() then updateDetails() end
        C_Timer.After(0.8, function()
            syncAllAuras(true)
            queueItemScan(0.2)
            scanSkillRules()
        end)
    elseif event == "UNIT_AURA" then
        local _, updateInfo = ...
        onUnitAuraUpdate(updateInfo)
    elseif event == "SPELL_DATA_LOAD_RESULT" then
        local spellID, success = ...
        spellLoadRequests[spellID] = nil
        if success and C_Spell and C_Spell.GetSpellInfo then
            local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
            local nameOK, name = pcall(function() return info.name end)
            if ok and nameOK and (not issecretvalue or not issecretvalue(name))
                and type(name) == "string" and name ~= "" then
                spellInfoCache[spellID] = info
            else
                spellInfoCache[spellID] = "invalid"
            end
        else
            spellInfoCache[spellID] = "invalid"
        end
        rebuildAuraWatches()
        syncAllAuras(true)
        if optionsFrame:IsShown() then
            refreshList()
            updateDetails()
            if triggerInputBox and triggerInputBox:HasFocus()
                and trim(triggerInputBox:GetText()):match("^%d+$") then
                runTriggerSearch()
            end
        end
    elseif event == "VOICE_CHAT_TTS_VOICES_UPDATE" then
        if optionsFrame:IsShown() then updateDetails() end
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        queueItemScan(0.15)
        C_Timer.After(0.7, function() queueItemScan(0.05) end)
        C_Timer.After(1.8, function() queueItemScan(0.05) end)
    elseif event == "UNIT_INVENTORY_CHANGED" then
        local unit = ...
        if unit == "player" then queueItemScan(0.15) end
    elseif event == "BAG_UPDATE_COOLDOWN" then
        queueItemScan(0.05)
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        scanSkillRules()
    elseif event == "PLAYER_REGEN_DISABLED" then
        if pickerActive then
            stopItemPicker()
            setStatus("Item selection was stopped when combat started.", true)
        end
    end
end)
