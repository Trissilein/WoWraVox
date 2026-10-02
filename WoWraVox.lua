local addonName, ns = ...
local DB_VERSION = 5

-- Measurement only (/wvprof).  ns.Prof.on is a session flag, never saved; per-event timing runs only
-- while it is set.  Load timings (ns.Prof.load) are always taken: a handful of clock reads per login.
ns.Prof = { on = false, ev = {}, load = {}, clock = debugprofilestop or function() return 0 end }
ns.Prof.load.chunkStart = ns.Prof.clock()

ns._Aura = ns._Aura or {}
ns._Aura.EMPTY = {} -- shared read-only empty table for hot paths
local activeAuras = {}
local auraByInstanceID = {}
local auraWatchBySpellID = {}
ns._Aura.eventStates = {}
ns._Aura.unreadableBaselines = {}
local spellInfoCache = {}
local spellLoadRequests = {}
local itemCooldownStates = {}
local itemDebugDedupe = {}
local optionsFrame
local listScroll
local listChild
local listEmptyText
local listPanel
local detailPanel
local editorScroll
local auraEditor
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
local triggerInputBox
local triggerAddButton
local triggerStatus
local triggerLabel
local triggerPlaceholder
local triggerPanel
local triggerScroll
local triggerChild
local triggerRows = {}
local itemSourceText
local refreshList, saveDetails, updateDetails
local readyLabel
local searchPopup
local searchRows = {}
local runTriggerSearch
ns.spellSearch = { serial = 0, maxID = 2000000, idsPerRequest = 50000, batchSize = 128, budgetMS = 1 }
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
ns.Layout = ns.Layout or {}
-- One fixed window, no tiers and no resizing: the editor grid below is computed for exactly this size.
ns.Layout.maxWidth = 1408
ns.Layout.maxHeight = 943
ns.Layout.previewHeight = 104
-- Horizontal grid of the editor. All COLn/visible values are VISIBLE edges (what the eye sees), x from the
-- left edge of the panel. Chrome facts and their sources: docs/UI-ALIGNMENT.md section 1.
ns.Layout.PAD = 22          -- left padding of headings/labels inside panels
ns.Layout.RIGHT = -22       -- right padding as SetPoint x offset
ns.Layout.FIELD_X = 225     -- EditBox frame x of the field column (TTS/screen text, fallback, trigger input)
ns.Layout.EDITBOX_INSET = 5 -- InputBoxTemplate border starts 5 px left of the frame (Blizzard InputBoxVisualTemplate)
ns.Layout.DD_INSET_L = 15   -- [Annahme] transparent art inside a UIDropDownMenuTemplate frame, left (Ace3 AceGUI-Dropdown uses -15)
ns.Layout.DD_INSET_R = 17   -- same, right (Ace3 AceGUI-Dropdown uses +17)
ns.Layout.DD_CHROME = 50    -- UIDropDownMenu_SetWidth(frame, w) sets frame width w + 2 * 25 (UIDROPDOWNMENU_DEFAULT_WIDTH_PADDING)
ns.Layout.COL1 = ns.Layout.FIELD_X - ns.Layout.EDITBOX_INSET -- 220: visible left edge of text boxes AND dropdown column 1
ns.Layout.DROPDOWN_X = ns.Layout.COL1 - ns.Layout.DD_INSET_L -- 205: dropdown FRAME x for column 1 (single point to retune the inset)
ns.Layout.COL_GAP = 8       -- visible gap between neighbouring dropdowns / swatch
ns.Layout.COL2 = 540        -- visible left edge of dropdown column 2 (Sound channel = Size, Voice panel: Volume)
ns.Layout.SIZE_W = 136      -- visible width of the Size dropdown; col3 = COL2 + SIZE_W + COL_GAP (Style, Speed)
ns.Layout.SWATCH_W = 26
ns.Layout.VALUE_W = 42      -- slider value label incl. its 8 px offset
ns.Layout.ROW_X = 24        -- left edge of the first control (checkbox) of a panel row
ns.Layout.BUTTON_W = 112    -- width of the right-hand test/preview/anchor buttons
ns.Layout.MARGIN = 16       -- outer window margin / add-rule view inset
ns.Layout.EXTRA_X = 16      -- left edge of the skill/item extra rows (heading, source text)
ns.Layout.refreshListPending = false

-- The window is always maxWidth x maxHeight; on small screens it is scaled down instead of resized.
ns.Layout.getWindowScale = function()
    local availableWidth = math.max(1, (UIParent:GetWidth() or ns.Layout.maxWidth) - 24)
    local availableHeight = math.max(1, (UIParent:GetHeight() or ns.Layout.maxHeight) - 24)
    return math.min(1, availableWidth / ns.Layout.maxWidth, availableHeight / ns.Layout.maxHeight)
end

-- Visible column edges / widths for an editor panel of the given width.
ns.Layout.getColumns = function(width)
    local c = ns.Layout
    local textRight = width + c.RIGHT - c.BUTTON_W - 8 -- right edge of the TTS/screen text boxes
    local col3 = c.COL2 + c.SIZE_W + c.COL_GAP
    return {
        col1 = c.COL1, col2 = c.COL2, col3 = col3, right = textRight,
        col1Width = c.COL2 - c.COL_GAP - c.COL1,
        col2Width = textRight - c.COL2,
        sizeWidth = c.SIZE_W,
        styleWidth = textRight - col3,
        swatch = c.COL1 - c.COL_GAP - c.SWATCH_W,
    }
end

-- Places a UIDropDownMenuTemplate frame so that its VISIBLE box spans visLeft .. visLeft + visWidth.
ns.Layout.placeDropdown = function(dropdown, parent, visLeft, y, visWidth)
    dropdown:ClearAllPoints()
    dropdown:SetPoint("TOPLEFT", parent, "TOPLEFT", visLeft - ns.Layout.DD_INSET_L, y)
    UIDropDownMenu_SetWidth(dropdown, visWidth + ns.Layout.DD_INSET_L + ns.Layout.DD_INSET_R - ns.Layout.DD_CHROME)
end

ns.Layout.clampEditorScroll = function(offset)
    if not editorScroll then return end
    local range = math.max(0, editorScroll:GetVerticalScrollRange() or 0)
    editorScroll:SetVerticalScroll(math.max(0, math.min(tonumber(offset) or 0, range)))
end

ns.screenControls = {}
ns.screenFrames = {}
ns.notificationPanels = {}
ns.Layout.expirationPanelState = setmetatable({}, { __mode = "k" })
ns.listSectionCollapsed = ns.listSectionCollapsed or { Active = false, Inactive = false }
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
local BLIZZARD_NOTIFICATION_SOUND_CHOICES = {
    { kind = "kit", key = "Raid warning", soundKitID = SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959 },
    { kind = "kit", key = "Ready check", soundKitID = SOUNDKIT and SOUNDKIT.READY_CHECK or 8960 },
    { kind = "kit", key = "Alarm clock 1", soundKitID = SOUNDKIT and SOUNDKIT.ALARM_CLOCK_WARNING_1 or 18871 },
    { kind = "kit", key = "Alarm clock 2", soundKitID = SOUNDKIT and SOUNDKIT.ALARM_CLOCK_WARNING_2 or 12867 },
    { kind = "kit", key = "Alarm clock 3", soundKitID = SOUNDKIT and SOUNDKIT.ALARM_CLOCK_WARNING_3 or 12889 },
    { kind = "kit", key = "Battle.net notification", soundKitID = SOUNDKIT and SOUNDKIT.UI_BNET_TOAST or 18019 },
    { kind = "kit", key = "Power aura", soundKitID = SOUNDKIT and SOUNDKIT.UI_POWER_AURA_GENERIC or 23287 },
    { kind = "kit", key = "Quest complete", soundKitID = SOUNDKIT and SOUNDKIT.UI_AUTO_QUEST_COMPLETE or 23404 },
    { kind = "kit", key = "Countdown finished", soundKitID = SOUNDKIT and SOUNDKIT.UI_BATTLEGROUND_COUNTDOWN_FINISHED or 25478 },
}
local NOTIFICATION_SOUND_CHOICES = {}
local NOTIFICATION_MEDIA_PREFIX = "media:"

local function sharedMediaLibrary()
    if not (type(LibStub) == "function" or type(LibStub) == "table") then return nil end
    local ok, library = pcall(LibStub, "LibSharedMedia-3.0", true)
    if ok and type(library) == "table" then return library end
end

local function fetchSharedMediaSound(name)
    if type(name) ~= "string" or name == "" then return nil end
    local library = sharedMediaLibrary()
    if not (library and type(library.Fetch) == "function") then return nil end
    local ok, path = pcall(library.Fetch, library, "sound", name, true)
    if ok and type(path) == "string" and path ~= "" then return path end
end

function ns.refreshNotificationSoundChoices(missingName)
    wipe(NOTIFICATION_SOUND_CHOICES)
    local known = {}
    local required = {}
    if type(missingName) == "string" and missingName ~= "" then required[missingName] = true end
    for _, category in ipairs({ "auras", "items", "skills" }) do
        for _, rule in ipairs(type(WoWraVoxDB) == "table" and WoWraVoxDB[category] or {}) do
            for _, eventKey in ipairs(category == "auras" and { "apply", "expire" } or { "ready" }) do
                local name = rule[eventKey .. "SoundMediaName"]
                if type(name) == "string" and name ~= "" then required[name] = true end
            end
        end
    end
    for _, choice in ipairs(BLIZZARD_NOTIFICATION_SOUND_CHOICES) do
        table.insert(NOTIFICATION_SOUND_CHOICES, choice)
    end

    local library = sharedMediaLibrary()
    local names
    if library and type(library.List) == "function" then
        local ok, listed = pcall(library.List, library, "sound")
        if ok and type(listed) == "table" then names = listed end
    end
    for _, name in ipairs(names or {}) do
        local path = fetchSharedMediaSound(name)
        if type(name) == "string" and name ~= "" and path and not known[name] then
            table.insert(NOTIFICATION_SOUND_CHOICES, {
                kind = "media", key = name, mediaName = name,
                value = NOTIFICATION_MEDIA_PREFIX .. name,
            })
            known[name] = true
        end
    end
    for name in pairs(required) do
        if not known[name] then
            table.insert(NOTIFICATION_SOUND_CHOICES, {
                kind = "media", key = name, mediaName = name,
                value = NOTIFICATION_MEDIA_PREFIX .. name,
                missing = fetchSharedMediaSound(name) == nil,
            })
        end
    end
end

local function notificationSoundChoiceForValue(value)
    for _, choice in ipairs(NOTIFICATION_SOUND_CHOICES) do
        local choiceValue = choice.kind == "media" and choice.value or choice.soundKitID
        if choiceValue == value then return choice end
    end
end

ns.refreshNotificationSoundChoices()

local NOTIFICATION_CUE_CHOICES = {
    { value = "none", label = "No category cue" },
    { value = "defensive", label = "Defensive" },
    { value = "offensive", label = "Offensive" },
    { value = "bloodlust", label = "Bloodlust" },
}
local NOTIFICATION_CUE_ALIASES = {
    ["Defensive cooldown"] = "defensive",
    ["Offensive cooldown"] = "offensive",
    ["Bloodlust"] = "bloodlust",
    defensive = "defensive", offensive = "offensive", bloodlust = "bloodlust",
}
local NOTIFICATION_CUE_LABELS = {
    defensive = "Defensive", offensive = "Offensive", bloodlust = "Bloodlust",
}
local NOTIFICATION_SOUND_CHANNELS = {
    { key = "Master", value = "Master" },
    { key = "Sound effects", value = "SFX" },
    { key = "Dialog", value = "Dialog" },
    { key = "Music", value = "Music" },
    { key = "Ambience", value = "Ambience" },
}
local NOTIFICATION_SOUND_CHANNEL_SET = { Master = true, SFX = true, Dialog = true, Music = true, Ambience = true }
local DEFAULT_NOTIFICATION_SOUND_KIT = SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959

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
    if type(LibStub) == "function" or type(LibStub) == "table" then
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
ns.L = L

local function notificationSoundChoiceText(choice)
    if choice.kind == "media" then
        return choice.key .. (choice.missing and " (missing)" or "")
    end
    return L(choice.key)
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s*(.-)%s*$", "%1"))
end

function ns.Prof.add(name, ms)
    local entry = ns.Prof.ev[name]
    if not entry then
        entry = { calls = 0, total = 0, max = 0 }
        ns.Prof.ev[name] = entry
    end
    entry.calls = entry.calls + 1
    entry.total = entry.total + ms
    if ms > entry.max then entry.max = ms end
end

-- Swapping the OnEvent script keeps the flag-off path free of any per-event cost.
function ns.Prof.setOn(on)
    ns.Prof.on = on
    if ns.eventFrame then ns.eventFrame:SetScript("OnEvent", on and ns.Prof.onEvent or ns.onEvent) end
end

function ns.Prof.onEvent(self, event, ...)
    local started = ns.Prof.clock()
    ns.onEvent(self, event, ...)
    ns.Prof.add(event, ns.Prof.clock() - started)
end

-- Blizzard's C_AddOnProfiler metrics (all times in ms per tick; AllowedWhenUntainted, not secret).
function ns.Prof.metric(name)
    local id = Enum and Enum.AddOnProfilerMetric and Enum.AddOnProfilerMetric[name]
    if id == nil then return nil end
    local ok, value = pcall(C_AddOnProfiler.GetAddOnMetric, addonName, id)
    if ok and type(value) == "number" and not (issecretvalue and issecretvalue(value)) then return value end
    return nil
end

function ns.Prof.show()
    local prof = ns.Prof
    local function fmt(pattern, value) return value and string.format(pattern, value) or "-" end
    local out = {}
    out[#out + 1] = prof.on and L("Per-event timing is ON. Use /wvprof off or /wvprof reset.")
        or L("Per-event timing is OFF. Use /wvprof on, play, then /wvprof.")
    if C_AddOnProfiler and C_AddOnProfiler.GetAddOnMetric then
        out[#out + 1] = L("Blizzard add-on profiler, ms per tick:")
            .. " session " .. fmt("%.3f", prof.metric("SessionAverageTime"))
            .. ", recent " .. fmt("%.3f", prof.metric("RecentAverageTime"))
            .. ", encounter " .. fmt("%.3f", prof.metric("EncounterAverageTime"))
            .. ", peak " .. fmt("%.3f", prof.metric("PeakTime"))
        out[#out + 1] = L("Ticks over 1/5/10/50/100 ms:")
            .. " " .. fmt("%.0f", prof.metric("CountTimeOver1Ms")) .. "/" .. fmt("%.0f", prof.metric("CountTimeOver5Ms"))
            .. "/" .. fmt("%.0f", prof.metric("CountTimeOver10Ms")) .. "/" .. fmt("%.0f", prof.metric("CountTimeOver50Ms"))
            .. "/" .. fmt("%.0f", prof.metric("CountTimeOver100Ms"))
    else
        out[#out + 1] = L("Blizzard add-on profiler unavailable.")
    end
    local cvarOK, scriptProfile = pcall(GetCVar, "scriptProfile")
    if cvarOK and scriptProfile ~= "1" then
        out[#out + 1] = L("scriptProfile is off, so CPU usage reads 0. Enable: /console scriptProfile 1, then /reload.")
    elseif cvarOK then
        local getCPU = GetAddOnCPUUsage or (C_AddOns and C_AddOns.GetAddOnCPUUsage)
        local update = UpdateAddOnCPUUsage or (C_AddOns and C_AddOns.UpdateAddOnCPUUsage)
        if update then pcall(update) end
        local ok, cpu = false, nil
        if getCPU then ok, cpu = pcall(getCPU, addonName) end
        if ok and type(cpu) == "number" then
            out[#out + 1] = string.format(L("Script CPU (scriptProfile): %.1f ms total."), cpu)
        end
    end
    local load = prof.load
    out[#out + 1] = L("Load (ms):") .. " files " .. fmt("%.1f", load.files) .. ", db " .. fmt("%.1f", load.db)
        .. ", options " .. fmt("%.1f", load.options) .. ", refresh " .. fmt("%.1f", load.refresh)
        .. ", watches " .. fmt("%.1f", load.watches) .. ", total " .. fmt("%.1f", load.total)
    out[#out + 1] = L("Login (ms):") .. " PLAYER_ENTERING_WORLD " .. fmt("%.1f", load.pew)
        .. ", deferred sync " .. fmt("%.1f", load.pewSync)
    local rows = {}
    for name, entry in pairs(prof.ev) do rows[#rows + 1] = { name = name, entry = entry } end
    if #rows == 0 then
        out[#out + 1] = L("No per-event data yet.")
    else
        table.sort(rows, function(a, b) return a.entry.total > b.entry.total end)
        out[#out + 1] = L("name  calls  total ms  avg ms  max ms")
        for index = 1, math.min(#rows, 8) do
            local entry = rows[index].entry
            out[#out + 1] = string.format("%s  %d  %.2f  %.3f  %.2f", rows[index].name,
                entry.calls, entry.total, entry.total / entry.calls, entry.max)
        end
    end
    for _, line in ipairs(out) do print(line) end
end

function ns.Prof.Command(message)
    local arg = tostring(message or ""):lower():match("^%s*(%S*)")
    if arg == "on" then
        ns.Prof.setOn(true)
    elseif arg == "off" then
        ns.Prof.setOn(false)
    elseif arg == "reset" then
        wipe(ns.Prof.ev)
        print(L("Profiling counters reset."))
        return
    end
    ns.Prof.show()
end

local function copyIDs(ids)
    local result = {}
    for _, id in ipairs(ids or {}) do
        if type(id) == "number" and id > 0 and id <= 2147483647 and id == math.floor(id) then
            table.insert(result, id)
        end
    end
    return result
end

function ns._Aura.validIntegerID(value)
    local id = tonumber(value)
    return id and id > 0 and id <= 2147483647 and id == math.floor(id) and id or nil
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
        if not id or id <= 0 or id > 2147483647 then return nil, false end
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

ns.ANCHOR_POINTS = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
    RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }
function ns.copyScreenAnchor(anchor)
    anchor = type(anchor) == "table" and anchor or DEFAULT_SCREEN_ANCHOR
    return {
        point = ns.ANCHOR_POINTS[anchor.point] and anchor.point or DEFAULT_SCREEN_ANCHOR.point,
        relativePoint = ns.ANCHOR_POINTS[anchor.relativePoint] and anchor.relativePoint or DEFAULT_SCREEN_ANCHOR.relativePoint,
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
        alertCategory = "none",
        applyEnabled = false,
        applyMessage = "",
        applySoundEnabled = false,
        applySoundKitID = DEFAULT_NOTIFICATION_SOUND_KIT,
        applySoundChannel = "Master",
        expireEnabled = false,
        expireMessage = "",
        expireSoundEnabled = false,
        expireSoundKitID = DEFAULT_NOTIFICATION_SOUND_KIT,
        expireSoundChannel = "Master",
        screenProfiles = {
            apply = ns.newScreenProfile(false, ""),
            expire = ns.newScreenProfile(false, ""),
        },
        voiceID = getDefaultVoiceID(),
        volume = 80,
        speechSpeed = 100,
    }
end

local function newItemRule(itemID, name, icon)
    return {
        itemID = itemID,
        name = name or ("Item " .. tostring(itemID or "")),
        icon = icon,
        enabled = true,
        alertCategory = "none",
        readyEnabled = true,
        message = (name or "Item") .. " " .. L("ready"),
        screenProfiles = { ready = ns.newScreenProfile(false, "") },
        voiceID = getDefaultVoiceID(),
        volume = 80,
        speechSpeed = 100,
        readySoundEnabled = false,
        readySoundKitID = DEFAULT_NOTIFICATION_SOUND_KIT,
        readySoundChannel = "Master",
    }
end

local function newSkillRule(spellID, name, icon)
    local ruleName = name or ("Spell " .. tostring(spellID or ""))
    return {
        spellID = tonumber(spellID) or 0,
        name = ruleName,
        icon = icon,
        enabled = true,
        alertCategory = "none",
        triggerType = "offCooldown",
        readyEnabled = true,
        message = (name or "Spell") .. " " .. L("ready"),
        screenProfiles = { ready = ns.newScreenProfile(false, "") },
        voiceID = getDefaultVoiceID(),
        volume = 80,
        speechSpeed = 100,
        readySoundEnabled = false,
        readySoundKitID = DEFAULT_NOTIFICATION_SOUND_KIT,
        readySoundChannel = "Master",
    }
end

local function copyDefault(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copyDefault(child) end
    return result
end

function ns.CreateStarterDatabase()
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
        rule.applyScreenEnabled = nil
        rule.applyScreenText = nil
        rule.expireScreenEnabled = nil
        rule.expireScreenText = nil
    else
        rule.screenProfiles.ready = ns.normalizeScreenProfile(
            rule.screenProfiles.ready, rule.screenEnabled, rule.screenText, settings)
        rule.screenEnabled = nil
        rule.screenText = nil
    end
end

function ns.normalizeNotificationSettings(rule, category)
    rule.alertCategory = NOTIFICATION_CUE_ALIASES[rule.alertCategory] or "none"
    local soundEvents = category == "auras" and { "apply", "expire" } or { "ready" }
    for _, eventKey in ipairs(soundEvents) do
        local mediaField = eventKey .. "SoundMediaName"
        local mediaName = rule[mediaField]
        rule[mediaField] = type(mediaName) == "string" and trim(mediaName) ~= "" and trim(mediaName) or nil
    end
    if category ~= "auras" then
        rule.readyEnabled = rule.readyEnabled ~= false
        rule.readySoundEnabled = rule.readySoundEnabled == true
        rule.readySoundKitID = tonumber(rule.readySoundKitID) or DEFAULT_NOTIFICATION_SOUND_KIT
        rule.readySoundChannel = NOTIFICATION_SOUND_CHANNEL_SET[rule.readySoundChannel] and rule.readySoundChannel or "Master"
    end
end

-- Foreign-target announcements and the combat cast map were removed; silently drop their old saved fields.
-- Equipment slot IDs are integers 1..19; anything else (including a missing slot) means "track the item".
function ns.normalizeSlotID(value)
    local slotID = tonumber(value)
    if slotID and slotID >= 1 and slotID <= 19 and slotID == math.floor(slotID) then return slotID end
    return nil
end

function ns.normalizeTargetRule(rule)
    if type(rule) ~= "table" then return end
    rule.autoAnnounceTarget = nil
    rule.otherTargetMessage = nil
    rule.targetMessage = nil
    rule.combatCastByAuraID = nil
    rule.defensiveMappingVersion = nil
end

-- Holy Armaments (432459 Holy Bulwark / 432472 Sacred Weapon) used to be a linked "shared charge" pair.
-- Both spells draw from one charge pool, so the 432459 rule now announces every regained charge on its own
-- (trigger chargeGained) and the partner is disabled, not deleted: two active rules would announce each charge
-- twice. Name and message change only while they are still the swapped or generated defaults. Idempotent,
-- because the link fields are dropped.
function ns.migrateSharedChargeRules(rules)
    local byID = {}
    for _, rule in ipairs(rules or {}) do
        if type(rule) == "table" and rule.id ~= nil then byID[tostring(rule.id)] = rule end
    end
    for _, rule in ipairs(rules or {}) do
        local partner = type(rule) == "table" and tonumber(rule.spellID) == 432459
            and rule.sharedChargePartnerID ~= nil and byID[tostring(rule.sharedChargePartnerID)]
        if partner and partner ~= rule and tonumber(partner.spellID) == 432472 then
            local names = { ["Holy Bulwark"] = true, ["Sacred Weapon"] = true, ["Spell 432459"] = true }
            if C_Spell and C_Spell.GetSpellName then
                for _, id in ipairs({ 432459, 432472 }) do
                    local ok, name = pcall(C_Spell.GetSpellName, id)
                    if ok and not (issecretvalue and issecretvalue(name)) and type(name) == "string" then
                        names[name] = true
                    end
                end
            end
            local generatedMessage = false
            for name in pairs(names) do
                if rule.message == name .. " ready" or rule.message == name .. " " .. L("ready") then
                    generatedMessage = true
                end
            end
            if names[rule.name] then rule.name = "Holy Armaments" end
            if generatedMessage then rule.message = "Holy Armaments " .. L("ready") end
            rule.triggerType = "chargeGained"
            partner.enabled = false
        end
    end
    for _, rule in ipairs(rules or {}) do
        if type(rule) == "table" then
            rule.sharedChargePartnerID = nil
            rule.sharedChargeSourceSpellID = nil
            rule.fallbackMessage = nil
        end
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
    ns.normalizeNotificationSettings(rule, category)
    if category == "auras" then ns.normalizeTargetRule(rule) end
end

local function initializeDatabase()
    if type(WoWraVoxDB) ~= "table" then WoWraVoxDB = ns.CreateStarterDatabase() end

    if WoWraVoxDB.version == 2 or WoWraVoxDB.version == 3 or WoWraVoxDB.version == 4 then
        WoWraVoxDB.version = DB_VERSION
    end

    if WoWraVoxDB.version ~= DB_VERSION
        or type(WoWraVoxDB.auras) ~= "table"
        or type(WoWraVoxDB.items) ~= "table" then
        print("|cffff4040WoWraVox:|r gespeicherte Konfiguration nicht erkannt; Add-on pausiert.")
        return false
    end

    WoWraVoxDB.spellSearchIndex = nil

    WoWraVoxDB.settings = type(WoWraVoxDB.settings) == "table" and WoWraVoxDB.settings or {}
    local settings = WoWraVoxDB.settings
    settings.tooltipIDs = settings.tooltipIDs ~= false
    local validFont = false
    for _, choice in ipairs(SCREEN_FONT_CHOICES) do
        if settings.screenFont == choice.key then validFont = true; break end
    end
    if not validFont then settings.screenFont = SCREEN_FONT_CHOICES[1].key end
    settings.screenSize = ns.getScreenSizeValue(settings.screenSize)
    settings.screenAnchor = ns.copyScreenAnchor(settings.screenAnchor)
    WoWraVoxDB.skills = type(WoWraVoxDB.skills) == "table" and WoWraVoxDB.skills or {}
    for _, category in ipairs({ "auras", "items", "skills" }) do
        local rules = WoWraVoxDB[category]
        for index = #rules, 1, -1 do
            if type(rules[index]) ~= "table" then table.remove(rules, index) end
        end
    end
    local usedRuleIDs = {}
    local nextRuleID = tonumber(WoWraVoxDB.nextRuleID) or 0

    for _, rule in ipairs(WoWraVoxDB.auras) do
        nextRuleID = ns.ensureRuleID(rule, usedRuleIDs, nextRuleID)
        ns.Profiles.NormalizeRuleSpecializations(rule)
        rule.name = type(rule.name) == "string" and rule.name or "Aura"
        rule.spellIDs = copyIDs(rule.spellIDs or (rule.spellID and { tonumber(rule.spellID) } or {}))
        rule.enabled = rule.enabled ~= false
        rule.applyEnabled = rule.applyEnabled == true
        rule.applyMessage = type(rule.applyMessage) == "string" and rule.applyMessage or ""
        ns.normalizeTargetRule(rule)
        rule.applySoundEnabled = rule.applySoundEnabled == true
        rule.applySoundKitID = tonumber(rule.applySoundKitID) or DEFAULT_NOTIFICATION_SOUND_KIT
        rule.applySoundChannel = NOTIFICATION_SOUND_CHANNEL_SET[rule.applySoundChannel] and rule.applySoundChannel or "Master"
        rule.applyScreenEnabled = rule.applyScreenEnabled == true
        rule.applyScreenText = type(rule.applyScreenText) == "string" and rule.applyScreenText or ""
        rule.expireEnabled = rule.expireEnabled == true
        rule.expireMessage = type(rule.expireMessage) == "string" and rule.expireMessage or ""
        rule.expireSoundEnabled = rule.expireSoundEnabled == true
        rule.expireSoundKitID = tonumber(rule.expireSoundKitID) or DEFAULT_NOTIFICATION_SOUND_KIT
        rule.expireSoundChannel = NOTIFICATION_SOUND_CHANNEL_SET[rule.expireSoundChannel] and rule.expireSoundChannel or "Master"
        rule.expireScreenEnabled = rule.expireScreenEnabled == true
        rule.expireScreenText = type(rule.expireScreenText) == "string" and rule.expireScreenText or ""
        rule.voiceID = tonumber(rule.voiceID) or getDefaultVoiceID()
        rule.volume = math.max(0, math.min(100, tonumber(rule.volume) or 100))
        rule.speechSpeed = math.max(100, math.min(200, 100 + math.floor(((tonumber(rule.speechSpeed) or 100) - 100) / 10 + 0.5) * 10))
        ns.normalizeNotificationSettings(rule, "auras")
        ns.normalizeRuleScreenProfiles(rule, "auras", settings)
    end

    for _, rule in ipairs(WoWraVoxDB.items) do
        nextRuleID = ns.ensureRuleID(rule, usedRuleIDs, nextRuleID)
        ns.Profiles.NormalizeRuleSpecializations(rule)
        rule.itemID = tonumber(rule.itemID) or 0
        rule.slotID = ns.normalizeSlotID(rule.slotID)
        rule.name = type(rule.name) == "string" and rule.name or ("Item " .. tostring(rule.itemID))
        rule.message = type(rule.message) == "string" and rule.message or ""
        rule.enabled = rule.enabled ~= false
        rule.screenEnabled = rule.screenEnabled == true
        rule.screenText = type(rule.screenText) == "string" and rule.screenText or ""
        rule.voiceID = tonumber(rule.voiceID) or getDefaultVoiceID()
        rule.volume = math.max(0, math.min(100, tonumber(rule.volume) or 100))
        rule.speechSpeed = math.max(100, math.min(200, 100 + math.floor(((tonumber(rule.speechSpeed) or 100) - 100) / 10 + 0.5) * 10))
        ns.normalizeNotificationSettings(rule, "items")
        ns.normalizeRuleScreenProfiles(rule, "items", settings)
    end

    for _, rule in ipairs(WoWraVoxDB.skills) do
        nextRuleID = ns.ensureRuleID(rule, usedRuleIDs, nextRuleID)
        ns.Profiles.NormalizeRuleSpecializations(rule)
        rule.spellID = tonumber(rule.spellID) or 0
        rule.name = type(rule.name) == "string" and rule.name or ("Spell " .. tostring(rule.spellID))
        ns.SkillTracking.NormalizeRule(rule)
        rule.message = type(rule.message) == "string" and rule.message or ""
        rule.enabled = rule.enabled ~= false
        rule.screenEnabled = rule.screenEnabled == true
        rule.screenText = type(rule.screenText) == "string" and rule.screenText or ""
        rule.voiceID = tonumber(rule.voiceID) or getDefaultVoiceID()
        rule.volume = math.max(0, math.min(100, tonumber(rule.volume) or 100))
        rule.speechSpeed = math.max(100, math.min(200, 100 + math.floor(((tonumber(rule.speechSpeed) or 100) - 100) / 10 + 0.5) * 10))
        ns.normalizeNotificationSettings(rule, "skills")
        ns.normalizeRuleScreenProfiles(rule, "skills", settings)
    end
    ns.migrateSharedChargeRules(WoWraVoxDB.skills)

    WoWraVoxDB.nextRuleID = nextRuleID

    return true
end

function ns.NormalizeAllProfiles()
    if not ns.Profiles or not ns.Profiles.ForEachProfileData then return end
    ns.Profiles.ForEachProfileData(function(data)
        data.spellSearchIndex = nil
        if data.version == 2 or data.version == 3 or data.version == 4 then data.version = DB_VERSION end
        if data.version == DB_VERSION then
            data.settings = type(data.settings) == "table" and data.settings or {}
            data.settings.showMinimap = nil -- minimap button was removed
            data.minimap = nil
            for _, category in ipairs({ "auras", "items", "skills" }) do
                local rules = type(data[category]) == "table" and data[category] or {}
                for _, rule in ipairs(rules) do
                    if type(rule) == "table" then
                        ns.Profiles.NormalizeRuleSpecializations(rule)
                        if category == "auras" then
                            rule.spellIDs = copyIDs(rule.spellIDs or (rule.spellID and { tonumber(rule.spellID) } or {}))
                            ns.normalizeTargetRule(rule)
                        end
                        ns.normalizeNotificationSettings(rule, category)
                        ns.normalizeRuleScreenProfiles(rule, category, data.settings)
                        if category == "skills" then ns.SkillTracking.NormalizeRule(rule) end
                    end
                end
                if category == "skills" then ns.migrateSharedChargeRules(rules) end
            end
        end
    end)
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
    local numericID = tonumber(needle)
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
                    local idMatches = matchNumericID and numericID
                        and (numericID == spellID or (#needle >= 3 and tostring(spellID):find(needle, 1, true) ~= nil))
                    if nameMatches or idMatches then
                        candidates[spellID] = candidates[spellID] or "Spellbook"
                    end
                end
            end
        end
    end
end

function ns._Aura.searchAvailableSpells(query, exactNameID)
    query = trim(query)
    if query == "" then return {} end
    local needle = query:lower()
    local numericID = tonumber(query)
    local numericQuery = needle:match("^%d+$") ~= nil
    local candidates, partialInfo = {}, {}
    for id, origin in pairs(observedSpellIDs) do candidates[id] = origin end
    for _, rule in ipairs(WoWraVoxDB.auras) do
        for _, id in ipairs(rule.spellIDs) do candidates[id] = "WoWraVox rule" end
    end
    if numericID and numericID > 0 and numericID == math.floor(numericID) then
        candidates[numericID] = candidates[numericID] or "Spell ID"
    end
    if isPublicNumber(exactNameID) then candidates[exactNameID] = candidates[exactNameID] or "Spell ID" end
    collectPlayerAuras(candidates)
    collectSpellbook(candidates, needle, true)
    local scan = ns.spellSearch.partial
    if not numericQuery and scan and scan.query:lower() == needle and scan.rule == selectedAuraRule then
        for id, info in pairs(scan.matches) do
            candidates[id] = candidates[id] or "Game search"
            partialInfo[id] = info
        end
    end
    local results, hasPending, exactNamePending = {}, false, false
    for id, origin in pairs(candidates) do
        local idText = tostring(id)
        local idMatches = numericQuery and (id == numericID
            or (#needle >= 3 and idText:find(needle, 1, true) ~= nil))
        if not numericQuery or idMatches then
            local info, status = partialInfo[id], "valid"
            if not info then info, status = getSpellInfo(id) end
            if status == "pending" then hasPending = true end
            if id == exactNameID and status == "pending" then exactNamePending = true end
            if status == "valid" and (idMatches or (not numericQuery and info.name:lower():find(needle, 1, true))) then
                local nameLower = info.name:lower()
                local rank = numericQuery and (id == numericID and 0 or 1)
                    or (nameLower == needle and 0 or (nameLower:sub(1, #needle) == needle and 1 or 2))
                table.insert(results, { id = id, name = info.name, icon = info.iconID, origin = origin, rank = rank })
            end
        end
    end
    table.sort(results, function(a, b)
        local aGlobal = a.origin == "Game search"
        local bGlobal = b.origin == "Game search"
        if aGlobal ~= bGlobal then return not aGlobal end
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.name ~= b.name then return a.name < b.name end
        return a.id < b.id
    end)
    return results, hasPending, exactNamePending
end

ns.runPartialSpellSearch = function(query, rule, generation, resume)
    query = trim(query)
    if not (C_Spell and C_Spell.GetSpellName and C_Timer and C_Timer.After) then
        ns.spellSearch.partial = {
            query = query, rule = rule, generation = generation, matches = {},
            unavailable = true, hasMore = false,
        }
        runTriggerSearch(ns.spellSearch.partial.generation)
        return
    end
    local state = ns.spellSearch.partial
    if not (resume and state and state.query == query and state.rule == rule
        and state.generation == generation and state.hasMore) then
        state = { query = query, rule = rule, generation = generation, nextID = 1, matches = {}, hasMore = true }
        ns.spellSearch.partial = state
    else
        state.matches = {}
    end
    state.scanned = 0
    state.found = 0
    state.running = true
    ns.spellSearch.serial = ns.spellSearch.serial + 1
    state.serial = ns.spellSearch.serial
    local serial = state.serial
    local needle = query:lower()

    local function scanBatch()
        if ns.spellSearch.partial ~= state or state.serial ~= serial then return end
        if state.generation ~= searchGeneration or state.rule ~= selectedAuraRule
            or not triggerInputBox or not triggerInputBox:IsShown() or trim(triggerInputBox:GetText()) ~= query
            or not optionsFrame or not optionsFrame:IsShown()
            or not searchPopup or not searchPopup:IsShown() then
            state.running = false
            return
        end
        local exactResult = triggerAddButton and triggerAddButton.exactResult
        if exactResult and exactResult.query == query and exactResult.rule == rule then
            state.running = false
            return
        end
        local canProfile = type(debugprofilestop) == "function"
        local startedAt = canProfile and debugprofilestop() or nil
        local batchCount = 0
        while batchCount < ns.spellSearch.batchSize
            and state.scanned < ns.spellSearch.idsPerRequest
            and state.nextID <= ns.spellSearch.maxID do
            if batchCount > 0 and startedAt and debugprofilestop() - startedAt >= ns.spellSearch.budgetMS then
                break
            end
            local id = state.nextID
            state.nextID = id + 1
            state.scanned = state.scanned + 1
            batchCount = batchCount + 1
            local ok, name = pcall(C_Spell.GetSpellName, id)
            if ok and type(name) == "string" and name ~= ""
                and (not issecretvalue or not issecretvalue(name))
                and name:lower():find(needle, 1, true) then
                local icon
                if C_Spell.GetSpellTexture then
                    local iconOK, iconValue = pcall(C_Spell.GetSpellTexture, id)
                    if iconOK and isPublicNumber(iconValue) then icon = iconValue end
                end
                state.matches[id] = { name = name, iconID = icon }
                state.found = state.found + 1
                if state.found >= 6 then break end
            end
        end
        local complete = state.found >= 6 or state.scanned >= ns.spellSearch.idsPerRequest
            or state.nextID > ns.spellSearch.maxID
        if complete then
            state.running = false
            state.hasMore = state.nextID <= ns.spellSearch.maxID
        end
        local now = GetTime and GetTime() or 0
        if complete or now - (state.lastRefresh or 0) >= 0.3 then
            state.lastRefresh = now
            runTriggerSearch(state.generation)
        end
        if not complete then C_Timer.After(0, scanBatch) end
    end

    C_Timer.After(0, scanBatch)
end

function ns._Aura.cancelPartialSpellSearch()
    ns.spellSearch.serial = ns.spellSearch.serial + 1
    ns.spellSearch.partial = nil
end

local function searchSpellbookSkills(query)
    query = trim(query)
    if query == "" then return {} end
    local needle = query:lower()
    local numericID = tonumber(query)
    local numericQuery = needle:match("^%d+$") ~= nil
    local candidates = {}
    collectSpellbook(candidates, needle, true)
    local results = {}
    for id in pairs(candidates) do
        local idMatches = numericQuery and (id == numericID
            or (#needle >= 3 and tostring(id):find(needle, 1, true) ~= nil))
        if not numericQuery or idMatches then
            local info, status = getSpellInfo(id)
            if status == "valid" and (idMatches or (not numericQuery and info.name:lower():find(needle, 1, true))) then
                local nameLower = info.name:lower()
                local rank = numericQuery and (id == numericID and 0 or 1)
                    or (nameLower == needle and 0 or (nameLower:sub(1, #needle) == needle and 1 or 2))
                table.insert(results, { id = id, name = info.name, icon = info.iconID, origin = "Spellbook", rank = rank })
            end
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

function ns._Aura.readableString(value)
    if type(value) ~= "string" or value == "" then return nil end
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret == true then return nil end
    end
    return value
end

-- True while aura queries generally return secret values.  Falls back to combat
-- lockdown when the API is missing or its result is not a readable boolean.
function ns._Aura.aurasAreSecret()
    if C_Secrets and type(C_Secrets.ShouldAurasBeSecret) == "function" then
        local ok, secret = pcall(C_Secrets.ShouldAurasBeSecret)
        if ok and type(secret) == "boolean" and not (issecretvalue and issecretvalue(secret)) then
            return secret
        end
    end
    return InCombatLockdown and InCombatLockdown() or false
end

function ns._Aura.getTTSRate(speedPercent)
    return math.floor((math.max(100, math.min(200, tonumber(speedPercent) or 100)) - 100) / 10 + 0.5)
end

local function playTTS(voiceID, message, volume, speedPercent)
    if not (C_VoiceChat and C_VoiceChat.SpeakText) then return false, "api-unavailable" end
    if type(message) ~= "string" or not message:match("%S") then return false, "empty-message" end
    local rate = ns._Aura.getTTSRate(speedPercent)
    ns._Aura.traceTTSCall(voiceID, message, rate, volume)
    local ok, err = pcall(C_VoiceChat.SpeakText, voiceID, message, rate, volume, false)
    if not ok then return false, "call-error: " .. tostring(err) end
    return true, "call-returned"
end

-- Debug only: SpeakText returns nothing, so the TTS playback events are the only proof that
-- speech actually started.  Events are registered lazily on the first call with debug on.
ns._Aura.TTS_EVENTS = {
    "VOICE_CHAT_TTS_PLAYBACK_STARTED", "VOICE_CHAT_TTS_PLAYBACK_FINISHED", "VOICE_CHAT_TTS_PLAYBACK_FAILED",
}

function ns._Aura.setTTSEvents(on)
    local frame = ns.eventFrame
    if not (frame and frame.RegisterEvent) then return end
    for _, name in ipairs(ns._Aura.TTS_EVENTS) do
        if on then frame:RegisterEvent(name) else frame:UnregisterEvent(name) end
    end
    ns._Aura.ttsEventsOn = on
end

function ns._Aura.traceTTSCall(voiceID, message, rate, volume)
    local debugOn = ns.AuraSoundFallback ~= nil and ns.AuraSoundFallback.debugEnabled == true
    if debugOn ~= (ns._Aura.ttsEventsOn == true) then ns._Aura.setTTSEvents(debugOn) end
    if not debugOn then return end
    local now = GetTime()
    ns._Aura.lastTTSCallAt = now
    ns.AuraSoundFallback.Log("TTS-CALL", string.format("t=%.3f voice=%s rate=%s volume=%s text=%s",
        now, tostring(voiceID), tostring(rate), tostring(volume), message:sub(1, 80)))
end

function ns._Aura.onTTSEvent(event, utteranceID, status)
    if not (ns.AuraSoundFallback and ns.AuraSoundFallback.debugEnabled) then
        ns._Aura.setTTSEvents(false)
        return
    end
    local now = GetTime()
    local kind = event:match("PLAYBACK_(%a+)$")
    if kind == "STARTED" then
        ns._Aura.lastTTSStartAt = now
        ns.AuraSoundFallback.Log("TTS-START", string.format("+%d ms since last TTS-CALL utterance=%s",
            ns._Aura.lastTTSCallAt and (now - ns._Aura.lastTTSCallAt) * 1000 or -1, tostring(utteranceID)))
    elseif kind == "FINISHED" then
        ns.AuraSoundFallback.Log("TTS-FINISHED", string.format("spoke %d ms utterance=%s",
            ns._Aura.lastTTSStartAt and (now - ns._Aura.lastTTSStartAt) * 1000 or -1, tostring(utteranceID)))
    else
        ns.AuraSoundFallback.Log("TTS-FAILED", string.format("utterance=%s status=%s", tostring(utteranceID), tostring(status)))
    end
end

-- Notification path only: messages with the same voice/volume/rate raised in the same frame are
-- joined into ONE SpeakText call (the engine queue is neither FIFO nor LIFO for near-simultaneous
-- calls).  Returns like playTTS; "queued" counts as accepted.
ns._Aura.ttsQueue = {}

function ns._Aura.queueTTS(voiceID, message, volume, speedPercent)
    if not (C_VoiceChat and C_VoiceChat.SpeakText) then return false, "api-unavailable" end
    if type(message) ~= "string" or not message:match("%S") then return false, "empty-message" end
    local queue = ns._Aura.ttsQueue
    local rate = ns._Aura.getTTSRate(speedPercent)
    local batch
    for _, pending in ipairs(queue) do
        if pending.voiceID == voiceID and pending.volume == volume and pending.rate == rate then
            batch = pending
            break
        end
    end
    if not batch then
        batch = { voiceID = voiceID, volume = volume, rate = rate, speed = speedPercent, texts = {} }
        table.insert(queue, batch)
        if #queue == 1 then C_Timer.After(0, ns._Aura.flushTTS) end
    end
    table.insert(batch.texts, message)
    return true, "queued"
end

function ns._Aura.flushTTS()
    local queue = ns._Aura.ttsQueue
    ns._Aura.ttsQueue = {}
    for _, batch in ipairs(queue) do
        local text = batch.texts[1]
        for index = 2, #batch.texts do
            text = text .. (text:match("[%.!?:;,]%s*$") and " " or ". ") .. batch.texts[index]
        end
        if #batch.texts > 1 and ns.AuraSoundFallback then
            ns.AuraSoundFallback.Log("TTS-COALESCE", string.format("messages=%d voice=%s", #batch.texts, tostring(batch.voiceID)))
        end
        local ok, status = playTTS(batch.voiceID, text, batch.volume, batch.speed)
        if not ok then
            if ns.AuraSoundFallback then ns.AuraSoundFallback.Log("TTS-FAILURE", "deferred status=" .. tostring(status)) end
        end
    end
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

function ns.playNotificationSound(rule, eventKey)
    local prefix = eventKey == "apply" and "apply" or eventKey == "expire" and "expire" or eventKey == "ready" and "ready"
    if not (rule and prefix and rule[prefix .. "SoundEnabled"]) then return false end
    local channel = NOTIFICATION_SOUND_CHANNEL_SET[rule[prefix .. "SoundChannel"]] and rule[prefix .. "SoundChannel"] or "Master"
    local mediaName = rule[prefix .. "SoundMediaName"]
    local mediaPath = fetchSharedMediaSound(mediaName)
    if mediaPath and type(PlaySoundFile) == "function" then
        local ok, played = pcall(PlaySoundFile, mediaPath, channel, true)
        if ok and played ~= false then return true end
    end
    local soundKitID = tonumber(rule[prefix .. "SoundKitID"])
    if not soundKitID or soundKitID <= 0 or type(PlaySound) ~= "function" then return false end
    local ok, played = pcall(PlaySound, soundKitID, channel, true)
    return ok and played ~= false
end

function ns.formatRuleNotificationMessage(rule, message)
    if type(message) ~= "string" then message = "" end
    return message
end

local function notifyRule(rule, eventKey, message, spellID, sourceEvent, detectedEvent)
    local ttsCallReturned = false
    local ttsStatus = "disabled"
    local screenShown = false
    local native = ns.AuraSoundFallback
    -- WoW plays registered native sounds itself; the category word replaces the apply sound.
    local nativeSound = native and native.IsRegistered(spellID, eventKey)
    local categorySelected = eventKey == "apply" and rule.alertCategory ~= "none"
        and native and native.GetCategorySoundFile(rule.alertCategory) ~= nil
    local profile = ns.getRuleScreenProfile(rule, eventKey)
    local ttsEnabled = eventKey == "apply" and rule.applyEnabled
        or eventKey == "expire" and rule.expireEnabled
        or eventKey == "ready" and rule.readyEnabled ~= false
    local ttsMessage = ttsEnabled and ns.formatRuleNotificationMessage(rule, message) or ""
    if ttsEnabled then
        ttsCallReturned, ttsStatus = ns._Aura.queueTTS(rule.voiceID, ttsMessage, rule.volume, rule.speechSpeed)
        if not ttsCallReturned and native then
            native.Log("TTS-FAILURE", string.format("rule=%s spell=%s event=%s status=%s category=%s",
                tostring(rule.id or "?"), tostring(spellID or rule.itemID or "?"), tostring(eventKey),
                tostring(ttsStatus), tostring(categorySelected)))
        end
    end
    local soundPlayed = not nativeSound and not categorySelected and ns.playNotificationSound(rule, eventKey)
    if profile and profile.enabled then
        local screenText = ns.formatRuleNotificationMessage(rule, profile.text)
        if trim(screenText) ~= "" then screenShown = ns.showScreenText(rule, eventKey, screenText) end
    end
    if native then
        local soundRequested = eventKey == "apply" and rule.applySoundEnabled
            or eventKey == "expire" and rule.expireSoundEnabled
            or eventKey == "ready" and rule.readySoundEnabled
        local reason = ttsEnabled and not ttsCallReturned and "tts-not-accepted"
            or (ttsEnabled or soundRequested or (profile and profile.enabled) or categorySelected)
            and "channels-attempted" or "all-output-channels-disabled"
        native.Log("NOTIFY-OUTPUT", string.format("rule=%s spell=%s event=%s trigger=%s source=%s reason=%s native=%s sound=%s tts=%s screen=%s",
            tostring(rule.id or "?"), tostring(spellID or rule.itemID or "?"), tostring(eventKey), tostring(detectedEvent or eventKey), tostring(sourceEvent or "?"), tostring(reason), tostring(nativeSound == true),
            tostring(soundPlayed == true), tostring(ttsStatus), tostring(screenShown == true)))
    end
    return ttsCallReturned or screenShown or soundPlayed
end

function ns._Aura.resetEventState()
    ns._Aura.eventStates = {}
    ns._Aura.unreadableBaselines = {}
end

function ns._Aura.getEventState(rule, spellID)
    local states = ns._Aura.eventStates[rule]
    if not states then
        states = {}
        ns._Aura.eventStates[rule] = states
    end
    local state = states[spellID]
    if not state then
        state = {}
        states[spellID] = state
    end
    return state
end

function ns._Aura.clearEventState(spellID)
    for rule, states in pairs(ns._Aura.eventStates) do
        states[spellID] = nil
        if not next(states) then ns._Aura.eventStates[rule] = nil end
    end
    ns._Aura.unreadableBaselines[spellID] = nil
end

function ns._Aura.logDedupe(rule, spellID, sourceEvent, reason)
    if ns.AuraSoundFallback then
        ns.AuraSoundFallback.Log("AURA-DEDUPE", string.format("rule=%s aura=%s source=%s reason=%s combat=%s",
            tostring(rule and rule.id or "?"), tostring(spellID), tostring(sourceEvent or "?"), tostring(reason),
            tostring(InCombatLockdown and InCombatLockdown() or false)))
    end
end

function ns._Aura.consumeRead(spellID, sourceEvent)
    if not sourceEvent then return end
    for rule, states in pairs(ns._Aura.eventStates) do
        local state = states[spellID]
        if state and state.pendingAuraRead then
            state.pendingAuraRead = nil
            state.auraObserved = true
            ns._Aura.logDedupe(rule, spellID, sourceEvent, "cast-before-aura")
        end
    end
end

function ns._Aura.shouldAnnounceApply(rule, spellID, sourceEvent, castGUID)
    local state = ns._Aura.getEventState(rule, spellID)
    local now = GetTime and GetTime() or 0
    if sourceEvent == "UNIT_SPELLCAST_SUCCEEDED" then
        if castGUID and state.lastCastGUID == castGUID then
            ns._Aura.logDedupe(rule, spellID, sourceEvent, "duplicate-cast")
            return false
        end
        if not castGUID and state.lastCastAt and now - state.lastCastAt <= 0.1 then
            ns._Aura.logDedupe(rule, spellID, sourceEvent, "duplicate-cast-window")
            return false
        end
        if state.lastAuraAt and now - state.lastAuraAt <= 0.3 then
            state.lastCastGUID = castGUID
            state.lastCastAt = now
            ns._Aura.logDedupe(rule, spellID, sourceEvent, "aura-before-cast")
            return false
        end
        state.lastCastGUID = castGUID
        state.lastCastAt = now
        state.pendingAuraRead = true
        return true
    end

    if sourceEvent ~= "BASELINE_SYNC" then state.lastAuraAt = now end
    if state.pendingAuraRead then
        state.pendingAuraRead = nil
        state.auraObserved = true
        ns._Aura.logDedupe(rule, spellID, sourceEvent, "cast-before-aura")
        return false
    end
    if ns._Aura.unreadableBaselines[spellID] then
        state.auraObserved = true
        state.lastAuraAt = nil
        ns._Aura.logDedupe(rule, spellID, sourceEvent, "late-readable-baseline")
        return false
    end
    state.applyAnnounced = true
    state.auraObserved = true
    return true
end

local function sayAura(spellID, eventKind, sourceEvent, castGUID, targetRule)
    for _, rule in ipairs(WoWraVoxDB.auras) do
        if (not targetRule or targetRule == rule) and rule.enabled
            and ns.Profiles.RuleMatchesCurrentSpecialization(rule) then
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
                local soundEnabled
                if eventKind == "apply" then soundEnabled = rule.applySoundEnabled
                else soundEnabled = rule.expireSoundEnabled end
                if enabled or soundEnabled or (profile and profile.enabled) then
                    if eventKind ~= "apply" or ns._Aura.shouldAnnounceApply(rule, spellID, sourceEvent, castGUID) then
                        notifyRule(rule, eventKind, enabled and message or "", spellID, sourceEvent, eventKind)
                    end
                end
            end
        end
    end
end

local function rebuildAuraWatches()
    wipe(auraWatchBySpellID)
    for _, rule in ipairs(WoWraVoxDB.auras) do
        local applyScreen = ns.getRuleScreenProfile(rule, "apply")
        local expireScreen = ns.getRuleScreenProfile(rule, "expire")
        if rule.enabled and ns.Profiles.RuleMatchesCurrentSpecialization(rule)
            and (rule.applyEnabled or rule.expireEnabled or rule.applySoundEnabled or rule.expireSoundEnabled
            or rule.alertCategory ~= "none" or applyScreen.enabled or expireScreen.enabled) then
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
    for rule, states in pairs(ns._Aura.eventStates) do
        local applyScreen = ns.getRuleScreenProfile(rule, "apply")
        local expireScreen = ns.getRuleScreenProfile(rule, "expire")
        local ruleActive = rule.enabled and ns.Profiles.RuleMatchesCurrentSpecialization(rule)
            and (rule.applyEnabled or rule.expireEnabled or rule.applySoundEnabled or rule.expireSoundEnabled
            or rule.alertCategory ~= "none" or applyScreen.enabled or expireScreen.enabled)
        if not ruleActive then
            ns._Aura.eventStates[rule] = nil
        else
            for spellID in pairs(states) do
                local configured = false
                for _, configuredID in ipairs(rule.spellIDs or {}) do
                    if configuredID == spellID then configured = true; break end
                end
                if not configured or not auraWatchBySpellID[spellID] then states[spellID] = nil end
            end
            if not next(states) then ns._Aura.eventStates[rule] = nil end
        end
    end
    for spellID in pairs(ns._Aura.unreadableBaselines) do
        if not auraWatchBySpellID[spellID] then ns._Aura.unreadableBaselines[spellID] = nil end
    end
    if ns.AuraSoundFallback then ns.AuraSoundFallback.Refresh(WoWraVoxDB.auras) end
end

function ns._Aura.getSelfBuffStatus(spellID)
    if not isPublicNumber(spellID) or not (C_Spell and type(C_Spell.IsSelfBuff) == "function") then
        return "unavailable"
    end
    local ok, isSelfBuff = pcall(C_Spell.IsSelfBuff, spellID)
    if not ok or (type(issecretvalue) == "function" and issecretvalue(isSelfBuff))
        or type(isSelfBuff) ~= "boolean" then
        return "unavailable"
    end
    return isSelfBuff and "true" or "false"
end

function ns._Aura.safeCastGUID(castGUID)
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, castGUID)
        if not ok or secret == true then return "unavailable" end
    end
    if type(castGUID) ~= "string" or castGUID == "" then return "unavailable" end
    return castGUID
end

function ns._Aura.formatCastDebugMatches(matches)
    return #matches > 0 and table.concat(matches, ",") or "none"
end

function ns._Aura.logCastDiagnostic(castGUID, castSpellID, selfBuffStatus, identityMatches)
    if not (ns.AuraSoundFallback and ns.AuraSoundFallback.debugEnabled == true) then return end
    ns.AuraSoundFallback.Log("AURA-CAST", string.format("cast=%s guid=%s identity=%s selfbuff=%s",
        tostring(castSpellID), ns._Aura.safeCastGUID(castGUID), ns._Aura.formatCastDebugMatches(identityMatches),
        tostring(selfBuffStatus)))
end

-- In combat (secret auras) a self-only buff is announced from the player's own successful cast:
-- the tracked aura ID must equal the cast ID and C_Spell.IsSelfBuff(castID) must be true.
function ns._Aura.handleCast(unit, castGUID, castSpellID)
    if unit ~= "player" or not isPublicNumber(castSpellID) then return end
    if not ns._Aura.aurasAreSecret() then return end
    castGUID = ns._Aura.readableString(castGUID)
    local selfBuffStatus = ns._Aura.getSelfBuffStatus(castSpellID)
    local isSelfBuff = selfBuffStatus == "true"
    local identityMatches = {}
    for _, rule in ipairs(WoWraVoxDB and WoWraVoxDB.auras or {}) do
        if rule.enabled and ns.Profiles.RuleMatchesCurrentSpecialization(rule) then
            local announced = false
            for _, rawAuraID in ipairs(rule.spellIDs or {}) do
                local auraID = ns._Aura.validIntegerID(rawAuraID)
                if auraID == castSpellID and not announced then
                    announced = true
                    table.insert(identityMatches, tostring(rule.id or "?") .. ":" .. tostring(auraID))
                    if isSelfBuff then
                        sayAura(auraID, "apply", "UNIT_SPELLCAST_SUCCEEDED", castGUID, rule)
                    end
                end
            end
        end
    end
    ns._Aura.logCastDiagnostic(castGUID, castSpellID, selfBuffStatus, identityMatches)
end

local processAura
local function scheduleAuraExpiry(spellID, state, delay)
    state.timerGeneration = (state.timerGeneration or 0) + 1
    local generation = state.timerGeneration
    C_Timer.After(math.max(0.05, delay), function()
        if activeAuras[spellID] == state and state.timerGeneration == generation then
            processAura(spellID, false, "AURA_TIMER")
        end
    end)
end

processAura = function(spellID, isBaseline, sourceEvent)
    if not auraWatchBySpellID[spellID] then return end
    local aura, queryOK = getAura(spellID)
    local state = activeAuras[spellID]
    if not queryOK then
        -- Unreadable in a secret state: a later readable aura must not be spoken as new.
        if isBaseline or ns._Aura.aurasAreSecret() then ns._Aura.unreadableBaselines[spellID] = true end
        if ns.AuraSoundFallback then ns.AuraSoundFallback.LogAura(spellID, "aura-api-unavailable-or-secret", sourceEvent) end
        if state and state.expirationTime > 0 and GetTime() >= state.expirationTime - 0.25 then
            state.queryFailures = (state.queryFailures or 0) + 1
            if state.queryFailures <= 4 then scheduleAuraExpiry(spellID, state, 0.5) end
        end
        return
    end

    if aura then
        if ns.AuraSoundFallback then ns.AuraSoundFallback.LogAura(spellID, "aura-readable-present", sourceEvent) end
        local expirationTime, expirationOK = safeAuraField(aura, "expirationTime")
        local auraInstanceID, instanceOK = safeAuraField(aura, "auraInstanceID")
        if not expirationOK or not instanceOK then
            if isBaseline or ns._Aura.aurasAreSecret() then ns._Aura.unreadableBaselines[spellID] = true end
            if state and state.expirationTime > 0 and GetTime() >= state.expirationTime - 0.25 then
                state.queryFailures = (state.queryFailures or 0) + 1
                if state.queryFailures <= 4 then scheduleAuraExpiry(spellID, state, 0.5) end
            end
            return
        end
        if type(expirationTime) ~= "number" then expirationTime = 0 end

        local lateReadable = ns._Aura.unreadableBaselines[spellID] == true
        ns._Aura.unreadableBaselines[spellID] = nil
        if state then ns._Aura.consumeRead(spellID, sourceEvent) end
        if not state then
            state = { expirationTime = expirationTime, auraInstanceID = auraInstanceID }
            activeAuras[spellID] = state
            if auraInstanceID then auraByInstanceID[auraInstanceID] = spellID end
            if not isBaseline and auraBaselineComplete and not lateReadable then
                sayAura(spellID, "apply", sourceEvent)
            end
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

    -- aura == nil.  While auras are secret, "absent" is only trusted at the aura's
    -- known expiry moment; otherwise it is unknown and no state is touched.
    local now = GetTime()
    local atExpiry = state and state.expirationTime > 0
        and now >= state.expirationTime - 0.5 and now <= state.expirationTime + 3
    if not atExpiry and ns._Aura.aurasAreSecret() then
        if ns.AuraSoundFallback then ns.AuraSoundFallback.LogAura(spellID, "aura-absent-unknown-secret", sourceEvent) end
        return
    end
    ns._Aura.clearEventState(spellID)
    if state then
        if ns.AuraSoundFallback then ns.AuraSoundFallback.LogAura(spellID, "aura-readable-absent", sourceEvent) end
        activeAuras[spellID] = nil
        if state.auraInstanceID then auraByInstanceID[state.auraInstanceID] = nil end
        if atExpiry then
            sayAura(spellID, "expire", sourceEvent)
        end
    end
end

local function syncAllAuras(isBaseline)
    local profiling = ns.Prof.on
    local started = profiling and ns.Prof.clock()
    rebuildAuraWatches()
    for spellID in pairs(auraWatchBySpellID) do processAura(spellID, isBaseline, isBaseline and "BASELINE_SYNC" or "FULL_SYNC") end
    if isBaseline then auraBaselineComplete = true end
    if profiling then ns.Prof.add("syncAllAuras", ns.Prof.clock() - started) end
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

local function onUnitAuraUpdate(unit, updateInfo)
    if unit ~= "player" then return end
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
    for _, aura in ipairs(type(added) == "table" and added or ns._Aura.EMPTY) do
        local spellID, ok = safeAuraField(aura, "spellId")
        if ok and isPublicNumber(spellID) and auraWatchBySpellID[spellID] then
            affected[spellID] = true
        elseif not ok then
            queueAuraSync()
        end
    end
    for _, instanceID in ipairs(type(updated) == "table" and updated or ns._Aura.EMPTY) do
        local spellID = isPublicNumber(instanceID) and auraByInstanceID[instanceID]
        if spellID then affected[spellID] = true end
    end
    for _, instanceID in ipairs(type(removed) == "table" and removed or ns._Aura.EMPTY) do
        local spellID = isPublicNumber(instanceID) and auraByInstanceID[instanceID]
        if spellID then affected[spellID] = true end
    end

    local profiling = ns.Prof.on
    local started = profiling and ns.Prof.clock()
    for spellID in pairs(affected) do processAura(spellID, false, "UNIT_AURA") end
    if profiling then ns.Prof.add("processAura(UNIT_AURA)", ns.Prof.clock() - started) end
end

function ns.getEquippedItemID(slotID)
    if not GetInventoryItemID then return nil end
    local ok, itemID = pcall(GetInventoryItemID, "player", slotID)
    if ok and isPublicNumber(itemID) then return itemID end
    return nil
end

function ns.findEquippedItemSlot(itemID)
    for slotID = 1, 19 do
        if ns.getEquippedItemID(slotID) == itemID then return slotID end
    end
    return nil
end

-- Equipment slot IDs 1..19 -> suffix of Blizzard's localized global string (HEADSLOT, TRINKET0SLOT, ...).
ns.SLOT_STRING_KEYS = {
    "HEAD", "NECK", "SHOULDER", "SHIRT", "CHEST", "WAIST", "LEGS", "FEET", "WRIST", "HANDS",
    "FINGER0", "FINGER1", "TRINKET0", "TRINKET1", "BACK", "MAINHAND", "SECONDARYHAND", "RANGED", "TABARD",
}

function ns.slotName(slotID)
    if slotID == 13 then return L("Trinket 1") end
    if slotID == 14 then return L("Trinket 2") end
    local key = ns.SLOT_STRING_KEYS[slotID]
    local name = key and _G[key .. "SLOT"]
    if type(name) == "string" and name ~= "" then return name end
    return string.format(L("Slot %d"), tonumber(slotID) or 0)
end

function ns.slotDefaultMessage(slotID)
    return ns.slotName(slotID) .. " " .. L("ready")
end

-- itemSwapAt[rule] = time a slot rule last saw a different item: the cooldown running then is the
-- equip lockout of the new item, not a use, so it never ends in a Ready.
ns.itemSwapAt = setmetatable({}, { __mode = "k" })

function ns.readableCooldownNumber(value)
    return (not issecretvalue or not issecretvalue(value))
        and type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

function ns.readItemCooldownSource(source, callback)
    local ok, startTime, duration, enabled = pcall(callback)
    if not ok then return nil, "call-error" end
    if (issecretvalue and (issecretvalue(startTime) or issecretvalue(duration) or issecretvalue(enabled)))
        or not ns.readableCooldownNumber(startTime) or not ns.readableCooldownNumber(duration)
        or (type(enabled) ~= "boolean" and not ns.readableCooldownNumber(enabled)) then
        return nil, "unreadable"
    end
    return {
        source = source,
        startTime = startTime,
        duration = duration,
        enabled = enabled,
    }, nil
end

function ns.readEquippedItemCooldown(slotID, itemID)
    local reason
    if GetInventoryItemCooldown then
        local reading, readReason = ns.readItemCooldownSource("inventory", function()
            return GetInventoryItemCooldown("player", slotID)
        end)
        if reading then return reading end
        reason = readReason
    else
        reason = "api-unavailable"
    end

    if C_Item and C_Item.GetItemCooldown then
        local reading, readReason = ns.readItemCooldownSource("item", function()
            return C_Item.GetItemCooldown(itemID)
        end)
        if reading then return reading end
        reason = readReason or reason
    end
    return nil, reason or "api-unavailable"
end

function ns.logItemDecision(rule, event, reason, slotID, source)
    if not (ns.AuraSoundFallback and ns.AuraSoundFallback.debugEnabled == true) then return end
    local key = table.concat({ tostring(rule and rule.id or "?"), tostring(event), tostring(reason),
        tostring(slotID or "?"), tostring(source or "?") }, ":")
    local now = GetTime()
    if itemDebugDedupe[key] and now - itemDebugDedupe[key] < 1 then return end
    itemDebugDedupe[key] = now
    ns.AuraSoundFallback.Log("ITEM", string.format("rule=%s item=%s slot=%s event=%s source=%s reason=%s",
        tostring(rule and rule.id or "?"), tostring(rule and rule.itemID or "?"), tostring(slotID or "?"),
        tostring(event), tostring(source or "?"), tostring(reason)))
end

function ns.itemCooldownStateMatches(state, itemID, slotID, reading, cooldownEnd)
    return state and state.itemID == itemID and state.slotID == slotID
        and ns.readableCooldownNumber(state.cycleStart)
        and math.abs(state.cycleStart - reading.startTime) <= 0.25
        and ns.readableCooldownNumber(state.cooldownEnd)
        and math.abs(state.cooldownEnd - cooldownEnd) <= 0.25
end

function ns.scheduleItemReady(rule, state)
    if state.timerEnd == state.cooldownEnd then return end
    state.timerEnd = state.cooldownEnd
    local expectedEnd = state.cooldownEnd
    C_Timer.After(math.max(0.1, expectedEnd - GetTime() + 0.1), function()
        if itemCooldownStates[rule] == state and state.cooldownEnd == expectedEnd then
            state.timerEnd = nil
            ns.checkItemRule(rule)
        end
    end)
end

ns.checkItemRule = function(rule)
    if not rule.enabled or not ns.Profiles.RuleMatchesCurrentSpecialization(rule)
        or (not rule.slotID and rule.itemID <= 0) then
        if itemCooldownStates[rule] then ns.logItemDecision(rule, "check", "inactive") end
        itemCooldownStates[rule] = nil
        return
    end
    local slotID, itemID = rule.slotID, rule.itemID
    if slotID then
        -- Slot rule: whatever is equipped there now is the item to watch.
        itemID = ns.getEquippedItemID(slotID)
        if not itemID then
            if itemCooldownStates[rule] then ns.logItemDecision(rule, "check", "slot-empty", slotID) end
            itemCooldownStates[rule] = nil
            return
        end
        if itemID ~= rule.itemID then
            ns.followSlotItem(rule, itemID, slotID)
            ns.logItemDecision(rule, "check", "slot-item-changed", slotID)
        end
    else
        slotID = ns.findEquippedItemSlot(itemID)
        if not slotID then
            if itemCooldownStates[rule] then ns.logItemDecision(rule, "check", "not-equipped") end
            itemCooldownStates[rule] = nil
            return
        end
    end

    local reading, readReason = ns.readEquippedItemCooldown(slotID, itemID)
    local state = itemCooldownStates[rule]
    if not reading then
        ns.logItemDecision(rule, "check", "unreadable-" .. tostring(readReason), slotID)
        return
    end

    local now = GetTime()
    if reading.enabled ~= true and reading.enabled ~= 1 then
        ns.logItemDecision(rule, "check", "cooldown-disabled", slotID, reading.source)
        return
    end
    local cooldownEnd = reading.startTime + reading.duration
    local active = reading.duration > 0 and reading.startTime > 0 and cooldownEnd > now
    if active then
        if not ns.itemCooldownStateMatches(state, itemID, slotID, reading, cooldownEnd) then
            local swapAt = rule.slotID and ns.itemSwapAt[rule]
            state = {
                itemID = itemID,
                slotID = slotID,
                cycleStart = reading.startTime,
                cooldownEnd = cooldownEnd,
                source = reading.source,
                -- Equip lockout of a just-swapped item: watched, but never announced.
                notified = swapAt ~= nil and reading.startTime <= swapAt + 2,
            }
            itemCooldownStates[rule] = state
            ns.logItemDecision(rule, "active", "cycle-start", slotID, reading.source)
        else
            state.source = reading.source
        end
        ns.scheduleItemReady(rule, state)
        return
    end

    if not state then
        ns.logItemDecision(rule, "ready", "baseline", slotID, reading.source)
        return
    end
    if state.itemID ~= itemID or state.slotID ~= slotID then
        itemCooldownStates[rule] = nil
        ns.logItemDecision(rule, "ready", "identity-changed", slotID, reading.source)
        return
    end
    if state.notified then
        ns.logItemDecision(rule, "ready", "duplicate", slotID, reading.source)
        itemCooldownStates[rule] = nil
        return
    end
    state.notified = true
    ns.logItemDecision(rule, "ready", "confirmed", slotID, reading.source)
    notifyRule(rule, "ready", rule.message, nil, "ITEM_COOLDOWN_DONE", "offCooldown")
    itemCooldownStates[rule] = nil
end

function ns.scanItemRules()
    itemScanPending = false
    local profiling = ns.Prof.on
    local started = profiling and ns.Prof.clock()
    for _, rule in ipairs(WoWraVoxDB.items) do ns.checkItemRule(rule) end
    if profiling then ns.Prof.add("scanItemRules", ns.Prof.clock() - started) end
end

function ns.queueItemScan(delay)
    if itemScanPending then return end
    itemScanPending = true
    C_Timer.After(delay or 0.1, ns.scanItemRules)
end

-- Points an existing item rule at another equipped item.  The message follows the item only while
-- it is still the generated "<name> ready" default (or the rule is an unfilled starter); the
-- cooldown cycle is dropped so the next scan restarts silently for the new item.
-- slotID (optional) switches the rule to slot mode (it then tracks whatever sits in that slot);
-- nil switches it back to following this exact item.
function ns.retargetItemRule(rule, itemID, name, icon, slotID)
    local generated = (rule.name or L("Item")) .. " " .. L("ready")
    local followsItem = rule.starter ~= nil or rule.message == generated
        or (rule.slotID ~= nil and rule.message == ns.slotDefaultMessage(rule.slotID))
    rule.itemID = itemID
    rule.name = name
    rule.icon = icon
    rule.slotID = slotID
    rule.starter = nil
    if followsItem then
        rule.message = slotID and ns.slotDefaultMessage(slotID) or ((name or L("Item")) .. " " .. L("ready"))
    end
    itemCooldownStates[rule] = nil
end

local function scanSkillRules(event)
    local profiling = ns.Prof.on
    local started = profiling and ns.Prof.clock()
    ns.SkillTracking.Scan(WoWraVoxDB and WoWraVoxDB.skills, event)
    if profiling then ns.Prof.add("scanSkillRules", ns.Prof.clock() - started) end
end

ns.SkillTracking.Configure(
    function(rule) return ns.Profiles and ns.Profiles.RuleMatchesCurrentSpecialization(rule) end,
    function(rule, cause, sourceEvent)
        notifyRule(rule, "ready", rule.message, rule.spellID, sourceEvent, cause)
    end,
    L,
    function(spellID, name) if ns.AddLearnedAuraRule then ns.AddLearnedAuraRule(spellID, name) end end,
    function(rule, triggerType) if ns.ApplyLearnedTrigger then ns.ApplyLearnedTrigger(rule, triggerType) end end
)

function ns.RefreshRuleActivationState()
    if not WoWraVoxDB then return end
    activeAuras = {}
    auraByInstanceID = {}
    ns._Aura.resetEventState()
    wipe(itemCooldownStates)
    ns.SkillTracking.ResetAll()
    auraBaselineComplete = false
    syncAllAuras(true)
    ns.queueItemScan(0.2)
    scanSkillRules()
    if optionsFrame and optionsFrame:IsShown() then
        refreshList()
        updateDetails()
    end
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

-- A slot rule saw another item in its slot: follow it (icon always, name while it was the old item's
-- name), drop the cooldown cycle so the next scan restarts silently, and remember the swap time.
-- Custom messages are kept; the generated "<slot> ready" default is slot-based and needs no change.
function ns.followSlotItem(rule, itemID, slotID)
    local oldName = getItemInfo(rule.itemID)
    local name, icon = getItemInfo(itemID, slotID)
    if rule.name == oldName or rule.name == nil then rule.name = name end
    rule.icon = icon or rule.icon
    rule.itemID = itemID
    itemCooldownStates[rule] = nil
    ns.itemSwapAt[rule] = GetTime()
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
    local canSpeak = C_VoiceChat ~= nil and C_VoiceChat.SpeakText ~= nil
    testApplyButton:SetEnabled(canSpeak == true and trim(ns.formatRuleNotificationMessage(selectedAuraRule, applyMessageBox:GetText())) ~= "")
    testExpireButton:SetEnabled(canSpeak == true and trim(ns.formatRuleNotificationMessage(selectedAuraRule, expireMessageBox:GetText())) ~= "")
    local choosingStarterItem = selectedCategory == "items" and selectedItemRule
        and selectedItemRule.starter == "trinket" and (tonumber(selectedItemRule.itemID) or 0) <= 0
    local readyRule = selectedItemRule or selectedSkillRule
    testItemButton:SetEnabled(choosingStarterItem == true or (canSpeak == true and readyRule ~= nil
        and trim(ns.formatRuleNotificationMessage(readyRule, readyMessageBox:GetText())) ~= ""))
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
    if panel.SetBackdrop then
        panel:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        panel:SetBackdropColor(r, g, b, 0.97)
        panel:SetBackdropBorderColor(0.52, 0.41, 0.2, 1)
    end
    panel.bg = panel:CreateTexture(nil, "BACKGROUND")
    panel.bg:SetAllPoints()
    panel.bg:SetColorTexture(r, g, b, 1)
    if not panel.texture then
        panel.texture = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
        panel.texture:SetAllPoints()
        panel.texture:SetTexture("Interface\\FrameGeneral\\UI-Background-Marble")
        panel.texture:SetAlpha(0.12)
    end
    panel.corners = panel.corners or {}
    local cornerSize = 6
    for index, point in ipairs({ "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }) do
        local corner = panel.corners[index]
        if not corner then
            corner = panel:CreateTexture(nil, "BORDER")
            panel.corners[index] = corner
        end
        corner:SetTexture("Interface\\Buttons\\WHITE8X8")
        corner:SetSize(cornerSize, cornerSize)
        corner:ClearAllPoints()
        corner:SetPoint(point, panel, point, 0, 0)
        corner:SetColorTexture(0.88, 0.68, 0.24, 0.95)
    end
    local borderColor = { 0.35, 0.29, 0.18, 0.78 }
    for _, edge in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local line = panel:CreateTexture(nil, "BORDER")
        if edge == "TOP" or edge == "BOTTOM" then
            line:SetTexture("Interface\\Buttons\\WHITE8X8")
            line:SetColorTexture(unpack(borderColor))
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

local function makeVolumeSlider(parent, point, relativeTo, x, y, onChange, minValue, maxValue, valueStep, width)
    local slider = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
    slider:SetPoint(point, relativeTo, point, x, y)
    slider:SetSize(width or 150, 18)
    slider:SetMinMaxValues(minValue or 0, maxValue or 100)
    slider:SetValueStep(valueStep or 5)
    slider:SetObeyStepOnDrag(true)
    slider:SetScript("OnValueChanged", function(self, value)
        if editorLoading then return end
        local snappedValue = valueStep and (minValue or 0) + math.floor((value - (minValue or 0)) / valueStep + 0.5) * valueStep
            or math.floor(value + 0.5)
        onChange(math.max(minValue or 0, math.min(maxValue or 100, snappedValue)))
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
    if ns.SkillTracking.learning and ns.SkillTracking.learning.rule ~= rule then
        ns.SkillTracking.CancelLearning(L("Rule selection changed."), true)
    end
    ns.Layout.clampEditorScroll(0)
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
    if ns.SkillTracking.learning and ns.SkillTracking.learning.rule == selected then
        ns.SkillTracking.CancelLearning(L("The learned spell rule was removed."), true)
    end
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
        ns.SkillTracking.ResetRule(selected)
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

if StaticPopupDialogs then
    StaticPopupDialogs["WOWRAVOX_DELETE_RULE"] = {
        text = "%s",
        button1 = YES,
        button2 = NO,
        OnAccept = function(dialog, data)
            data = data or (dialog and dialog.data)
            if type(data) ~= "table" or not WoWraVoxDB then return end
            for _, rule in ipairs(WoWraVoxDB[data.category] or {}) do
                if rule == data.rule then
                    selectRule(data.rule, data.category)
                    removeSelectedRule()
                    return
                end
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

function ns.AddLearnedAuraRule(spellID, name)
    if not (WoWraVoxDB and type(WoWraVoxDB.auras) == "table" and tonumber(spellID)) then return end
    ns.SkillTracking.CancelLearning(nil, true)
    local rule = newAuraRule()
    rule.name = type(name) == "string" and name ~= "" and name or ("Spell " .. tostring(spellID))
    rule.spellIDs = { tonumber(spellID) }
    ns.registerNewRule(rule, "auras")
    table.insert(WoWraVoxDB.auras, rule)
    selectedCategory, selectedAuraRule = "auras", rule
    addRuleMode = false
    rebuildAuraWatches()
    syncAllAuras(true)
    refreshList()
    updateDetails()
    if optionsFrame then optionsFrame:Show() end
    setStatus(L("Learned aura rule created."))
end

function ns.ApplyLearnedTrigger(rule, triggerType)
    if not (rule and triggerType) then return end
    local valid = false
    for _, choice in ipairs(ns.SkillTracking.triggerTypes) do
        if choice.value == triggerType then valid = true; break end
    end
    if not valid then return end
    rule.triggerType = triggerType
    ns.SkillTracking.ResetRule(rule)
    if selectedSkillRule == rule and selectedCategory == "skills" then
        local label = ns.SkillTracking.GetTriggerLabel and ns.SkillTracking.GetTriggerLabel(triggerType)
        if auraEditor and auraEditor.skillTriggerDropdown and label then
            UIDropDownMenu_SetSelectedValue(auraEditor.skillTriggerDropdown, triggerType)
            UIDropDownMenu_SetText(auraEditor.skillTriggerDropdown, L(label))
            auraEditor.skillLearningStatus:SetText(L(ns.SkillTracking.GetTriggerDescription(triggerType)))
        end
        scanSkillRules()
        ns.updateRulePreviewFromEditor()
    end
    setStatus(L("Spell trigger updated from learning."))
end

function refreshList()
    if not (listScroll and listChild and WoWraVoxDB) then return end
    local rules = {}
    for _, rule in ipairs(WoWraVoxDB.auras) do table.insert(rules, { rule = rule, category = "auras" }) end
    for _, rule in ipairs(WoWraVoxDB.items) do table.insert(rules, { rule = rule, category = "items" }) end
    for _, rule in ipairs(WoWraVoxDB.skills) do table.insert(rules, { rule = rule, category = "skills" }) end
    local width = math.max(180, listChild:GetWidth() - 6)
    local rowHeight = 72

    local activeRules, inactiveRules = {}, {}
    local currentSpecID = ns.Profiles.GetCurrentSpecialization()
    for _, entry in ipairs(rules) do
        entry.specMatches = ns.Profiles.RuleMatchesCurrentSpecialization(entry.rule, currentSpecID)
        if entry.rule.enabled and entry.specMatches then
            table.insert(activeRules, entry)
        else
            table.insert(inactiveRules, entry)
        end
    end

    ns.listSectionHeaders = ns.listSectionHeaders or {}
    local ordered = {}
    if #rules > 0 then
        table.insert(ordered, { section = "Active", count = #activeRules })
        if not ns.listSectionCollapsed.Active then
            for _, entry in ipairs(activeRules) do table.insert(ordered, entry) end
        end
        table.insert(ordered, { section = "Inactive", count = #inactiveRules })
        if not ns.listSectionCollapsed.Inactive then
            for _, entry in ipairs(inactiveRules) do table.insert(ordered, entry) end
        end
        for _, section in ipairs({ "Active", "Inactive" }) do
            if not ns.listSectionHeaders[section] then
                local header = CreateFrame("Button", nil, listChild)
                header:SetHeight(22)
                header:RegisterForClicks("LeftButtonUp")
                header.arrow = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                header.arrow:SetSize(14, 18)
                header.arrow:SetPoint("RIGHT", header, "RIGHT", -2, 0)
                header.arrow:SetJustifyH("CENTER")
                header.arrow:SetTextColor(1, 0.82, 0.2)
                header.label = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                header.label:SetPoint("LEFT", header, "LEFT", 0, 0)
                header.label:SetPoint("RIGHT", header.arrow, "LEFT", -4, 0)
                header.label:SetJustifyH("LEFT")
                header.label:SetTextColor(1, 0.82, 0.2)
                header:SetScript("OnClick", function(self)
                    local key = self.section
                    ns.listSectionCollapsed[key] = not ns.listSectionCollapsed[key]
                    refreshList()
                end)
                ns.listSectionHeaders[section] = header
            end
            ns.listSectionHeaders[section].section = section
        end
    else
        for _, header in pairs(ns.listSectionHeaders) do header:Hide() end
    end

    local position, rowIndex = 4, 0
    for _, entry in ipairs(ordered) do
        if entry.section then
            local header = ns.listSectionHeaders[entry.section]
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", listChild, "TOPLEFT", 9, -position)
            header:SetWidth(width - 12)
            header.label:SetText(string.format(L(entry.section .. " (%d)"), entry.count))
            header.arrow:SetText(ns.listSectionCollapsed[entry.section] and ">" or "^")
            header:Show()
            position = position + 22
        else
        rowIndex = rowIndex + 1
        local index = rowIndex
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
            -- Scripts read self.rule/self.category, so they are set once per row frame.
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
                    ns.queueItemScan(0.1)
                else
                    ns.SkillTracking.ResetRule(target)
                    scanSkillRules()
                end
                refreshList()
                updateDetails()
            end)
            row.remove:SetScript("OnClick", function(self)
                local parent = self:GetParent()
                selectRule(parent.rule, parent.category)
                StaticPopup_Show("WOWRAVOX_DELETE_RULE", string.format(L("Delete rule \"%s\"?"), ruleDisplay(parent.rule, parent.category)),
                    nil, { rule = parent.rule, category = parent.category })
            end)
            listRows[index] = row
        end

        row.rule, row.category = rule, category
        row:SetWidth(width)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", listChild, "TOPLEFT", 6, -position)
        position = position + rowHeight + 8
        local selected = (selectedCategory == category)
            and ((category == "auras" and selectedAuraRule == rule)
                or (category == "items" and selectedItemRule == rule)
                or (category == "skills" and selectedSkillRule == rule))
        local active = rule.enabled and entry.specMatches
        local muted = not active
        if selected then
            row.bg:SetColorTexture(0.31, 0.23, 0.10, 0.95)
            row:SetBackdropColor(0.31, 0.23, 0.10, 0.95)
            row:SetBackdropBorderColor(0.72, 0.55, 0.22, 1)
            row.bottomEdge:SetColorTexture(0.72, 0.55, 0.22, 1)
        elseif muted then
            row.bg:SetColorTexture(0.075, 0.075, 0.08, 0.95)
            row:SetBackdropColor(0.075, 0.075, 0.08, 0.95)
            row:SetBackdropBorderColor(0.18, 0.19, 0.22, 1)
            row.bottomEdge:SetColorTexture(0.18, 0.19, 0.22, 1)
        else
            row.bg:SetColorTexture(0.125, 0.125, 0.13, 1)
            row:SetBackdropColor(0.125, 0.125, 0.13, 1)
            row:SetBackdropBorderColor(0.22, 0.24, 0.28, 1)
            row.bottomEdge:SetColorTexture(0.22, 0.24, 0.28, 1)
        end
        row.icon:SetDesaturated(muted)
        row.icon:SetAlpha(muted and 0.48 or 1)
        row.title:SetTextColor(muted and 0.43 or 1, muted and 0.43 or 1, muted and 0.43 or 1)
        row.sub:SetTextColor(muted and 0.55 or 1, muted and 0.55 or 0.82, muted and 0.55 or 0.2)
        row.toggle:SetAlpha(muted and 0.72 or 1)
        row.remove:SetAlpha(muted and 0.5 or 1)
        local inactiveReason = not rule.enabled and "Disabled"
            or (not entry.specMatches and (currentSpecID and "Other specialization" or "Specialization unavailable"))
        if category == "auras" then
            local info = rule.spellIDs[1] and getSpellInfo(rule.spellIDs[1])
            row.icon:SetTexture(info and info.iconID or "Interface\\Icons\\INV_Misc_QuestionMark")
            local triggerText = (rule.applyEnabled and L("Apply") or "")
            if rule.expireEnabled then triggerText = triggerText .. (triggerText ~= "" and " · " or "") .. L("Expire") end
            row.sub:SetText(#rule.spellIDs .. " " .. L("triggers") .. " · " .. (triggerText ~= "" and triggerText or L("No trigger"))
                .. (inactiveReason and (" · " .. L(inactiveReason)) or ""))
        elseif category == "items" then
            row.icon:SetTexture(rule.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            if rule.starter == "trinket" and rule.itemID <= 0 then
                row.sub:SetText(L("Choose an equipped item") .. (inactiveReason and (" · " .. L(inactiveReason)) or ""))
            else
                row.sub:SetText((rule.slotID and ns.slotName(rule.slotID) or ("Item " .. tostring(rule.itemID))) .. " · " .. L("Ready")
                    .. (inactiveReason and (" · " .. L(inactiveReason)) or ""))
            end
        else
            local info = rule.spellID and getSpellInfo(rule.spellID)
            row.icon:SetTexture(rule.icon or (info and info.iconID) or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.sub:SetText("Spell ID " .. tostring(rule.spellID) .. " · " .. L("Ready")
                .. (inactiveReason and (" · " .. L(inactiveReason)) or ""))
        end
        row.title:SetText(ruleDisplay(rule, category))
        row.toggle:SetChecked(rule.enabled)
        row:Show()
        end
    end

    for index = rowIndex + 1, #listRows do listRows[index]:Hide() end
    listChild:SetHeight(math.max(1, position + 4))
    if listEmptyText then
        listEmptyText:SetText(L("No rules yet. Use + to add an aura group or item."))
        listEmptyText:SetShown(#rules == 0)
    end
end

-- The list scroll frame's OnSizeChanged can fire several times while the window is laid out:
-- coalesce them into one refreshList per 0.05 s. All other callers keep the synchronous refreshList().
ns.Layout.requestRefreshList = function()
    if ns.Layout.refreshListPending then return end
    ns.Layout.refreshListPending = true
    C_Timer.After(0.05, function()
        ns.Layout.refreshListPending = false
        refreshList()
    end)
end

ns.Layout.notificationPanelHasEnabledChannel = function(panel)
    local ttsChecked = panel.ttsEnabled:GetChecked()
    local soundChecked = panel.soundEnabled:GetChecked()
    local screenChecked = panel.screen.enabled:GetChecked()
    return (ttsChecked == true or ttsChecked == 1)
        or (soundChecked == true or soundChecked == 1)
        or (screenChecked == true or screenChecked == 1)
end

-- Heading affordance of a collapsible panel: minus/plus chevron on the left, grey hint on the right.
ns.Layout.refreshPanelHeader = function(panel)
    if not panel.headerIndicator then return end
    local expanded = panel.expanded ~= false
    panel.headerIndicator:SetTexture(expanded and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
    panel.headerHint:SetText(L(expanded and "Click to collapse" or "Click to expand"))
end

ns.Layout.ensureExpirationPanelState = function(panel, rule)
    if panel.eventKey ~= "expire" then
        panel.expanded = true
        return true
    end
    if rule and ns.Layout.expirationPanelState[rule] == nil then
        ns.Layout.expirationPanelState[rule] = ns.Layout.notificationPanelHasEnabledChannel(panel)
    end
    panel.expanded = not rule or ns.Layout.expirationPanelState[rule] ~= false
    ns.Layout.refreshPanelHeader(panel)
    return panel.expanded
end

ns.Layout.setExpirationPanelExpanded = function(panel, expanded)
    if not panel or panel.eventKey ~= "expire" then return end
    panel.expanded = expanded ~= false
    if selectedCategory == "auras" and selectedAuraRule then
        ns.Layout.expirationPanelState[selectedAuraRule] = panel.expanded
    end
    ns.Layout.refreshPanelHeader(panel)
end

ns.Layout.isNotificationPanelExpanded = function(panel)
    return panel.eventKey ~= "expire" or panel.expanded ~= false
end

local function layoutScreenRow(row, parent, y)
    if not row then return end
    local cols = ns.Layout.getColumns(math.max(1, auraEditor:GetWidth()))
    row.enabled:ClearAllPoints()
    row.enabled:SetPoint("TOPLEFT", parent, "TOPLEFT", ns.Layout.ROW_X, y)
    row.text:ClearAllPoints()
    row.text:SetHeight(30)
    row.text:SetPoint("TOPLEFT", parent, "TOPLEFT", ns.Layout.FIELD_X, y + 1)
    row.preview:ClearAllPoints()
    row.preview:SetPoint("TOPRIGHT", parent, "TOPRIGHT", ns.Layout.RIGHT, y + 1)
    row.preview:SetSize(ns.Layout.BUTTON_W, 30)
    row.text:SetPoint("RIGHT", row.preview, "LEFT", -8, 0)
    row.label:ClearAllPoints()
    -- Second line: swatch (left of column 1, moves no dropdown line) | Font | Size | Style | Anchor button.
    -- The 32 px high dropdown frames are centred on the 26 px swatch, hence y - 33.
    row.color:ClearAllPoints()
    row.color:SetPoint("TOPLEFT", parent, "TOPLEFT", cols.swatch, y - 36)
    ns.Layout.placeDropdown(row.font, parent, cols.col1, y - 33, cols.col1Width)
    ns.Layout.placeDropdown(row.size, parent, cols.col2, y - 33, cols.sizeWidth)
    ns.Layout.placeDropdown(row.style, parent, cols.col3, y - 33, cols.styleWidth)
    row.anchor:ClearAllPoints()
    row.anchor:SetPoint("TOPRIGHT", parent, "TOPRIGHT", ns.Layout.RIGHT, y - 36)
    row.anchor:SetSize(ns.Layout.BUTTON_W, 30)
    row.label:SetPoint("LEFT", row.enabled, "RIGHT", 6, 0)
    row.label:SetWidth(150)
    row.label:SetJustifyH("LEFT")
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

local function layoutNotificationPanel(panel, y)
    local frame = panel.frame
    local frameWidth = math.max(1, auraEditor:GetWidth())
    local cols = ns.Layout.getColumns(frameWidth)
    local screenChecked = panel.screen.enabled:GetChecked()
    local screenEnabled = screenChecked == true or screenChecked == 1
    local screenY = -112
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 0, y)
    frame:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", 0, y)
    local lowestControl = math.max(43 + 30, 78 + 30, -screenY + 30)
    if screenEnabled then lowestControl = math.max(lowestControl, -screenY + 36 + 30) end
    frame:SetHeight(ns.Layout.isNotificationPanelExpanded(panel) and lowestControl + 10 or 34)
    panel.heading:ClearAllPoints()
    panel.heading:SetPoint("TOPLEFT", frame, "TOPLEFT", ns.Layout.PAD, -10)
    if panel.categoryChoice then
        panel.categoryChoice:ClearAllPoints()
        panel.categoryChoice:SetPoint("TOPRIGHT", frame, "TOPRIGHT", ns.Layout.RIGHT, -4)
        UIDropDownMenu_SetWidth(panel.categoryChoice, 142)
        panel.categoryLabel:ClearAllPoints()
        panel.categoryLabel:SetPoint("RIGHT", panel.categoryChoice, "LEFT", -8, 0)
    end
    panel.ttsEnabled:ClearAllPoints()
    panel.ttsEnabled:SetPoint("TOPLEFT", frame, "TOPLEFT", ns.Layout.ROW_X, -43)
    panel.ttsLabel:ClearAllPoints()
    panel.ttsLabel:SetPoint("LEFT", panel.ttsEnabled, "RIGHT", 6, 0)
    panel.ttsTest:ClearAllPoints()
    panel.ttsTest:SetPoint("TOPRIGHT", frame, "TOPRIGHT", ns.Layout.RIGHT, -42)
    panel.ttsTest:SetSize(ns.Layout.BUTTON_W, 30)
    panel.soundEnabled:ClearAllPoints()
    panel.soundEnabled:SetPoint("TOPLEFT", frame, "TOPLEFT", ns.Layout.ROW_X, -78)
    panel.soundLabel:ClearAllPoints()
    panel.soundLabel:SetPoint("LEFT", panel.soundEnabled, "RIGHT", 6, 0)
    panel.soundTest:ClearAllPoints()
    panel.soundTest:SetPoint("TOPRIGHT", frame, "TOPRIGHT", ns.Layout.RIGHT, -77)
    panel.soundTest:SetSize(ns.Layout.BUTTON_W, 30)
    layoutScreenRow(panel.screen, frame, screenY)
    panel.ttsMessage:ClearAllPoints()
    panel.ttsMessage:SetHeight(30)
    panel.ttsMessage:SetPoint("TOPLEFT", frame, "TOPLEFT", ns.Layout.FIELD_X, -42)
    panel.ttsMessage:SetPoint("RIGHT", panel.ttsTest, "LEFT", -8, 0)
    -- Sound row shares the dropdown columns of the screen row below (col1 = Font, col2 = Size); the last
    -- box (channel) ends at the right edge of the text boxes.
    ns.Layout.placeDropdown(panel.soundChoice, frame, cols.col1, -77, cols.col1Width)
    ns.Layout.placeDropdown(panel.soundChannel, frame, cols.col2, -77, cols.col2Width)
end

function ns.setNotificationPanelShown(panel, shown)
    if not panel then return end
    local expanded = ns.Layout.isNotificationPanelExpanded(panel)
    panel.frame:SetShown(shown)
    if panel.categoryChoice then
        panel.categoryChoice:SetShown(shown and expanded)
        panel.categoryLabel:SetShown(shown and expanded)
    end
    if panel.headerButton then panel.headerButton:SetShown(shown and panel.eventKey == "expire") end
    local ttsChecked = panel.ttsEnabled:GetChecked()
    local ttsDetails = shown and expanded and (ttsChecked == true or ttsChecked == 1)
    panel.ttsEnabled:SetShown(shown and expanded)
    panel.ttsLabel:SetShown(shown and expanded)
    panel.ttsMessage:SetShown(ttsDetails)
    local choosingStarterItem = panel.eventKey == "ready" and selectedCategory == "items"
        and selectedItemRule and selectedItemRule.starter == "trinket"
        and (tonumber(selectedItemRule.itemID) or 0) <= 0
    panel.ttsTest:SetShown(ttsDetails or (shown and expanded and choosingStarterItem))
    local soundChecked = panel.soundEnabled:GetChecked()
    local soundDetails = shown and expanded and (soundChecked == true or soundChecked == 1)
    panel.soundEnabled:SetShown(shown and expanded)
    panel.soundLabel:SetShown(shown and expanded)
    panel.soundChoice:SetShown(soundDetails)
    panel.soundChannel:SetShown(soundDetails)
    panel.soundTest:SetShown(soundDetails)
    showScreenRow(panel.screen, shown and expanded)
end

local function layoutSharedEditor(isAura)
    local editorWidth = math.max(1, auraEditor:GetWidth())
    local cols = ns.Layout.getColumns(editorWidth)
    local query = triggerInputBox and trim(triggerInputBox:GetText()) or ""
    local headerHeight = 116
    auraEditor.rulePanel:ClearAllPoints()
    auraEditor.rulePanel:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 0, 0)
    auraEditor.rulePanel:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", 0, 0)
    auraEditor.rulePanel:SetHeight(headerHeight)
    auraEditor.ruleIcon:ClearAllPoints()
    auraEditor.ruleIcon:SetSize(50, 50)
    auraEditor.ruleIcon:SetPoint("TOPLEFT", auraEditor.rulePanel, "TOPLEFT", ns.Layout.PAD, -55)
    ruleNameBox:ClearAllPoints()
    ruleNameBox:SetSize(444, 30)
    ruleNameBox:SetPoint("TOPLEFT", auraEditor.rulePanel, "TOPLEFT", 94, -58)
    ruleEnabledCheck:ClearAllPoints()
    ruleEnabledCheck:SetPoint("TOPLEFT", auraEditor.rulePanel, "TOPLEFT", 550, -48)
    ruleEnabledCheck:SetSize(30, 30)
    auraEditor.enabledLabel:ClearAllPoints()
    auraEditor.enabledLabel:SetPoint("LEFT", ruleEnabledCheck, "RIGHT", 4, 0)
    auraEditor.specFilter:ClearAllPoints()
    auraEditor.specFilter:SetPoint("TOPRIGHT", auraEditor.rulePanel, "TOPRIGHT", ns.Layout.RIGHT, -57)
    auraEditor.specFilterLabel:ClearAllPoints()
    auraEditor.specFilterLabel:SetPoint("RIGHT", auraEditor.specFilter, "LEFT", -6, 0)

    local triggerHeadingY = -headerHeight - 6
    triggerPanel:ClearAllPoints()
    triggerPanel:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 0, triggerHeadingY)
    triggerPanel:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", 0, triggerHeadingY)
    triggerPanel:SetHeight(226)
    triggerLabel:ClearAllPoints()
    triggerLabel:SetPoint("TOPLEFT", triggerPanel, "TOPLEFT", ns.Layout.PAD, -10)
    triggerInputBox:ClearAllPoints()
    triggerInputBox:SetPoint("TOPLEFT", triggerPanel, "TOPLEFT", ns.Layout.FIELD_X, -13)
    triggerInputBox:SetPoint("RIGHT", triggerAddButton, "LEFT", -8, 0)
    triggerInputBox:SetHeight(30)
    triggerInputBox:SetTextInsets(24, 6, 0, 0)
    triggerInputBox.searchIcon:ClearAllPoints()
    triggerInputBox.searchIcon:SetPoint("LEFT", triggerInputBox, "LEFT", 7, 0)
    triggerAddButton:ClearAllPoints()
    triggerAddButton:SetSize(ns.Layout.BUTTON_W, 30)
    triggerAddButton:SetPoint("TOPRIGHT", triggerPanel, "TOPRIGHT", ns.Layout.RIGHT, -13)
    triggerStatus:ClearAllPoints()
    triggerStatus:SetPoint("TOPLEFT", triggerPanel, "TOPLEFT", ns.Layout.PAD, -51)
    triggerStatus:SetPoint("RIGHT", triggerPanel, "RIGHT", ns.Layout.RIGHT, 0)
    triggerScroll:ClearAllPoints()
    triggerScroll:SetPoint("TOPLEFT", triggerPanel, "TOPLEFT", 10, -70)
    triggerScroll:SetPoint("BOTTOMRIGHT", triggerPanel, "BOTTOMRIGHT", -27, 8)
    triggerInputBox:SetShown(isAura)
    triggerPlaceholder:SetShown(isAura and query == "")
    triggerAddButton:SetShown(isAura)
    triggerStatus:SetShown(isAura)

    local firstMessageY = isAura and triggerHeadingY - triggerPanel:GetHeight() - 6 or -(headerHeight + 60)
    local isSkill = not isAura and selectedCategory == "skills"
    local messageY = firstMessageY - (isSkill and 24 or 0)
    local voiceY
    if isAura then
        auraEditor.skillTriggerLabel:Hide()
        auraEditor.skillTriggerDropdown:Hide()
        auraEditor.skillLearnButton:Hide()
        auraEditor.skillLearningStatus:Hide()
        auraEditor.notificationsHeading:Hide()
        ns.setNotificationPanelShown(ns.notificationPanels.ready, false)
        layoutNotificationPanel(ns.notificationPanels.apply, firstMessageY)
        local expireY = firstMessageY - ns.notificationPanels.apply.frame:GetHeight() - 6
        layoutNotificationPanel(ns.notificationPanels.expire, expireY)
        voiceY = expireY - ns.notificationPanels.expire.frame:GetHeight() - 6
    else
        auraEditor.notificationsHeading:Show()
        auraEditor.notificationsHeading:ClearAllPoints()
        auraEditor.notificationsHeading:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", ns.Layout.EXTRA_X, firstMessageY + 48)
        itemSourceText:ClearAllPoints()
        itemSourceText:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", ns.Layout.EXTRA_X, firstMessageY + 26)
        itemSourceText:SetWidth(190)
        auraEditor.slotTrackCheck:ClearAllPoints()
        auraEditor.slotTrackCheck:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 220, firstMessageY + 33)
        auraEditor.skillTriggerLabel:ClearAllPoints()
        auraEditor.skillTriggerLabel:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 220, firstMessageY + 25)
        auraEditor.skillTriggerDropdown:ClearAllPoints()
        auraEditor.skillTriggerDropdown:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 258, firstMessageY + 34)
        auraEditor.skillLearnButton:ClearAllPoints()
        auraEditor.skillLearnButton:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", ns.Layout.RIGHT, firstMessageY + 25)
        auraEditor.skillLearningStatus:ClearAllPoints()
        auraEditor.skillLearningStatus:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", ns.Layout.FIELD_X, firstMessageY - 2)
        auraEditor.skillLearningStatus:SetWidth(math.max(1, editorWidth - 247))
        auraEditor.skillTriggerLabel:SetShown(isSkill)
        auraEditor.skillTriggerDropdown:SetShown(isSkill)
        auraEditor.skillLearnButton:SetShown(isSkill)
        auraEditor.skillLearningStatus:SetShown(isSkill)
        ns.setNotificationPanelShown(ns.notificationPanels.apply, false)
        ns.setNotificationPanelShown(ns.notificationPanels.expire, false)
        ns.setNotificationPanelShown(ns.notificationPanels.ready, true)
        layoutNotificationPanel(ns.notificationPanels.ready, messageY)
        local rowBottom = -messageY + ns.notificationPanels.ready.frame:GetHeight()
        local viewportHeight = editorScroll and math.max(1, editorScroll:GetHeight()) or 620
        local voiceTop = math.max(rowBottom + 16, viewportHeight - 118 - 16)
        voiceY = -voiceTop
    end
    auraEditor.voicePanel:ClearAllPoints()
    auraEditor.voicePanel:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 0, voiceY)
    auraEditor.voicePanel:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", 0, voiceY)
    auraEditor.voicePanel:SetHeight(118)
    -- TTS panel on the same visible columns as the panels above: Voice = col1, Volume = col2, Speed = col3.
    auraEditor.voiceHeading:ClearAllPoints()
    auraEditor.voiceHeading:SetPoint("TOPLEFT", auraEditor.voicePanel, "TOPLEFT", ns.Layout.PAD, -8)
    auraEditor.voiceLabel:ClearAllPoints()
    auraEditor.voiceLabel:SetPoint("TOPLEFT", auraEditor.voicePanel, "TOPLEFT", cols.col1, -31)
    auraEditor.volumeLabel:ClearAllPoints()
    auraEditor.volumeLabel:SetPoint("TOPLEFT", auraEditor.voicePanel, "TOPLEFT", cols.col2, -31)
    auraEditor.speedLabel:ClearAllPoints()
    auraEditor.speedLabel:SetPoint("TOPLEFT", auraEditor.voicePanel, "TOPLEFT", cols.col3, -31)
    ns.Layout.placeDropdown(voiceDropdown, auraEditor.voicePanel, cols.col1, -43, cols.col1Width)
    volumeSlider:ClearAllPoints()
    volumeSlider:SetPoint("TOPLEFT", auraEditor.voicePanel, "TOPLEFT", cols.col2, -43)
    volumeSlider:SetWidth(cols.col3 - cols.col2 - ns.Layout.COL_GAP - ns.Layout.VALUE_W)
    auraEditor.speedSlider:ClearAllPoints()
    auraEditor.speedSlider:SetPoint("TOPLEFT", auraEditor.voicePanel, "TOPLEFT", cols.col3, -43)
    auraEditor.speedSlider:SetWidth(cols.right - cols.col3 - ns.Layout.VALUE_W)
    local viewportHeight = editorScroll and math.max(1, editorScroll:GetHeight()) or 620
    local contentHeight = -voiceY + auraEditor.voicePanel:GetHeight() + 16
    auraEditor.minimumContentHeight = isAura and math.max(620, contentHeight) or contentHeight
    auraEditor:SetHeight(math.max(auraEditor.minimumContentHeight, viewportHeight))
end

local function makeSectionLabel(parent, text, x, y, layoutLater)
    local label = createLabel(parent, text, "GameFontNormalLarge")
    if not layoutLater then label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y) end
    label:SetTextColor(1, 0.82, 0.2)
    return label
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

local function findRuleByID(ruleID)
    ruleID = trim(ruleID)
    if ruleID == "" or not WoWraVoxDB then return nil end
    for _, rules in ipairs({ WoWraVoxDB.auras, WoWraVoxDB.items, WoWraVoxDB.skills }) do
        for _, rule in ipairs(rules or {}) do
            if tostring(rule.id or "") == ruleID then return rule end
        end
    end
    return nil
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
    if count == 2 then
        name = name .. " or one other trigger"
    elseif count > 2 then
        name = name .. " or one of " .. (count - 1) .. " other triggers"
    end
    return name
end

local function buildPreviewLine(trigger, eventText, ttsEnabled, ttsMessage, soundEnabled, screenEnabled, screenText)
    local actions = {}
    if ttsEnabled and type(ttsMessage) == "string" and trim(ttsMessage) ~= "" then
        table.insert(actions, 'speak "' .. trim(ttsMessage) .. '"')
    end
    if soundEnabled then table.insert(actions, "play selected sound") end
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
        local apply = buildPreviewLine(trigger, "applies", values.applyEnabled,
            ns.formatRuleNotificationMessage(rule, values.applyMessage), values.applySoundEnabled,
            values.applyScreenEnabled, ns.formatRuleNotificationMessage(rule, values.applyScreenText))
        local expire = buildPreviewLine(trigger, "expires", values.expireEnabled,
            ns.formatRuleNotificationMessage(rule, values.expireMessage), values.expireSoundEnabled,
            values.expireScreenEnabled, ns.formatRuleNotificationMessage(rule, values.expireScreenText))
        if apply then table.insert(lines, apply) end
        if expire then table.insert(lines, expire) end
    else
        local eventText = "is ready"
        if category == "skills" then
            local eventByType = {
                offCooldown = "comes off cooldown",
                onCooldown = "goes on cooldown",
                chargeGained = "gains a charge",
                chargeSpent = "spends a charge",
                castSucceeded = "is cast successfully",
            }
            eventText = eventByType[rule.triggerType] or "comes off cooldown"
        end
        local ready = buildPreviewLine(trigger, L(eventText), values.readyEnabled ~= false,
            ns.formatRuleNotificationMessage(rule, values.message), values.readySoundEnabled,
            values.screenEnabled, ns.formatRuleNotificationMessage(rule, values.screenText))
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
            applySoundEnabled = ns.notificationPanels.apply.soundEnabled:GetChecked() == true
                or ns.notificationPanels.apply.soundEnabled:GetChecked() == 1,
            applyScreenEnabled = ns.screenControls.apply and (ns.screenControls.apply.enabled:GetChecked() == true or ns.screenControls.apply.enabled:GetChecked() == 1),
            applyScreenText = ns.screenControls.apply and ns.screenControls.apply.text:GetText() or "",
            expireEnabled = expireEnabledCheck:GetChecked() == true or expireEnabledCheck:GetChecked() == 1,
            expireMessage = expireMessageBox:GetText(),
            expireSoundEnabled = ns.notificationPanels.expire.soundEnabled:GetChecked() == true
                or ns.notificationPanels.expire.soundEnabled:GetChecked() == 1,
            expireScreenEnabled = ns.screenControls.expire and (ns.screenControls.expire.enabled:GetChecked() == true or ns.screenControls.expire.enabled:GetChecked() == 1),
            expireScreenText = ns.screenControls.expire and ns.screenControls.expire.text:GetText() or "",
        }
    else
        values = {
            readyEnabled = ns.notificationPanels.ready.ttsEnabled:GetChecked() == true
                or ns.notificationPanels.ready.ttsEnabled:GetChecked() == 1,
            message = readyMessageBox:GetText(),
            readySoundEnabled = ns.notificationPanels.ready.soundEnabled:GetChecked() == true
                or ns.notificationPanels.ready.soundEnabled:GetChecked() == 1,
            screenEnabled = ns.screenControls.ready and (ns.screenControls.ready.enabled:GetChecked() == true or ns.screenControls.ready.enabled:GetChecked() == 1),
            screenText = ns.screenControls.ready and ns.screenControls.ready.text:GetText() or "",
        }
    end
    detailPanel.rulePreviewText:SetText(buildRulePreview(rule, selectedCategory, values))
end
ns.updateRulePreviewFromEditor = updateRulePreviewFromEditor

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
                ns._Aura.clearEventState(parent.spellID)
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
    if count > 0 then summary = summary .. " · " .. string.format(L("%d valid"), validCount) end
    if pendingCount > 0 then summary = summary .. " · " .. string.format(L("%d loading"), pendingCount) end
    if invalidCount > 0 then summary = summary .. " · " .. string.format(L("%d invalid"), invalidCount) end
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

runTriggerSearch = function(expectedGeneration)
    if not (triggerInputBox and triggerAddButton and searchPopup and selectedAuraRule) then return end
    if expectedGeneration and expectedGeneration ~= searchGeneration then return end
    local query = trim(triggerInputBox:GetText())
    if query == "" then searchPopup:Hide(); return end
    local ids, isIDList = parseSpellIDs(query)
    local results, emptyText = {}, L("No matching spells.")
    local hasPending, exactNamePending = false, false
    local nameSearch = triggerAddButton.nameSearch
    local exactSearch = nameSearch and nameSearch.query == query and nameSearch.rule == selectedAuraRule
        and nameSearch.generation == searchGeneration
    local scan = ns.spellSearch.partial
    if not (scan and scan.query == query and scan.rule == selectedAuraRule
        and scan.generation == searchGeneration) then scan = nil end

    if isIDList and #ids > 0 then
        triggerAddButton:SetText(L("Add"))
        triggerAddButton:SetEnabled(true)
        if #ids > 1 then
            searchPopup:Hide()
            triggerStatus:SetText(L("Press Enter or Add to include these IDs."))
            triggerStatus:SetTextColor(0.72, 0.78, 0.86)
            return
        end
        results, hasPending = ns._Aura.searchAvailableSpells(query, nil, selectedAuraRule)
        if hasPending then emptyText = L("Checking spell data…") end
        triggerStatus:SetText(L("Press Enter or Add to include these IDs."))
        triggerStatus:SetTextColor(0.72, 0.78, 0.86)
    elseif query:find(",", 1, true) or tonumber(query) then
        searchPopup:Hide()
        triggerAddButton:SetText(L("Add"))
        triggerAddButton:SetEnabled(false)
        triggerStatus:SetText(L("Invalid ID list"))
        triggerStatus:SetTextColor(1, 0.35, 0.25)
        return
    else
        results, hasPending, exactNamePending = ns._Aura.searchAvailableSpells(
            query, exactSearch and nameSearch.id, selectedAuraRule)
        if exactSearch then nameSearch.pending = exactNamePending end
        local exactHit, exactCount
        for _, result in ipairs(results) do
            if result.name:lower() == query:lower() then
                exactHit = result
                exactCount = (exactCount or 0) + 1
            end
        end
        if exactHit and (exactHit.origin == "Game search" or (exactSearch and nameSearch.id)) then
            exactHit.confirmOnly = true
        end
        for _, result in ipairs(results) do
            if result.origin == "Game search" then result.confirmOnly = true end
        end
        local selectedResult = triggerAddButton.selectedSearchResult
        local selectedReady = selectedResult and selectedResult.query == query
            and selectedResult.rule == selectedAuraRule and selectedResult.generation == searchGeneration
        if not selectedReady then
            triggerAddButton.selectedSearchResult = nil
            selectedResult = nil
        end
        if exactHit and exactCount == 1 then
            triggerAddButton.exactResult = {
                query = query, rule = selectedAuraRule, generation = searchGeneration, id = exactHit.id,
            }
            triggerAddButton:SetText(L("Add"))
            triggerAddButton:SetEnabled(true)
            if scan and scan.running then scan.running = false end
        else
            triggerAddButton.exactResult = nil
            if scan and scan.running then
                triggerAddButton:SetText(L("Searching"))
                triggerAddButton:SetEnabled(false)
            elseif scan and scan.hasMore then
                triggerAddButton:SetText(L("Search more"))
                triggerAddButton:SetEnabled(true)
            else
                triggerAddButton:SetText(L("Search"))
                triggerAddButton:SetEnabled(#query >= 3 and not (scan and scan.unavailable))
            end
        end
        if selectedResult then
            triggerAddButton:SetText(L("Add"))
            triggerAddButton:SetEnabled(true)
        end
        if exactSearch and exactNamePending then
            emptyText = L("Checking spell data…")
        elseif scan and scan.unavailable then
            emptyText = L("Global spell search is unavailable. Try a Spell ID.")
        elseif scan and scan.running and #results == 0 then
            emptyText = string.format(L("Searching spell IDs… %d/%d"), scan.scanned or 0, ns.spellSearch.idsPerRequest)
        elseif scan and not scan.running and scan.hasMore and #results == 0 then
            emptyText = L("No matches in this range. Press Search more.")
        elseif hasPending then
            emptyText = L("Checking spell data…")
        end
    end

    local visible = math.min(#results, #searchRows, 6)
    for index, row in ipairs(searchRows) do
        local result = results[index]
        row.result = result
        if result and index <= 6 then
            if not result.icon and C_Spell and C_Spell.GetSpellTexture then
                local iconOK, iconValue = pcall(C_Spell.GetSpellTexture, result.id)
                if iconOK and (not issecretvalue or not issecretvalue(iconValue)) and type(iconValue) == "number" then
                    result.icon = iconValue
                end
            end
            row.icon:SetTexture(result.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.title:SetText(result.name)
            row.idText:SetText(tostring(result.id) .. " · " .. L(result.origin))
            local selected = triggerAddButton.selectedSearchResult
            row.selection:SetShown(selected and selected.id == result.id
                and selected.query == query and selected.rule == selectedAuraRule
                and selected.generation == searchGeneration or false)
            row:Show()
        else
            row.selection:Hide()
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
    elseif triggerAddButton.selectedSearchResult and triggerAddButton.selectedSearchResult.query == query
        and triggerAddButton.selectedSearchResult.rule == selectedAuraRule
        and triggerAddButton.selectedSearchResult.generation == searchGeneration then
        triggerStatus:SetText(L("Spell found. Press Add to include it."))
        triggerStatus:SetTextColor(0.72, 0.78, 0.86)
    elseif triggerAddButton.exactResult and triggerAddButton.exactResult.query == query
        and triggerAddButton.exactResult.rule == selectedAuraRule
        and triggerAddButton.exactResult.generation == searchGeneration then
        triggerStatus:SetText(L("Spell found. Press Add to include it."))
        triggerStatus:SetTextColor(0.72, 0.78, 0.86)
    elseif scan and scan.running then
        triggerStatus:SetText(string.format(L("Searching spell IDs… %d/%d"), scan.scanned or 0, ns.spellSearch.idsPerRequest))
        triggerStatus:SetTextColor(0.72, 0.78, 0.86)
    elseif scan and scan.hasMore then
        triggerStatus:SetText(string.format(L("%d matches. Press Search more."), #results))
        triggerStatus:SetTextColor(0.72, 0.78, 0.86)
    elseif exactSearch and exactNamePending then
        triggerStatus:SetText(L("Checking spell data…"))
        triggerStatus:SetTextColor(0.72, 0.78, 0.86)
    elseif hasPending then
        triggerStatus:SetText(L("Checking spell data…"))
        triggerStatus:SetTextColor(0.72, 0.78, 0.86)
    elseif visible > 0 then
        triggerStatus:SetText(string.format(L("%d matches"), #results))
        triggerStatus:SetTextColor(0.72, 0.78, 0.86)
    elseif scan and scan.unavailable then
        triggerStatus:SetText(L("Global spell search is unavailable. Try a Spell ID."))
        triggerStatus:SetTextColor(1, 0.72, 0.3)
    else
        triggerStatus:SetText(L("No matches. Try a spell ID."))
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
    searchPopup.empty = createLabel(searchPopup, "No matching spells.", "GameFontHighlightSmall")
    searchPopup.empty:SetPoint("CENTER")
    for index = 1, 6 do
        local row = CreateFrame("Button", nil, searchPopup)
        row:SetPoint("TOPLEFT", searchPopup, "TOPLEFT", 5, -4 - (index - 1) * 36)
        row:SetPoint("TOPRIGHT", searchPopup, "TOPRIGHT", -5, -4 - (index - 1) * 36)
        row:SetHeight(34)
        row.selection = row:CreateTexture(nil, "BACKGROUND")
        row.selection:SetAllPoints(row)
        row.selection:SetColorTexture(0.68, 0.43, 0.08, 0.28)
        row.selection:Hide()
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
        addHelpTooltip(row, "Add trigger", "Click local spell suggestions to add. Select game-search results, then press Add.")
        row:SetScript("OnClick", function(self)
            if not (self.result and selectedAura()) then return end
            if self.result.confirmOnly then
                triggerAddButton.selectedSearchResult = {
                    id = self.result.id, query = trim(triggerInputBox:GetText()),
                    rule = selectedAura(), generation = searchGeneration,
                }
                runTriggerSearch(searchGeneration)
                return
            end
            addTriggerIDs({ self.result.id })
        end)
        searchRows[index] = row
    end
    searchPopup:Hide()
end

local function saveNotificationPanel(panel, rule, eventKey)
    local checked = panel.ttsEnabled:GetChecked()
    if eventKey == "ready" then
        rule.readyEnabled = checked == true or checked == 1
        rule.message = panel.ttsMessage:GetText()
    else
        rule[eventKey .. "Enabled"] = checked == true or checked == 1
        rule[eventKey .. "Message"] = panel.ttsMessage:GetText()
    end
    checked = panel.soundEnabled:GetChecked()
    rule[eventKey .. "SoundEnabled"] = checked == true or checked == 1
    local soundSelection = panel.soundChoice.screenValue
    local mediaField = eventKey .. "SoundMediaName"
    if type(soundSelection) == "string" and soundSelection:sub(1, #NOTIFICATION_MEDIA_PREFIX) == NOTIFICATION_MEDIA_PREFIX then
        rule[mediaField] = soundSelection:sub(#NOTIFICATION_MEDIA_PREFIX + 1)
    else
        rule[mediaField] = nil
        rule[eventKey .. "SoundKitID"] = tonumber(soundSelection) or DEFAULT_NOTIFICATION_SOUND_KIT
    end
    local channel = panel.soundChannel.screenValue
    rule[eventKey .. "SoundChannel"] = NOTIFICATION_SOUND_CHANNEL_SET[channel] and channel or "Master"
    if panel.categoryChoice then rule.alertCategory = panel.categoryChoice.screenValue or "none" end
    saveScreenRowProfile(panel.screen, rule)
end

local function loadNotificationPanel(panel, rule, eventKey)
    panel.ttsEnabled:SetChecked(eventKey == "ready" and rule.readyEnabled ~= false or rule[eventKey .. "Enabled"])
    panel.ttsMessage:SetText(eventKey == "ready" and rule.message or rule[eventKey .. "Message"] or "")
    panel.soundEnabled:SetChecked(rule[eventKey .. "SoundEnabled"])
    local mediaName = rule[eventKey .. "SoundMediaName"]
    ns.refreshNotificationSoundChoices(mediaName)
    local soundKitID = tonumber(rule[eventKey .. "SoundKitID"]) or DEFAULT_NOTIFICATION_SOUND_KIT
    local soundValue = mediaName and NOTIFICATION_MEDIA_PREFIX .. mediaName or soundKitID
    local soundChoice = notificationSoundChoiceForValue(soundValue)
    panel.soundChoice.screenValue = soundValue
    UIDropDownMenu_SetSelectedValue(panel.soundChoice, soundValue)
    UIDropDownMenu_SetText(panel.soundChoice, soundChoice and notificationSoundChoiceText(soundChoice)
        or tostring(mediaName or soundKitID) .. (mediaName and " (missing)" or ""))
    local channel = NOTIFICATION_SOUND_CHANNEL_SET[rule[eventKey .. "SoundChannel"]]
        and rule[eventKey .. "SoundChannel"] or "Master"
    panel.soundChannel.screenValue = channel
    UIDropDownMenu_SetSelectedValue(panel.soundChannel, channel)
    UIDropDownMenu_SetText(panel.soundChannel, L(channel == "SFX" and "Sound effects" or channel))
    if panel.categoryChoice then
        local category = NOTIFICATION_CUE_ALIASES[rule.alertCategory] or "none"
        panel.categoryChoice.screenValue = category
        UIDropDownMenu_SetSelectedValue(panel.categoryChoice, category)
        local categoryLabel = category == "none" and L("No category cue")
            or L(NOTIFICATION_CUE_LABELS[category] or category)
        UIDropDownMenu_SetText(panel.categoryChoice, categoryLabel)
    end
    loadScreenRowProfile(panel.screen, rule)
    ns.Layout.ensureExpirationPanelState(panel, rule)
    ns.setNotificationPanelShown(panel, true)
end

function saveDetails()
    if editorLoading or addRuleMode then return end
    local auraRule = selectedAura()
    if auraRule and ruleNameBox then
        auraRule.name = trim(ruleNameBox:GetText())
        saveNotificationPanel(ns.notificationPanels.apply, auraRule, "apply")
        saveNotificationPanel(ns.notificationPanels.expire, auraRule, "expire")
    else
        local readyRule = selectedItem() or selectedSkill()
        if readyRule and ruleNameBox then
            readyRule.name = trim(ruleNameBox:GetText())
            saveNotificationPanel(ns.notificationPanels.ready, readyRule, "ready")
        end
    end
    refreshList()
    updateRulePreviewFromEditor()
end

function updateDetails()
    if not detailPanel then return end
    local previousPartialSearch = ns.spellSearch.partial
    searchGeneration = searchGeneration + 1
    if previousPartialSearch and selectedCategory == "auras"
        and previousPartialSearch.rule == selectedAuraRule
        and triggerInputBox and previousPartialSearch.query == trim(triggerInputBox:GetText()) then
        previousPartialSearch.generation = searchGeneration
    else
        ns._Aura.cancelPartialSpellSearch()
    end
    if searchPopup then searchPopup:Hide() end

    local auraRule = selectedAura()
    local itemRule = selectedItem()
    local skillRule = selectedSkill()
    local rule = auraRule or itemRule or skillRule
    local ruleChanged = lastRenderedRule ~= rule or lastRenderedCategory ~= selectedCategory
    if ruleChanged then
        ns.Layout.clampEditorScroll(0)
    end
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
    if addRuleMode or not rule then
        if triggerAddButton then
            triggerAddButton.nameSearch = nil
            triggerAddButton.exactResult = nil
            triggerAddButton.selectedSearchResult = nil
            triggerAddButton:SetText(L("Add"))
            triggerAddButton:SetEnabled(false)
        end
    end
    if addRuleMode then return end
    if not rule then
        lastRenderedRule = nil
        lastRenderedCategory = nil
        return
    end

    if auraEditor.UpdateSpecializationFilter then auraEditor.UpdateSpecializationFilter(rule) end

    local unchangedRule = lastRenderedRule == rule and lastRenderedCategory == selectedCategory
    local savedSearch = triggerAddButton and (triggerAddButton.nameSearch or triggerAddButton.exactResult)
    local preserveSearchQuery = savedSearch and triggerInputBox and savedSearch.rule == rule
        and savedSearch.query == trim(triggerInputBox:GetText())
    local keepTriggerQuery = unchangedRule and (triggerInputBox:HasFocus() or preserveSearchQuery)
    local query = keepTriggerQuery and triggerInputBox:GetText() or ""
    if not keepTriggerQuery then
        if triggerAddButton then
            triggerAddButton.nameSearch = nil
            triggerAddButton.exactResult = nil
            triggerAddButton.selectedSearchResult = nil
            triggerAddButton:SetText(L("Add"))
            triggerAddButton:SetEnabled(false)
        end
    else
        local nameSearch = triggerAddButton and triggerAddButton.nameSearch
        if nameSearch then
            if nameSearch.rule == rule and nameSearch.query == trim(query) then
                nameSearch.generation = searchGeneration
            elseif triggerAddButton then
                triggerAddButton.nameSearch = nil
            end
        end
        local exactResult = triggerAddButton and triggerAddButton.exactResult
        if exactResult then
            if exactResult.rule == rule and exactResult.query == trim(query) then
                exactResult.generation = searchGeneration
            elseif triggerAddButton then
                triggerAddButton.exactResult = nil
            end
        end
        local selectedResult = triggerAddButton and triggerAddButton.selectedSearchResult
        if selectedResult then
            if selectedResult.rule == rule and selectedResult.query == trim(query) then
                selectedResult.generation = searchGeneration
            elseif triggerAddButton then
                triggerAddButton.selectedSearchResult = nil
            end
        end
    end
    editorLoading = true
    ruleNameBox:SetText(rule.name or "")
    ruleEnabledCheck:SetChecked(rule.enabled)
    if auraRule then
        local firstID = auraRule.spellIDs[1]
        local info = firstID and getSpellInfo(firstID)
        auraEditor.ruleIcon:SetTexture(info and info.iconID or "Interface\\Icons\\Spell_Nature_Rejuvenation")
        auraEditor.heading:SetText(L("AURA RULE"))
        auraEditor.iconButton:Hide()
        itemSourceText:Hide()
        auraEditor.slotTrackCheck:Hide()
        auraEditor.slotTrackLabel:Hide()
        triggerLabel:Show()
        triggerInputBox:Show()
        triggerPlaceholder:SetShown(not keepTriggerQuery or trim(query) == "")
        triggerAddButton:Show()
        triggerStatus:Show()
        triggerScroll.backdrop:Show()
        triggerScroll:Show()
        ns.setNotificationPanelShown(ns.notificationPanels.ready, false)
        auraEditor.skillTriggerLabel:Hide()
        auraEditor.skillTriggerDropdown:Hide()
        auraEditor.skillLearnButton:Hide()
        auraEditor.skillLearningStatus:Hide()
        readyLabel:Hide()
        readyMessageBox:Hide()
        testItemButton:Hide()
        loadNotificationPanel(ns.notificationPanels.apply, auraRule, "apply")
        loadNotificationPanel(ns.notificationPanels.expire, auraRule, "expire")
        layoutSharedEditor(true)
        if not keepTriggerQuery then triggerInputBox:SetText("") end
        updateSelectedTriggers()
    elseif itemRule or skillRule then
        local readyRule = itemRule or skillRule
        local skillInfo = skillRule and getSpellInfo(skillRule.spellID)
        auraEditor.ruleIcon:SetTexture(readyRule.icon or (skillInfo and skillInfo.iconID) or "Interface\\Icons\\INV_Misc_QuestionMark")
        auraEditor.heading:SetText(L(itemRule and "ITEM RULE" or "SPELL COOLDOWN"))
        auraEditor.iconButton:SetShown(itemRule ~= nil)
        triggerLabel:Hide()
        triggerInputBox:Hide()
        triggerPlaceholder:Hide()
        triggerAddButton:Hide()
        triggerStatus:Hide()
        triggerScroll.backdrop:Hide()
        triggerScroll:Hide()
        itemSourceText:Show()
        ns.setNotificationPanelShown(ns.notificationPanels.apply, false)
        ns.setNotificationPanelShown(ns.notificationPanels.expire, false)
        auraEditor.skillTriggerLabel:SetShown(skillRule ~= nil)
        auraEditor.skillTriggerDropdown:SetShown(skillRule ~= nil)
        auraEditor.skillLearnButton:SetShown(skillRule ~= nil)
        auraEditor.skillLearningStatus:SetShown(skillRule ~= nil)
        if skillRule then
            ns.SkillTracking.NormalizeRule(skillRule)
            UIDropDownMenu_SetSelectedValue(auraEditor.skillTriggerDropdown, skillRule.triggerType)
            UIDropDownMenu_SetText(auraEditor.skillTriggerDropdown, L(ns.SkillTracking.GetTriggerLabel(skillRule.triggerType)))
            if not (ns.SkillTracking.learning and ns.SkillTracking.learning.rule == skillRule) then
                auraEditor.skillLearningStatus:SetText(L(ns.SkillTracking.GetTriggerDescription(skillRule.triggerType)))
            end
        end
        loadNotificationPanel(ns.notificationPanels.ready, readyRule, "ready")
        layoutSharedEditor(false)
        itemSourceText:Show()
        if itemRule then
            local choosingStarter = itemRule.starter == "trinket" and itemRule.itemID <= 0
            auraEditor.slotTrackCheck:SetShown(not choosingStarter)
            auraEditor.slotTrackLabel:SetShown(not choosingStarter)
            auraEditor.slotTrackCheck:SetChecked(itemRule.slotID ~= nil)
            if choosingStarter then
                itemSourceText:SetText(L("Choose an equipped item"))
                itemSourceText:SetTextColor(1, 0.82, 0.2)
                testItemButton:SetText(L("Choose item"))
                testItemButton:SetEnabled(true)
                testItemButton:SetScript("OnClick", function() if ns.BeginItemPicker then ns.BeginItemPicker() end end)
            else
                local slotID
                if itemRule.slotID then
                    slotID = ns.getEquippedItemID(itemRule.slotID) and itemRule.slotID or nil
                else
                    slotID = ns.findEquippedItemSlot(itemRule.itemID)
                end
                itemSourceText:SetText(slotID and string.format(L("Equipped · Slot %d"), slotID) or L("Not equipped"))
                itemSourceText:SetTextColor(slotID and 0.55 or 1, slotID and 0.86 or 0.65, slotID and 0.62 or 0.25)
                testItemButton:SetText(L("Test"))
                if ns.TestCurrentReady then testItemButton:SetScript("OnClick", ns.TestCurrentReady) end
            end
        else
            auraEditor.slotTrackCheck:Hide()
            auraEditor.slotTrackLabel:Hide()
            itemSourceText:SetText(string.format(L("Spellbook · ID %d"), skillRule.spellID))
            itemSourceText:SetTextColor(0.55, 0.86, 0.62)
            testItemButton:SetText(L("Test"))
            testItemButton:SetScript("OnClick", ns.TestCurrentReady)
        end
    end

    UIDropDownMenu_SetSelectedValue(voiceDropdown, rule.voiceID)
    UIDropDownMenu_SetText(voiceDropdown, voiceName(rule.voiceID))
    volumeSlider:SetValue(rule.volume)
    volumeValue:SetText(tostring(rule.volume))
    auraEditor.speedSlider:SetValue(rule.speechSpeed)
    auraEditor.speedValue:SetText(tostring(rule.speechSpeed) .. "%")
    if keepTriggerQuery then
        triggerInputBox:SetText(query)
    end
    editorLoading = false
    lastRenderedRule = rule
    lastRenderedCategory = selectedCategory
    if keepTriggerQuery then
        searchGeneration = searchGeneration + 1
        local generation = searchGeneration
        if triggerAddButton and triggerAddButton.nameSearch then triggerAddButton.nameSearch.generation = generation end
        if triggerAddButton and triggerAddButton.exactResult then triggerAddButton.exactResult.generation = generation end
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
detailPanel:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 394, -64)
detailPanel:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -ns.Layout.MARGIN, ns.Layout.MARGIN)

detailPanel.emptyText = createLabel(detailPanel, "Select a rule or add an aura group or item.", "GameFontHighlight")
detailPanel.emptyText:SetPoint("CENTER")
detailPanel.emptyText:SetWidth(360)
detailPanel.emptyText:SetJustifyH("CENTER")

detailPanel.rulePreviewPanel = CreateFrame("Frame", nil, detailPanel, "BackdropTemplate")
detailPanel.rulePreviewPanel:SetPoint("BOTTOMLEFT", detailPanel, "BOTTOMLEFT", 0, 0)
detailPanel.rulePreviewPanel:SetPoint("BOTTOMRIGHT", detailPanel, "BOTTOMRIGHT", -8, 0)
detailPanel.rulePreviewPanel:SetHeight(104)
stylePanel(detailPanel.rulePreviewPanel, 0.045, 0.05, 0.06)
detailPanel.rulePreviewHeading = makeSectionLabel(detailPanel.rulePreviewPanel, "RULE PREVIEW", 18, -12)
detailPanel.rulePreviewText = createLabel(detailPanel.rulePreviewPanel, "", "GameFontHighlightSmall")
detailPanel.rulePreviewText:SetPoint("TOPLEFT", detailPanel.rulePreviewPanel, "TOPLEFT", 18, -42)
detailPanel.rulePreviewText:SetPoint("TOPRIGHT", detailPanel.rulePreviewPanel, "TOPRIGHT", -18, -42)
detailPanel.rulePreviewText:SetHeight(54)
detailPanel.rulePreviewText:SetJustifyH("LEFT")
detailPanel.rulePreviewText:SetJustifyV("TOP")
detailPanel.rulePreviewText:SetWordWrap(true)

editorScroll = CreateFrame("ScrollFrame", nil, detailPanel, "UIPanelScrollFrameTemplate")
editorScroll:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", 0, -2)
editorScroll:SetPoint("BOTTOMRIGHT", detailPanel.rulePreviewPanel, "TOPRIGHT", 0, 8)
if editorScroll.ScrollBar then editorScroll.ScrollBar:Hide() end
editorScroll:EnableMouseWheel(true)
editorScroll:SetScript("OnMouseWheel", function(self, delta)
    self:SetVerticalScroll(math.max(0, math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - delta * 48)))
end)
auraEditor = CreateFrame("Frame", nil, editorScroll)
auraEditor:SetSize(1, 620)
editorScroll:SetScrollChild(auraEditor)
local function resizeEditorChild()
    local scrollOffset = editorScroll:GetVerticalScroll()
    auraEditor:SetWidth(math.max(1, editorScroll:GetWidth() - 4))
    auraEditor:SetHeight(math.max(auraEditor.minimumContentHeight or 620, editorScroll:GetHeight()))
    if ns.screenControls.ready and auraEditor.voicePanel then
        layoutSharedEditor(selectedCategory == "auras")
    end
    ns.Layout.clampEditorScroll(scrollOffset)
end
editorScroll:HookScript("OnSizeChanged", resizeEditorChild)
C_Timer.After(0, resizeEditorChild)
auraEditor.rulePanel = CreateFrame("Frame", nil, auraEditor, "BackdropTemplate")
auraEditor.rulePanel:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 0, 0)
auraEditor.rulePanel:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", 0, 0)
auraEditor.rulePanel:SetHeight(116)
stylePanel(auraEditor.rulePanel, 0.09, 0.095, 0.105)
auraEditor.heading = makeSectionLabel(auraEditor.rulePanel, "RULE", ns.Layout.PAD, -16)
auraEditor.ruleIcon = auraEditor.rulePanel:CreateTexture(nil, "ARTWORK")
auraEditor.ruleIcon:SetSize(38, 38)
auraEditor.ruleIcon:SetPoint("TOPLEFT", auraEditor.rulePanel, "TOPLEFT", 12, -34)
auraEditor.ruleIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
-- Item rules only: clicking the icon re-opens the item picker for this rule.  Anchored to the
-- icon texture, so it follows every layoutSharedEditor placement.
auraEditor.iconButton = CreateFrame("Button", nil, auraEditor.rulePanel)
auraEditor.iconButton:SetAllPoints(auraEditor.ruleIcon)
auraEditor.iconButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
auraEditor.iconButton:SetScript("OnClick", function()
    if selectedCategory == "items" and selectedItemRule and ns.BeginItemPicker then
        ns.BeginItemPicker(selectedItemRule)
    end
end)
addHelpTooltip(auraEditor.iconButton, "Change item", "Click to pick another equipped item for this rule.")
auraEditor.iconButton:Hide()

ruleNameBox = createEditBox(auraEditor.rulePanel, 444, 30)
ruleNameBox:SetPoint("TOPLEFT", auraEditor.rulePanel, "TOPLEFT", 94, -58)
ruleEnabledCheck = CreateFrame("CheckButton", nil, auraEditor.rulePanel, "UICheckButtonTemplate")
ruleEnabledCheck:SetPoint("TOPLEFT", auraEditor.rulePanel, "TOPLEFT", 550, -48)
ruleEnabledCheck:SetSize(30, 30)
auraEditor.enabledLabel = createLabel(auraEditor.rulePanel, "Active", "GameFontNormalSmall")
auraEditor.enabledLabel:SetPoint("LEFT", ruleEnabledCheck, "RIGHT", 4, 0)

    auraEditor.specFilter = CreateFrame("Frame", nil, auraEditor.rulePanel, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(auraEditor.specFilter, 138)
    auraEditor.specFilterLabel = createLabel(auraEditor.rulePanel, "Specs", "GameFontNormalSmall")
    auraEditor.UpdateSpecializationFilter = function(rule)
        local filter = auraEditor.specFilter
    filter.rule = rule
    local selected = {}
    for _, specID in ipairs(type(rule) == "table" and rule.specializationIDs or {}) do selected[specID] = true end
    UIDropDownMenu_SetText(filter, next(selected) and string.format(L("%d selected"), #rule.specializationIDs) or L("All specs"))
end
UIDropDownMenu_Initialize(auraEditor.specFilter, function(menu, level)
    local rule = auraEditor.specFilter.rule
    if not rule then return end
    local selected = {}
    for _, specID in ipairs(rule.specializationIDs or {}) do selected[specID] = true end
    local allInfo = UIDropDownMenu_CreateInfo()
    allInfo.text = L("All specializations")
    allInfo.isNotRadio = true
    allInfo.checked = function() return not rule.specializationIDs or #rule.specializationIDs == 0 end
    allInfo.func = function()
        if selectedRule() ~= rule then CloseDropDownMenus(); return end
        saveDetails()
        rule.specializationIDs = nil
        ns.RefreshRuleActivationState()
        CloseDropDownMenus()
    end
    UIDropDownMenu_AddButton(allInfo, level)

    local specs = ns.Profiles.GetCurrentClassSpecializations()
    local currentIDs = {}
    for _, spec in ipairs(specs) do currentIDs[spec.id] = true end
    local function addSpecChoice(specID, text)
        local info = UIDropDownMenu_CreateInfo()
        info.text = text
        info.value = specID
        info.isNotRadio = true
        info.checked = function() return selected[specID] == true end
        info.keepShownOnClick = true
        info.func = function()
            if selectedRule() ~= rule then CloseDropDownMenus(); return end
            saveDetails()
            local ids = {}
            local wasSelected = selected[specID] == true
            for _, id in ipairs(rule.specializationIDs or {}) do
                if id ~= specID then table.insert(ids, id) end
            end
            if not wasSelected then table.insert(ids, specID) end
            selected[specID] = not wasSelected
            rule.specializationIDs = ids
            ns.Profiles.NormalizeRuleSpecializations(rule)
            ns.RefreshRuleActivationState()
        end
        UIDropDownMenu_AddButton(info, level)
    end

    for _, spec in ipairs(specs) do addSpecChoice(spec.id, spec.name) end
    local otherIDs = {}
    for specID in pairs(selected) do
        if not currentIDs[specID] then table.insert(otherIDs, specID) end
    end
    table.sort(otherIDs)
    if #otherIDs > 0 then
        local titleInfo = UIDropDownMenu_CreateInfo()
        titleInfo.text = L("Other classes")
        titleInfo.isTitle = true
        titleInfo.notCheckable = true
        UIDropDownMenu_AddButton(titleInfo, level)
        for _, specID in ipairs(otherIDs) do addSpecChoice(specID, ns.Profiles.GetSpecializationLabel(specID)) end
    end
end)
addHelpTooltip(auraEditor.specFilter, "Specializations", "Choose the specializations for which this rule is active.")

end

local function buildTriggerControls()
    triggerPanel = CreateFrame("Frame", nil, auraEditor, "BackdropTemplate")
    stylePanel(triggerPanel, 0.07, 0.075, 0.085)
    triggerLabel = makeSectionLabel(triggerPanel, "TRIGGERS", 12, -8, true)
    triggerInputBox = createEditBox(triggerPanel, 300, 24)
    triggerInputBox.searchIcon = triggerInputBox:CreateTexture(nil, "ARTWORK")
    triggerInputBox.searchIcon:SetSize(14, 14)
    triggerInputBox.searchIcon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    triggerInputBox:SetMaxLetters(180)
    triggerPlaceholder = createLabel(triggerPanel, "Search name or paste spell IDs", "GameFontDisableSmall")
    triggerPlaceholder:SetPoint("LEFT", triggerInputBox, "LEFT", 23, 0)
    triggerPlaceholder:SetPoint("RIGHT", triggerInputBox, "RIGHT", -8, 0)
 triggerPlaceholder:SetJustifyH("LEFT")
 triggerPlaceholder:SetTextColor(0.46, 0.5, 0.58)
triggerInputBox:SetScript("OnTextChanged", function(self)
    if editorLoading then return end
    searchGeneration = searchGeneration + 1
    ns._Aura.cancelPartialSpellSearch()
    triggerAddButton.nameSearch = nil
    triggerAddButton.exactResult = nil
    triggerAddButton.selectedSearchResult = nil
    local generation = searchGeneration
    local query = trim(self:GetText())
    triggerPlaceholder:SetShown(query == "")
    local ids, valid = parseSpellIDs(query)
    triggerAddButton:SetText(L(valid and #ids > 0 and "Add" or "Search"))
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
        triggerAddButton:SetText(L("Add"))
        searchPopup:Hide()
        triggerStatus:SetText(L("Invalid ID list"))
        triggerStatus:SetTextColor(1, 0.35, 0.25)
        return
    end
    if #query < 3 then
        searchPopup:Hide()
        return
    end
    triggerAddButton:SetText(L("Search"))
    triggerAddButton:SetEnabled(true)
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
        if searchRows[1].result.confirmOnly then
            triggerAddButton:Click()
        else
            addTriggerIDs({ searchRows[1].result.id })
        end
        return
    end
    self:ClearFocus()
end)
triggerInputBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
    searchGeneration = searchGeneration + 1
    ns._Aura.cancelPartialSpellSearch()
    triggerAddButton.nameSearch = nil
    triggerAddButton.exactResult = nil
    triggerAddButton.selectedSearchResult = nil
    triggerAddButton:SetText(L("Add"))
    triggerAddButton:SetEnabled(false)
    searchPopup:Hide()
    if selectedAura() then layoutSharedEditor(true) end
end)
triggerAddButton = CreateFrame("Button", nil, triggerPanel, "UIPanelButtonTemplate")
triggerAddButton:SetSize(80, 24)
triggerAddButton:SetText(L("Add"))
triggerAddButton:SetEnabled(false)
triggerAddButton:SetScript("OnClick", function()
    local query = trim(triggerInputBox:GetText())
    local ids, valid = parseSpellIDs(query)
    if valid and #ids > 0 then
        addTriggerIDs(ids)
        return
    end
    local selectedResult = triggerAddButton.selectedSearchResult
    if selectedResult and selectedResult.query == query and selectedResult.rule == selectedAura()
        and selectedResult.generation == searchGeneration then
        addTriggerIDs({ selectedResult.id })
        return
    end
    local exactResult = triggerAddButton.exactResult
    if exactResult and exactResult.query == query and exactResult.rule == selectedAura()
        and exactResult.generation == searchGeneration then
        addTriggerIDs({ exactResult.id })
        return
    end
    local scan = ns.spellSearch.partial
    if scan and scan.query == query and scan.rule == selectedAura()
        and scan.generation == searchGeneration and scan.hasMore and not scan.running then
        ns.runPartialSpellSearch(query, scan.rule, searchGeneration, true)
        return
    end
    if #query < 3 or query:find(",", 1, true) or tonumber(query) then
        triggerAddButton:SetEnabled(false)
        triggerStatus:SetText(L("Enter valid spell IDs separated by commas."))
        triggerStatus:SetTextColor(1, 0.35, 0.25)
        return
    end
    local nameSearch = { query = query, rule = selectedAura(), generation = searchGeneration }
    if C_Spell and C_Spell.GetSpellIDForSpellIdentifier then
        local ok, spellID = pcall(C_Spell.GetSpellIDForSpellIdentifier, query)
        if ok and isPublicNumber(spellID) then
            nameSearch.id = spellID
        else
            nameSearch.failed = true
        end
    else
        nameSearch.unavailable = true
    end
    triggerAddButton.nameSearch = nameSearch
    triggerAddButton.exactResult = nil
    runTriggerSearch(searchGeneration)
    if not triggerAddButton.exactResult and not nameSearch.pending then
        ns.runPartialSpellSearch(query, nameSearch.rule, searchGeneration, false)
    end
end)
triggerStatus = createLabel(triggerPanel, "", "GameFontNormalSmall")
triggerScroll = CreateFrame("ScrollFrame", nil, triggerPanel, "UIPanelScrollFrameTemplate")
triggerScroll.backdrop = triggerPanel
triggerChild = CreateFrame("Frame", nil, triggerScroll)
triggerChild:SetSize(1, 1)
triggerScroll:SetScrollChild(triggerChild)
triggerScroll:HookScript("OnSizeChanged", function(self, width)
    triggerChild:SetWidth(math.max(1, width - 4))
    updateSelectedTriggers()
end)
itemSourceText = createLabel(auraEditor, "", "GameFontNormalSmall")
auraEditor.slotTrackCheck = CreateFrame("CheckButton", nil, auraEditor, "UICheckButtonTemplate")
auraEditor.slotTrackCheck:SetSize(24, 24)
auraEditor.slotTrackLabel = createLabel(auraEditor, "Track the slot, not the item", "GameFontNormalSmall")
auraEditor.slotTrackLabel:SetPoint("LEFT", auraEditor.slotTrackCheck, "RIGHT", 2, 0)
auraEditor.slotTrackCheck:Hide()
auraEditor.slotTrackLabel:Hide()

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
    row.label = createLabel(parent, labelText, "GameFontNormalSmall")
    row.label:SetMaxLines(1)
    row.text = createEditBox(parent, 280, 24)
    row.preview = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    row.preview:SetSize(72, 24)
    row.preview:SetText(L("Preview"))
    row.font = createScreenChoiceDropdown(parent, 116, SCREEN_FONT_CHOICES,
        function(choice) return choice.key end,
        function(choice) return L(choice.key) end,
        function(value)
            row.fontValue = value
            saveDetails()
            local profile = selectedRule() and ns.getRuleScreenProfile(selectedRule(), row.eventKey)
            if profile then profile.font = value; ns.applyScreenFrameStyle(row.frame, profile) end
        end)
    row.size = createScreenChoiceDropdown(parent, 72, SCREEN_SIZE_CHOICES,
        function(size) return tostring(size) end,
        function(size) return tostring(size) end,
        function(value)
            row.sizeValue = tonumber(value)
            saveDetails()
            local profile = selectedRule() and ns.getRuleScreenProfile(selectedRule(), row.eventKey)
            if profile then profile.size = ns.getScreenSizeValue(row.sizeValue); ns.applyScreenFrameStyle(row.frame, profile) end
        end)
    row.style = createScreenChoiceDropdown(parent, 150, SCREEN_STYLE_CHOICES,
        function(choice) return choice.key end,
        function(choice) return L(choice.label) end,
        function(value)
            row.styleValue = value
            saveDetails()
            local profile = selectedRule() and ns.getRuleScreenProfile(selectedRule(), row.eventKey)
            if profile then profile.style = value; ns.applyScreenFrameStyle(row.frame, profile) end
        end)
    row.color = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row.color:SetSize(26, 26)
    row.color:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    row.color:SetBackdropColor(0.05, 0.05, 0.06, 1)
    row.color:SetBackdropBorderColor(0.72, 0.55, 0.22, 1)
    row.color.fill = row.color:CreateTexture(nil, "ARTWORK")
    row.color.fill:SetPoint("TOPLEFT", row.color, "TOPLEFT", 3, -3)
    row.color.fill:SetPoint("BOTTOMRIGHT", row.color, "BOTTOMRIGHT", -3, 3)
    row.color:SetScript("OnClick", function() ns.openScreenColorPicker(row) end)
    row.anchor = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    row.anchor:SetSize(72, 24)
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

local function buildAuraNotificationPanel(eventKey, title)
    local panel = {}
    panel.eventKey = eventKey
    panel.expanded = true
    panel.frame = CreateFrame("Frame", nil, auraEditor, "BackdropTemplate")
    panel.frame:SetHeight(162)
    stylePanel(panel.frame, 0.09, 0.095, 0.105)
    panel.heading = makeSectionLabel(panel.frame, title, 12, -8)
    -- The whole 34 px heading row is the click target: chevron left of the title, hint on the right.
    panel.headerButton = CreateFrame("Button", nil, panel.frame)
    panel.headerButton:SetPoint("TOPLEFT", panel.frame, "TOPLEFT", 0, 0)
    panel.headerButton:SetPoint("TOPRIGHT", panel.frame, "TOPRIGHT", 0, 0)
    panel.headerButton:SetHeight(34)
    panel.headerButton:SetFrameLevel(panel.frame:GetFrameLevel() + 1)
    panel.headerButton:SetHighlightTexture("Interface\\Buttons\\WHITE8X8", "ADD")
    panel.headerButton:GetHighlightTexture():SetAlpha(0.07)
    panel.headerIndicator = panel.headerButton:CreateTexture(nil, "ARTWORK")
    panel.headerIndicator:SetSize(16, 16)
    panel.headerIndicator:SetPoint("LEFT", panel.headerButton, "LEFT", ns.Layout.PAD - 20, 0)
    panel.headerHint = panel.headerButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.headerHint:SetPoint("RIGHT", panel.headerButton, "RIGHT", ns.Layout.RIGHT, 0)
    panel.headerHint:SetTextColor(0.6, 0.6, 0.62)
    ns.Layout.refreshPanelHeader(panel)
    panel.headerButton:SetScript("OnClick", function()
        if panel.eventKey ~= "expire" then return end
        ns.Layout.setExpirationPanelExpanded(panel, not ns.Layout.isNotificationPanelExpanded(panel))
        ns.setNotificationPanelShown(panel, true)
        layoutSharedEditor(true)
    end)
    addHelpTooltip(panel.headerButton, "Expiration", "Click to expand or collapse this panel.")

    panel.ttsEnabled = CreateFrame("CheckButton", nil, panel.frame, "UICheckButtonTemplate")
    panel.ttsLabel = createLabel(panel.frame, "TTS", "GameFontNormal")
    panel.ttsMessage = createEditBox(panel.frame, 300, 24)
    panel.ttsTest = CreateFrame("Button", nil, panel.frame, "UIPanelButtonTemplate")
    panel.ttsTest:SetSize(72, 24)
    panel.ttsTest:SetText(L("Test"))

    panel.soundEnabled = CreateFrame("CheckButton", nil, panel.frame, "UICheckButtonTemplate")
    panel.soundLabel = createLabel(panel.frame, "Sound", "GameFontNormal")
    panel.soundChoice = createScreenChoiceDropdown(panel.frame, 140, NOTIFICATION_SOUND_CHOICES,
        function(choice) return choice.kind == "media" and choice.value or choice.soundKitID end,
        notificationSoundChoiceText,
        function(value)
            panel.soundChoice.screenValue = value
            saveDetails()
            updateRulePreviewFromEditor()
        end)
    panel.soundChannel = createScreenChoiceDropdown(panel.frame, 108, NOTIFICATION_SOUND_CHANNELS,
        function(choice) return choice.value end,
        function(choice) return L(choice.key) end,
        function(value)
            panel.soundChannel.screenValue = value
            saveDetails()
            updateRulePreviewFromEditor()
        end)
    panel.soundTest = CreateFrame("Button", nil, panel.frame, "UIPanelButtonTemplate")
    panel.soundTest:SetSize(56, 24)
    panel.soundTest:SetText(L("Test"))
    panel.soundTest:SetScript("OnClick", function()
        saveDetails()
        local rule = selectedRule()
        if rule and ns.playNotificationSound(rule, eventKey) then
            setStatus("Sound test sent to WoW. Check audio in game.")
        else
            setStatus("Sound test could not be sent to WoW.", true)
        end
    end)
    if eventKey == "apply" then
        panel.categoryLabel = createLabel(panel.frame, "Application-Fallback", "GameFontNormalSmall")
        panel.categoryChoice = createScreenChoiceDropdown(panel.frame, 142, NOTIFICATION_CUE_CHOICES,
            function(choice) return choice.value end,
            function(choice) return L(choice.label) end,
            function(value)
                panel.categoryChoice.screenValue = value
                saveDetails()
                rebuildAuraWatches()
                syncAllAuras(true)
                updateRulePreviewFromEditor()
            end)
        addHelpTooltip(panel.categoryChoice, "Application-Fallback", "WoW plays the category word itself when the aura is applied, for auras that are not your own self-cast buffs; it never plays on expiration.")
    end
    panel.screen = buildScreenRow(panel.frame, "On-screen text", -89, eventKey)
    ns.screenControls[eventKey] = panel.screen
    ns.notificationPanels[eventKey] = panel
    return panel
end

local function buildMessageControls()
    auraEditor.notificationsHeading = makeSectionLabel(auraEditor, "NOTIFICATIONS", ns.Layout.EXTRA_X, -255)
    local applyPanel = buildAuraNotificationPanel("apply", "Application")
    local expirePanel = buildAuraNotificationPanel("expire", "Expiration")
    local readyPanel = buildAuraNotificationPanel("ready", "Ready")
    applyEnabledCheck, applyMessageBox, testApplyButton = applyPanel.ttsEnabled, applyPanel.ttsMessage, applyPanel.ttsTest
    expireEnabledCheck, expireMessageBox, testExpireButton = expirePanel.ttsEnabled, expirePanel.ttsMessage, expirePanel.ttsTest
    readyLabel, readyMessageBox, testItemButton = readyPanel.ttsLabel, readyPanel.ttsMessage, readyPanel.ttsTest
    auraEditor.skillTriggerLabel = createLabel(auraEditor, "Trigger", "GameFontNormalSmall")
    auraEditor.skillTriggerDropdown = CreateFrame("Frame", nil, auraEditor, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(auraEditor.skillTriggerDropdown, 180)
    UIDropDownMenu_Initialize(auraEditor.skillTriggerDropdown, function(menu, level)
        local hasCharges = selectedSkillRule and ns.SkillTracking.HasCharges(selectedSkillRule.spellID)
        for _, choice in ipairs(ns.SkillTracking.triggerTypes) do
            local selectedChoice = choice
            local info = UIDropDownMenu_CreateInfo()
            info.text = L(selectedChoice.label)
            info.value = selectedChoice.value
            info.checked = selectedSkillRule and selectedSkillRule.triggerType == selectedChoice.value
            info.disabled = selectedChoice.kind == "charge" and not hasCharges
            if info.disabled then
                info.tooltipTitle = L("Charge trigger unavailable")
                info.tooltipText = L("This spell has no charge data.")
                info.tooltipOnButton = true
            end
            info.func = function()
                if not selectedSkill() then CloseDropDownMenus(); return end
                selectedSkillRule.triggerType = selectedChoice.value
                ns.SkillTracking.ResetRule(selectedSkillRule)
                UIDropDownMenu_SetSelectedValue(auraEditor.skillTriggerDropdown, selectedChoice.value)
                UIDropDownMenu_SetText(auraEditor.skillTriggerDropdown, L(selectedChoice.label))
                auraEditor.skillLearningStatus:SetText(L(ns.SkillTracking.GetTriggerDescription(selectedChoice.value)))
                scanSkillRules()
                updateRulePreviewFromEditor()
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    auraEditor.skillLearnButton = CreateFrame("Button", nil, auraEditor, "UIPanelButtonTemplate")
    auraEditor.skillLearnButton:SetSize(86, 26)
    auraEditor.skillLearnButton:SetText(L("Learn"))
    auraEditor.skillLearnButton:SetScript("OnClick", function()
        if ns.SkillTracking.learning then
            ns.SkillTracking.StopLearning()
        elseif not ns.SkillTracking.StartLearning(selectedSkill()) then
            setStatus(L("Select a valid spell rule before learning."), true)
        end
    end)
    auraEditor.skillLearningStatus = createLabel(auraEditor, "", "GameFontHighlightSmall")
    auraEditor.skillLearningStatus:SetTextColor(0.75, 0.82, 0.92)
    ns.SkillTracking.onLearningChanged = function(session, status, remaining)
        if not auraEditor.skillLearnButton then return end
        local active = session and (session.phase == "waiting" or session.phase == "observing")
        auraEditor.skillLearnButton:SetText(L(active and "Stop" or "Learn"))
        if session and session.phase == "waiting" then
            auraEditor.skillLearningStatus:SetText(string.format(L("Cast %s within %d seconds."), session.spellName, remaining or math.max(1, math.ceil(session.deadline - GetTime()))))
        elseif session and session.phase == "observing" then
            auraEditor.skillLearningStatus:SetText(string.format(L("Observing auras and cooldowns: %d seconds."), remaining or math.max(1, math.ceil(session.deadline - GetTime()))))
        else
            auraEditor.skillLearningStatus:SetText(status or (session and session.status) or "")
        end
        if status or (session and session.phase == "complete") then
            setStatus(status or session.status or L("Learning complete."))
        end
    end
    ns.SkillTracking.CreateDebugWindow()
    ns.SkillTracking.CreateLearningWindow()
    ns.screenControls.ready = readyPanel.screen

    auraEditor.voicePanel = CreateFrame("Frame", nil, auraEditor, "BackdropTemplate")
    stylePanel(auraEditor.voicePanel, 0.09, 0.095, 0.105)
    auraEditor.voiceHeading = makeSectionLabel(auraEditor.voicePanel, "TTS", ns.Layout.PAD, -8)
    auraEditor.voiceLabel = createLabel(auraEditor.voicePanel, "Voice", "GameFontNormalSmall")
    voiceDropdown = createVoiceDropdown(auraEditor.voicePanel, "TOPLEFT", auraEditor.voicePanel, 12, -43, function(voiceID)
    local rule = selectedAura() or selectedItem() or selectedSkill()
    if rule then rule.voiceID = voiceID end
    end)
    auraEditor.volumeLabel = createLabel(auraEditor.voicePanel, "Volume", "GameFontNormalSmall")
    volumeSlider = makeVolumeSlider(auraEditor.voicePanel, "TOPLEFT", auraEditor.voicePanel, 0, -43, function(value)
    local rule = selectedAura() or selectedItem() or selectedSkill()
    if rule then rule.volume = value; volumeValue:SetText(tostring(value)) end
end)
volumeValue = createLabel(auraEditor.voicePanel, "80", "GameFontHighlight")
volumeValue:SetPoint("LEFT", volumeSlider, "RIGHT", 8, 0)
auraEditor.speedLabel = createLabel(auraEditor.voicePanel, "Speech speed", "GameFontNormalSmall")
auraEditor.speedSlider = makeVolumeSlider(auraEditor.voicePanel, "TOPLEFT", auraEditor.voicePanel, 0, -43, function(value)
    local rule = selectedAura() or selectedItem() or selectedSkill()
    if rule then rule.speechSpeed = value; auraEditor.speedValue:SetText(tostring(value) .. "%") end
end, 100, 200, 10, 90)
auraEditor.speedValue = createLabel(auraEditor.voicePanel, "100%", "GameFontHighlight")
auraEditor.speedValue:SetPoint("LEFT", auraEditor.speedSlider, "RIGHT", 8, 0)
if auraEditor.speedSlider.Low then auraEditor.speedSlider.Low:SetText("100%") end
if auraEditor.speedSlider.High then auraEditor.speedSlider.High:SetText("200%") end

end

local function buildCreationView()
creationView = CreateFrame("Frame", nil, detailPanel, "BackdropTemplate")
creationView:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", ns.Layout.MARGIN, -ns.Layout.MARGIN)
creationView:SetPoint("BOTTOMRIGHT", detailPanel, "BOTTOMRIGHT", -ns.Layout.MARGIN, ns.Layout.MARGIN)
    stylePanel(creationView, 0.105, 0.115, 0.13)
    creationView.heading = makeSectionLabel(creationView, "ADD RULE", ns.Layout.PAD, -15)
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
    skillSearchStatus:SetPoint("TOPLEFT", creationView, "TOPLEFT", ns.Layout.PAD, -92)
    skillSearchStatus:SetPoint("RIGHT", creationView, "RIGHT", ns.Layout.RIGHT, 0)
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
        if row.eventKey == "expire" then ns.Layout.setExpirationPanelExpanded(ns.notificationPanels.expire, true) end
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
        ns.queueItemScan(0.1)
        refreshList()
        updateRulePreviewFromEditor()
    elseif selectedSkill() and not editorLoading then
        local checked = ruleEnabledCheck:GetChecked()
        selectedSkillRule.enabled = checked == true or checked == 1
        ns.SkillTracking.ResetRule(selectedSkillRule)
        scanSkillRules()
        refreshList()
        updateRulePreviewFromEditor()
    end
end)
auraEditor.slotTrackCheck:SetScript("OnClick", function(self)
    local rule = selectedItem()
    if editorLoading or not rule then return end
    saveDetails()
    local wanted = self:GetChecked()
    wanted = wanted == true or wanted == 1
    local slotID = wanted and ns.findEquippedItemSlot(rule.itemID) or nil
    if wanted and not slotID then
        self:SetChecked(false)
        setStatus("Equip the item to track its slot.", true)
        return
    end
    -- The message follows the mode only while it is the generated default of the old mode.
    local oldDefault = rule.slotID and ns.slotDefaultMessage(rule.slotID) or ((rule.name or L("Item")) .. " " .. L("ready"))
    if rule.message == oldDefault then
        rule.message = slotID and ns.slotDefaultMessage(slotID) or ((rule.name or L("Item")) .. " " .. L("ready"))
    end
    rule.slotID = slotID
    itemCooldownStates[rule] = nil
    ns.queueItemScan(0.1)
    refreshList()
    updateDetails()
end)
addHelpTooltip(auraEditor.slotTrackCheck, "Track the slot, not the item",
    "Follow whatever is equipped in this slot, so swapping trinkets keeps one rule. A swapped-in item never announces its equip lockout.")
for _, panel in pairs(ns.notificationPanels) do
    local notificationPanel = panel
    panel.ttsEnabled:SetScript("OnClick", function()
        if selectedAura() then onAuraToggle() else saveDetails(); updateRulePreviewFromEditor() end
        ns.Layout.setExpirationPanelExpanded(notificationPanel, true)
        ns.setNotificationPanelShown(notificationPanel, true)
        layoutSharedEditor(selectedCategory == "auras")
    end)
    panel.soundEnabled:SetScript("OnClick", function()
        if selectedAura() then onAuraToggle() else saveDetails(); updateRulePreviewFromEditor() end
        ns.Layout.setExpirationPanelExpanded(notificationPanel, true)
        ns.setNotificationPanelShown(notificationPanel, true)
        layoutSharedEditor(selectedCategory == "auras")
    end)
    addHelpTooltip(panel.ttsEnabled, "TTS", "Speak a message when this event occurs.")
    addHelpTooltip(panel.soundEnabled, "Sound", "Play a Blizzard sound when this event occurs.")
    addHelpTooltip(panel.soundChoice, "Sound", "Choose a Blizzard sound effect.")
    addHelpTooltip(panel.soundChannel, "Audio channel", "Choose the WoW playback channel for this sound.")
    addHelpTooltip(panel.soundTest, "Test notification", "Play the selected sound on the selected channel.")
end

testApplyButton:SetScript("OnClick", function()
    saveDetails()
    if selectedAuraRule and not playTTS(selectedAuraRule.voiceID, ns.formatRuleNotificationMessage(selectedAuraRule, selectedAuraRule.applyMessage), selectedAuraRule.volume, selectedAuraRule.speechSpeed) then
        setStatus("TTS test could not be sent to WoW.", true)
    else
        setStatus("TTS test sent to WoW. Check audio in game.")
    end
end)
testExpireButton:SetScript("OnClick", function()
    saveDetails()
    if selectedAuraRule and not playTTS(selectedAuraRule.voiceID, ns.formatRuleNotificationMessage(selectedAuraRule, selectedAuraRule.expireMessage), selectedAuraRule.volume, selectedAuraRule.speechSpeed) then
        setStatus("TTS test could not be sent to WoW.", true)
    else
        setStatus("TTS test sent to WoW. Check audio in game.")
    end
end)
function ns.TestCurrentReady()
    saveDetails()
    local readyRule = selectedItem() or selectedSkill()
    local message = readyRule and ns.formatRuleNotificationMessage(readyRule, readyRule.message) or ""
    if readyRule and not playTTS(readyRule.voiceID, message, readyRule.volume, readyRule.speechSpeed) then
        setStatus("TTS test could not be sent to WoW.", true)
    else
        setStatus("TTS test sent to WoW. Check audio in game.")
    end
end
testItemButton:SetScript("OnClick", ns.TestCurrentReady)

addHelpTooltip(ruleNameBox, "Rule name", "Display name for this rule.")
addHelpTooltip(ruleEnabledCheck, "Active", "Enable or disable this rule.")
addHelpTooltip(triggerInputBox, "Triggers", "Search by spell name or enter one or more comma-separated spell IDs.")
addHelpTooltip(triggerAddButton, "Add triggers", "Add IDs, or search a full spell name and review the result before adding.")
addHelpTooltip(applyEnabledCheck, "TTS", "Speak a message when this aura event occurs.")
addHelpTooltip(applyMessageBox, "Notification message", "Message spoken when the aura appears.")
addHelpTooltip(testApplyButton, "Test notification", "Preview this message with the selected voice and volume.")
addHelpTooltip(expireEnabledCheck, "TTS", "Speak a message when this aura event occurs.")
addHelpTooltip(expireMessageBox, "Notification message", "Message spoken when the aura expires naturally.")
addHelpTooltip(testExpireButton, "Test notification", "Preview this message with the selected voice and volume.")
addHelpTooltip(readyMessageBox, "Ready notification", "Message spoken when the observed item cooldown is ready.")
addHelpTooltip(testItemButton, "Test notification", "Preview this message with the selected voice and volume.")
addHelpTooltip(auraEditor.skillTriggerDropdown, "Spell trigger", "Choose a spell cooldown, charge, or successful cast event to monitor.")
addHelpTooltip(auraEditor.skillLearnButton, "Learning Mode", "Observe this spell cast, its cooldown and charges, and changes to your own buffs and debuffs.")
addHelpTooltip(voiceDropdown.Button or voiceDropdown, "Voice", "Select the voice for this rule.")
addHelpTooltip(volumeSlider, "Volume", "Set the speech volume from 0 to 100.")
addHelpTooltip(auraEditor.speedSlider, "Speech speed", "Set the speech speed from 100% to 200%.")
addHelpTooltip(creationView.auraButton, "Aura", "Track buff, debuff, or item-effect auras.")
addHelpTooltip(creationView.itemButton, "Equipped item", "Choose an equipped item and announce when its cooldown is ready.")
addHelpTooltip(creationView.skillButton, "Spell cooldown", "Choose a spell from your spellbook and announce when its cooldown is ready.")
addHelpTooltip(creationView.cancelButton, "Cancel", "Return to the selected rule without creating a new one.")
updatePreviewButtons()
end

local function createEditorWidgets()
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
    ns.itemPickerReplaceRule = nil
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

-- A slot rule is a duplicate by slot; an item rule by item (a slot rule's last-seen item does not count).
function ns.itemRuleIsDuplicate(rule, itemID, slotID, trackSlot)
    if trackSlot then return rule.slotID == slotID end
    return not rule.slotID and rule.itemID == itemID
end

-- Slot mode for a pick: the user's checkbox choice once touched, otherwise on for the trinket slots.
function ns.pickerTracksSlot(slotID)
    local check = pickerPrompt and pickerPrompt.slotCheck
    if not check then return false end
    if check.userSet then return check:GetChecked() == true or check:GetChecked() == 1 end
    return slotID == 13 or slotID == 14
end

local function addPickedItem(slotID)
    local itemID = ns.getEquippedItemID(slotID)
    if not itemID then
        setStatus("No item in this equipment slot.", true)
        return
    end
    local replaceRule = ns.itemPickerReplaceRule
    local starterRule = selectedItemRule and selectedItemRule.starter == "trinket" and selectedItemRule or nil
    local trackSlot = ns.pickerTracksSlot(slotID)
    local replaceValid = false
    for _, rule in ipairs(WoWraVoxDB.items) do
        if rule == replaceRule then replaceValid = true end
    end
    if not replaceValid then replaceRule = nil end
    for _, rule in ipairs(WoWraVoxDB.items) do
        if ns.itemRuleIsDuplicate(rule, itemID, slotID, trackSlot) then
            addRuleMode = false
            stopItemPicker()
            selectedCategory = "items"
            selectedItemRule = rule
            refreshList()
            updateDetails()
            optionsFrame:Show()
            if replaceRule and rule ~= replaceRule then setStatus("Item already tracked.") end
            return
        end
    end

    local name, icon = getItemInfo(itemID, slotID)
    local rule = replaceRule or starterRule
    if rule then
        ns.retargetItemRule(rule, itemID, name, icon, trackSlot and slotID or nil)
    else
        rule = newItemRule(itemID, name, icon)
        if trackSlot then
            rule.slotID = slotID
            rule.message = ns.slotDefaultMessage(slotID)
        end
        ns.registerNewRule(rule, "items")
        table.insert(WoWraVoxDB.items, rule)
    end
    addRuleMode = false
    stopItemPicker()
    selectedCategory = "items"
    selectedItemRule = rule
    refreshList()
    updateDetails()
    ns.queueItemScan(0.1)
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
                    -- Show the default this slot would get until the user decides themselves.
                    local check = pickerPrompt and pickerPrompt.slotCheck
                    if check and not check.userSet then check:SetChecked(ns.pickerTracksSlot(self.slotID)) end
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

local function beginItemPicker(replaceRule)
    if InCombatLockdown and InCombatLockdown() then
        setStatus("Item selection is blocked in combat.", true)
        return
    end
    ns.itemPickerReplaceRule = replaceRule
    pickerActive = true
    pickerRetries = 0
    if pickerPrompt then
        local check = pickerPrompt.slotCheck
        -- Editing a slot rule keeps slot mode unless the user unticks it.
        check.userSet = replaceRule ~= nil and replaceRule.slotID ~= nil
        check:SetChecked(check.userSet)
        pickerPrompt:Show()
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
    pickerPrompt:SetSize(400, 118)
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
    pickerPrompt.slotCheck = CreateFrame("CheckButton", nil, pickerPrompt, "UICheckButtonTemplate")
    pickerPrompt.slotCheck:SetSize(24, 24)
    pickerPrompt.slotCheck:SetPoint("BOTTOMLEFT", pickerPrompt, "BOTTOMLEFT", 10, 10)
    pickerPrompt.slotCheck:SetScript("OnClick", function(self) self.userSet = true end)
    local slotLabel = createLabel(pickerPrompt, "Track the slot, not the item", "GameFontHighlightSmall")
    slotLabel:SetPoint("LEFT", pickerPrompt.slotCheck, "RIGHT", 2, 0)
    addHelpTooltip(pickerPrompt.slotCheck, "Track the slot, not the item",
        "Follow whatever is equipped in this slot, so swapping trinkets keeps one rule. Preset for the trinket slots.")
    pickerPrompt:HookScript("OnHide", function()
        if pickerActive then stopItemPicker() end
    end)
end

function ns.createSettingsPanel()
    settingsPanel = CreateFrame("Frame", nil, optionsFrame, "BackdropTemplate")
    settingsPanel:SetPoint("TOPRIGHT", optionsFrame.settingsButton, "BOTTOMRIGHT", 0, -5)
    settingsPanel:SetSize(math.min(611, math.max(320, UIParent:GetWidth() - 24)), math.min(232, math.max(220, UIParent:GetHeight() - 24)))
    settingsPanel:SetFrameStrata("DIALOG")
    settingsPanel:SetFrameLevel(optionsFrame:GetFrameLevel() + 100)
    settingsPanel:SetClampedToScreen(true)
    stylePanel(settingsPanel, 0.19, 0.19, 0.18)
    local title = createLabel(settingsPanel, "DISPLAY OPTIONS", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", ns.Layout.PAD, -16)
    title:SetTextColor(1, 0.82, 0.2)
    local titleRule = settingsPanel:CreateTexture(nil, "ARTWORK")
    titleRule:SetTexture("Interface\\Buttons\\WHITE8X8")
    titleRule:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", ns.Layout.PAD, -43)
    titleRule:SetPoint("TOPRIGHT", settingsPanel, "TOPRIGHT", ns.Layout.RIGHT, -43)
    titleRule:SetHeight(1)
    titleRule:SetColorTexture(0.72, 0.55, 0.22, 0.9)
    local definitions = {
        { key = "tooltipIDs", text = "IDs in game tooltips", help = "Shows spell IDs for auras and spells, plus item and available effect IDs for items." },
    }
    local displayChecks = {}
    for index, definition in ipairs(definitions) do
        local check = CreateFrame("CheckButton", nil, settingsPanel, "UICheckButtonTemplate")
        check:SetSize(30, 30)
        check:SetChecked(WoWraVoxDB.settings[definition.key])
        local label = createLabel(settingsPanel, definition.text, "GameFontHighlightSmall")
        label:SetPoint("LEFT", check, "RIGHT", 8, 0)
        check.label = label
        check:SetScript("OnClick", function(self)
            local checked = self:GetChecked()
            local enabled = checked == true or checked == 1
            WoWraVoxDB.settings[definition.key] = enabled
        end)
        addHelpTooltip(check, definition.text, definition.help)
        settingsPanel[definition.key] = check
        displayChecks[index] = check
    end

    local profileList = {}
    local function profileDropdown(width, choices, onSelect)
        local dropdown = CreateFrame("Frame", nil, settingsPanel, "UIDropDownMenuTemplate")
        UIDropDownMenu_SetWidth(dropdown, width)
        local function initialize(menu, level)
            for _, choice in ipairs(choices) do
                local selected = choice
                local info = UIDropDownMenu_CreateInfo()
                info.text = selected.text or L(selected.key)
                info.value = selected.value
                info.checked = dropdown.profileValue == selected.value
                info.func = function()
                    dropdown.profileValue = selected.value
                    onSelect(selected.value)
                    UIDropDownMenu_SetSelectedValue(dropdown, selected.value)
                    UIDropDownMenu_SetText(dropdown, selected.text or L(selected.key))
                    CloseDropDownMenus()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end
        UIDropDownMenu_Initialize(dropdown, initialize)
        dropdown.SetProfileValue = function(value, text)
            dropdown.profileValue = value
            UIDropDownMenu_SetSelectedValue(dropdown, value)
            UIDropDownMenu_SetText(dropdown, text or L("No profiles"))
            UIDropDownMenu_Initialize(dropdown, initialize)
        end
        return dropdown
    end

    local profileHeading = makeSectionLabel(settingsPanel, "PROFILES", ns.Layout.PAD, -104)
    local profileRule = settingsPanel:CreateTexture(nil, "ARTWORK")
    profileRule:SetTexture("Interface\\Buttons\\WHITE8X8")
    profileRule:SetHeight(1)
    profileRule:SetColorTexture(0.72, 0.55, 0.22, 0.9)
    local characterProfileLabel = createLabel(settingsPanel, "Profile", "GameFontNormalSmall")
    characterProfileLabel:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", ns.Layout.PAD, -132)
    local characterProfileDropdown = profileDropdown(330, profileList, function(profileID)
        if ns.Profiles.AssignCharacterProfile(profileID) then
            if settingsPanel.RefreshProfileControls then settingsPanel.RefreshProfileControls() end
        end
    end)

    local profileNameLabel = createLabel(settingsPanel, "Profile name", "GameFontNormalSmall")
    profileNameLabel:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", ns.Layout.PAD, -177)
    local copyProfileName = createEditBox(settingsPanel, 246, 30)
    local newProfileButton = CreateFrame("Button", nil, settingsPanel, "UIPanelButtonTemplate")
    newProfileButton:SetSize(92, 30)
    newProfileButton:SetText(L("New"))
    local copyProfileButton = CreateFrame("Button", nil, settingsPanel, "UIPanelButtonTemplate")
    copyProfileButton:SetSize(88, 30)
    copyProfileButton:SetText(L("Copy"))

    local diagnosticsToggle = CreateFrame("Button", nil, settingsPanel, "UIPanelButtonTemplate")
    diagnosticsToggle:SetSize(190, 26)
    local diagnosticsControls = CreateFrame("Frame", nil, settingsPanel)
    local debugCheck = CreateFrame("CheckButton", nil, diagnosticsControls, "UICheckButtonTemplate")
    debugCheck:SetSize(28, 28)
    local debugLabel = createLabel(diagnosticsControls, L("Debug logging"), "GameFontHighlightSmall")
    debugLabel:SetPoint("LEFT", debugCheck, "RIGHT", 4, 0)
    local testTTSButton = CreateFrame("Button", nil, diagnosticsControls, "UIPanelButtonTemplate")
    testTTSButton:SetSize(88, 24)
    testTTSButton:SetText(L("Test TTS"))
    local showLogButton = CreateFrame("Button", nil, diagnosticsControls, "UIPanelButtonTemplate")
    showLogButton:SetSize(88, 24)
    showLogButton:SetText(L("Show log"))
    local diagnosticsStatus = createLabel(diagnosticsControls, "", "GameFontHighlightSmall")
    diagnosticsStatus:SetJustifyH("LEFT")
    diagnosticsStatus:SetWordWrap(true)

    local function refreshDiagnosticsStatus(status)
        status = status or (ns.AuraSoundFallback and ns.AuraSoundFallback.GetStatus()) or {}
        debugCheck:SetChecked(ns.SkillTracking.debugEnabled == true)
        if not status.available then
            diagnosticsStatus:SetText(L("Native aura sound API unavailable."))
        elseif status.queued then
            diagnosticsStatus:SetText(L("Sound changes pending until combat ends."))
        else
            diagnosticsStatus:SetText(string.format(L("Aura sounds: %d/%d registered, %d refused."),
                tonumber(status.registered) or 0, tonumber(status.wanted) or 0, tonumber(status.refused) or 0))
        end
    end
    debugCheck:SetChecked(ns.SkillTracking.debugEnabled == true)
    debugCheck:SetScript("OnClick", function(self)
        ns.SkillTracking.SetDebugEnabled(self:GetChecked() == true or self:GetChecked() == 1)
    end)
    testTTSButton:SetScript("OnClick", function()
        if selectedAuraRule and playTTS(selectedAuraRule.voiceID, L("WoWraVox combat voice test."), selectedAuraRule.volume, selectedAuraRule.speechSpeed) then
            diagnosticsStatus:SetText(L("TTS test sent."))
        else
            diagnosticsStatus:SetText(L("Select an aura rule with a voice before testing TTS."))
        end
    end)
    showLogButton:SetScript("OnClick", function() ns.SkillTracking.ShowDebug() end)
    addHelpTooltip(debugCheck, L("Debug logging"), L("Temporarily log aura visibility, spell cooldown snapshots, cast events, and output attempts. Use /wvdebug show to copy the log."))

    local function layoutProfileControls()
        local left = 132
        local rowWidth = math.max(150, settingsPanel:GetWidth() - left - 31)
        local stackedChecks = settingsPanel:GetWidth() < 520
        local sectionShift = stackedChecks and 37 or 0
        for index, check in ipairs(displayChecks) do
            check:ClearAllPoints()
            local x = (index == 1 or stackedChecks) and ns.Layout.ROW_X or 340
            local y = -54 - (index == 2 and stackedChecks and 37 or 0)
            check:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", x, y)
        end
        -- Absolute y from the top, fixed at the collapsed panel height: a LEFT/RIGHT anchor is
        -- vertically centered and would drift when the diagnostics expander changes the height.
        local collapsedHeight = math.min((stackedChecks and 272 or (rowWidth >= 446 and 232 or 260)) + 36,
            math.max(220, UIParent:GetHeight() - 24))
        local ruleY = -(collapsedHeight / 2 + 95 + sectionShift) + 0.5
        profileRule:ClearAllPoints()
        profileRule:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", ns.Layout.PAD, ruleY)
        profileRule:SetPoint("TOPRIGHT", settingsPanel, "TOPRIGHT", ns.Layout.RIGHT, ruleY)
        profileHeading:ClearAllPoints()
        profileHeading:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", ns.Layout.PAD, -104 - sectionShift)
        characterProfileLabel:ClearAllPoints()
        characterProfileLabel:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", ns.Layout.PAD, -132 - sectionShift)
        characterProfileDropdown:ClearAllPoints()
        characterProfileDropdown:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", left - ns.Layout.EDITBOX_INSET - ns.Layout.DD_INSET_L, -129 - sectionShift)
        UIDropDownMenu_SetWidth(characterProfileDropdown, math.min(429, rowWidth - 17))
        profileNameLabel:ClearAllPoints()
        profileNameLabel:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", ns.Layout.PAD, -177 - sectionShift)
        copyProfileName:ClearAllPoints()
        copyProfileName:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", left, -173 - sectionShift)
        newProfileButton:ClearAllPoints()
        copyProfileButton:ClearAllPoints()
        if rowWidth >= 446 then
            copyProfileName:SetWidth(246)
            newProfileButton:SetPoint("LEFT", copyProfileName, "RIGHT", 12, 0)
            copyProfileButton:SetPoint("LEFT", newProfileButton, "RIGHT", 10, 0)
        else
            copyProfileName:SetWidth(rowWidth)
            newProfileButton:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", left, -201 - sectionShift)
            copyProfileButton:SetPoint("TOPRIGHT", settingsPanel, "TOPRIGHT", ns.Layout.RIGHT, -201 - sectionShift)
        end
        diagnosticsToggle:ClearAllPoints()
        diagnosticsToggle:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", ns.Layout.PAD, -235 - sectionShift)
        diagnosticsToggle:SetText(L(settingsPanel.diagnosticsExpanded and "Hide diagnostics" or "Combat diagnostics"))
        diagnosticsControls:ClearAllPoints()
        diagnosticsControls:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", ns.Layout.PAD, -267 - sectionShift)
        local diagnosticsWidth = math.max(180, settingsPanel:GetWidth() - 64)
        diagnosticsControls:SetWidth(diagnosticsWidth)
        debugCheck:ClearAllPoints()
        testTTSButton:ClearAllPoints()
        showLogButton:ClearAllPoints()
        diagnosticsStatus:ClearAllPoints()
        debugCheck:SetPoint("TOPLEFT", diagnosticsControls, "TOPLEFT", 0, 0)
        testTTSButton:SetPoint("TOPLEFT", diagnosticsControls, "TOPLEFT", 0, -34)
        showLogButton:SetPoint("LEFT", testTTSButton, "RIGHT", 4, 0)
        diagnosticsStatus:SetPoint("TOPLEFT", diagnosticsControls, "TOPLEFT", 0, -66)
        diagnosticsStatus:SetWidth(diagnosticsWidth)
        diagnosticsControls:SetHeight(96)
        diagnosticsControls:SetShown(settingsPanel.diagnosticsExpanded == true)
        local wantedHeight = collapsedHeight
        if settingsPanel.diagnosticsExpanded then wantedHeight = wantedHeight + diagnosticsControls:GetHeight() + 40 end
        wantedHeight = math.min(wantedHeight, math.max(220, UIParent:GetHeight() - 24))
        if math.abs(settingsPanel:GetHeight() - wantedHeight) > 1 then
            settingsPanel:SetHeight(wantedHeight)
        end
    end
    diagnosticsToggle:SetScript("OnClick", function()
        settingsPanel.diagnosticsExpanded = not settingsPanel.diagnosticsExpanded
        layoutProfileControls()
        refreshDiagnosticsStatus()
    end)
    layoutProfileControls()
    settingsPanel:HookScript("OnSizeChanged", layoutProfileControls)
    if ns.AuraSoundFallback then ns.AuraSoundFallback.SetStatusCallback(refreshDiagnosticsStatus) end

    local function showProfileResult(profileID, reason, successText, failedText)
        if profileID then
            copyProfileName:SetText("")
            if settingsPanel.RefreshProfileControls then settingsPanel.RefreshProfileControls() end
            setStatus(successText)
        elseif reason == "empty" then
            setStatus("Enter a profile name.", true)
        elseif reason == "duplicate" then
            setStatus("A profile with this name already exists.", true)
        else
            setStatus(failedText, true)
        end
    end
    newProfileButton:SetScript("OnClick", function()
        local profileID, reason = ns.Profiles.CreateCharacterProfile(copyProfileName:GetText())
        showProfileResult(profileID, reason, "Profile created.", "Profile could not be created.")
    end)
    copyProfileButton:SetScript("OnClick", function()
        local profileID, reason = ns.Profiles.CopyProfile(copyProfileName:GetText())
        showProfileResult(profileID, reason, "Profile copied.", "Profile could not be copied.")
    end)

    settingsPanel.RefreshProfileControls = function()
        local profiles = ns.Profiles.GetProfiles()
        wipe(profileList)
        for _, profile in ipairs(profiles) do
            table.insert(profileList, { value = profile.id, text = profile.name })
        end
        local characterProfileID = ns.Profiles.GetCharacterProfileID()
        characterProfileDropdown.SetProfileValue(characterProfileID,
            ns.Profiles.GetProfileName(characterProfileID) or L("No profiles"))
        debugCheck:SetChecked(ns.SkillTracking.debugEnabled == true)
        refreshDiagnosticsStatus()
    end
    settingsPanel.RefreshProfileControls()
    addHelpTooltip(characterProfileDropdown, "Profile", "Choose the profile used by this character.")
    addHelpTooltip(newProfileButton, "New profile", "Create a profile with the three starter rules.")
    addHelpTooltip(copyProfileButton, "Copy profile", "Copy the selected profile for this character.")
    addHelpTooltip(diagnosticsToggle, L("Combat diagnostics"), L("Temporary debug controls. Settings reset on /reload."))
    settingsPanel:Hide()
end

ns.Layout.layoutOptionsColumns = function()
    if not (optionsFrame and listPanel and detailPanel) then return end
    local editorScrollOffset = editorScroll and editorScroll:GetVerticalScroll() or 0
    local listWidth = 362
    listPanel:SetWidth(listWidth)
    detailPanel:ClearAllPoints()
    detailPanel:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", ns.Layout.MARGIN + listWidth + ns.Layout.MARGIN, -64)
    detailPanel:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -ns.Layout.MARGIN, ns.Layout.MARGIN)
    detailPanel.rulePreviewPanel:ClearAllPoints()
    detailPanel.rulePreviewPanel:SetPoint("BOTTOMLEFT", detailPanel, "BOTTOMLEFT", 0, 0)
    detailPanel.rulePreviewPanel:SetPoint("BOTTOMRIGHT", detailPanel, "BOTTOMRIGHT", -8, 0)
    detailPanel.rulePreviewPanel:SetHeight(ns.Layout.previewHeight)
    detailPanel.rulePreviewText:SetHeight(ns.Layout.previewHeight - 50)
    editorScroll:ClearAllPoints()
    editorScroll:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", 0, -2)
    editorScroll:SetPoint("BOTTOMRIGHT", detailPanel.rulePreviewPanel, "TOPRIGHT", 0, 8)
    if statusText then
        statusText:ClearAllPoints()
        statusText:SetPoint("BOTTOMLEFT", detailPanel, "BOTTOMLEFT", 0, -1)
        statusText:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -24, 25)
    end
    if listScroll then
        listChild:SetWidth(math.max(1, listScroll:GetWidth()))
        ns.Layout.requestRefreshList()
    end
    ns.Layout.clampEditorScroll(editorScrollOffset)
end

function ns.createOptions()
    optionsFrame = CreateFrame("Frame", "WoWraVoxOptions", UIParent, "BackdropTemplate")
    stylePanel(optionsFrame, 0.035, 0.04, 0.05)
    optionsFrame:SetScale(ns.Layout.getWindowScale())
    optionsFrame:SetSize(ns.Layout.maxWidth, ns.Layout.maxHeight)
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
    header:SetHeight(50)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() optionsFrame:StartMoving() end)
    header:SetScript("OnDragStop", function() optionsFrame:StopMovingOrSizing() end)

    local headerBackground = header:CreateTexture(nil, "BACKGROUND")
    headerBackground:SetAllPoints()
    headerBackground:SetTexture("Interface\\FrameGeneral\\UI-Background-Marble")
    headerBackground:SetVertexColor(0.35, 0.29, 0.16)
    headerBackground:SetAlpha(0.62)
    local headerShade = header:CreateTexture(nil, "BACKGROUND", nil, 1)
    headerShade:SetAllPoints()
    headerShade:SetColorTexture(0.025, 0.025, 0.03, 0.94)
    local headerAccent = header:CreateTexture(nil, "ARTWORK")
    headerAccent:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
    headerAccent:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
    headerAccent:SetHeight(1)
    headerAccent:SetTexture("Interface\\Buttons\\WHITE8X8")
    headerAccent:SetColorTexture(0.62, 0.48, 0.22, 1)

    local brandIcon = header:CreateTexture(nil, "ARTWORK")
    brandIcon:SetSize(40, 40)
    brandIcon:SetPoint("LEFT", header, "LEFT", 20, 0)
    brandIcon:SetTexture("Interface\\AddOns\\WoWraVox\\Assets\\WoWraVoxIcon.tga")

    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", header, "CENTER", 0, 0)
    title:SetText("WoWraVox")
    title:SetTextColor(1, 0.82, 0.2)

    local closeButton = CreateFrame("Button", nil, header, "BackdropTemplate")
    closeButton:SetSize(36, 36)
    closeButton:SetPoint("RIGHT", header, "RIGHT", -20, 0)
    closeButton:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-Panel-Button-Up",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    closeButton:SetBackdropColor(0.42, 0.34, 0.18, 1)
    closeButton:SetBackdropBorderColor(0.82, 0.62, 0.24, 1)
    local closeMarkA = closeButton:CreateTexture(nil, "ARTWORK")
    closeMarkA:SetColorTexture(0.95, 0.08, 0.04, 1)
    closeMarkA:SetSize(16, 3)
    closeMarkA:SetPoint("CENTER")
    closeMarkA:SetRotation(math.rad(45))
    local closeMarkB = closeButton:CreateTexture(nil, "ARTWORK")
    closeMarkB:SetColorTexture(0.95, 0.08, 0.04, 1)
    closeMarkB:SetSize(16, 3)
    closeMarkB:SetPoint("CENTER")
    closeMarkB:SetRotation(math.rad(-45))
    closeButton:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.5, 0.12, 0.08, 1)
        self:SetBackdropBorderColor(1, 0.72, 0.2, 1)
    end)
    closeButton:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.42, 0.34, 0.18, 1)
        self:SetBackdropBorderColor(0.82, 0.62, 0.24, 1)
    end)
    closeButton:SetScript("OnClick", function()
        saveDetails()
        optionsFrame:Hide()
    end)
    addHelpTooltip(closeButton, "Close", "Close the WoWraVox window.")

    optionsFrame.settingsButton = CreateFrame("Button", nil, header, "BackdropTemplate")
    optionsFrame.settingsButton:SetSize(36, 36)
    optionsFrame.settingsButton:SetPoint("RIGHT", closeButton, "LEFT", -6, 0)
    optionsFrame.settingsButton:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-Panel-Button-Up",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    optionsFrame.settingsButton:SetBackdropColor(0.42, 0.34, 0.18, 1)
    optionsFrame.settingsButton:SetBackdropBorderColor(0.82, 0.62, 0.24, 1)
    optionsFrame.settingsButton.icon = optionsFrame.settingsButton:CreateTexture(nil, "ARTWORK")
    optionsFrame.settingsButton.icon:SetTexture("Interface\\Buttons\\UI-OptionsButton")
    optionsFrame.settingsButton.icon:SetPoint("CENTER")
    optionsFrame.settingsButton.icon:SetSize(24, 24)
    optionsFrame.settingsButton:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.58, 0.46, 0.2, 1)
        self:SetBackdropBorderColor(1, 0.82, 0.3, 1)
    end)
    optionsFrame.settingsButton:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.42, 0.34, 0.18, 1)
        self:SetBackdropBorderColor(0.82, 0.62, 0.24, 1)
    end)
    ns.createSettingsPanel()
    optionsFrame.settingsButton:SetScript("OnClick", function()
        if settingsPanel:IsShown() then settingsPanel:Hide() else settingsPanel:Show() end
    end)
    addHelpTooltip(optionsFrame.settingsButton, "Display options", "Configure tooltip IDs.")

    listPanel = CreateFrame("Frame", nil, optionsFrame, "BackdropTemplate")
    listPanel:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", ns.Layout.MARGIN, -64)
    listPanel:SetPoint("BOTTOMLEFT", optionsFrame, "BOTTOMLEFT", ns.Layout.MARGIN, ns.Layout.MARGIN)
    listPanel:SetWidth(362)
    stylePanel(listPanel, 0.115, 0.115, 0.11)
    local listHeading = createLabel(listPanel, "RULES", "GameFontNormalSmall")
    listHeading:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 18, -12)
    listHeading:SetTextColor(1, 0.82, 0.2)
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
    listEmptyText:SetPoint("RIGHT", listPanel, "RIGHT", -30, 0)
    listEmptyText:SetJustifyH("LEFT")
    listScroll:HookScript("OnSizeChanged", function(self, width)
        listChild:SetWidth(math.max(1, width))
        ns.Layout.requestRefreshList()
    end)

    createEditorWidgets()
    ns.Layout.layoutOptionsColumns()

    optionsFrame.addButton = CreateFrame("Button", nil, listPanel, "UIPanelButtonTemplate")
    optionsFrame.addButton:SetHeight(28)
    optionsFrame.addButton:SetPoint("BOTTOMLEFT", listPanel, "BOTTOMLEFT", 9, 5)
    optionsFrame.addButton:SetPoint("BOTTOMRIGHT", listPanel, "BOTTOMRIGHT", -9, 5)
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
    statusText:SetPoint("BOTTOMLEFT", detailPanel, "BOTTOMLEFT", 0, -1)
    statusText:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -24, 25)
    statusText:SetJustifyH("LEFT")
    ns.Layout.layoutOptionsColumns()

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
    createPickerPrompt()
end

function ns.Profiles.ActivateUI()
    if not initializeDatabase() then return end
    ns.SkillTracking.CancelLearning(L("Profile changed."), true)
    if ns.screenAnchorTarget then ns.setScreenAnchorUnlocked(ns.screenAnchorTarget, false) end
    for key, frame in pairs(ns.screenFrames) do
        frame.generation = (frame.generation or 0) + 1
        frame.active = false
        frame:Hide()
        ns.screenFrames[key] = nil
    end
    activeAuras = {}
    auraByInstanceID = {}
    ns._Aura.resetEventState()
    wipe(itemCooldownStates)
    ns.SkillTracking.ResetAll()
    auraBaselineComplete = false
    selectedAuraRule = WoWraVoxDB.auras[1]
    selectedItemRule = WoWraVoxDB.items[1]
    selectedSkillRule = WoWraVoxDB.skills[1]
    selectedCategory = "auras"
    if not selectedAuraRule and selectedItemRule then selectedCategory = "items"
    elseif not selectedAuraRule and not selectedItemRule and selectedSkillRule then selectedCategory = "skills" end
    lastRenderedRule = nil
    lastRenderedCategory = nil
    rebuildAuraWatches()
    syncAllAuras(true)
    if optionsFrame and optionsFrame:IsShown() then
        refreshList()
        updateDetails()
    end
    if settingsPanel then
        if settingsPanel.tooltipIDs then settingsPanel.tooltipIDs:SetChecked(WoWraVoxDB.settings.tooltipIDs) end
        if settingsPanel.RefreshProfileControls then settingsPanel.RefreshProfileControls() end
    end
    ns.queueItemScan(0.2)
    scanSkillRules()
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

ns.eventFrame = CreateFrame("Frame")
ns.eventFrame:RegisterEvent("ADDON_LOADED")
function ns.onEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName ~= addonName then return end
        self:UnregisterEvent("ADDON_LOADED")
        -- Always-on load timing (ns.Prof.load, shown by /wvprof): a few clock reads, once per session.
        local load = ns.Prof.load
        local clock = ns.Prof.clock
        local loadStart = clock()
        load.files = loadStart - load.chunkStart
        ns.Profiles.onBeforeChange = function()
            ns.SkillTracking.CancelLearning(L("Profile changed."), true)
            saveDetails()
        end
        ns.Profiles.onChanged = ns.Profiles.ActivateUI
        ns.Profiles.Prepare()
        if not initializeDatabase() then return end
        ns.Profiles.CreateInitialProfile()
        ns.NormalizeAllProfiles()
        local stamp = clock()
        load.db = stamp - loadStart
        ns.createOptions()
        load.options = clock() - stamp
        stamp = clock()
        selectedAuraRule = WoWraVoxDB.auras[1]
        selectedItemRule = WoWraVoxDB.items[1]
        selectedSkillRule = WoWraVoxDB.skills[1]
        if not selectedAuraRule and selectedItemRule then selectedCategory = "items"
        elseif not selectedAuraRule and not selectedItemRule and selectedSkillRule then selectedCategory = "skills" end
        refreshList()
        updateDetails()
        load.refresh = clock() - stamp
        SLASH_WOWRAVOXPROF1 = "/wvprof"
        SlashCmdList.WOWRAVOXPROF = ns.Prof.Command
        SLASH_WOWRAVOX1 = "/wowravox"
        SLASH_WOWRAVOX2 = "/wvr"
        SlashCmdList.WOWRAVOX = ns.ToggleOptions
        SLASH_WOWRAVOXDEBUG1 = "/wvdebug"
        SLASH_WOWRAVOXDEBUG2 = "/wvrdebug"
        SlashCmdList.WOWRAVOXDEBUG = ns.SkillTracking.HandleDebugCommand
        SLASH_WOWRAVOXTTS1 = "/wvttstest"
        SlashCmdList.WOWRAVOXTTS = function(message)
            local requestedID = trim(message)
            local rule = requestedID ~= "" and findRuleByID(requestedID) or selectedRule()
            if requestedID ~= "" and not rule then
                if DEFAULT_CHAT_FRAME then
                    DEFAULT_CHAT_FRAME:AddMessage("|cffd8b65aWoWraVox:|r " ..
                        string.format(L("Unknown rule ID: %s"), requestedID))
                end
                return
            end
            local ruleID = rule and tostring(rule.id or "selected") or "none"
            local voiceID = rule and tonumber(rule.voiceID) or getDefaultVoiceID()
            local volume = rule and tonumber(rule.volume) or 100
            local speedPercent = rule and tonumber(rule.speechSpeed) or 100
            local rate = ns._Aura.getTTSRate(speedPercent)
            local _, result = playTTS(voiceID, L("WoWraVox combat voice test."), volume, speedPercent)
            local inCombat = InCombatLockdown and InCombatLockdown() or false
            local probe = string.format("rule=%s source=manual combat=%s voice=%s volume=%s rate=%s result=%s",
                ruleID, tostring(inCombat), tostring(voiceID), tostring(volume), tostring(rate), tostring(result))
            if ns.AuraSoundFallback then
                ns.AuraSoundFallback.Log("TTS-PROBE", probe)
            end
            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage("|cffd8b65aWoWraVox:|r " ..
                    string.format(L("TTS probe: %s. Audible output must be checked."), probe))
            end
        end
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterUnitEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
        self:RegisterUnitEvent("UNIT_AURA", "player")
        self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
        self:RegisterEvent("SPELL_DATA_LOAD_RESULT")
        self:RegisterEvent("VOICE_CHAT_TTS_VOICES_UPDATE")
        self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
        self:RegisterEvent("UNIT_INVENTORY_CHANGED")
        self:RegisterEvent("BAG_UPDATE_COOLDOWN")
        self:RegisterEvent("SPELL_UPDATE_COOLDOWN")
        self:RegisterEvent("SPELL_UPDATE_CHARGES")
        self:RegisterEvent("PLAYER_REGEN_DISABLED")
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        self:RegisterEvent("PLAYER_LOGOUT")
        stamp = clock()
        rebuildAuraWatches()
        load.watches = clock() - stamp
        ns.queueItemScan(0.5)
        scanSkillRules()
        load.total = clock() - loadStart
    elseif event == "PLAYER_ENTERING_WORLD" then
        local load = ns.Prof.load
        local started = not load.pew and ns.Prof.clock() or nil
        local profileOK, profileChanged = ns.Profiles.ActivateCurrent()
        if profileOK and profileChanged then ns.Profiles.ActivateUI() end
        if settingsPanel and settingsPanel.RefreshProfileControls then settingsPanel.RefreshProfileControls() end
        ns.refreshScreenFontChoices()
        if optionsFrame and optionsFrame:IsShown() then updateDetails() end
        if started then load.pew = ns.Prof.clock() - started end
        C_Timer.After(0.8, function()
            local syncStarted = not load.pewSync and ns.Prof.clock() or nil
            syncAllAuras(true)
            ns.queueItemScan(0.2)
            scanSkillRules()
            if syncStarted then load.pewSync = ns.Prof.clock() - syncStarted end
        end)
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        ns.SkillTracking.CancelLearning(L("Specialization changed."), true)
        C_Timer.After(0.1, function()
            local profileOK, profileChanged = ns.Profiles.ActivateCurrent()
            if profileOK and profileChanged then ns.Profiles.ActivateUI() end
            if profileOK and not profileChanged then ns.RefreshRuleActivationState() end
            if settingsPanel and settingsPanel.RefreshProfileControls then settingsPanel.RefreshProfileControls() end
        end)
    elseif event == "UNIT_AURA" then
        local unit, updateInfo = ...
        ns.SkillTracking.HandleEvent(event, ...)
        onUnitAuraUpdate(unit, updateInfo)
    elseif event == "SPELL_DATA_LOAD_RESULT" then
        local spellID, success = ...
        if not spellLoadRequests[spellID] then return end
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
            if triggerInputBox and triggerInputBox:IsShown() then
                local query = trim(triggerInputBox:GetText())
                local nameSearch = triggerAddButton and triggerAddButton.nameSearch
                local exactResult = triggerAddButton and triggerAddButton.exactResult
                local searchStillCurrent = (nameSearch and nameSearch.rule == selectedAura() and nameSearch.query == query)
                    or (exactResult and exactResult.rule == selectedAura() and exactResult.query == query)
                if searchStillCurrent or (triggerInputBox:HasFocus() and (query:match("^%d+$") or #query >= 3)) then
                    runTriggerSearch()
                end
                if searchStillCurrent and nameSearch and nameSearch.id == spellID and not nameSearch.pending
                    and not (triggerAddButton and triggerAddButton.exactResult) and not ns.spellSearch.partial then
                    ns.runPartialSpellSearch(query, nameSearch.rule, searchGeneration, false)
                end
            end
        end
    elseif event == "VOICE_CHAT_TTS_VOICES_UPDATE" then
        if optionsFrame:IsShown() then updateDetails() end
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        ns.queueItemScan(0.15)
        C_Timer.After(0.7, function() ns.queueItemScan(0.05) end)
        C_Timer.After(1.8, function() ns.queueItemScan(0.05) end)
    elseif event == "UNIT_INVENTORY_CHANGED" then
        local unit = ...
        if unit == "player" then ns.queueItemScan(0.15) end
    elseif event == "BAG_UPDATE_COOLDOWN" then
        ns.queueItemScan(0.05)
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        scanSkillRules(event)
        ns.SkillTracking.ObserveLearningSpell(event)
    elseif event == "SPELL_UPDATE_CHARGES" then
        scanSkillRules(event)
        ns.SkillTracking.ObserveLearningSpell(event)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, castSpellID = ...
        ns._Aura.handleCast(unit, castGUID, castSpellID)
        ns.SkillTracking.HandleEvent(event, ...)
    elseif event == "PLAYER_LOGOUT" then
        ns.SkillTracking.CancelLearning(L("Player logged out."), true)
        if optionsFrame and optionsFrame:IsShown() then saveDetails() end
        ns.NormalizeAllProfiles()
        ns.Profiles.PrepareSavedVariables()
    elseif event == "PLAYER_REGEN_DISABLED" then
        if pickerActive then
            stopItemPicker()
            setStatus("Item selection was stopped when combat started.", true)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        queueAuraSync()
        ns.queueItemScan(0.05)
    elseif event:find("^VOICE_CHAT_TTS_PLAYBACK_") then
        ns._Aura.onTTSEvent(event, ...)
    end
end
ns.eventFrame:SetScript("OnEvent", ns.onEvent)
