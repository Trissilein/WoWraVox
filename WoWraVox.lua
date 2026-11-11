local addonName, ns = ...
local DB_VERSION = 5

-- Readable window text: WoWraVox's own font objects, two points above Blizzard's GameFont(Normal|Highlight)(Small).
do
    local function makeFont(name, template, size)
        if _G[name] or not (CreateFont and _G[template]) then return end
        local font = CreateFont(name)
        font:CopyFontObject(_G[template])
        local file, _, flags = _G[template]:GetFont()
        if file then font:SetFont(file, size, flags or "") end
    end
    makeFont("WoWraVoxFontNormalSmall", "GameFontNormalSmall", 12)
    makeFont("WoWraVoxFontHighlightSmall", "GameFontHighlightSmall", 12)
    makeFont("WoWraVoxFontNormal", "GameFontNormal", 14)
    makeFont("WoWraVoxFontHighlight", "GameFontHighlight", 14)
end

-- Measurement only (/wvprof).  ns.Prof.on is a session flag, never saved; per-event timing runs only
-- while it is set.  Load timings (ns.Prof.load) are always taken: a handful of clock reads per login.
ns.Prof = { on = false, ev = {}, load = {}, clock = debugprofilestop or function() return 0 end }
ns.Prof.load.chunkStart = ns.Prof.clock()

ns._Aura = ns._Aura or {}
ns._Aura.EMPTY = {} -- shared read-only empty table for hot paths
function ns.tryDebugReport(method, ...)
    local report = ns.DebugReport
    local callback = type(report) == "table" and report[method]
    if type(callback) ~= "function" then return false end
    return pcall(callback, ...)
end
local activeAuras = {}
local auraByInstanceID = {}
local auraWatchBySpellID = {}
ns._Aura.eventStates = {}
ns._Aura.unreadableBaselines = {}
local spellInfoCache = {}
local spellLoadRequests = {}
local itemCooldownStates = {}
local itemDebugDedupe = {}
local auraTracker = { updatePending = false, sealSyncPending = false }
function ns._Aura.cancelExpiry(state)
    if not state then return end
    local timer = state.expiryTimer
    state.expiryTimer = nil
    state.expiryTimerKind = nil
    state.expiryTimerTarget = nil
    state.expiryTimerInstanceID = nil
    state.timerGeneration = (state.timerGeneration or 0) + 1
    if timer and type(timer.Cancel) == "function" then pcall(timer.Cancel, timer) end
end

function ns._Aura.clearActiveState()
    for _, state in pairs(activeAuras) do ns._Aura.cancelExpiry(state) end
    wipe(activeAuras)
    wipe(auraByInstanceID)
    if auraTracker.stateManager then auraTracker.stateManager:Reset() end
end
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
local selectedMarkerKey = "apply" -- the timeline node whose output the editor shows
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
local triggerHelpButton
local triggerLegendLine
local triggerPlaceholder
local triggerPanel
local triggerScroll
local triggerChild
local triggerRows = {}
local itemSourceText
local refreshList, saveDetails, updateDetails
local selectedAura
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
ns.Layout.maxHeight = 800 -- default height; the window can be dragged taller or shorter (minHeight..screen)
ns.Layout.minHeight = 560
ns.Layout.statusHeight = 32
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
ns.Layout.MEMBER_ROW_H = 28 -- trigger / item member rows: 20 px icon + the 8 px edges of the skin row art
ns.Layout.refreshListPending = false

-- The window is always maxWidth x maxHeight; on small screens it is scaled down instead of resized.
ns.Layout.getWindowScale = function()
    local availableWidth = math.max(1, (UIParent:GetWidth() or ns.Layout.maxWidth) - 24)
    local availableHeight = math.max(1, (UIParent:GetHeight() or ns.Layout.maxHeight) - 24)
    return math.min(1, availableWidth / ns.Layout.maxWidth, availableHeight / ns.Layout.minHeight)
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

-- UIDropDownMenu_SetWidth plus the text zone (SetWidth resets the Text width, so the zone is applied after every
-- call). Texture skins end the text before the arrow divider, cut off instead of wrapped; current keeps
-- the native zone, which already ends before the arrow button.
ns.Layout.setDropdownWidth = function(dropdown, width)
    UIDropDownMenu_SetWidth(dropdown, width)
    local right, textWidth = ns.Skin.DropdownTextZone(width + ns.Layout.DD_CHROME)
    local text = right and dropdown.Text
    if not text then return end
    text:ClearAllPoints()
    text:SetPoint("RIGHT", dropdown, "RIGHT", -right, 2)
    text:SetWidth(textWidth)
    text:SetJustifyH("RIGHT")
    text:SetWordWrap(false)
end

-- Places a UIDropDownMenuTemplate frame so that its VISIBLE box spans visLeft .. visLeft + visWidth.
ns.Layout.placeDropdown = function(dropdown, parent, visLeft, y, visWidth)
    dropdown:ClearAllPoints()
    dropdown:SetPoint("TOPLEFT", parent, "TOPLEFT", visLeft - ns.Layout.DD_INSET_L, y)
    ns.Layout.setDropdownWidth(dropdown, visWidth + ns.Layout.DD_INSET_L + ns.Layout.DD_INSET_R - ns.Layout.DD_CHROME)
end

ns.Layout.clampEditorScroll = function(offset)
    if not editorScroll then return end
    local range = math.max(0, editorScroll:GetVerticalScrollRange() or 0)
    editorScroll:SetVerticalScroll(math.max(0, math.min(tonumber(offset) or 0, range)))
end

ns.screenControls = {}
ns.screenFrames = {}
ns.screenFramePool = ns.screenFramePool or {}
ns.notificationPanels = {}
ns.Layout.panelState = setmetatable({}, { __mode = "k" }) -- rule -> { apply | expire | voice = expanded }; session only
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
    { value = "somebody-loves-you", label = "Somebody loves you" },
    { value = "offensive-external", label = "Offensive · Somebody loves you" },
    { value = "defensive-external", label = "Defensive · Somebody loves you" },
    { value = "healing", label = "Healing" },
    { value = "bloodlust", label = "Bloodlust" },
}
local NOTIFICATION_CUE_ALIASES = {
    ["Defensive cooldown"] = "defensive",
    ["Offensive cooldown"] = "offensive",
    ["Healing cooldown"] = "healing",
    ["Bloodlust"] = "bloodlust",
    ["Somebody loves you"] = "somebody-loves-you",
    ["Offensive · Somebody loves you"] = "offensive-external",
    ["Defensive · Somebody loves you"] = "defensive-external",
    defensive = "defensive", offensive = "offensive", healing = "healing", bloodlust = "bloodlust",
    ["somebody-loves-you"] = "somebody-loves-you",
    ["offensive-external"] = "offensive-external", ["defensive-external"] = "defensive-external",
}
local NOTIFICATION_CUE_LABELS = {
    defensive = "Defensive", offensive = "Offensive", healing = "Healing", bloodlust = "Bloodlust",
    ["somebody-loves-you"] = "Somebody loves you",
    ["offensive-external"] = "Offensive · Somebody loves you",
    ["defensive-external"] = "Defensive · Somebody loves you",
}
ns.NOTIFICATION_CUE_LABELS = NOTIFICATION_CUE_LABELS
local NOTIFICATION_SOUND_CHANNELS = {
    { key = "Master", value = "Master" },
    { key = "Sound effects", value = "SFX" },
    { key = "Dialog", value = "Dialog" },
    { key = "Music", value = "Music" },
    { key = "Ambience", value = "Ambience" },
}
local NOTIFICATION_SOUND_CHANNEL_SET = { Master = true, SFX = true, Dialog = true, Music = true, Ambience = true }
ns.NOTIFICATION_SOUND_CHANNEL_SET = NOTIFICATION_SOUND_CHANNEL_SET
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
        expireCategory = "none",
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
        beforeExpireEnabled = false,
        beforeExpirePercent = 5,
        beforeExpireMessage = "",
        beforeExpireSoundEnabled = false,
        beforeExpireSoundKitID = DEFAULT_NOTIFICATION_SOUND_KIT,
        beforeExpireSoundChannel = "Master",
        screenProfiles = {
            apply = ns.newScreenProfile(false, ""),
            expire = ns.newScreenProfile(false, ""),
            beforeExpire = ns.newScreenProfile(false, ""),
        },
        voiceID = getDefaultVoiceID(),
        volume = 80,
        speechSpeed = 100,
    }
end
ns.newAuraRule = newAuraRule

local function newItemRule(itemID, name, icon, slotID)
    return {
        members = { { itemID = itemID, slotID = slotID } },
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
    local items = copyDefault(defaults.items or {})
    for _, rule in ipairs(items) do
        local slotID = rule.members and rule.members[1] and rule.members[1].slotID
        if slotID then
            rule.name = ns.slotName(slotID)
            rule.message = ns.slotDefaultMessage(slotID)
        end
    end
    return {
        version = DB_VERSION,
        starterPresetVersion = tonumber(defaults.version) or 1,
        auras = copyDefault(defaults.auras or {}),
        items = items,
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
        rule.screenProfiles.beforeExpire = ns.normalizeScreenProfile(
            rule.screenProfiles.beforeExpire, rule.beforeExpireScreenEnabled, rule.beforeExpireScreenText, settings)
        rule.applyScreenEnabled = nil
        rule.applyScreenText = nil
        rule.expireScreenEnabled = nil
        rule.expireScreenText = nil
        rule.beforeExpireScreenEnabled = nil
        rule.beforeExpireScreenText = nil
        -- Intermediate timeline markers (m1, m2, ...) keep their own screen profile under their key.
        for key, profile in pairs(rule.screenProfiles) do
            if type(key) == "string" and key:match("^m%d+$") then
                rule.screenProfiles[key] = ns.normalizeScreenProfile(profile, false, "", settings)
            end
        end
    else
        rule.screenProfiles.ready = ns.normalizeScreenProfile(
            rule.screenProfiles.ready, rule.screenEnabled, rule.screenText, settings)
        rule.screenEnabled = nil
        rule.screenText = nil
    end
end

function ns.normalizeNotificationSettings(rule, category)
    rule.alertCategory = NOTIFICATION_CUE_ALIASES[rule.alertCategory] or "none"
    if category == "auras" then rule.expireCategory = NOTIFICATION_CUE_ALIASES[rule.expireCategory] or "none" end
    local soundEvents = category == "auras" and { "apply", "expire", "beforeExpire" } or { "ready" }
    for _, eventKey in ipairs(soundEvents) do
        local mediaField = eventKey .. "SoundMediaName"
        local mediaName = rule[mediaField]
        rule[mediaField] = type(mediaName) == "string" and trim(mediaName) ~= "" and trim(mediaName) or nil
    end
    if category == "auras" then
        rule.beforeExpireEnabled = rule.beforeExpireEnabled == true
        local warningPercent = tonumber(rule.beforeExpirePercent)
        if warningPercent ~= nil then
            rule.beforeExpirePercent = math.max(0, math.min(100, math.floor(warningPercent + 0.5)))
            rule.beforeExpireSeconds = nil
        elseif tonumber(rule.beforeExpireSeconds) ~= nil then
            rule.beforeExpirePercent = nil
            rule.beforeExpireSeconds = math.max(1, math.min(60,
                math.floor(tonumber(rule.beforeExpireSeconds) + 0.5)))
        else
            rule.beforeExpirePercent = 5
            rule.beforeExpireSeconds = nil
        end
        rule.beforeExpireMessage = type(rule.beforeExpireMessage) == "string" and rule.beforeExpireMessage or ""
        rule.beforeExpireSoundEnabled = rule.beforeExpireSoundEnabled == true
        rule.beforeExpireSoundKitID = tonumber(rule.beforeExpireSoundKitID) or DEFAULT_NOTIFICATION_SOUND_KIT
        rule.beforeExpireSoundChannel = NOTIFICATION_SOUND_CHANNEL_SET[rule.beforeExpireSoundChannel]
            and rule.beforeExpireSoundChannel or "Master"
    end
    if category ~= "auras" then
        rule.readyEnabled = rule.readyEnabled ~= false
        rule.readySoundEnabled = rule.readySoundEnabled == true
        rule.readySoundKitID = tonumber(rule.readySoundKitID) or DEFAULT_NOTIFICATION_SOUND_KIT
        rule.readySoundChannel = NOTIFICATION_SOUND_CHANNEL_SET[rule.readySoundChannel] and rule.readySoundChannel or "Master"
    end
    -- Spell ranks (SpellRanks.lua): on by default in WoW Forever, where spells come in ranks.
    if category == "skills" then
        if rule.allRanks == nil then rule.allRanks = ns.isForever == true end
        rule.allRanks = rule.allRanks == true
    elseif category == "auras" then
        -- Per trigger: rankIDs[id] = true counts every rank of that spell. Missing entries take the flavor default
        -- (on in WoW Forever); an explicit false stays off. A former rule-wide allRanks seeds the entries once.
        local old = rule.allRanks
        rule.allRanks = nil
        local ranks = type(rule.rankIDs) == "table" and rule.rankIDs or {}
        local clean = {}
        for _, id in ipairs(rule.spellIDs or {}) do
            local flag = ranks[id]
            if flag == nil then
                if old ~= nil then flag = old == true else flag = ns.isForever == true end
            end
            clean[id] = flag == true
        end
        rule.rankIDs = clean
    end
    -- Timeline markers (Markers.lua). Their output fields stay flat on the rule under the marker key.
    if ns.Markers then
        ns.Markers.Normalize(rule, category)
        local hasBeforeExpire = false
        for _, marker in ipairs(rule.markers) do
            local key = marker.key
            if key == "beforeExpire" then
                hasBeforeExpire = true
                -- The Codex tracker still reads the percent fields; keep them in step with the marker.
                rule.beforeExpireEnabled = true
                if marker.anchor == "end" and marker.offset then
                    rule.beforeExpirePercent, rule.beforeExpireSeconds = nil, math.max(1, math.min(60, math.floor(marker.offset + 0.5)))
                else
                    rule.beforeExpirePercent, rule.beforeExpireSeconds = math.max(0, math.min(100, math.floor(100 - marker.at + 0.5))), nil
                end
            elseif key:match("^m%d+$") then
                rule[key .. "Enabled"] = rule[key .. "Enabled"] == true
                rule[key .. "Message"] = type(rule[key .. "Message"]) == "string" and rule[key .. "Message"] or ""
                rule[key .. "SoundEnabled"] = rule[key .. "SoundEnabled"] == true
                local mediaName = rule[key .. "SoundMediaName"]
                rule[key .. "SoundMediaName"] = type(mediaName) == "string" and trim(mediaName) ~= "" and trim(mediaName) or nil
                rule[key .. "SoundKitID"] = tonumber(rule[key .. "SoundKitID"]) or DEFAULT_NOTIFICATION_SOUND_KIT
                rule[key .. "SoundChannel"] = NOTIFICATION_SOUND_CHANNEL_SET[rule[key .. "SoundChannel"]]
                    and rule[key .. "SoundChannel"] or "Master"
                rule[key .. "Category"] = NOTIFICATION_CUE_ALIASES[rule[key .. "Category"]] or "none"
            end
        end
        if category == "auras" and not hasBeforeExpire then rule.beforeExpireEnabled = false end
    end
end

-- Foreign-target announcements and the combat cast map were removed; silently drop their old saved fields.
-- Equipment slot IDs are integers 1..19; anything else (including a missing slot) means "track the item".
function ns.normalizeSlotID(value)
    local slotID = tonumber(value)
    if slotID and slotID >= 1 and slotID <= 19 and slotID == math.floor(slotID) then return slotID end
    return nil
end

-- An item rule watches a list of members: { itemID = n } (one fixed item) or { slotID = n, itemID = last
-- seen item } (whatever sits in that slot). Older saves kept one itemID/slotID pair on the rule itself;
-- it becomes the first member and the rule fields are dropped, so loading twice changes nothing more.
-- The unfilled starter trinket rule keeps an empty list until the picker fills it.
-- Key strings are cached per slot and per item ID: a scan asks for them several times per member, and the
-- concatenation would allocate each time. The cache only ever holds the same strings the concatenation gave.
ns.slotKeys, ns.itemKeys = {}, {}
function ns.memberKey(member)
    local slotID = member.slotID
    if slotID then
        local key = ns.slotKeys[slotID]
        if not key then key = "s" .. slotID; ns.slotKeys[slotID] = key end
        return key
    end
    local itemID = member.itemID
    if itemID == nil then return "i" .. tostring(itemID) end
    local key = ns.itemKeys[itemID]
    if not key then key = "i" .. tostring(itemID); ns.itemKeys[itemID] = key end
    return key
end

-- Shared empty list for rules without a members table. Read only: every writer (addItemMember, normalize)
-- creates rule.members first, and removeItemMember returns before touching the list when it is missing.
ns.noMembers = {}
function ns.itemMembers(rule)
    if type(rule.members) == "table" then return rule.members end
    return ns.noMembers
end

function ns.firstItemID(rule)
    local first = ns.itemMembers(rule)[1]
    return first and first.itemID or nil
end

-- The unfilled starter trinket rule: no member yet, the picker fills it.
function ns.isEmptyStarter(rule)
    return rule.starter == "trinket" and #ns.itemMembers(rule) == 0
end

function ns.normalizeItemRule(rule)
    if type(rule.members) ~= "table" then
        rule.members = {}
        if ns.normalizeSlotID(rule.slotID) or (tonumber(rule.itemID) or 0) > 0 then
            rule.members[1] = { itemID = rule.itemID, slotID = rule.slotID }
        end
    end
    rule.itemID, rule.slotID = nil, nil
    local members, seen = rule.members, {}
    for index = #members, 1, -1 do
        local member = members[index]
        local slotID = type(member) == "table" and ns.normalizeSlotID(member.slotID) or nil
        local itemID = type(member) == "table" and tonumber(member.itemID) or nil
        if itemID and itemID <= 0 then itemID = nil end
        if slotID or itemID then
            member.slotID, member.itemID = slotID, itemID
        else
            table.remove(members, index)
        end
    end
    for index = 1, #members do
        local key = ns.memberKey(members[index])
        if seen[key] then members[index] = false end
        seen[key] = true
    end
    for index = #members, 1, -1 do
        if members[index] == false then table.remove(members, index) end
    end
end

function ns.normalizeTargetRule(rule)
    if type(rule) ~= "table" then return end
    rule.autoAnnounceTarget = nil
    rule.otherTargetMessage = nil
    rule.targetMessage = nil
    rule.combatCastByAuraID = nil
    rule.defensiveMappingVersion = nil
end

-- Built-in presets (Defaults.lua, builtin = true), currently the Bloodlust rule: always present, cannot be
-- deleted, and their default triggers cannot be removed.  Everything else (texts, voice, on/off) stays editable.
-- Idempotent: runs on every load for every profile.
function ns.ensureBuiltinRules(rules)
    if type(rules) ~= "table" then return end
    if ns.isForever then
        -- Forever ships no built-in aura rules (Defaults.lua); drop the Bloodlust rule an older copy or profile created.
        for index = #rules, 1, -1 do
            local rule = rules[index]
            if type(rule) == "table" and rule.builtin and rule.presetID == "heroism-bloodlust" then table.remove(rules, index) end
        end
    end
    for _, preset in ipairs(ns.Defaults and ns.Defaults.auras or {}) do
        if preset.builtin and preset.presetID then
            local found
            for _, rule in ipairs(rules) do
                if type(rule) == "table" and rule.presetID == preset.presetID then found = rule; break end
            end
            if not found then
                found = copyDefault(preset)
                found.id = "builtin-" .. preset.presetID
                table.insert(rules, found)
            end
            found.builtin = true
            found.oneEffect = preset.oneEffect == true
            -- The fallback cue is switched on once for rules created before it was part of the preset.
            if not found.builtinCategorySet then
                found.builtinCategorySet = true
                if preset.alertCategory and (found.alertCategory == nil or found.alertCategory == "none") then
                    found.alertCategory = preset.alertCategory
                end
            end
            found.spellIDs = type(found.spellIDs) == "table" and found.spellIDs or {}
            local have = {}
            for _, id in ipairs(found.spellIDs) do have[id] = true end
            for _, id in ipairs(preset.spellIDs or {}) do
                if not have[id] then table.insert(found.spellIDs, id) end
            end
        end
    end
end

-- True when spellID is a trigger the built-in rule must keep.
function ns.isBuiltinTrigger(rule, spellID)
    if not (rule and rule.builtin) then return false end
    for _, preset in ipairs(ns.Defaults and ns.Defaults.auras or {}) do
        if preset.presetID == rule.presetID then
            for _, id in ipairs(preset.spellIDs or {}) do
                if id == spellID then return true end
            end
        end
    end
    return false
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

function ns.migrateRemovedDefensiveDefaults(source)
    local defaults = ns.Defaults
    if not (defaults and type(defaults.migrateRemovedDefensives) == "function") then return 0 end
    return defaults.migrateRemovedDefensives(source)
end

local function validStoredSpellID(value)
    if type(value) ~= "number" or value <= 0 or value ~= math.floor(value) then return false end
    if value ~= value or value == math.huge or value == -math.huge then return false end
    if issecretvalue then
        local ok, secret = pcall(issecretvalue, value)
        return ok and not secret
    end
    return true
end

local function normalizeAuraTrackerData(data)
    if type(data) ~= "table" then return end
    local tracker = type(data.auraTracker) == "table" and data.auraTracker or {}
    local layout = ns.AuraTrackerView and ns.AuraTrackerView.NormalizeConfig
        and ns.AuraTrackerView.NormalizeConfig(tracker) or {}
    tracker.size = layout.size or 40
    tracker.spacing = layout.spacing or 6
    tracker.groups = layout.groups or {}
    tracker.freeIcons = layout.freeIcons or {}
    tracker.visibilityByEntry = layout.visibilityByEntry or {}
    tracker.showCountdown = tracker.showCountdown ~= false
    tracker.showName = tracker.showName == true
    tracker.showStacks = tracker.showStacks ~= false
    tracker.sealNameFilter = type(tracker.sealNameFilter) == "string" and tracker.sealNameFilter or nil

    local families = type(tracker.families) == "table" and tracker.families or {}
    local source = families.seals
    if type(source) == "table" then
        local seals = {
            spells = {},
            excludedSpellIDs = {},
            includeInTracker = source.includeInTracker == true,
            ruleID = type(source.ruleID) == "string" and source.ruleID or nil,
        }
        for _, row in ipairs(type(source.spells) == "table" and source.spells or {}) do
            if type(row) == "table" and validStoredSpellID(row.spellID) then
                local castID = validStoredSpellID(row.castID) and row.castID or row.spellID
                local auraID = validStoredSpellID(row.auraID) and row.auraID or nil
                local evidence = type(row.mappingEvidence) == "table" and row.mappingEvidence or nil
                local verified = row.mappingVerified == true and auraID ~= nil and evidence ~= nil
                    and (evidence.source == "cdm" or evidence.source == "learning")
                    and evidence.confirmed == true and evidence.castID == castID and evidence.auraID == auraID
                table.insert(seals.spells, {
                    spellID = row.spellID,
                    name = type(row.name) == "string" and row.name or "",
                    castID = castID,
                    auraID = verified and auraID or nil,
                    mappingVerified = verified,
                    mappingEvidence = verified and { source = evidence.source, confirmed = true,
                        castID = castID, auraID = auraID } or nil,
                })
            end
        end
        for id, excluded in pairs(type(source.excludedSpellIDs) == "table" and source.excludedSpellIDs or {}) do
            local spellID = tonumber(id)
            if validStoredSpellID(spellID) and excluded == true then seals.excludedSpellIDs[spellID] = true end
        end
        families.seals = #seals.spells > 0 and seals or nil
    else
        families.seals = nil
    end
    tracker.families = families
    data.auraTracker = tracker
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
    normalizeAuraTrackerData(WoWraVoxDB)
    WoWraVoxDB.skills = type(WoWraVoxDB.skills) == "table" and WoWraVoxDB.skills or {}
    for _, category in ipairs({ "auras", "items", "skills" }) do
        local rules = WoWraVoxDB[category]
        for index = #rules, 1, -1 do
            if type(rules[index]) ~= "table" then table.remove(rules, index) end
        end
    end
    local usedRuleIDs = {}
    local nextRuleID = tonumber(WoWraVoxDB.nextRuleID) or 0

    ns.migrateRemovedDefensiveDefaults(WoWraVoxDB)
    ns.ensureBuiltinRules(WoWraVoxDB.auras)
    for _, rule in ipairs(WoWraVoxDB.auras) do
        nextRuleID = ns.ensureRuleID(rule, usedRuleIDs, nextRuleID)
        ns.Profiles.NormalizeRuleSpecializations(rule)
        rule.name = type(rule.name) == "string" and rule.name or "Aura"
        rule.spellIDs = copyIDs(rule.spellIDs or (rule.spellID and { tonumber(rule.spellID) } or {}))
        rule.enabled = rule.enabled ~= false
        rule.applyEnabled = rule.applyEnabled == true
        rule.applyMessage = type(rule.applyMessage) == "string" and rule.applyMessage or ""
        rule.oneEffect = rule.oneEffect == true
        ns.normalizeTargetRule(rule)
        ns._Aura.normalizeCastMap(rule)
        ns._Aura.normalizeCategoryMap(rule)
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
        ns.normalizeItemRule(rule)
        rule.name = type(rule.name) == "string" and rule.name or ("Item " .. tostring(ns.firstItemID(rule) or 0))
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
            normalizeAuraTrackerData(data)
            data.settings.showMinimap = nil -- minimap button was removed
            data.minimap = nil
            for _, category in ipairs({ "auras", "items", "skills" }) do
                local rules = type(data[category]) == "table" and data[category] or {}
                if category == "auras" and type(data.auras) == "table" then
                    ns.migrateRemovedDefensiveDefaults(data)
                    ns.ensureBuiltinRules(rules)
                end
                for _, rule in ipairs(rules) do
                    if type(rule) == "table" then
                        ns.Profiles.NormalizeRuleSpecializations(rule)
                        if category == "auras" then
                            rule.spellIDs = copyIDs(rule.spellIDs or (rule.spellID and { tonumber(rule.spellID) } or {}))
                            rule.oneEffect = rule.oneEffect == true
                            ns.normalizeTargetRule(rule)
                            ns._Aura.normalizeCastMap(rule)
                            ns._Aura.normalizeCategoryMap(rule)
                        end
                        if category == "items" then ns.normalizeItemRule(rule) end
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
    if type(value) ~= "number" then return false end
    if issecretvalue then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then return false end
    end
    return value > 0 and value == math.floor(value)
end

-- Buffs the player receives are remembered across sessions (at most 2000 IDs). One name can belong to several
-- spell IDs, one per spec, so a name search finds every variant the player has actually met.
function ns.ObserveSpell(spellID, origin)
    if not isPublicNumber(spellID) then return end
    observedSpellIDs[spellID] = origin or "Seen"
    local db = WoWraVoxProfilesDB
    if origin ~= "Your aura" or type(db) ~= "table" then return end
    if type(db.learnedSpellIDs) ~= "table" then db.learnedSpellIDs = {} end
    local learned = db.learnedSpellIDs
    if learned[spellID] or (db.learnedSpellCount or 0) >= 2000 then return end
    learned[spellID] = true
    db.learnedSpellCount = (db.learnedSpellCount or 0) + 1
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

local function collectSpellbook(candidates, needle, matchNumericID, spellNames)
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
                    local namePublic = nameOK and type(name) == "string"
                    if namePublic and issecretvalue then
                        local secretOK, secret = pcall(issecretvalue, name)
                        namePublic = secretOK and not secret
                    end
                    local nameMatches = namePublic and name:lower():find(needle, 1, true)
                    local idMatches = matchNumericID and numericID
                        and (numericID == spellID or (#needle >= 3 and tostring(spellID):find(needle, 1, true) ~= nil))
                    if nameMatches or idMatches then
                        candidates[spellID] = candidates[spellID] or "Spellbook"
                        if spellNames and namePublic then spellNames[spellID] = name end
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
    local learned = type(WoWraVoxProfilesDB) == "table" and WoWraVoxProfilesDB.learnedSpellIDs
    if type(learned) == "table" then
        for id in pairs(learned) do candidates[id] = candidates[id] or "Your aura" end
    end
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
    if ns._Aura.sim then return ns._Aura.sim.getAura(spellID) end -- /wvdebug sim (Simulation.lua)
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
    if ns._Aura.sim then return ns._Aura.sim.secret end -- /wvdebug sim (Simulation.lua)
    if C_Secrets and type(C_Secrets.ShouldAurasBeSecret) == "function" then
        local ok, secret = pcall(C_Secrets.ShouldAurasBeSecret)
        if ok and type(secret) == "boolean" and not (issecretvalue and issecretvalue(secret)) then
            return secret
        end
    end
    return InCombatLockdown and InCombatLockdown() or false
end

-- Blizzard's base secrecy class for an aura ID (C_Secrets.GetSpellAuraSecrecy): "never" auras (e.g. the
-- Sated/Exhaustion family) stay readable in combat, "always"/"contextual" ones can be hidden.
-- Returns "never", "always", "contextual" or "unknown" (API missing or unreadable).
ns._Aura.secrecyCache = {}
function ns._Aura.auraSecrecy(spellID)
    local cache = ns._Aura.secrecyCache
    if cache[spellID] then return cache[spellID] end
    local result = "unknown"
    if C_Secrets and type(C_Secrets.GetSpellAuraSecrecy) == "function" and isPublicNumber(spellID) then
        local ok, level = pcall(C_Secrets.GetSpellAuraSecrecy, spellID)
        if ok and type(level) == "number" and not (issecretvalue and issecretvalue(level)) then
            local levels = Enum and Enum.SecrecyLevel
            if level == (levels and levels.NeverSecret or 0) then result = "never"
            elseif level == (levels and levels.AlwaysSecret or 1) then result = "always"
            elseif level == (levels and levels.ContextuallySecret or 2) then result = "contextual" end
        end
    end
    if result ~= "unknown" then cache[spellID] = result end
    return result
end

-- /wvdebug secrecy: Blizzard's secrecy class for every aura ID in the aura rules.
function ns._Aura.printSecrecy()
    local function say(line)
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffd8b65aWoWraVox:|r " .. line) end
    end
    say("ShouldAurasBeSecret: " .. tostring(ns._Aura.aurasAreSecret()))
    local seen = {}
    for _, rule in ipairs(WoWraVoxDB and WoWraVoxDB.auras or {}) do
        for _, spellID in ipairs(type(rule.spellIDs) == "table" and rule.spellIDs or {}) do
            if not seen[spellID] then
                seen[spellID] = true
                local info = getSpellInfo(spellID)
                local known = "?"
                if type(IsPlayerSpell) == "function" then
                    local ok, result = pcall(IsPlayerSpell, spellID)
                    if ok and type(result) == "boolean" then known = tostring(result) end
                end
                say(string.format("%s · %s · %s · selfbuff=%s · castable=%s", info and info.name or "?", tostring(spellID),
                    ns._Aura.auraSecrecy(spellID), tostring(ns._Aura.getSelfBuffStatus(spellID)), known))
            end
        end
    end
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
        elseif eventKey == "beforeExpire" then
            fallbackEnabled, fallbackText = rule.beforeExpireScreenEnabled, rule.beforeExpireScreenText
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


-- Font, colour and shadow without measuring. The font must exist before the first SetText: a FontString
-- without a font raises "Font not set". A font file that does not load falls back to the Blizzard font.
function ns.applyScreenFontStyle(frame, profile)
    if not (frame and frame.text and profile) then return end
    local font = ns.getScreenFontChoiceByKey(profile.font)
    local style = ns.getScreenStyleChoice(profile.style)
    local text = frame.text
    local size, flags = ns.getScreenSizeValue(profile.size), style.flags or ""
    if not (pcall(text.SetFont, text, font.path, size, flags) and text:GetFont()) then
        if not (pcall(text.SetFont, text, "Fonts\\FRIZQT__.TTF", size, flags) and text:GetFont()) then
            text:SetFontObject(GameFontNormal)
        end
    end
    local color = ns.copyScreenColor(profile.color)
    text:SetTextColor(color.r, color.g, color.b, color.a)
    if style.shadow then
        text:SetShadowColor(0, 0, 0, style.shadowAlpha or 1)
        text:SetShadowOffset(style.shadowX or 2, style.shadowY or -2)
    else
        text:SetShadowColor(0, 0, 0, 0)
        text:SetShadowOffset(0, 0)
    end
end

function ns.applyScreenFrameStyle(frame, profile)
    if not (frame and frame.text and profile) then return end
    ns.applyScreenFontStyle(frame, profile)
    ns.fitScreenFrame(frame) -- font / size changed: re-measure the current text
end

-- Frame size around a text of the given measured size: 16 px left/right and 4 px top/bottom padding. Wider than
-- maxWidth: the frame is maxWidth wide and the third result tells the caller to wrap and measure again.
function ns.screenTextSize(stringWidth, stringHeight, maxWidth)
    local width = (tonumber(stringWidth) or 0) + 32
    local height = (tonumber(stringHeight) or 0) + 8
    maxWidth = tonumber(maxWidth)
    if maxWidth and width > maxWidth then return maxWidth, height, true end
    return width, height, false
end

-- The frame hugs its text (centred on the anchor point): one line, no wrapping, until 80 % of the screen width.
function ns.fitScreenFrame(frame)
    local text = frame and frame.text
    if not (text and text:GetText()) then return end
    local maxWidth = (UIParent:GetWidth() or 1920) * 0.8
    text:SetWordWrap(false)
    text:SetWidth(0)
    local width, height, wrap = ns.screenTextSize(text:GetStringWidth(), text:GetStringHeight(), maxWidth)
    if wrap then
        text:SetWidth(maxWidth - 32)
        text:SetWordWrap(true)
        width, height = ns.screenTextSize(maxWidth - 32, text:GetStringHeight(), maxWidth)
    end
    frame:SetSize(width, height)
end

-- Snap an offset from the screen centre (x right, y up) to the guide grid: within 6 px of a grid line it lands
-- on the line, otherwise it stays where it is. The centre lines (line 0) win: within 6 px of the centre the
-- text always lands on it, even on a fine grid. free = no snapping. Whole pixels either way.
function ns.snapScreenOffset(x, y, grid, free)
    x, y = tonumber(x) or 0, tonumber(y) or 0
    if free then return math.floor(x + 0.5), math.floor(y + 0.5) end
    grid = tonumber(grid) or 10
    if grid < 1 then grid = 10 end
    local function snap(value)
        if math.abs(value) <= 6 then return 0 end
        local line = math.floor(value / grid + 0.5) * grid
        return math.abs(value - line) <= 6 and line or math.floor(value + 0.5)
    end
    return snap(x), snap(y)
end

-- Spacing of the guide lines: 10 px, doubled while the screen would need more than 400 lines.
function ns.screenGridStep(width, height)
    width, height = tonumber(width) or 1920, tonumber(height) or 1080
    local step = 10
    while width / step + height / step + 2 > 400 do step = step * 2 end
    return step
end

-- Offset of the frame CENTRE from the screen centre for a saved anchor. Anchors saved by older versions used any
-- point of an 800 x 80 frame; they are converted so the text stays where it was.
function ns.screenCenterOffset(anchor, screenWidth, screenHeight)
    anchor = ns.copyScreenAnchor(anchor)
    local function fraction(point)
        return point:find("LEFT") and -0.5 or point:find("RIGHT") and 0.5 or 0,
            point:find("BOTTOM") and -0.5 or point:find("TOP") and 0.5 or 0
    end
    local rx, ry = fraction(anchor.relativePoint)
    local px, py = fraction(anchor.point)
    return anchor.x + rx * (tonumber(screenWidth) or 0) - px * 800, anchor.y + ry * (tonumber(screenHeight) or 0) - py * 80
end

function ns.positionScreenFrame(frame, profile)
    if not (frame and profile) then return end
    frame:ClearAllPoints()
    local x, y = ns.screenCenterOffset(profile.anchor, UIParent:GetWidth(), UIParent:GetHeight())
    frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
    if ns.screenAnchorTarget == frame then ns.updateScreenGuides(frame) end
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
    local _, _, _, x, y = frame:GetPoint(1)
    profile.anchor = ns.copyScreenAnchor({
        point = "CENTER",
        relativePoint = "CENTER",
        x = math.floor((x or 0) + 0.5),
        y = math.floor((y or 0) + 0.5),
    })
end

-- Anchor-mode overlay (created once, under the text frames): a screen-filling grid (faint lines every 10 px, every
-- 5th line stronger, gold centre lines), the crosshair at the anchor point and a fixed coordinate field at the top.
function ns.getScreenGuides()
    if ns.screenGuides then return ns.screenGuides end
    local guides = CreateFrame("Frame", nil, UIParent)
    guides:SetAllPoints(UIParent)
    guides:SetFrameStrata("TOOLTIP")
    guides:SetFrameLevel(1)
    guides:EnableMouse(false)
    guides.lines = {} -- texture pool: created on demand, reused for every layout
    guides.step = 10
    guides.cross = CreateFrame("Frame", nil, guides)
    guides.cross:SetSize(1, 1)
    local function arm(width, height)
        local tex = guides:CreateTexture(nil, "OVERLAY")
        tex:SetColorTexture(0.95, 0.72, 0.25, 1)
        tex:SetPoint("CENTER", guides.cross, "CENTER", 0, 0)
        tex:SetSize(width, height)
    end
    arm(41, 1)
    arm(1, 41)
    -- above the text frames (level 5): the text can never cover the field
    guides.coords = CreateFrame("Frame", nil, guides, "BackdropTemplate")
    guides.coords:SetSize(150, 40)
    guides.coords:SetPoint("TOP", UIParent, "TOP", 0, -30)
    guides.coords:SetFrameLevel(10)
    guides.coords:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    guides.coords:SetBackdropColor(0.03, 0.03, 0.04, 0.92)
    guides.coords:SetBackdropBorderColor(0.72, 0.55, 0.22, 1)
    guides.coords.text = guides.coords:CreateFontString(nil, "OVERLAY", "WoWraVoxFontHighlightSmall")
    guides.coords.text:SetPoint("CENTER", guides.coords, "CENTER", 0, 0)
    guides.coords.text:SetJustifyH("CENTER")
    guides:Hide()
    ns.screenGuides = guides
    return guides
end

-- (Re)build the grid for the current screen size; skipped while the size is unchanged.
function ns.layoutScreenGuides(guides)
    local width, height = UIParent:GetWidth() or 1920, UIParent:GetHeight() or 1080
    local key = width .. "x" .. height
    if guides.gridKey == key then return end
    guides.gridKey = key
    guides.step = ns.screenGridStep(width, height)
    local used = 0
    local function place(vertical, index)
        used = used + 1
        local tex = guides.lines[used]
        if not tex then
            tex = guides:CreateTexture(nil, "ARTWORK")
            guides.lines[used] = tex
        end
        if index == 0 then tex:SetColorTexture(0.95, 0.72, 0.25, 0.4)
        elseif index % 5 == 0 then tex:SetColorTexture(1, 1, 1, 0.12)
        else tex:SetColorTexture(1, 1, 1, 0.04) end
        local offset = index * guides.step
        tex:ClearAllPoints()
        if vertical then
            tex:SetPoint("TOP", UIParent, "TOP", offset, 0)
            tex:SetPoint("BOTTOM", UIParent, "BOTTOM", offset, 0)
            tex:SetWidth(1)
        else
            tex:SetPoint("LEFT", UIParent, "LEFT", 0, offset)
            tex:SetPoint("RIGHT", UIParent, "RIGHT", 0, offset)
            tex:SetHeight(1)
        end
        tex:Show()
    end
    local columns, rows = math.floor(width / 2 / guides.step), math.floor(height / 2 / guides.step)
    for index = -columns, columns do place(true, index) end
    for index = -rows, rows do place(false, index) end
    for index = used + 1, #guides.lines do guides.lines[index]:Hide() end
end

-- Put the crosshair on the frame's centre (= the anchor point) and refresh the coordinate field.
function ns.updateScreenGuides(frame)
    local guides = ns.screenGuides
    if not (guides and frame) then return end
    guides.cross:ClearAllPoints()
    guides.cross:SetPoint("CENTER", frame, "CENTER", 0, 0)
    local _, _, _, x, y = frame:GetPoint(1)
    x, y = math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5)
    if guides.shownX ~= x or guides.shownY ~= y then
        guides.shownX, guides.shownY = x, y
        guides.coords.text:SetText(string.format("x: %d  y: %d\n|cff8c929a%s|r", x, y, L("Shift = free")))
    end
end

-- Drag in anchor mode: the frame follows the cursor and snaps to the grid (Shift = free). OnUpdate only runs
-- while dragging.
function ns.dragScreenFrame(frame)
    local drag = frame.drag
    if not drag then return end
    local cursorX, cursorY = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    local x, y = ns.snapScreenOffset(drag.x + cursorX / scale - drag.cursorX, drag.y + cursorY / scale - drag.cursorY,
        ns.screenGuides and ns.screenGuides.step or 10, IsShiftKeyDown())
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
    ns.updateScreenGuides(frame)
end

function ns.bindScreenFrame(frame, rule, eventKey)
    frame.rule = rule
    frame.eventKey = eventKey
    frame.pooled = false
    frame:SetScript("OnDragStart", function(self)
        if not (ns.screenAnchorUnlocked and ns.screenAnchorTarget == self) then return end
        local _, _, _, x, y = self:GetPoint(1)
        local cursorX, cursorY = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        self.drag = { cursorX = cursorX / scale, cursorY = cursorY / scale, x = x or 0, y = y or 0 }
        self:SetScript("OnUpdate", ns.dragScreenFrame)
    end)
    frame:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        if self.drag and ns.screenAnchorUnlocked and ns.screenAnchorTarget == self then
            ns.saveScreenFrameAnchor(self)
        end
        self.drag = nil
    end)
end

function ns.createScreenFrame(rule, eventKey)
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:SetSize(1, 1) -- fitted to the text by ns.fitScreenFrame
    frame:SetFrameStrata("TOOLTIP")
    frame:SetFrameLevel(5)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame.anchorBorder = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    frame.anchorBorder:SetAllPoints()
    frame.anchorBorder:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    frame.anchorBorder:SetBackdropColor(0, 0, 0, 0)
    frame.anchorBorder:SetBackdropBorderColor(0.95, 0.72, 0.25, 1)
    frame.anchorBorder:Hide()
    -- Template font: a FontString without a font raises "Font not set" on its first SetText.
    frame.text = frame:CreateFontString(nil, "OVERLAY", "WoWraVoxFontNormal")
    frame.text:SetPoint("CENTER", frame, "CENTER", 0, 0)
    frame.text:SetJustifyH("CENTER")
    frame.text:SetJustifyV("MIDDLE")
    frame.text:SetWordWrap(false)
    frame.active = false
    frame:EnableMouse(false)
    frame:Hide()
    ns.bindScreenFrame(frame, rule, eventKey)
    return frame
end

function ns.getScreenFrame(rule, eventKey)
    local ruleFrames = ns.screenFrames[rule]
    if not ruleFrames then
        ruleFrames = {}
        ns.screenFrames[rule] = ruleFrames
    end
    local frame = ruleFrames[eventKey]
    if not frame then
        frame = table.remove(ns.screenFramePool)
        if frame then
            ns.bindScreenFrame(frame, rule, eventKey)
        else
            frame = ns.createScreenFrame(rule, eventKey)
        end
        ruleFrames[eventKey] = frame
    end
    return frame
end

function ns.setScreenAnchorUnlocked(frame, unlocked)
    if unlocked then
        if ns.screenAnchorTarget and ns.screenAnchorTarget ~= frame then
            ns.screenAnchorTarget:SetScript("OnUpdate", nil)
            ns.screenAnchorTarget.drag = nil
            ns.screenAnchorTarget:EnableMouse(false)
            ns.screenAnchorTarget.anchorBorder:Hide()
            if not ns.screenAnchorTarget.active then ns.screenAnchorTarget:Hide() end
        end
        ns.screenAnchorTarget = frame
        ns.screenAnchorUnlocked = true
        frame:EnableMouse(true)
        frame.anchorBorder:Show()
        local profile = ns.getRuleScreenProfile(frame.rule, frame.eventKey)
        frame.text:SetText(trim(profile and profile.text or "") ~= "" and profile.text or "WoWraVox")
        ns.applyScreenFrameStyle(frame, profile) -- also fits the frame to the text
        local guides = ns.getScreenGuides()
        ns.layoutScreenGuides(guides)
        guides:Show()
        ns.positionScreenFrame(frame, profile)
        frame:Show()
    elseif not frame or ns.screenAnchorTarget == frame then
        ns.screenAnchorUnlocked = false
        ns.screenAnchorTarget = nil
        if ns.screenGuides then ns.screenGuides:Hide() end
        if frame then
            frame:SetScript("OnUpdate", nil)
            frame.drag = nil
            frame:EnableMouse(false)
            frame.anchorBorder:Hide()
            if not frame.active then frame:Hide() end
        end
    end
    ns.updateScreenAnchorButtons()
end

-- Anchor mode belongs to the open options window: ends it for the current target (no-op when none).
function ns.endScreenAnchor()
    if ns.screenAnchorTarget then ns.setScreenAnchorUnlocked(ns.screenAnchorTarget, false) end
end

function ns.releaseScreenFrame(frame)
    if not frame or frame.pooled then return end
    frame.generation = (frame.generation or 0) + 1
    frame.active = false
    frame:SetScript("OnUpdate", nil)
    frame:SetScript("OnDragStart", nil)
    frame:SetScript("OnDragStop", nil)
    frame.drag = nil
    frame:EnableMouse(false)
    frame.anchorBorder:Hide()
    frame.text:SetText("")
    frame.rule = nil
    frame.eventKey = nil
    frame:Hide()
    frame.pooled = true
    table.insert(ns.screenFramePool, frame)
end

function ns.clearScreenFrames()
    for _, eventFrames in pairs(ns.screenFrames) do
        for _, frame in pairs(eventFrames) do ns.releaseScreenFrame(frame) end
    end
    wipe(ns.screenFrames)
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
    ns.applyScreenFontStyle(frame, profile) -- the font must be set before the text is assigned
    frame.text:SetText(message)
    ns.fitScreenFrame(frame) -- fits the frame to the text
    ns.positionScreenFrame(frame, profile)
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
    local ruleFrames = ns.screenFrames[rule]
    local frame = ruleFrames and ruleFrames[eventKey]
    if not frame then return end
    frame.generation = (frame.generation or 0) + 1
    frame.active = false
    if not (ns.screenAnchorUnlocked and ns.screenAnchorTarget == frame) then frame:Hide() end
end

function ns.hideScreenFramesForRule(rule)
    if not rule then return end
    local ruleFrames = ns.screenFrames[rule]
    if not ruleFrames then return end
    for _, frame in pairs(ruleFrames) do
        if ns.screenAnchorTarget == frame then ns.setScreenAnchorUnlocked(frame, false) end
        ns.releaseScreenFrame(frame)
    end
    ns.screenFrames[rule] = nil
end

function ns.playNotificationSound(rule, eventKey)
    local isKey = ns.Markers and ns.Markers.IsKey(eventKey)
        or eventKey == "apply" or eventKey == "expire" or eventKey == "ready" or eventKey == "beforeExpire"
    local prefix = isKey and eventKey or nil
    if not (rule and prefix and rule[prefix .. "SoundEnabled"]) then return false end
    local channel = NOTIFICATION_SOUND_CHANNEL_SET[rule[prefix .. "SoundChannel"]] and rule[prefix .. "SoundChannel"] or "Master"
    local mediaName = rule[prefix .. "SoundMediaName"]
    local mediaPath = fetchSharedMediaSound(mediaName)
    if mediaPath and type(PlaySoundFile) == "function" then
        local ok, played = pcall(PlaySoundFile, mediaPath, channel, true)
        if ok and played ~= false then return true end
    end
    local soundKitID = tonumber(rule[prefix .. "SoundKitID"])
    if soundKitID and soundKitID > 0 and type(PlaySound) == "function" then
        local ok, played = pcall(PlaySound, soundKitID, channel, true)
        if ok and played ~= false then return true end
    end
    -- Media and rule sound ID both unplayable (missing library, unknown ID): play the default kit instead of silence.
    if type(PlaySound) ~= "function" then return false end
    local ok, played = pcall(PlaySound, DEFAULT_NOTIFICATION_SOUND_KIT, channel, true)
    return ok and played ~= false
end

-- ctx (optional) maps lower-case wildcard names to text: { item = "Name", slot = "Trinket 1" } or, for aura
-- events, { spell = "Name" }. {item}, {slot} and {spell} (any letter case) are replaced; an unknown wildcard,
-- or one without a value, stays as typed.
function ns.formatRuleNotificationMessage(rule, message, ctx)
    if type(message) ~= "string" then message = "" end
    if ctx and message:find("{", 1, true) then
        message = message:gsub("{(%a+)}", function(word)
            local value = ctx[word:lower()]
            if type(value) == "string" then return value end
        end)
    end
    return message
end

local function notifyRule(rule, eventKey, message, spellID, sourceEvent, detectedEvent, ctx)
    ns.tryDebugReport("NoteNotify", rule, eventKey, message, spellID, sourceEvent, detectedEvent)
    local ttsCallReturned = false
    local ttsStatus = "disabled"
    local screenShown = false
    local native = ns.AuraSoundFallback
    -- Aura events can use {spell}: the name of the aura that fired.
    if not ctx and eventKey ~= "ready" and spellID then
        ctx = ns._Aura.spellContext(spellID)
    end
    local ttsMessage = ns.formatRuleNotificationMessage(rule, message, ctx)
    local profile = ns.getRuleScreenProfile(rule, eventKey)
    local screenText = profile and ns.formatRuleNotificationMessage(rule, profile.text, ctx) or ""
    local decision = ns.RuleOutput and ns.RuleOutput.Decide and ns.RuleOutput.Decide(rule, eventKey, {
        spellID = spellID, values = rule, preview = false, message = ttsMessage, screenText = screenText,
    })
    if not decision then
        return false
    end
    if decision.shouldSpeak then
        ttsCallReturned, ttsStatus = ns._Aura.queueTTS(rule.voiceID, ttsMessage, rule.volume, rule.speechSpeed)
        if not ttsCallReturned and native then
            native.Log("TTS-FAILURE", string.format("rule=%s spell=%s event=%s status=%s native=%s",
                tostring(rule.id or "?"), tostring(spellID or ns.firstItemID(rule) or "?"), tostring(eventKey),
                tostring(ttsStatus), tostring(decision.native and decision.native.status or "?")))
        end
    end
    local soundPlayed = false
    if decision.shouldPlaySound then
        soundPlayed = ns.playNotificationSound(rule, eventKey)
    end
    if decision.shouldShowText and trim(screenText) ~= "" then
        screenShown = ns.showScreenText(rule, eventKey, screenText)
    end
    if native then
        local nativeStatus = decision.native and decision.native.status or "unavailable"
        local reason = decision.native and decision.native.reason or decision.reason or "decision"
        native.Log("NOTIFY-OUTPUT", string.format(
            "rule=%s spell=%s event=%s trigger=%s source=%s reason=%s native=%s nativeStatus=%s sound=%s tts=%s screen=%s",
            tostring(rule.id or "?"), tostring(spellID or ns.firstItemID(rule) or "?"), tostring(eventKey),
            tostring(detectedEvent or eventKey), tostring(sourceEvent or "?"), tostring(reason),
            tostring(decision.native and decision.native.registered == true), tostring(nativeStatus),
            tostring(soundPlayed == true), tostring(ttsStatus), tostring(screenShown == true)))
    end
    return ttsCallReturned or screenShown or soundPlayed
end

function ns._Aura.resetEventState()
    ns._Aura.eventStates = {}
    ns._Aura.unreadableBaselines = {}
    if ns._Aura.oneEffectApplyAt then wipe(ns._Aura.oneEffectApplyAt) end
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

-- Rules with oneEffect treat all their triggers as one effect: while another trigger of the rule is still
-- active, neither the start nor the end of this one is announced.  A start is also skipped right after the
-- rule announced one (own cast first, its readable debuff a moment later).
ns._Aura.oneEffectApplyAt = setmetatable({}, { __mode = "k" })
function ns._Aura.otherTriggerActive(rule, spellID, eventKind)
    if eventKind ~= "apply" and eventKind ~= "expire" then return false end
    if not rule.oneEffect then return false end
    for _, otherID in ipairs(rule.spellIDs) do
        if otherID ~= spellID and activeAuras[otherID] then return true end
    end
    local lastApply = ns._Aura.oneEffectApplyAt[rule]
    return eventKind == "apply" and lastApply ~= nil and GetTime() - lastApply < 3
end

-- A configured ID matches a spell ID directly, or as another rank of the same spell when the rule tracks all ranks.
function ns.TriggerTracksRanks(rule, configuredID)
    local flag = rule and type(rule.rankIDs) == "table" and rule.rankIDs[configuredID]
    if flag == nil then flag = ns.isForever == true end
    return flag == true
end

function ns.RuleSpellMatches(rule, configuredID, spellID)
    if configuredID == spellID then return true end
    return ns.TriggerTracksRanks(rule, configuredID) and ns.SpellRanks ~= nil and ns.SpellRanks.SameFamily(configuredID, spellID)
end

-- True when an intermediate timeline node of the rule has some output switched on.
function ns.ruleHasMarkerOutput(rule)
    for _, marker in ipairs(rule.markers or {}) do
        local key = marker.key
        if key ~= "apply" and key ~= "expire" and key ~= "ready" then
            local profile = type(rule.screenProfiles) == "table" and rule.screenProfiles[key] or nil
            if rule[key .. "Enabled"] or rule[key .. "SoundEnabled"] or (profile and profile.enabled) then return true end
        end
    end
    return false
end

local function sayAura(spellID, eventKind, sourceEvent, castGUID, targetRule)
    for _, rule in ipairs(WoWraVoxDB.auras) do
        if (not targetRule or targetRule == rule) and rule.enabled
            and ns.Profiles.RuleMatchesCurrentSpecialization(rule)
            and not ns._Aura.otherTriggerActive(rule, spellID, eventKind) then
            local matches = false
            for _, configuredID in ipairs(rule.spellIDs) do
                if ns.RuleSpellMatches(rule, configuredID, spellID) then matches = true; break end
            end
            if matches then
                -- Any timeline marker key: apply, expire, beforeExpire, m1, m2, ...
                local enabled, message = rule[eventKind .. "Enabled"], rule[eventKind .. "Message"]
                local profile = ns.getRuleScreenProfile(rule, eventKind)
                local soundEnabled = rule[eventKind .. "SoundEnabled"]
                if enabled or soundEnabled or (profile and profile.enabled) then
                    if eventKind ~= "apply" or ns._Aura.shouldAnnounceApply(rule, spellID, sourceEvent, castGUID) then
                        if eventKind == "apply" and rule.oneEffect then ns._Aura.oneEffectApplyAt[rule] = GetTime() end
                        notifyRule(rule, eventKind, enabled and message or "", spellID, sourceEvent, eventKind)
                    end
                end
            end
        end
    end
end

do
local function auraTrackerConfig()
    local tracker = type(WoWraVoxDB) == "table" and WoWraVoxDB.auraTracker or nil
    return type(tracker) == "table" and tracker or {}
end

local function trackerRuleIDs(config)
    local selected = {}
    config = config or auraTrackerConfig()
    for _, group in pairs(type(config.groups) == "table" and config.groups or {}) do
        for _, id in ipairs(type(group) == "table" and group.entryIds or {}) do selected[tostring(id)] = true end
    end
    for _, item in ipairs(type(config.freeIcons) == "table" and config.freeIcons or {}) do
        local id = type(item) == "table" and item.id or item
        if id ~= nil then selected[tostring(id)] = true end
    end
    return selected
end

local function ruleHasBeforeExpireOutput(rule)
    local profile = ns.getRuleScreenProfile(rule, "beforeExpire")
    return rule.beforeExpireEnabled == true or rule.beforeExpireSoundEnabled == true
        or profile and profile.enabled == true
end

local function auraIconForSpell(spellID)
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, texture = pcall(C_Spell.GetSpellTexture, spellID)
        if ok and (type(texture) == "string" or type(texture) == "number") then
            local secret = false
            if issecretvalue then
                local secretOK, result = pcall(issecretvalue, texture)
                secret = not secretOK or result == true
            end
            if not secret then return texture end
        end
    end
    local info = getSpellInfo(spellID)
    local icon, ok = safeAuraField(info, "iconID")
    return ok and icon or nil
end

local function auraDurationObject(instanceID)
    if not (C_UnitAuras and type(C_UnitAuras.GetAuraDuration) == "function") or not isPublicNumber(instanceID) then return nil end
    local ok, duration = pcall(C_UnitAuras.GetAuraDuration, "player", instanceID)
    if not ok or duration == nil then return nil end
    if issecretvalue then
        local secretOK, secret = pcall(issecretvalue, duration)
        if not secretOK or secret then return nil end
    end
    if issecrettable and type(duration) == "table" then
        local secretOK, secret = pcall(issecrettable, duration)
        if not secretOK or secret then return nil end
    end
    return duration
end

do
-- Intermediate timeline markers (MarkerTimers.lua). The duration is the readable one, else the rule's override, else
-- the last readable duration learned for this spell (WoWraVoxProfilesDB.auraDurations); the latter two are estimates.
local markerTimers = ns.MarkerTimers and ns.MarkerTimers.Create({
    now = function() return GetTime() end,
    schedule = function(delay, callback)
        local ok, timer = pcall(C_Timer.NewTimer, delay, callback)
        return ok and timer or nil
    end,
    cancel = function(timer)
        if timer and type(timer.Cancel) == "function" then pcall(timer.Cancel, timer) end
    end,
    emit = function(ruleID, spellID, markerKey)
        for _, rule in ipairs(WoWraVoxDB and WoWraVoxDB.auras or {}) do
            if rule.id == ruleID then
                sayAura(spellID, markerKey, "MARKER_TIMER", nil, rule)
                return
            end
        end
    end,
})
ns.markerTimers = markerTimers

local function learnedDurations()
    if type(WoWraVoxProfilesDB) ~= "table" then return nil end
    WoWraVoxProfilesDB.auraDurations = type(WoWraVoxProfilesDB.auraDurations) == "table" and WoWraVoxProfilesDB.auraDurations or {}
    return WoWraVoxProfilesDB.auraDurations
end
ns.learnedDurations = learnedDurations

local function markerSignature(rule)
    local parts = {}
    for _, marker in ipairs(rule.markers or {}) do parts[#parts + 1] = marker.key .. "@" .. tostring(marker.at) .. "/" .. tostring(marker.anchor) .. tostring(marker.offset) end
    return table.concat(parts, ",") .. "|" .. tostring(rule.durationOverride)
end

function ns.updateMarkerTimers(rule, spellID, presence, expiration, readableDuration, isBaseline)
    if not (markerTimers and rule and rule.id) or presence == "unknown" then return end
    if presence ~= "active" then
        markerTimers:Update(rule.id, spellID, { active = false })
        return
    end
    local store = learnedDurations()
    if isPublicNumber(readableDuration) and readableDuration > 0 then ns.MarkerTimers.Learn(store, spellID, readableDuration) end
    local duration, estimated = ns.MarkerTimers.DurationFor(rule, spellID, readableDuration, store)
    local start
    if isPublicNumber(expiration) and expiration > 0 and isPublicNumber(readableDuration) and readableDuration > 0 then
        start = expiration - readableDuration
    else
        local current = markerTimers:Get(rule.id, spellID)
        start = current and current.start or GetTime()
    end
    markerTimers:Update(rule.id, spellID, {
        active = true, start = start, duration = duration, estimated = estimated,
        markers = rule.markers, baseline = isBaseline == true, signature = markerSignature(rule),
    })
end
end

local function updateAuraTrackerState(spellID, presence, aura, state, sourceEvent, isBaseline)
    if not auraTracker.stateManager then return end
    for _, rule in ipairs(WoWraVoxDB and WoWraVoxDB.auras or {}) do
        local ruleID = rule.id
        local matches = false
        if ruleID and rule.enabled and ns.Profiles.RuleMatchesCurrentSpecialization(rule) then
            for _, configuredID in ipairs(rule.spellIDs or {}) do
                if ns.RuleSpellMatches(rule, configuredID, spellID) then matches = true; break end
            end
        end
        if matches then
            local instanceID, stacks
            if aura then
                local instanceOK
                instanceID, instanceOK = safeAuraField(aura, "auraInstanceID")
                if not instanceOK then instanceID = nil end
                local stacksOK
                stacks, stacksOK = safeAuraField(aura, "applications")
                if not stacksOK or not isPublicNumber(stacks) then stacks = nil end
            end
            local expiration = state and state.expirationTime or nil
            local duration
            if aura then
                local value, durationOK = safeAuraField(aura, "duration")
                if durationOK and isPublicNumber(value) and value > 0 then duration = value end
            end
            local auraDurationObjectValue = aura and instanceID and auraDurationObject(instanceID) or nil
            ns.updateMarkerTimers(rule, spellID, presence, expiration, duration, isBaseline)
            auraTracker.stateManager:Update(ruleID, spellID, {
                presence = presence,
                instanceID = instanceID or (state and state.auraInstanceID),
                expirationTime = expiration,
                duration = duration,
                icon = auraIconForSpell(spellID),
                stacks = stacks,
                source = sourceEvent == "CDM_SIGNAL" and "cdm" or (presence == "active" and "aura" or "unknown"),
                durationObject = auraDurationObjectValue,
            }, {
                baseline = isBaseline == true,
                beforeExpireEnabled = false, -- every intermediate marker, the old warning included, runs in MarkerTimers
                warningPercent = rule.beforeExpirePercent,
            })
        end
    end
end

local function queueAuraTrackerUpdate()
    if not (auraTracker.view and auraTracker.frame) or auraTracker.updatePending then return end
    auraTracker.updatePending = true
    C_Timer.After(0, function()
        auraTracker.updatePending = false
        if auraTracker.view then auraTracker.view:Update(ns.getAuraTrackerEntries and ns.getAuraTrackerEntries() or {}) end
    end)
end

if ns.AuraTrackerState then
    auraTracker.stateManager = ns.AuraTrackerState.Create({
        now = function() return GetTime() end,
        schedule = function(delay, callback)
            local ok, timer = pcall(C_Timer.NewTimer, delay, callback)
            return ok and timer or nil
        end,
        cancel = function(timer)
            if timer and type(timer.Cancel) == "function" then pcall(timer.Cancel, timer) end
        end,
        emit = function(ruleID, eventKey, context)
            local rule
            for _, candidate in ipairs(WoWraVoxDB and WoWraVoxDB.auras or {}) do
                if candidate.id == ruleID then rule = candidate; break end
            end
            if rule and context and isPublicNumber(context.spellID) then
                sayAura(context.spellID, eventKey, "AURA_TRACKER_TIMER", nil, rule)
            end
        end,
    })
end

local function findAuraRuleByID(ruleID)
    for _, rule in ipairs(WoWraVoxDB and WoWraVoxDB.auras or {}) do
        if tostring(rule.id) == tostring(ruleID) then return rule end
    end
end

local function resolveAuraTrackerSignalSpellID(spellIDs)
    for _, candidateID in ipairs(spellIDs) do
        if isPublicNumber(candidateID) and auraWatchBySpellID[candidateID] then return candidateID end
    end
    local resolved
    for _, candidateID in ipairs(spellIDs) do
        if isPublicNumber(candidateID) then
            for _, rule in ipairs(WoWraVoxDB and WoWraVoxDB.auras or {}) do
                if rule.enabled and ns.Profiles.RuleMatchesCurrentSpecialization(rule) then
                    for _, auraID in ipairs(rule.spellIDs or {}) do
                        if auraWatchBySpellID[auraID] and ns._Aura.castIDFor(rule, auraID) == candidateID then
                            if resolved and resolved ~= auraID then return nil end
                            resolved = auraID
                        end
                    end
                end
            end
        end
    end
    return resolved
end

local function ensureSealTrackerGroup(config)
    config.groups = type(config.groups) == "table" and config.groups or {}
    local first
    for _, group in pairs(config.groups) do
        if type(group) == "table" and group.id then first = group; break end
    end
    if first then return first end
    local group = { id = "seals", order = 1, entryIds = {}, point = "CENTER", relativePoint = "CENTER",
        x = 0, y = 0, size = config.size or 40, spacing = config.spacing or 6 }
    config.groups.seals = group
    return group
end

local function syncAuraTrackerSealRule()
    local tracker = auraTrackerConfig()
    local families = type(tracker.families) == "table" and tracker.families or {}
    local family = families.seals
    if type(family) ~= "table" then return false end
    local auraIDs, castsByAura, seen = {}, {}, {}
    for _, row in ipairs(family.spells or {}) do
        if row.mappingVerified == true and validStoredSpellID(row.auraID) and validStoredSpellID(row.castID)
            and not seen[row.auraID] then
            seen[row.auraID] = true
            auraIDs[#auraIDs + 1] = row.auraID
            castsByAura[row.auraID] = row.castID
        end
    end
    table.sort(auraIDs)
    if #auraIDs == 0 then return false end

    local rule = family.ruleID and findAuraRuleByID(family.ruleID)
    if not rule then
        rule = newAuraRule()
        rule.name = L("All Seals")
        rule.spellIDs = {}
        WoWraVoxDB.nextRuleID = ns.ensureRuleID(rule, {}, tonumber(WoWraVoxDB.nextRuleID) or 0)
        table.insert(WoWraVoxDB.auras, rule)
        family.ruleID = rule.id
    end
    rule.name = L("All Seals")
    rule.spellIDs = auraIDs
    rule.castByAuraID = castsByAura
    ns._Aura.normalizeCastMap(rule)

    if family.includeInTracker == true then
        local group = ensureSealTrackerGroup(tracker)
        local included = false
        for _, id in ipairs(group.entryIds or {}) do
            if tostring(id) == tostring(rule.id) then included = true; break end
        end
        if not included then
            group.entryIds = type(group.entryIds) == "table" and group.entryIds or {}
            group.entryIds[#group.entryIds + 1] = tostring(rule.id)
        end
    end
    tracker.families = families
    if auraTracker.view then auraTracker.view:SetConfig(tracker) end
    if ns._Aura.rebuildAuraWatches then ns._Aura.rebuildAuraWatches() end
    C_Timer.After(0, function()
        if ns._Aura.syncAllAuras then ns._Aura.syncAllAuras(true) end
        if optionsFrame and optionsFrame:IsShown() and refreshList then refreshList() end
        queueAuraTrackerUpdate()
    end)
    return true
end

local function scanAuraTrackerSeals(nameFilter, includeInTracker)
    local familyAPI = ns.AuraTrackerFamily
    if not (familyAPI and WoWraVoxDB and not (InCombatLockdown and InCombatLockdown())) then return 0, "combat-or-unavailable" end
    local _, classFile = UnitClass("player")
    if classFile ~= "PALADIN" then return 0, "paladin-only" end
    local locale = GetLocale and GetLocale() or ""
    local filter = type(nameFilter) == "string" and trim(nameFilter) or ""
    local needle = locale == "enUS" and "seal of " or locale == "deDE" and "siegel " or filter:lower()
    if needle == "" then return 0, "manual-filter-required" end
    local spellbookIDs, spellNames = {}, {}
    collectSpellbook(spellbookIDs, needle, false, spellNames)
    local rows = {}
    for spellID in pairs(spellbookIDs) do
        local name = spellNames[spellID]
        if type(name) == "string" then rows[#rows + 1] = { spellID = spellID, name = name, learned = true } end
    end
    local candidates = familyAPI.ScanCandidates(rows, locale, filter ~= "" and filter or nil)
    if #candidates == 0 then return 0, "no-candidates" end

    local tracker = auraTrackerConfig()
    tracker.families = type(tracker.families) == "table" and tracker.families or {}
    local existingFamily = tracker.families.seals
    local family, added = familyAPI.Sync(tracker.families.seals, candidates, false)
    if family then
        family.includeInTracker = includeInTracker == nil
            and existingFamily and existingFamily.includeInTracker == true or includeInTracker == true
        tracker.sealNameFilter = filter ~= "" and filter or tracker.sealNameFilter
        tracker.families.seals = family
        normalizeAuraTrackerData(WoWraVoxDB)
        syncAuraTrackerSealRule()
        if ns.AuraCDM and type(ns.AuraCDM.RefreshSignals) == "function" then
            pcall(ns.AuraCDM.RefreshSignals)
        end
        if auraTracker.view then auraTracker.view:SetConfig(auraTrackerConfig()) end
    end
    local familyRule = family and family.ruleID and findAuraRuleByID(family.ruleID)
    local hasUnmapped = false
    for _, row in ipairs(family and family.spells or {}) do
        if row.mappingVerified ~= true then hasUnmapped = true; break end
    end
    local status = familyRule and (hasUnmapped and "partially-mapped" or "ready")
        or family and "unmapped-until-cdm" or "no-candidates"
    return added, status,
        familyRule and familyRule.id or nil
end
ns.syncAuraTrackerSeals = scanAuraTrackerSeals

local lastSealMappingScanAt = 0
local function observeSealMappingsFromCDM(spellIDs, active)
    if active ~= true or not (ns.AuraTrackerFamily and WoWraVoxDB)
        or (InCombatLockdown and InCombatLockdown())
        or not (C_UnitAuras and type(C_UnitAuras.GetAuraDataByIndex) == "function") then return false end
    local tracker = auraTrackerConfig()
    local family = tracker.families and tracker.families.seals
    if type(family) ~= "table" or type(family.spells) ~= "table" then return false end
    local now = GetTime()
    if now - lastSealMappingScanAt < 0.5 then return false end
    lastSealMappingScanAt = now
    local cdmIDs = {}
    for _, id in ipairs(type(spellIDs) == "table" and spellIDs or {}) do
        if isPublicNumber(id) then cdmIDs[id] = true end
    end
    if not next(cdmIDs) then return false end

    local changed = false
    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        for index = 1, 255 do
            local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", index, filter)
            if not ok then break end
            if issecretvalue then
                local secretOK, secret = pcall(issecretvalue, aura)
                if not secretOK or secret then break end
            end
            if issecrettable and type(aura) == "table" then
                local secretOK, secret = pcall(issecrettable, aura)
                if not secretOK or secret then break end
            end
            if not aura then break end
            local auraID, idOK = safeAuraField(aura, "spellId")
            if idOK and isPublicNumber(auraID) then
                local auraName, nameOK = safeAuraField(aura, "name")
                if nameOK and type(auraName) == "string" then
                    for _, row in ipairs(family.spells) do
                        if row.mappingVerified ~= true and cdmIDs[row.castID]
                            and type(row.name) == "string" and row.name == auraName then
                            local evidence = { source = "cdm", confirmed = true, castID = row.castID, auraID = auraID }
                            local confirmed = ns.AuraTrackerFamily.ConfirmMapping(family, row.spellID,
                                row.castID, auraID, evidence)
                            changed = changed or confirmed == true
                        end
                    end
                end
            end
        end
    end
    if changed then
        tracker.families.seals = family
        normalizeAuraTrackerData(WoWraVoxDB)
        syncAuraTrackerSealRule()
    end
    return changed
end

function ns.getAuraTrackerEntries()
    local config = auraTrackerConfig()
    local selected = trackerRuleIDs(config)
    local entries = {}
    for ruleID in pairs(selected) do
        local rule = findAuraRuleByID(ruleID)
        if rule then
            local chosen, chosenState
            local states = auraTracker.stateManager and auraTracker.stateManager:Get(rule.id) or {}
            for _, spellID in ipairs(rule.spellIDs or {}) do
                local state = states and states[spellID]
                if state and (state.presence == "active" or state.presence == "unknown") then
                    if not chosenState or state.presence == "active" then
                        chosen, chosenState = spellID, state
                        if state.presence == "active" then break end
                    end
                end
            end
            chosen = chosen or rule.spellIDs and rule.spellIDs[1]
            local state = chosenState or (states and chosen and states[chosen])
            local presence = state and state.presence or "unknown"
            entries[#entries + 1] = {
                id = tostring(rule.id),
                name = rule.name,
                icon = chosen and auraIconForSpell(chosen) or nil,
                active = presence == "active",
                presence = presence,
                stacks = state and state.stacks or nil,
                durationObject = chosen and auraTracker.stateManager
                    and auraTracker.stateManager:GetDurationObject(rule.id, chosen) or nil,
                source = state and state.source or "unknown",
                groupId = nil,
            }
        end
    end
    table.sort(entries, function(a, b) return a.id < b.id end)
    return entries
end

local function saveAuraTrackerLayout(config)
    if not WoWraVoxDB then return end
    local tracker = auraTrackerConfig()
    local source = type(config) == "table" and config or tracker
    local layout = ns.AuraTrackerView.NormalizeConfig(source)
    tracker.size, tracker.spacing = layout.size, layout.spacing
    tracker.groups, tracker.freeIcons = layout.groups, layout.freeIcons
    tracker.visibilityByEntry = layout.visibilityByEntry
    if type(source.showCountdown) == "boolean" then tracker.showCountdown = source.showCountdown end
    if type(source.showName) == "boolean" then tracker.showName = source.showName end
    if type(source.showStacks) == "boolean" then tracker.showStacks = source.showStacks end
    WoWraVoxDB.auraTracker = tracker
    if auraTracker.view then
        auraTracker.view:SetConfig(tracker)
        auraTracker.view:Update(ns.getAuraTrackerEntries())
    end
    if auraTracker.frame and auraTracker.frame.status then
        auraTracker.frame.status:SetText(next(trackerRuleIDs(tracker)) and ""
            or L("Aura tracker is empty. Configure it to add rules."))
    end
end

local function createAuraTrackerUI()
    if auraTracker.frame or not (UIParent and ns.AuraTrackerView) then return end
    local frame = CreateFrame("Frame", "WoWraVoxAuraTracker", UIParent, "BackdropTemplate")
    frame:SetSize(560, 286)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetFrameStrata("HIGH")
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    frame:SetBackdropColor(0.025, 0.03, 0.04, 0.82)
    frame:SetBackdropBorderColor(0.52, 0.42, 0.22, 0.75)
    frame:Hide()
    auraTracker.frame = frame

    local title = frame:CreateFontString(nil, "OVERLAY", "WoWraVoxFontNormal")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -9)
    title:SetText(L("Aura tracker"))
    title:SetTextColor(1, 0.82, 0.2)

    local function button(text, width, anchor, relative, x, y)
        local result = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        result:SetSize(width, 22)
        result:SetPoint(anchor, relative, anchor, x, y)
        result:SetText(L(text))
        return result
    end

    local function setEditing(editing)
        editing = editing == true
        if editing and InCombatLockdown and InCombatLockdown() then
            frame.status:SetText(L("Layout changes are available out of combat."))
            return false
        end
        auraTracker.view:SetEditMode(editing)
        frame.editButton:SetText(L(editing and "Done" or "Configure"))
        frame.resetButton:SetShown(editing)
        frame.countdownCheck:SetShown(editing)
        frame.nameCheck:SetShown(editing)
        frame.stacksCheck:SetShown(editing)
        frame.allSealsButton:SetShown(editing and frame.isPaladin)
        frame.cdmButton:SetShown(editing)
        frame.sealFilter:SetShown(editing and frame.manualSealFilter)
        return true
    end
    auraTracker.setEditing = setEditing

    frame.closeButton = button("Close", 52, "TOPRIGHT", frame, -6, -5)
    frame.closeButton:SetScript("OnClick", function() frame:Hide() end)
    frame.editButton = button("Configure", 82, "RIGHT", frame.closeButton, -5, 0)
    frame.editButton:SetScript("OnClick", function()
        setEditing(not auraTracker.view.editMode)
    end)
    frame.resetButton = button("Reset positions", 100, "RIGHT", frame.editButton, -5, 0)
    frame.resetButton:SetScript("OnClick", function()
        if InCombatLockdown and InCombatLockdown() then return end
        local config = auraTrackerConfig()
        for _, group in pairs(config.groups or {}) do
            group.x, group.y, group.point, group.relativePoint = nil, nil, nil, nil
        end
        for _, item in ipairs(config.freeIcons or {}) do
            item.x, item.y, item.point, item.relativePoint = nil, nil, nil, nil
        end
        saveAuraTrackerLayout(config)
        if auraTracker.view.ResetPosition then auraTracker.view:ResetPosition() end
    end)
    frame.resetButton:Hide()

    frame.content = CreateFrame("Frame", nil, frame)
    frame.content:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -68)
    frame.content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 6)
    frame.status = frame:CreateFontString(nil, "OVERLAY", "WoWraVoxFontHighlightSmall")
    frame.status:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -35)
    frame.status:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
    frame.status:SetHeight(24)
    frame.status:SetJustifyH("LEFT")
    frame.status:SetText(L("Aura tracker is empty. Configure it to add rules."))

    local config = auraTrackerConfig()
    local callbacks = {
        listRules = function()
            local result = {}
            for _, rule in ipairs(WoWraVoxDB and WoWraVoxDB.auras or {}) do
                result[#result + 1] = { id = tostring(rule.id), name = rule.name or tostring(rule.id) }
            end
            return result
        end,
        onLayoutChange = function(nextConfig) saveAuraTrackerLayout(nextConfig) end,
        onAddEntry = function(ruleID)
            local tracker = auraTrackerConfig()
            local group = ensureSealTrackerGroup(tracker)
            group.entryIds = type(group.entryIds) == "table" and group.entryIds or {}
            for _, id in ipairs(group.entryIds) do if tostring(id) == tostring(ruleID) then return end end
            for _, item in ipairs(tracker.freeIcons or {}) do if tostring(item.id) == tostring(ruleID) then return end end
            group.entryIds[#group.entryIds + 1] = tostring(ruleID)
            saveAuraTrackerLayout(tracker)
            if ns._Aura.rebuildAuraWatches then ns._Aura.rebuildAuraWatches() end
            if ns._Aura.syncAllAuras then ns._Aura.syncAllAuras(true) end
        end,
        onAddGroup = function()
            local tracker = auraTrackerConfig()
            tracker.groups = type(tracker.groups) == "table" and tracker.groups or {}
            local order = 0
            for _, group in pairs(tracker.groups) do
                order = math.max(order, tonumber(group.order) or 0)
            end
            local suffix, id = order + 1, nil
            repeat
                id = "tracker-group-" .. tostring(suffix)
                suffix = suffix + 1
            until tracker.groups[id] == nil
            tracker.groups[id] = { id = id, order = order + 1, entryIds = {}, point = "CENTER",
                relativePoint = "CENTER", x = 0, y = 0, size = tracker.size or 40, spacing = tracker.spacing or 6 }
            saveAuraTrackerLayout(tracker)
        end,
        onRemoveEntry = function(ruleID)
            local tracker = auraTrackerConfig()
            for _, group in pairs(tracker.groups or {}) do
                for index = #(group.entryIds or {}), 1, -1 do
                    if tostring(group.entryIds[index]) == tostring(ruleID) then table.remove(group.entryIds, index) end
                end
            end
            for index = #(tracker.freeIcons or {}), 1, -1 do
                if tostring(tracker.freeIcons[index].id) == tostring(ruleID) then table.remove(tracker.freeIcons, index) end
            end
            if tracker.visibilityByEntry then tracker.visibilityByEntry[tostring(ruleID)] = nil end
            saveAuraTrackerLayout(tracker)
            if ns._Aura.rebuildAuraWatches then ns._Aura.rebuildAuraWatches() end
        end,
        onDetachEntry = function(ruleID, groupID)
            local tracker = auraTrackerConfig()
            local group = tracker.groups and tracker.groups[groupID]
            if not group then return end
            for index = #(group.entryIds or {}), 1, -1 do
                if tostring(group.entryIds[index]) == tostring(ruleID) then table.remove(group.entryIds, index) end
            end
            tracker.freeIcons = type(tracker.freeIcons) == "table" and tracker.freeIcons or {}
            tracker.freeIcons[#tracker.freeIcons + 1] = { id = tostring(ruleID), order = #tracker.freeIcons + 1,
                point = "CENTER", relativePoint = "CENTER", x = 0, y = 0, size = tracker.size or 40 }
            saveAuraTrackerLayout(tracker)
        end,
        onVisibilityChange = function(ruleID, mode)
            local tracker = auraTrackerConfig()
            tracker.visibilityByEntry = type(tracker.visibilityByEntry) == "table" and tracker.visibilityByEntry or {}
            tracker.visibilityByEntry[tostring(ruleID)] = mode == "dimInactive" and "dimInactive" or nil
            saveAuraTrackerLayout(tracker)
        end,
        onMoveEntry = function(ruleID, direction, groupID)
            local tracker = auraTrackerConfig()
            local group = tracker.groups and tracker.groups[groupID]
            if not group or type(group.entryIds) ~= "table" then return end
            for index, id in ipairs(group.entryIds) do
                if tostring(id) == tostring(ruleID) then
                    local target = index + (direction == "previous" and -1 or 1)
                    if target >= 1 and target <= #group.entryIds then
                        group.entryIds[index], group.entryIds[target] = group.entryIds[target], group.entryIds[index]
                        saveAuraTrackerLayout(tracker)
                    end
                    return
                end
            end
        end,
    }
    auraTracker.view = ns.AuraTrackerView.Create(frame.content, config, callbacks)
    auraTracker.view:Update(ns.getAuraTrackerEntries())

    local locale = GetLocale and GetLocale() or ""
    frame.manualSealFilter = locale ~= "enUS" and locale ~= "deDE"
    local _, classFile = UnitClass("player")
    frame.isPaladin = classFile == "PALADIN"
    -- createEditBox is a local defined further down the file; reach it through ns at run time.
    frame.sealFilter = ns.createEditBox(frame, 128, 22)
    frame.sealFilter:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 36)
    frame.sealFilter:SetText(auraTrackerConfig().sealNameFilter or "")
    frame.sealFilter:SetTextInsets(5, 5, 0, 0)
    frame.sealFilter:Hide()
    frame.allSealsButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.allSealsButton:SetSize(104, 22)
    frame.allSealsButton:SetPoint("BOTTOMLEFT", frame.sealFilter, "BOTTOMRIGHT", 4, 0)
    frame.allSealsButton:SetText(L("Add all Seals"))
    frame.allSealsButton:SetScript("OnClick", function()
        local filter = frame.manualSealFilter and frame.sealFilter:GetText() or nil
        local added, status = ns.syncAuraTrackerSeals(filter, true)
        if frame.manualSealFilter and filter and filter ~= "" then
            local tracker = auraTrackerConfig()
            tracker.sealNameFilter = trim(filter)
        end
        local message = status == "partially-mapped" and "Seal family added; some mappings await Blizzard CDM evidence."
            or status == "ready" and added == 0 and "All matching Seals are already added."
            or status == "ready" and string.format(L("Added %d seal candidates."), added)
            or status == "unmapped-until-cdm" and "Seal candidates saved; aura mapping waits for Blizzard CDM evidence."
            or status == "manual-filter-required" and "Enter a localized name filter first."
            or status == "paladin-only" and "All Seals is available only to Paladins."
            or status == "combat-or-unavailable" and "Add all Seals after combat."
            or status == "no-candidates" and "No matching learned Seals found."
            or string.format(L("Added %d seal candidates."), added)
        frame.status:SetText(L(message))
    end)
    frame.allSealsButton:SetShown(false)

    frame.cdmButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.cdmButton:SetSize(128, 22)
    frame.cdmButton:SetPoint("LEFT", frame.allSealsButton, "RIGHT", 4, 0)
    frame.cdmButton:SetText(L("Open Blizzard CDM"))
    frame.cdmButton:SetScript("OnClick", function()
        local ok = ns.AuraCDM and ns.AuraCDM.OpenSettings and ns.AuraCDM.OpenSettings()
        if not ok then frame.status:SetText(L("Blizzard Cooldown Manager is unavailable or combat is active.")) end
    end)
    frame.cdmButton:Hide()

    local function displayCheck(key, label, x)
        local check = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
        check:SetSize(22, 22)
        check:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", x, 8)
        check.text = check:CreateFontString(nil, "OVERLAY", "WoWraVoxFontHighlightSmall")
        check.text:SetPoint("LEFT", check, "RIGHT", 1, 0)
        check.text:SetText(L(label))
        check:SetChecked(auraTrackerConfig()[key] ~= false)
        check:SetScript("OnClick", function(self)
            local nextConfig = auraTrackerConfig()
            nextConfig[key] = self:GetChecked() == true or self:GetChecked() == 1
            saveAuraTrackerLayout(nextConfig)
        end)
        check:Hide()
        return check
    end
    frame.countdownCheck = displayCheck("showCountdown", "Countdown", 12)
    frame.nameCheck = displayCheck("showName", "Name", 124)
    frame.stacksCheck = displayCheck("showStacks", "Stacks", 220)
    frame.status:SetText(L("Aura tracker is empty. Configure it to add rules."))
end

function ns.OpenAuraTracker(editMode)
    if not auraTracker.frame then createAuraTrackerUI() end
    if not auraTracker.frame or not auraTracker.view or not auraTracker.setEditing then return false end
    auraTracker.view:SetConfig(auraTrackerConfig())
    local entries = ns.getAuraTrackerEntries()
    auraTracker.view:Update(entries)
    auraTracker.frame.status:SetText(#entries == 0 and L("Aura tracker is empty. Configure it to add rules.") or "")
    auraTracker.frame:Show()
    return auraTracker.setEditing(editMode == true)
end

auraTracker.config = auraTrackerConfig
auraTracker.ruleIDs = trackerRuleIDs
auraTracker.findRule = findAuraRuleByID
auraTracker.resolveSignalSpellID = resolveAuraTrackerSignalSpellID
auraTracker.updateState = updateAuraTrackerState
auraTracker.queueUpdate = queueAuraTrackerUpdate
auraTracker.observeSealMappings = observeSealMappingsFromCDM
auraTracker.scanSeals = scanAuraTrackerSeals
auraTracker.createUI = createAuraTrackerUI
end

local rebuildAuraWatchesInner
local function rebuildAuraWatches()
    rebuildAuraWatchesInner()
    -- Families asked for during the rebuild that are not known yet: one background scan, then rebuild once more.
    if ns.SpellRanks then ns.SpellRanks.RunScan() end
end
function rebuildAuraWatchesInner()
    wipe(auraWatchBySpellID)
    local tracker = auraTracker.config()
    local validRuleIDs = {}
    for _, rule in ipairs(WoWraVoxDB.auras) do validRuleIDs[tostring(rule.id)] = true end
    local prunedTrackerLayout = false
    for _, group in pairs(tracker.groups or {}) do
        if type(group) == "table" then
            for index = #(group.entryIds or {}), 1, -1 do
                if not validRuleIDs[tostring(group.entryIds[index])] then
                    table.remove(group.entryIds, index)
                    prunedTrackerLayout = true
                end
            end
        end
    end
    for index = #(tracker.freeIcons or {}), 1, -1 do
        local id = type(tracker.freeIcons[index]) == "table" and tracker.freeIcons[index].id or tracker.freeIcons[index]
        if not validRuleIDs[tostring(id)] then
            table.remove(tracker.freeIcons, index)
            prunedTrackerLayout = true
        end
    end
    for id in pairs(tracker.visibilityByEntry or {}) do
        if not validRuleIDs[tostring(id)] then
            tracker.visibilityByEntry[id] = nil
            prunedTrackerLayout = true
        end
    end
    if prunedTrackerLayout and auraTracker.view then auraTracker.view:SetConfig(tracker) end
    local trackerIDs = auraTracker.ruleIDs(tracker)
    local activeRuleIDs = {}
    for _, rule in ipairs(WoWraVoxDB.auras) do
        local applyScreen = ns.getRuleScreenProfile(rule, "apply")
        local expireScreen = ns.getRuleScreenProfile(rule, "expire")
        local beforeExpireScreen = ns.getRuleScreenProfile(rule, "beforeExpire")
        local ruleID = tostring(rule.id)
        local trackerSelected = trackerIDs[ruleID] == true
        local ruleActive = rule.enabled and ns.Profiles.RuleMatchesCurrentSpecialization(rule)
            and (rule.applyEnabled or rule.expireEnabled or rule.applySoundEnabled or rule.expireSoundEnabled
            or rule.beforeExpireEnabled or rule.beforeExpireSoundEnabled
            or ns._Aura.hasApplyCue(rule) or (rule.expireCategory or "none") ~= "none"
            or applyScreen.enabled or expireScreen.enabled or beforeExpireScreen.enabled or trackerSelected
            or ns.ruleHasMarkerOutput(rule))
        if ruleActive then
            activeRuleIDs[ruleID] = true
            local watchIDs = rule.spellIDs
            if ns.SpellRanks then
                watchIDs = {}
                for _, id in ipairs(rule.spellIDs) do
                    if ns.TriggerTracksRanks(rule, id) then
                        for _, member in ipairs(ns.SpellRanks.Expand({ id })) do watchIDs[#watchIDs + 1] = member end
                    else
                        watchIDs[#watchIDs + 1] = id
                    end
                end
            end
            for _, spellID in ipairs(watchIDs) do
                local _, status = getSpellInfo(spellID)
                if status == "valid" then auraWatchBySpellID[spellID] = true end
            end
        elseif auraTracker.stateManager then
            auraTracker.stateManager:ResetRule(rule.id)
        end
    end

    for spellID in pairs(activeAuras) do
        if not auraWatchBySpellID[spellID] then
            local state = activeAuras[spellID]
            ns._Aura.cancelExpiry(state)
            if state and state.auraInstanceID then auraByInstanceID[state.auraInstanceID] = nil end
            activeAuras[spellID] = nil
        end
    end
    for rule, states in pairs(ns._Aura.eventStates) do
        local applyScreen = ns.getRuleScreenProfile(rule, "apply")
        local expireScreen = ns.getRuleScreenProfile(rule, "expire")
        local beforeExpireScreen = ns.getRuleScreenProfile(rule, "beforeExpire")
        local ruleActive = rule.enabled and ns.Profiles.RuleMatchesCurrentSpecialization(rule)
            and (rule.applyEnabled or rule.expireEnabled or rule.applySoundEnabled or rule.expireSoundEnabled
            or rule.beforeExpireEnabled or rule.beforeExpireSoundEnabled
            or ns._Aura.hasApplyCue(rule) or (rule.expireCategory or "none") ~= "none"
            or applyScreen.enabled or expireScreen.enabled or beforeExpireScreen.enabled
            or trackerIDs[tostring(rule.id)] == true or ns.ruleHasMarkerOutput(rule))
        if not ruleActive then
            ns._Aura.eventStates[rule] = nil
        else
            for spellID in pairs(states) do
                local configured = false
                for _, configuredID in ipairs(rule.spellIDs or {}) do
                    if ns.RuleSpellMatches(rule, configuredID, spellID) then configured = true; break end
                end
                if not configured or not auraWatchBySpellID[spellID] then states[spellID] = nil end
            end
            if not next(states) then ns._Aura.eventStates[rule] = nil end
        end
    end
    for spellID in pairs(ns._Aura.unreadableBaselines) do
        if not auraWatchBySpellID[spellID] then ns._Aura.unreadableBaselines[spellID] = nil end
    end
    if auraTracker.stateManager then
        for _, rule in ipairs(WoWraVoxDB.auras) do
            if not activeRuleIDs[tostring(rule.id)] then auraTracker.stateManager:ResetRule(rule.id) end
        end
    end
    if ns.AuraSoundFallback then ns.AuraSoundFallback.Refresh(WoWraVoxDB.auras) end
end
ns._Aura.rebuildAuraWatches = rebuildAuraWatches

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

-- The cast that stands for a trigger: a preset rule can bundle a cast ID with a different aura ID
-- (rule.castByAuraID[auraID] = castID); every other trigger is its own cast.
function ns._Aura.castIDFor(rule, auraID)
    local map = type(rule) == "table" and rule.castByAuraID
    return type(map) == "table" and ns._Aura.validIntegerID(map[auraID]) or auraID
end

-- Keeps only positive integer pairs; nil when nothing valid is left.
function ns._Aura.normalizeCastMap(rule)
    local map = rule.castByAuraID
    if type(map) ~= "table" then rule.castByAuraID = nil; return end
    local clean
    for auraID, castID in pairs(map) do
        if type(auraID) == "number" and ns._Aura.validIntegerID(auraID) == auraID
            and type(castID) == "number" and ns._Aura.validIntegerID(castID) == castID then
            clean = clean or {}
            clean[auraID] = castID
        end
    end
    rule.castByAuraID = clean
end

-- Keeps only positive integer aura IDs with a valid category cue (rule.categoryByAuraID[auraID] = cue);
-- nil when nothing valid is left.
function ns._Aura.normalizeCategoryMap(rule)
    local map = rule.categoryByAuraID
    if type(map) ~= "table" then rule.categoryByAuraID = nil; return end
    local clean
    for auraID, cue in pairs(map) do
        local canonical = type(cue) == "string" and NOTIFICATION_CUE_ALIASES[cue] or nil
        if type(auraID) == "number" and ns._Aura.validIntegerID(auraID) == auraID and canonical then
            clean = clean or {}
            clean[auraID] = canonical
        end
    end
    rule.categoryByAuraID = clean
end

-- The category cue of one trigger: an explicit group cue (alertCategory) wins for every effect; a group on
-- "none" falls back to the effect's own cue (rule.categoryByAuraID); otherwise "none". Applies to the
-- application only, the expiration cue stays a group value.
function ns._Aura.cueFor(rule, spellID)
    if type(rule) ~= "table" then return "none" end
    local group = rule.alertCategory
    if type(group) == "string" and group ~= "" and group ~= "none" then return group end
    local map = rule.categoryByAuraID
    local cue = type(map) == "table" and type(spellID) == "number" and map[spellID] or nil
    return type(cue) == "string" and cue or "none"
end

-- True when a rule has any application cue: a group cue or per-effect cues.
function ns._Aura.hasApplyCue(rule)
    return rule.alertCategory ~= "none" or (type(rule.categoryByAuraID) == "table" and next(rule.categoryByAuraID) ~= nil)
end

-- Text of the "none" entry of the Application-Fallback dropdown: "Per effect" while the group has no cue of its
-- own but its effects bring theirs.
function ns._Aura.noneCueLabel(rule, eventKey)
    local map = eventKey == "apply" and type(rule) == "table" and rule.categoryByAuraID
    return L(type(map) == "table" and next(map) ~= nil and "Per effect" or "No category cue")
end

-- Localized display text of one cue ("Offensive · Somebody loves you" and so on).
function ns._Aura.cueLabel(cue)
    return L(NOTIFICATION_CUE_LABELS[cue] or cue)
end

-- Wildcard context of an aura trigger for {spell}: the name WoW gives the spell, nil when it is unreadable.
function ns._Aura.spellContext(spellID)
    if type(spellID) ~= "number" or not (C_Spell and type(C_Spell.GetSpellName) == "function") then return nil end
    local ok, name = pcall(C_Spell.GetSpellName, spellID)
    if ok and type(name) == "string" and name ~= "" and not (issecretvalue and issecretvalue(name)) then
        return { spell = name }
    end
end

-- C_Spell.IsSelfBuff describes the effect, not the spell's class owner. Require the current character to know
-- the cast ID before treating it as an own-cast signal; otherwise external class buffs need their category cue.
function ns._Aura.addonCanSpeak(spellID, rule)
    local castID = ns._Aura.castIDFor(rule, spellID)
    if ns._Aura.getSelfBuffStatus(castID) ~= "true" then return false end
    local hasSpellbookAPI = false
    if type(IsPlayerSpell) == "function" then
        hasSpellbookAPI = true
        local ok, known = pcall(IsPlayerSpell, castID)
        if ok and known == true then return true end
    end
    if type(IsSpellKnownOrOverridesKnown) == "function" then
        hasSpellbookAPI = true
        local ok, known = pcall(IsSpellKnownOrOverridesKnown, castID)
        if ok and known == true then return true end
    end
    if type(IsSpellKnown) == "function" then
        hasSpellbookAPI = true
        local ok, known = pcall(IsSpellKnown, castID)
        if ok and known == true then return true end
    end
    -- Retail always provides spellbook APIs. Keep non-Retail harnesses on prior behavior when none exist.
    return not hasSpellbookAPI
end

function ns._Aura.combatInfo(spellID, rule)
    local secrecy = ns._Aura.auraSecrecy(spellID)
    if secrecy == "never" then
        return "spoken", L("Combat: custom text possible"), L("WoW exposes this effect in combat. Custom text requires TTS to be enabled.")
    elseif ns._Aura.addonCanSpeak(spellID, rule) then
        return "cast", L("Combat: own cast"), L("Your current character knows this self-buff spell, so WoWraVox can use custom text for your cast. An effect from another player may need the configured category sound.")
    elseif secrecy == "unknown" then
        return "unknown", L("Combat: availability unknown"), L("Combat detection cannot currently be determined. A configured category sound may announce this effect.")
    end
    return "sound", L("Combat: category may be needed"), L("WoW may hide this effect in combat. Custom text may be unavailable; the configured category sound can announce it instead.")
end

local AURA_TRACKING_STATUS = {
    direct = { key = "direct", label = "Direct", color = { 0.35, 0.86, 0.56 },
        help = "WoWraVox can read this aura in combat without a Cooldown Manager signal." },
    ownCast = { key = "ownCast", label = "Own cast", color = { 0.45, 0.76, 0.96 },
        help = "This self-buff spell is known to your current character, so WoWraVox can detect your own cast. An effect from another player may need the selected category cue." },
    tracked = { key = "tracked", label = "CDM tracked", color = { 0.35, 0.82, 0.58 },
        help = "This aura is already assigned to Cooldown Manager Tracked Buffs or Bars. Its active state can serve as a combat signal. Click this row to open Advanced Cooldown Settings." },
    available = { key = "available", label = "Available, not tracked", color = { 1, 0.68, 0.2 },
        help = "Your current class/spec exposes this learned aura in Cooldown Manager, but it is not assigned to Tracked Buffs or Bars yet. Click this row for a prompt, then open Advanced Cooldown Settings and assign it manually. The category cue remains available." },
    unavailable = { key = "unavailable", label = "Category cue", color = { 1, 0.48, 0.34 },
        help = "No matching trackable aura is exposed for this class/spec. If WoW hides the effect, WoWraVox can use the configured category cue; custom text may be unavailable." },
    unlearned = { key = "unlearned", label = "Not learned", color = { 0.68, 0.7, 0.74 },
        help = "Cooldown Manager lists this as an aura for your class/spec, but marks it as not learned. WoWraVox will not suggest tracking it." },
    unknown = { key = "unknown", label = "Status unknown", color = { 0.68, 0.7, 0.74 },
        help = "WoWraVox could not verify this aura's Cooldown Manager eligibility. Learning mode and the configured category cue remain available." },
}

local function auraTrackingPresentation(spellID, rule, statuses)
    local combatState = ns._Aura.combatInfo(spellID, rule)
    if combatState == "spoken" then return AURA_TRACKING_STATUS.direct end
    local status = type(statuses) == "table" and statuses[spellID]
    local key = type(status) == "table" and status.key or status
    return AURA_TRACKING_STATUS[key] or AURA_TRACKING_STATUS.unknown
end

function ns._Aura.addCombatTooltip(spellID, rule, statuses)
    local state, label, explanation = ns._Aura.combatInfo(spellID, rule)
    GameTooltip:AddLine(label, 0.88, 0.75, 0.4, true)
    GameTooltip:AddLine(explanation, 0.8, 0.8, 0.8, true)
    if not rule then return end
    local trackingStatus = auraTrackingPresentation(spellID, rule, statuses)
    local statusColor = trackingStatus.color
    GameTooltip:AddLine(L(trackingStatus.label), statusColor[1], statusColor[2], statusColor[3], true)
    GameTooltip:AddLine(L(trackingStatus.help), 0.8, 0.8, 0.8, true)
    local decision = ns.RuleOutput.Decide(rule, "apply", { spellID = spellID })
    if decision.native.selected then
        local category = decision.native.category
        for _, choice in ipairs(NOTIFICATION_CUE_CHOICES) do
            if choice.value == category then category = L(choice.label); break end
        end
        GameTooltip:AddLine(string.format(L("Application category: %s"), category), 0.9, 0.82, 0.5, true)
        local status = decision.native.status
        local text = status == "registered" and "Category sound registered: it plays instead of custom text, without a duplicate announcement."
            or status == "pending" and "Category sound registration pending. It is not ready yet."
            or status == "failed" and "Category sound registration failed. This effect may remain silent in combat."
            or "Category sound is not currently registered."
        GameTooltip:AddLine(L(text), 0.8, 0.8, 0.8, true)
    elseif trackingStatus.key == "ownCast" and decision.media.native.status ~= "registered" then
        GameTooltip:AddLine(L("No category sound configured for effects received from another player. They may be silent in combat."),
            0.95, 0.65, 0.3, true)
    elseif state ~= "spoken" and state ~= "cast" and decision.media.native.status ~= "registered" then
        GameTooltip:AddLine(L("No category sound configured. This effect may remain silent in combat."), 0.95, 0.65, 0.3, true)
    end
end

function ns._Aura.handleCast(unit, castGUID, castSpellID)
    if unit ~= "player" or not isPublicNumber(castSpellID) then return end
    if not ns._Aura.aurasAreSecret() then return end
    castGUID = ns._Aura.readableString(castGUID)
    local selfBuffStatus = ns._Aura.getSelfBuffStatus(castSpellID)
    local identityMatches = {}
    for _, rule in ipairs(WoWraVoxDB and WoWraVoxDB.auras or {}) do
        if rule.enabled and ns.Profiles.RuleMatchesCurrentSpecialization(rule) then
            local announced = false
            for _, rawAuraID in ipairs(rule.spellIDs or {}) do
                local auraID = ns._Aura.validIntegerID(rawAuraID)
                if auraID and ns.RuleSpellMatches(rule, ns._Aura.castIDFor(rule, auraID), castSpellID) and not announced then
                    announced = true
                    table.insert(identityMatches, tostring(rule.id or "?") .. ":" .. tostring(auraID))
                    if ns._Aura.addonCanSpeak(auraID, rule) then
                        sayAura(auraID, "apply", "UNIT_SPELLCAST_SUCCEEDED", castGUID, rule)
                    end
                end
            end
        end
    end
    ns._Aura.logCastDiagnostic(castGUID, castSpellID, selfBuffStatus, identityMatches)
end

local processAura
local function scheduleAuraExpiry(spellID, state, delay, kind)
    kind = kind or "expiry"
    if state.expiryTimer and state.expiryTimerKind == kind
        and state.expiryTimerInstanceID == state.auraInstanceID
        and (kind == "retry" or state.expiryTimerTarget == state.expirationTime) then
        return
    end
    ns._Aura.cancelExpiry(state)
    local generation = state.timerGeneration
    local ok, timer = pcall(C_Timer.NewTimer, math.max(0.05, delay), function()
        if activeAuras[spellID] == state and state.timerGeneration == generation then
            state.expiryTimer = nil
            state.expiryTimerKind = nil
            state.expiryTimerTarget = nil
            state.expiryTimerInstanceID = nil
            processAura(spellID, false, "AURA_TIMER")
        end
    end)
    if ok and timer then
        state.expiryTimer = timer
        state.expiryTimerKind = kind
        state.expiryTimerTarget = kind == "expiry" and state.expirationTime or nil
        state.expiryTimerInstanceID = state.auraInstanceID
    end
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
            if state.queryFailures <= 4 then scheduleAuraExpiry(spellID, state, 0.5, "retry") end
        end
        auraTracker.updateState(spellID, "unknown", nil, state, sourceEvent, isBaseline)
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
                if state.queryFailures <= 4 then scheduleAuraExpiry(spellID, state, 0.5, "retry") end
            end
            auraTracker.updateState(spellID, "active", aura, nil, sourceEvent, isBaseline)
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
            -- Once a real expiry is readable, a CDM removal must respect it; durationless CDM states keep their signal.
            state.fromCDM = state.fromCDM and expirationTime <= 0
            if state.auraInstanceID and state.auraInstanceID ~= auraInstanceID then
                auraByInstanceID[state.auraInstanceID] = nil
            end
            state.auraInstanceID = auraInstanceID
            state.expirationTime = expirationTime
            if auraInstanceID then auraByInstanceID[auraInstanceID] = spellID end
        end

        if expirationTime > 0 then
            scheduleAuraExpiry(spellID, state, expirationTime - GetTime())
        else
            ns._Aura.cancelExpiry(state)
        end
        auraTracker.updateState(spellID, "active", aura, state, sourceEvent, isBaseline)
        return
    end

    -- aura == nil.  While auras are secret, "absent" is only trusted at the aura's
    -- known expiry moment; otherwise it is unknown and no state is touched.  Auras Blizzard
    -- marks as never secret stay readable in combat, so nil is a reliable "absent" for them.
    local now = GetTime()
    local atExpiry = state and state.expirationTime > 0
        and now >= state.expirationTime - 0.5 and now <= state.expirationTime + 3
    if not atExpiry and ns._Aura.aurasAreSecret() and ns._Aura.auraSecrecy(spellID) ~= "never" then
        -- Unknown, not absent: if the aura turns readable later (combat ended while it runs) it was applied
        -- while hidden and must not be announced as new then.
        ns._Aura.unreadableBaselines[spellID] = true
        if ns.AuraSoundFallback then ns.AuraSoundFallback.LogAura(spellID, "aura-absent-unknown-secret", sourceEvent) end
        auraTracker.updateState(spellID, "unknown", nil, state, sourceEvent, isBaseline)
        return
    end
    ns._Aura.clearEventState(spellID)
    if state then
        if ns.AuraSoundFallback then ns.AuraSoundFallback.LogAura(spellID, "aura-readable-absent", sourceEvent) end
        ns._Aura.cancelExpiry(state)
        activeAuras[spellID] = nil
        if state.auraInstanceID then auraByInstanceID[state.auraInstanceID] = nil end
        if atExpiry then
            sayAura(spellID, "expire", sourceEvent)
        end
    end
    auraTracker.updateState(spellID, "inactive", nil, nil, sourceEvent, isBaseline)
end

local processAuraImpl = processAura
processAura = function(spellID, isBaseline, sourceEvent)
    processAuraImpl(spellID, isBaseline, sourceEvent)
    auraTracker.queueUpdate()
end
ns._Aura.processAura = processAura

-- Cooldown Manager signal for auras hidden in combat (WoWraVoxTooltip.lua reports the icon's linked spell IDs
-- and whether it is lit). It speaks only while the addon's own reading of the aura is hidden:
-- a readable aura belongs to processAura, so nothing is announced twice.  activeAuras[spellID] is the shared
-- active state, so a transition runs once however many icons or hooks report it, and it feeds the same
-- apply/expire rules (sayAura) as a normal read, with the cast dedupe of shouldAnnounceApply.
function ns._Aura.cdmSignal(spellIDs, active)
    if type(active) ~= "boolean" then return end
    if type(spellIDs) ~= "table" then spellIDs = { spellIDs } end
    auraTracker.observeSealMappings(spellIDs, active)
    local spellID = auraTracker.resolveSignalSpellID(spellIDs)
    if not spellID then return end
    local aura, queryOK = getAura(spellID)
    local hidden = not queryOK
    if queryOK and aura == nil then
        -- processAura treats "absent" in a secret context as unknown too; Blizzard's never-secret auras are exempt
        hidden = ns._Aura.aurasAreSecret() and ns._Aura.auraSecrecy(spellID) ~= "never"
    elseif queryOK then
        local _, expirationOK = safeAuraField(aura, "expirationTime")
        local _, instanceOK = safeAuraField(aura, "auraInstanceID")
        hidden = not (expirationOK and instanceOK)
    end
    if not hidden then
        if aura then
            auraTracker.updateState(spellID, "active", aura, activeAuras[spellID], "CDM_SIGNAL", false)
        else
            auraTracker.updateState(spellID, "inactive", nil, nil, "CDM_SIGNAL", false)
        end
        auraTracker.queueUpdate()
        return
    end

    local state = activeAuras[spellID]
    if active then
        auraTracker.updateState(spellID, "active", nil, nil, "CDM_SIGNAL", false)
        auraTracker.queueUpdate()
        if state then return end
        activeAuras[spellID] = { expirationTime = 0, fromCDM = true }
        -- the icon is proof of a new application: a hidden read of the same moment must not suppress it
        ns._Aura.unreadableBaselines[spellID] = nil
        if ns.AuraSoundFallback then ns.AuraSoundFallback.LogAura(spellID, "cdm-icon-active", "CDM_SIGNAL") end
        if auraBaselineComplete then sayAura(spellID, "apply", "CDM_SIGNAL") end
        return
    end
    if not state then
        auraTracker.updateState(spellID, "inactive", nil, nil, "CDM_SIGNAL", false)
        auraTracker.queueUpdate()
        return
    end
    -- An end counts as an expiry like in processAura: inside the readable expiry window, or for an aura whose
    -- application this signal announced (no expiry time known).
    local now = GetTime()
    local expired = (state.expirationTime > 0 and now >= state.expirationTime - 0.5 and now <= state.expirationTime + 3)
        or (state.fromCDM and state.expirationTime <= 0)
    ns._Aura.cancelExpiry(state)
    ns._Aura.clearEventState(spellID)
    activeAuras[spellID] = nil
    if state.auraInstanceID then auraByInstanceID[state.auraInstanceID] = nil end
    if ns.AuraSoundFallback then ns.AuraSoundFallback.LogAura(spellID, "cdm-icon-inactive", "CDM_SIGNAL") end
    if expired then sayAura(spellID, "expire", "CDM_SIGNAL") end
    auraTracker.updateState(spellID, "inactive", nil, nil, "CDM_SIGNAL", false)
    auraTracker.queueUpdate()
end

local function syncAllAuras(isBaseline)
    local profiling = ns.Prof.on
    local started = profiling and ns.Prof.clock()
    rebuildAuraWatches()
    for spellID in pairs(auraWatchBySpellID) do processAura(spellID, isBaseline, isBaseline and "BASELINE_SYNC" or "FULL_SYNC") end
    if isBaseline then auraBaselineComplete = true end
    if profiling then ns.Prof.add("syncAllAuras", ns.Prof.clock() - started) end
end
ns._Aura.syncAllAuras = syncAllAuras

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
        ns.tryDebugReport("NoteAura", nil, "payload hidden")
        queueAuraSync()
        return
    end

    local isFullUpdate, fullOK = safeAuraField(updateInfo, "isFullUpdate")
    if not fullOK or isFullUpdate then
        ns.tryDebugReport("NoteAura", nil, fullOK and "full update" or "full update (unreadable)")
        queueAuraSync()
        return
    end
    local added, addedOK = safeAuraField(updateInfo, "addedAuras")
    local updated, updatedOK = safeAuraField(updateInfo, "updatedAuraInstanceIDs")
    local removed, removedOK = safeAuraField(updateInfo, "removedAuraInstanceIDs")
    if not (addedOK and updatedOK and removedOK) then
        ns.tryDebugReport("NoteAura", nil, "lists hidden")
        queueAuraSync()
        return
    end

    local affected = {}
    for _, aura in ipairs(type(added) == "table" and added or ns._Aura.EMPTY) do
        local spellID, ok = safeAuraField(aura, "spellId")
        ns.tryDebugReport("NoteAura", ok and isPublicNumber(spellID) and spellID or nil, "added, id hidden")
        if ok and isPublicNumber(spellID) then ns.ObserveSpell(spellID, "Your aura") end
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

-- Direct read of one slot: one GetInventoryItemID call.
function ns.readEquippedItemID(slotID)
    if not GetInventoryItemID then return nil end
    local ok, itemID = pcall(GetInventoryItemID, "player", slotID)
    if ok and isPublicNumber(itemID) then return itemID end
    return nil
end

-- Scan-scoped equipment snapshot, slots 1..19, read once per ns.scanItemRules (19 reads however many members).
-- equipBySlot[slot] = itemID (nil = empty); equipSlotByItem[itemID] = lowest slot holding it, as the linear
-- search returned before. Both tables are reused (wiped, never reallocated). Only valid while
-- equipSnapshotActive is true: set by ns.readEquipSnapshot, cleared by ns.scanItemRules.
ns.equipBySlot = {}
ns.equipSlotByItem = {}
ns.equipSnapshotActive = false

function ns.readEquipSnapshot()
    local bySlot, slotByItem = ns.equipBySlot, ns.equipSlotByItem
    ns.equipSnapshotActive = false
    for key in pairs(bySlot) do bySlot[key] = nil end
    for key in pairs(slotByItem) do slotByItem[key] = nil end
    for slotID = 1, 19 do
        local itemID = ns.readEquippedItemID(slotID)
        bySlot[slotID] = itemID
        if itemID ~= nil and slotByItem[itemID] == nil then slotByItem[itemID] = slotID end
    end
    ns.equipSnapshotActive = true
end

-- Inside a scan: from the snapshot. Outside (timers, picker, UI): direct read, as before.
function ns.getEquippedItemID(slotID)
    if ns.equipSnapshotActive and type(slotID) == "number" and slotID >= 1 and slotID <= 19 and slotID % 1 == 0 then
        return ns.equipBySlot[slotID]
    end
    return ns.readEquippedItemID(slotID)
end

function ns.findEquippedItemSlot(itemID)
    if ns.equipSnapshotActive and itemID ~= nil then return ns.equipSlotByItem[itemID] end
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

-- {slot} is resolved at announcement time (ns.itemContext), so the text follows the slot in any language.
function ns.slotDefaultMessage(slotID)
    return "{slot} " .. L("ready")
end

-- itemSwapAt[member] = time a slot member last saw a different item: the cooldown running then is the
-- equip lockout of the new item, not a use, so it never ends in a Ready.
ns.itemSwapAt = setmetatable({}, { __mode = "k" })

function ns.readableCooldownNumber(value)
    return (not issecretvalue or not issecretvalue(value))
        and type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

-- One reused result table: the only caller (checkItemMember) reads it inside the same check and copies
-- the values it keeps (cycle start/end, source string), so no reading table outlives a check.
ns.itemReading = {}

function ns.readItemCooldownSource(source, callback, arg1, arg2)
    local ok, startTime, duration, enabled = pcall(callback, arg1, arg2)
    if not ok then return nil, "call-error" end
    if (issecretvalue and (issecretvalue(startTime) or issecretvalue(duration) or issecretvalue(enabled)))
        or not ns.readableCooldownNumber(startTime) or not ns.readableCooldownNumber(duration)
        or (type(enabled) ~= "boolean" and not ns.readableCooldownNumber(enabled)) then
        return nil, "unreadable"
    end
    local reading = ns.itemReading
    reading.source = source
    reading.startTime = startTime
    reading.duration = duration
    reading.enabled = enabled
    return reading, nil
end

function ns.readEquippedItemCooldown(slotID, itemID)
    local reason
    if GetInventoryItemCooldown then
        local reading, readReason = ns.readItemCooldownSource("inventory", GetInventoryItemCooldown, "player", slotID)
        if reading then return reading end
        reason = readReason
    else
        reason = "api-unavailable"
    end

    if C_Item and C_Item.GetItemCooldown then
        local reading, readReason = ns.readItemCooldownSource("item", C_Item.GetItemCooldown, itemID)
        if reading then return reading end
        reason = readReason or reason
    end
    return nil, reason or "api-unavailable"
end

function ns.logItemDecision(rule, event, reason, slotID, source, member)
    if not (ns.AuraSoundFallback and ns.AuraSoundFallback.debugEnabled == true) then return end
    local key = table.concat({ tostring(rule and rule.id or "?"), member and ns.memberKey(member) or "?",
        tostring(event), tostring(reason), tostring(slotID or "?"), tostring(source or "?") }, ":")
    local now = GetTime()
    if itemDebugDedupe[key] and now - itemDebugDedupe[key] < 1 then return end
    itemDebugDedupe[key] = now
    ns.AuraSoundFallback.Log("ITEM", string.format("rule=%s item=%s slot=%s event=%s source=%s reason=%s",
        tostring(rule and rule.id or "?"), tostring(member and member.itemID or "?"), tostring(slotID or "?"),
        tostring(event), tostring(source or "?"), tostring(reason)))
end

function ns.itemCooldownStateMatches(state, itemID, slotID, reading, cooldownEnd)
    return state and state.itemID == itemID and state.slotID == slotID
        and ns.readableCooldownNumber(state.cycleStart)
        and math.abs(state.cycleStart - reading.startTime) <= 0.25
        and ns.readableCooldownNumber(state.cooldownEnd)
        and math.abs(state.cooldownEnd - cooldownEnd) <= 0.25
end

-- itemCooldownStates[rule][memberKey] = the cooldown cycle of one member; members never share a cycle.
function ns.itemState(rule, key)
    local states = itemCooldownStates[rule]
    return states and states[key] or nil
end

-- state == nil drops that member's cycle (and the rule's table once it is empty).
function ns.setItemState(rule, key, state)
    local states = itemCooldownStates[rule]
    if not states then
        if state == nil then return end
        states = {}
        itemCooldownStates[rule] = states
    end
    states[key] = state
    if next(states) == nil then itemCooldownStates[rule] = nil end
end

function ns.scheduleItemReady(rule, member, state)
    if state.timerEnd == state.cooldownEnd then return end
    state.timerEnd = state.cooldownEnd
    local expectedEnd = state.cooldownEnd
    local key = ns.memberKey(member)
    C_Timer.After(math.max(0.1, expectedEnd - GetTime() + 0.1), function()
        if ns.itemState(rule, key) == state and state.cooldownEnd == expectedEnd then
            state.timerEnd = nil
            ns.checkItemRule(rule)
        end
    end)
end

function ns.checkItemMember(rule, member)
    local key = ns.memberKey(member)
    local slotID, itemID = member.slotID, member.itemID
    if slotID then
        -- Slot member: whatever is equipped there now is the item to watch.
        itemID = ns.getEquippedItemID(slotID)
        if not itemID then
            if ns.itemState(rule, key) then ns.logItemDecision(rule, "check", "slot-empty", slotID, nil, member) end
            ns.setItemState(rule, key, nil)
            return
        end
        if itemID ~= member.itemID then
            ns.followSlotItem(rule, member, itemID)
            ns.logItemDecision(rule, "check", "slot-item-changed", slotID, nil, member)
        end
    else
        if not itemID then return end
        slotID = ns.findEquippedItemSlot(itemID)
        if not slotID then
            if ns.itemState(rule, key) then ns.logItemDecision(rule, "check", "not-equipped", nil, nil, member) end
            ns.setItemState(rule, key, nil)
            return
        end
    end

    local reading, readReason = ns.readEquippedItemCooldown(slotID, itemID)
    local state = ns.itemState(rule, key)
    if not reading then
        -- Guarded: the concatenation would allocate on every scan while the cooldown is unreadable.
        if ns.AuraSoundFallback and ns.AuraSoundFallback.debugEnabled == true then
            ns.logItemDecision(rule, "check", "unreadable-" .. tostring(readReason), slotID, nil, member)
        end
        return
    end

    local now = GetTime()
    if reading.enabled ~= true and reading.enabled ~= 1 then
        ns.logItemDecision(rule, "check", "cooldown-disabled", slotID, reading.source, member)
        return
    end
    local cooldownEnd = reading.startTime + reading.duration
    local active = reading.duration > 0 and reading.startTime > 0 and cooldownEnd > now
    if active then
        if not ns.itemCooldownStateMatches(state, itemID, slotID, reading, cooldownEnd) then
            local swapAt = member.slotID and ns.itemSwapAt[member]
            state = {
                itemID = itemID,
                slotID = slotID,
                cycleStart = reading.startTime,
                cooldownEnd = cooldownEnd,
                source = reading.source,
                -- Equip lockout of a just-swapped item: watched, but never announced.
                notified = swapAt ~= nil and reading.startTime <= swapAt + 2,
            }
            ns.setItemState(rule, key, state)
            ns.logItemDecision(rule, "active", "cycle-start", slotID, reading.source, member)
        else
            state.source = reading.source
        end
        ns.scheduleItemReady(rule, member, state)
        return
    end

    if not state then
        ns.logItemDecision(rule, "ready", "baseline", slotID, reading.source, member)
        return
    end
    if state.itemID ~= itemID or state.slotID ~= slotID then
        ns.setItemState(rule, key, nil)
        ns.logItemDecision(rule, "ready", "identity-changed", slotID, reading.source, member)
        return
    end
    if state.notified then
        ns.logItemDecision(rule, "ready", "duplicate", slotID, reading.source, member)
        ns.setItemState(rule, key, nil)
        return
    end
    state.notified = true
    ns.logItemDecision(rule, "ready", "confirmed", slotID, reading.source, member)
    notifyRule(rule, "ready", rule.message, nil, "ITEM_COOLDOWN_DONE", "offCooldown", ns.itemContext(itemID, slotID))
    ns.setItemState(rule, key, nil)
end

ns.checkItemRule = function(rule)
    -- ns.itemScanSpecID is set only during ns.scanItemRules; nil (timer path, or spec unknown) makes the rule read it.
    if not rule.enabled or not ns.Profiles.RuleMatchesCurrentSpecialization(rule, ns.itemScanSpecID) then
        if itemCooldownStates[rule] then ns.logItemDecision(rule, "check", "inactive") end
        itemCooldownStates[rule] = nil
        return
    end
    for _, member in ipairs(ns.itemMembers(rule)) do ns.checkItemMember(rule, member) end
end

function ns.scanItemRuleList()
    -- Empty item list: nothing to name or check.
    if #WoWraVoxDB.items > 0 then
        -- Once per loaded profile, when item names can be resolved: slot rules are named after their slot.
        if ns.slotNamesChecked ~= WoWraVoxDB then
            ns.slotNamesChecked = WoWraVoxDB
            for _, rule in ipairs(WoWraVoxDB.items) do ns.nameSlotRule(rule) end
            if optionsFrame and optionsFrame:IsShown() then refreshList() end
        end
        -- One spec read per scan instead of one per spec-bound rule. Nil (spec unknown) keeps the per-rule read.
        ns.itemScanSpecID = ns.Profiles and ns.Profiles.GetCurrentSpecialization and ns.Profiles.GetCurrentSpecialization()
        ns.readEquipSnapshot()
        for _, rule in ipairs(WoWraVoxDB.items) do ns.checkItemRule(rule) end
    end
end

function ns.scanItemRules()
    itemScanPending = false
    ns.itemScanLast = GetTime()
    local profiling = ns.Prof.on
    local started = profiling and ns.Prof.clock()
    -- pcall: the snapshot flag and the spec snapshot are cleared even when a rule throws; the error is then re-raised unchanged.
    local ok, err = pcall(ns.scanItemRuleList)
    ns.equipSnapshotActive = false
    ns.itemScanSpecID = nil
    if profiling then ns.Prof.add("scanItemRules", ns.Prof.clock() - started) end
    if not ok then error(err, 0) end
end

-- Event-driven scans run at most once per 0.3 s. A request inside that window waits for the window to
-- end (trailing), so the last request always gets a scan after it. Timers (scheduleItemReady) call
-- ns.checkItemRule directly and never pass through here.
ns.ITEM_SCAN_MIN_INTERVAL = 0.3
function ns.queueItemScan(delay)
    if itemScanPending then return end
    itemScanPending = true
    local wait = delay or 0.1
    if ns.itemScanLast then
        wait = math.max(wait, ns.itemScanLast + ns.ITEM_SCAN_MIN_INTERVAL - GetTime())
    end
    C_Timer.After(wait, ns.scanItemRules)
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
    ns._Aura.clearActiveState()
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
        local ok, itemName, _, _, _, _, _, _, _, _, itemIcon = pcall(GetItemInfo, itemID)
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

-- A rule whose first member tracks a slot is named after the slot ("Trinket 1"), not after the item that
-- happens to sit there.  Rules saved with the item's name (also the placeholder "Item <id>") are renamed;
-- a name the user typed is kept.  Idempotent.
function ns.nameSlotRule(rule)
    local first = ns.itemMembers(rule)[1]
    if not (first and first.slotID) then return end
    local slotName = ns.slotName(first.slotID)
    -- Older profiles carry the generated "<slot name> ready" text; switch it to the {slot} wildcard.
    -- Any other text is the user's and stays.
    if rule.message == slotName .. " " .. L("ready") then rule.message = ns.slotDefaultMessage(first.slotID) end
    if rule.name == slotName then return end
    local candidates = {}
    for _, itemID in ipairs({ first.itemID or 0, ns.getEquippedItemID(first.slotID) or 0 }) do
        if itemID > 0 then
            candidates[(getItemInfo(itemID, first.slotID))] = true
            candidates["Item " .. itemID] = true
        end
    end
    if rule.name == nil or candidates[rule.name] then rule.name = slotName end
end

-- A slot member saw another item in its slot: follow it (rule icon always, rule name while it was the old
-- item's name - both only for the first member, which stands for the rule), drop the cooldown cycle so the
-- next scan restarts silently, and remember the swap time. Custom messages are kept; the generated
-- "<slot> ready" default is slot-based and needs no change.
function ns.followSlotItem(rule, member, itemID)
    if ns.itemMembers(rule)[1] == member then
        local oldName = member.itemID and getItemInfo(member.itemID)
        local name, icon = getItemInfo(itemID, member.slotID)
        if rule.name == oldName or rule.name == nil then rule.name = name end
        rule.icon = icon or rule.icon
    end
    member.itemID = itemID
    ns.setItemState(rule, ns.memberKey(member), nil)
    ns.itemSwapAt[member] = GetTime()
end

-- Name and icon of the item a member carries right now (a slot member: whatever is equipped there).
-- Third result: the slot the item is worn in right now (nil = not equipped).
function ns.itemMemberInfo(member)
    local worn = member.slotID and ns.getEquippedItemID(member.slotID) or nil
    local itemID = worn or member.itemID
    if not itemID then return nil end
    local slotID = worn and member.slotID or ns.findEquippedItemSlot(itemID)
    local name, icon = getItemInfo(itemID, slotID)
    if not slotID and C_Item and C_Item.GetItemIconByID then
        local ok, texture = pcall(C_Item.GetItemIconByID, itemID)
        icon = ok and texture or nil
    end
    return name, icon, slotID
end

-- Wildcard values for a Ready of one item: its name and the slot it sits in (nil = unknown, wildcard stays).
function ns.itemContext(itemID, slotID)
    return {
        item = itemID and (getItemInfo(itemID, slotID)) or nil,
        slot = slotID and ns.slotName(slotID) or nil,
    }
end

-- Context of a member as it is equipped now; the first member when none is given (preview and Test button).
function ns.itemRuleContext(rule, member)
    member = member or ns.itemMembers(rule)[1]
    if not member then return nil end
    local itemID, slotID = member.itemID, member.slotID
    if slotID then
        itemID = ns.getEquippedItemID(slotID) or itemID
    elseif itemID then
        slotID = ns.findEquippedItemSlot(itemID)
    end
    return ns.itemContext(itemID, slotID)
end

-- Wildcard context for editor previews and tests: items resolve against their first member, aura rules against
-- their first trigger ({spell}), other rules have none.
function ns.previewContext(rule)
    if type(rule.members) == "table" then return ns.itemRuleContext(rule) end
    return type(rule.spellIDs) == "table" and ns._Aura.spellContext(rule.spellIDs[1]) or nil
end

-- A duplicate is the same slot (slot member) or the same fixed item (item member); a slot member's last
-- seen item does not count. skipIndex leaves the member being replaced out of the comparison.
function ns.itemRuleIsDuplicate(rule, itemID, slotID, trackSlot, skipIndex)
    local key = trackSlot and ("s" .. tostring(slotID)) or ("i" .. tostring(itemID))
    for index, member in ipairs(ns.itemMembers(rule)) do
        if index ~= skipIndex and ns.memberKey(member) == key then return true end
    end
    return false
end

-- True while the message is still one the addon generated itself ("<name> ready" or "<slot> ready").
function ns.itemMessageIsGenerated(rule)
    local first = ns.itemMembers(rule)[1]
    return rule.message == (rule.name or L("Item")) .. " " .. L("ready")
        or (first ~= nil and first.slotID ~= nil and rule.message == ns.slotDefaultMessage(first.slotID))
end

-- Points member `index` (default: the first; one past the end appends) at another equipped item.  Rule name
-- and icon follow the first member.  The message follows the item only for a one-member rule while it is
-- still the generated "<name> ready" default (or the rule is an unfilled starter); the member's cooldown cycle
-- is dropped so the next scan restarts silently for the new item.
-- slotID (optional) makes it a slot member (it then tracks whatever sits in that slot); nil = this exact item.
function ns.retargetItemRule(rule, index, itemID, name, icon, slotID)
    if type(rule.members) ~= "table" then rule.members = {} end
    local members = rule.members
    index = math.max(1, math.min(index or 1, #members + 1))
    local followsItem = #members <= 1 and (rule.starter ~= nil or ns.itemMessageIsGenerated(rule))
    if members[index] then ns.setItemState(rule, ns.memberKey(members[index]), nil) end
    members[index] = { itemID = itemID, slotID = slotID }
    if index == 1 then
        rule.name = slotID and ns.slotName(slotID) or name
        rule.icon = icon
    end
    rule.starter = nil
    if followsItem then
        rule.message = slotID and ns.slotDefaultMessage(slotID) or ((name or L("Item")) .. " " .. L("ready"))
    end
end

-- Adds a member ({ itemID } or { slotID, itemID }). Returns true, or false, "duplicate".  The generated default
-- message becomes "{item} ready" when the second member arrives, so every member announces its own name.
function ns.addItemMember(rule, member)
    if ns.itemRuleIsDuplicate(rule, member.itemID, member.slotID, member.slotID ~= nil) then return false, "duplicate" end
    if type(rule.members) ~= "table" then rule.members = {} end
    if #rule.members == 1 and ns.itemMessageIsGenerated(rule) then
        rule.message = "{item} " .. L("ready")
    end
    table.insert(rule.members, member)
    return true
end

-- Removes member `index`; the last one cannot go.  Returns true, or false, "last" | "missing".
function ns.removeItemMember(rule, index)
    local members = ns.itemMembers(rule)
    local member = members[index]
    if not member then return false, "missing" end
    if #members <= 1 then return false, "last" end
    ns.setItemState(rule, ns.memberKey(member), nil)
    table.remove(members, index)
    if index == 1 then
        -- The rule shows its first member: name (while it still was the old item's name) and icon move on.
        local oldName = ns.itemMemberInfo(member)
        local newName, newIcon = ns.itemMemberInfo(members[1])
        if newName and (rule.name == oldName or rule.name == nil) then rule.name = newName end
        rule.icon = newIcon or rule.icon
    end
    return true
end

-- Switches member `index` between "this item" (wantSlot false) and "whatever sits in its slot" (true).
-- Returns true, or false, "not-equipped" | "duplicate" | "missing".
function ns.setItemMemberMode(rule, index, wantSlot)
    local member = ns.itemMembers(rule)[index]
    if not member then return false, "missing" end
    if (member.slotID ~= nil) == wantSlot then return true end
    local itemID, slotID = member.itemID, nil
    if wantSlot then
        slotID = itemID and ns.findEquippedItemSlot(itemID)
        if not slotID then return false, "not-equipped" end
    else
        itemID = ns.getEquippedItemID(member.slotID) or itemID
        if not itemID then return false, "not-equipped" end
    end
    if ns.itemRuleIsDuplicate(rule, itemID, slotID, wantSlot, index) then return false, "duplicate" end
    local generated = #rule.members == 1 and ns.itemMessageIsGenerated(rule)
    ns.setItemState(rule, ns.memberKey(member), nil)
    rule.members[index] = { itemID = itemID, slotID = slotID }
    if generated then
        rule.message = slotID and ns.slotDefaultMessage(slotID) or ((rule.name or L("Item")) .. " " .. L("ready"))
    end
    return true
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
        and ns.isEmptyStarter(selectedItemRule)
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
    local label = parent:CreateFontString(nil, "OVERLAY", template or "WoWraVoxFontHighlight")
    label:SetText(L(text or ""))
    return label
end

-- GameTooltip reuses its line FontStrings, so a font set on one line sticks to later tooltips: every overridden
-- line is remembered here and handed back to the default tooltip font.
function ns.resetTooltipFonts()
    local lines = ns.tooltipFontLines
    if not lines then return end
    ns.tooltipFontLines = nil
    for _, fontString in ipairs(lines) do
        pcall(fontString.SetFontObject, fontString, GameTooltipText)
    end
end

-- Title, optional wrapped explanation, then optional extra lines { text, r, g, b, font = { path, size, flags } }
-- (text goes through L()). A font override is for lines with characters the default tooltip font draws badly.
function ns.fillHelpTooltip(tooltip, title, explanation, lines)
    ns.resetTooltipFonts()
    tooltip:SetText(L(title), 1, 0.82, 0.2)
    if explanation then tooltip:AddLine(L(explanation), 0.85, 0.88, 0.94, true) end
    for _, entry in ipairs(lines or {}) do
        tooltip:AddLine(L(entry.text), entry.r or 0.85, entry.g or 0.88, entry.b or 0.94, true)
        if entry.font then
            local fontString = _G["GameTooltipTextLeft" .. tooltip:NumLines()]
            if fontString and pcall(fontString.SetFont, fontString, entry.font[1], entry.font[2], entry.font[3] or "") then
                ns.tooltipFontLines = ns.tooltipFontLines or {}
                ns.tooltipFontLines[#ns.tooltipFontLines + 1] = fontString
            end
        end
    end
end

local function addHelpTooltip(widget, title, explanation, lines)
    if not ns.tooltipHideHooked then
        ns.tooltipHideHooked = true
        GameTooltip:HookScript("OnHide", ns.resetTooltipFonts)
    end
    widget:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        ns.fillHelpTooltip(GameTooltip, title, explanation, lines)
        GameTooltip:Show()
    end)
    widget:HookScript("OnLeave", function()
        GameTooltip:Hide()
        ns.resetTooltipFonts()
    end)
end

-- Skin helpers (no-ops unless a texture skin is active). A 1 px rule texture is replaced by an 8 px divider
-- strip centred on it; an icon texture gets a frame holder around it (the frame art has a clear centre).
function ns.skinDivider(line)
    if not ns.Skin.Data() then return end
    local holder = CreateFrame("Frame", nil, line:GetParent())
    holder:SetHeight(8)
    holder:SetPoint("LEFT", line, "LEFT", 0, 0)
    holder:SetPoint("RIGHT", line, "RIGHT", 0, 0)
    line:Hide()
    ns.Skin.Register(holder, "divider")
end

function ns.skinIconFrame(icon)
    if not ns.Skin.Data() then return end
    local holder = CreateFrame("Frame", nil, icon:GetParent())
    holder:SetPoint("TOPLEFT", icon, "TOPLEFT", -2, 2)
    holder:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 2, -2)
    ns.Skin.Register(holder, "iconFrame", { scale = 0.5 })
end

-- kind: skin kind of the panel ("panel" by default); false = the caller registers it later.
local function stylePanel(panel, r, g, b, kind)
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
    panel.lines = {}
    for _, edge in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local line = panel:CreateTexture(nil, "BORDER")
        panel.lines[#panel.lines + 1] = line
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
    if kind ~= false then ns.Skin.Register(panel, kind or "panel") end
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
    ns.Skin.Register(box, "editbox")
    return box
end
ns.createEditBox = createEditBox

local function createVoiceDropdown(parent, point, relativeTo, x, y, onChange)
    local dropdown = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
    dropdown:SetPoint(point, relativeTo, point, x, y)
    ns.Layout.setDropdownWidth(dropdown, 145)
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
    ns.Skin.Register(dropdown, "dropdown")
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
    ns.Skin.Register(slider, "sliderTrack")
    ns.Skin.Register(slider, "sliderThumb")
    return slider
end

local function ruleDisplay(rule, category)
    if category == "items" then return rule.name or (L("Item") .. " " .. tostring(ns.firstItemID(rule))) end
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
    if ns.AuraPresetUI and ns.AuraPresetUI.creationActive then
        ns.AuraPresetUI.finishCreation(true)
    end
    saveDetails()
    if ns.SkillTracking.learning and ns.SkillTracking.learning.rule ~= rule then
        ns.SkillTracking.CancelLearning(L("Rule selection changed."), true)
    end
    ns.Layout.clampEditorScroll(0)
    addRuleMode = false
    selectedCategory = category
    if category == "auras" then
        if selectedAuraRule ~= rule then selectedMarkerKey = "apply" end
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
    if not selected or selected.builtin then return end
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
        local tracker = auraTracker.config()
        local sealFamily = tracker.families and tracker.families.seals
        if sealFamily and tostring(sealFamily.ruleID) == tostring(selected.id) then tracker.families.seals = nil end
        ns._Aura.clearActiveState()
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
    StaticPopupDialogs["WOWRAVOX_CDM_TRACK_AURA"] = {
        text = "%s",
        button1 = L("Open Advanced Cooldown Settings"),
        button2 = L("Cancel"),
        OnAccept = function()
            local ok, reason = false, "unavailable"
            if ns.AuraCDM and ns.AuraCDM.OpenSettings then ok, reason = ns.AuraCDM.OpenSettings() end
            if not ok and DEFAULT_CHAT_FRAME then
                local message = reason == "combat" and L("Open Advanced Cooldown Settings after combat.")
                    or L("Open Advanced Cooldown Settings from Edit Mode.")
                DEFAULT_CHAT_FRAME:AddMessage("|cffd8b65aWoWraVox:|r " .. message)
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
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
                header.arrow = header:CreateFontString(nil, "OVERLAY", "WoWraVoxFontNormalSmall")
                header.arrow:SetSize(14, 18)
                header.arrow:SetPoint("RIGHT", header, "RIGHT", -2, 0)
                header.arrow:SetJustifyH("CENTER")
                header.arrow:SetTextColor(1, 0.82, 0.2)
                header.label = header:CreateFontString(nil, "OVERLAY", "WoWraVoxFontNormalSmall")
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
            row.title = row:CreateFontString(nil, "OVERLAY", "WoWraVoxFontHighlightSmall")
            row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 58, -10)
            row.title:SetPoint("RIGHT", row, "RIGHT", -42, 0)
            row.title:SetHeight(30)
            row.title:SetJustifyH("LEFT")
            row.title:SetMaxLines(2)
            row.sub = row:CreateFontString(nil, "OVERLAY", "WoWraVoxFontNormalSmall")
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
            -- Extra tooltip lines for this row; the list loop sets row.tipLines[1] per row (hint or nil).
            row.tipLines = {}
            addHelpTooltip(row, "Edit rule", "Select this rule and show its settings.", row.tipLines)
            addHelpTooltip(row.toggle, "Enable or disable rule", "Toggle this rule without deleting it.")
            addHelpTooltip(row.remove, "Remove rule", "Delete this rule. Built-in rules can be switched off but not deleted.")
            -- Scripts read self.rule/self.category, so they are set once per row frame.
            row:SetScript("OnClick", function(self)
                -- Ctrl-click posts the aura group (or the item rule with its members) as a link into the chat box
                -- instead of selecting it. An item rule without a member (empty starter) is just selected.
                if IsControlKeyDown() and (self.category == "auras"
                    or (self.category == "items" and #ns.itemMembers(self.rule) > 0)) then
                    if self.rule.builtin then
                        setStatus(L("Built-in rules cannot be shared."), true)
                        return
                    end
                    ns.ShareUI.postToChat(self.rule)
                    return
                end
                selectRule(self.rule, self.category)
                if self.category == "items" and ns.isEmptyStarter(self.rule) and ns.BeginItemPicker then
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
                if parent.rule.builtin then return end
                selectRule(parent.rule, parent.category)
                StaticPopup_Show("WOWRAVOX_DELETE_RULE", string.format(L("Delete rule \"%s\"?"), ruleDisplay(parent.rule, parent.category)),
                    nil, { rule = parent.rule, category = parent.category })
            end)
            ns.Skin.Register(row, "listRow")
            ns.Skin.Register(row.toggle, "checkbox")
            ns.Skin.Register(row.remove, "dangerButton")
            ns.skinIconFrame(row.icon)
            listRows[index] = row
        end

        row.rule, row.category = rule, category
        row.tipLines[1] = ((category == "auras" or (category == "items" and #ns.itemMembers(rule) > 0)) and not rule.builtin)
            and { text = "Ctrl-click to post in chat." } or nil
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
        ns.Skin.SetState(row, "selected", selected)
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
        row.remove:SetEnabled(not rule.builtin)
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
            if ns.isEmptyStarter(rule) then
                row.sub:SetText(L("Choose an equipped item") .. (inactiveReason and (" · " .. L(inactiveReason)) or ""))
            else
                local members = ns.itemMembers(rule)
                -- A slot rule is named after its slot, so the line below shows the item sitting there now.
                local slotItemName = #members == 1 and members[1].slotID and rule.name == ns.slotName(members[1].slotID)
                    and (ns.itemMemberInfo(members[1]))
                local sourceText = #members > 1 and string.format(L("%d items"), #members)
                    or slotItemName
                    or (members[1] and members[1].slotID and ns.slotName(members[1].slotID))
                    or ("Item " .. tostring(ns.firstItemID(rule) or 0))
                row.sub:SetText(sourceText .. " · " .. L("Ready") .. (inactiveReason and (" · " .. L(inactiveReason)) or ""))
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
    ns.Skin.SetState(panel.headerIndicator, expanded and "expanded" or "collapsed")
    -- Expanded: the panel art alone frames the panel (the header art has its own bottom border); collapsed: header art.
    ns.Skin.SetArtShown(panel.headerButton, not expanded)
end

-- The rule being edited (any category), or nil.
ns.Layout.currentRule = function()
    return selectedCategory == "auras" and selectedAuraRule or selectedCategory == "items" and selectedItemRule
        or selectedCategory == "skills" and selectedSkillRule or nil
end

-- Collapsible panels (panel.collapsible): Application, Expiration and TTS. The state is kept per rule and panel
-- in ns.Layout.panelState; Expiration starts collapsed while no channel is on, the others start expanded.
ns.Layout.ensurePanelState = function(panel, rule)
    if not panel.collapsible then
        panel.expanded = true
        return true
    end
    local states = rule and ns.Layout.panelState[rule]
    if rule and not states then
        states = {}
        ns.Layout.panelState[rule] = states
    end
    if rule and states[panel.key] == nil then
        states[panel.key] = panel.key ~= "expire" or ns.Layout.notificationPanelHasEnabledChannel(panel)
    end
    panel.expanded = not rule or states[panel.key] ~= false
    ns.Layout.refreshPanelHeader(panel)
    return panel.expanded
end

ns.Layout.setPanelExpanded = function(panel, expanded)
    if not panel or not panel.collapsible then return end
    panel.expanded = expanded ~= false
    local rule = ns.Layout.currentRule()
    if rule then
        ns.Layout.panelState[rule] = ns.Layout.panelState[rule] or {}
        ns.Layout.panelState[rule][panel.key] = panel.expanded
    end
    ns.Layout.refreshPanelHeader(panel)
end

ns.Layout.isPanelExpanded = function(panel)
    return not panel.collapsible or panel.expanded ~= false
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
    local combatOffset = 0 -- the combat hint lives in the category tooltip now (no extra text row)
    local screenY = -112 - combatOffset
    if panel.warningPercent then screenY = screenY - 36 end
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 0, y)
    frame:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", 0, y)
    local lowestControl = math.max(43 + 30, 78 + combatOffset + 30, -screenY + 30)
    if screenEnabled then lowestControl = math.max(lowestControl, -screenY + 36 + 30) end
    local expanded = ns.Layout.isPanelExpanded(panel)
    frame:SetHeight(expanded and lowestControl + 10 or 34)
    panel.heading:ClearAllPoints()
    panel.heading:SetPoint("TOPLEFT", frame, "TOPLEFT", ns.Layout.PAD + (panel.collapsible and 22 or 0), -10) -- 22 = room for the chevron
    if panel.categoryChoice then
        panel.categoryChoice:ClearAllPoints()
        panel.categoryChoice:SetPoint("TOPRIGHT", frame, "TOPRIGHT", ns.Layout.RIGHT, -4)
        ns.Layout.setDropdownWidth(panel.categoryChoice, 142)
        panel.categoryLabel:ClearAllPoints()
        panel.categoryLabel:SetPoint("RIGHT", panel.categoryChoice, "LEFT", -8, 0)
        -- expanded, the fallback dropdown holds the right end of the header row: the hint moves left of it
        panel.headerHint:ClearAllPoints()
        if expanded then
            panel.headerHint:SetPoint("RIGHT", panel.categoryLabel, "LEFT", -12, 0)
        else
            panel.headerHint:SetPoint("RIGHT", panel.headerButton, "RIGHT", ns.Layout.RIGHT, 0)
        end
    end
    if panel.warningPercent then
        panel.warningLabel:ClearAllPoints()
        panel.warningLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", ns.Layout.ROW_X, -110)
        panel.warningPercent:ClearAllPoints()
        panel.warningPercent:SetPoint("TOPLEFT", frame, "TOPLEFT", ns.Layout.FIELD_X, -108)
        panel.warningPercent:SetSize(180, 18)
        panel.warningValue:ClearAllPoints()
        panel.warningValue:SetPoint("LEFT", panel.warningPercent, "RIGHT", 8, 0)
    end
    panel.ttsEnabled:ClearAllPoints()
    panel.ttsEnabled:SetPoint("TOPLEFT", frame, "TOPLEFT", ns.Layout.ROW_X, -43)
    panel.ttsLabel:ClearAllPoints()
    panel.ttsLabel:SetPoint("LEFT", panel.ttsEnabled, "RIGHT", 6, 0)
    panel.ttsTest:ClearAllPoints()
    panel.ttsTest:SetPoint("TOPRIGHT", frame, "TOPRIGHT", ns.Layout.RIGHT, -42)
    panel.ttsTest:SetSize(ns.Layout.BUTTON_W, 30)
    panel.soundEnabled:ClearAllPoints()
    panel.soundEnabled:SetPoint("TOPLEFT", frame, "TOPLEFT", ns.Layout.ROW_X, -78 - combatOffset)
    panel.soundLabel:ClearAllPoints()
    panel.soundLabel:SetPoint("LEFT", panel.soundEnabled, "RIGHT", 6, 0)
    panel.soundTest:ClearAllPoints()
    panel.soundTest:SetPoint("TOPRIGHT", frame, "TOPRIGHT", ns.Layout.RIGHT, -77 - combatOffset)
    panel.soundTest:SetSize(ns.Layout.BUTTON_W, 30)
    layoutScreenRow(panel.screen, frame, screenY)
    panel.ttsMessage:ClearAllPoints()
    panel.ttsMessage:SetHeight(30)
    panel.ttsMessage:SetPoint("TOPLEFT", frame, "TOPLEFT", ns.Layout.FIELD_X, -42)
    panel.ttsMessage:SetPoint("RIGHT", panel.ttsTest, "LEFT", -8, 0)
    if panel.combatHint then
        panel.combatHint:ClearAllPoints()
        panel.combatHint:SetPoint("TOPLEFT", frame, "TOPLEFT", ns.Layout.FIELD_X, -75)
        panel.combatHint:SetPoint("RIGHT", frame, "RIGHT", ns.Layout.RIGHT, 0)
        panel.combatHint:SetHeight(28)
    end
    -- Sound row shares the dropdown columns of the screen row below (col1 = Font, col2 = Size); the last
    -- box (channel) ends at the right edge of the text boxes.
    ns.Layout.placeDropdown(panel.soundChoice, frame, cols.col1, -77 - combatOffset, cols.col1Width)
    ns.Layout.placeDropdown(panel.soundChannel, frame, cols.col2, -77 - combatOffset, cols.col2Width)
end

function ns.setNotificationPanelShown(panel, shown)
    if not panel then return end
    local expanded = ns.Layout.isPanelExpanded(panel)
    panel.frame:SetShown(shown)
    if panel.categoryChoice then
        panel.categoryChoice:SetShown(shown and expanded)
        panel.categoryLabel:SetShown(shown and expanded)
    end
    if panel.headerButton then panel.headerButton:SetShown(shown and panel.collapsible) end
    local ttsChecked = panel.ttsEnabled:GetChecked()
    local ttsDetails = shown and expanded and (ttsChecked == true or ttsChecked == 1)
    panel.ttsEnabled:SetShown(shown and expanded)
    panel.ttsLabel:SetShown(shown and expanded)
    if panel.combatHint then panel.combatHint:SetShown(false) end
    panel.ttsMessage:SetShown(ttsDetails)
    if panel.warningPercent then
        panel.warningLabel:SetShown(shown and expanded)
        panel.warningPercent:SetShown(shown and expanded)
        panel.warningValue:SetShown(shown and expanded)
    end
    local choosingStarterItem = panel.eventKey == "ready" and selectedCategory == "items"
        and selectedItemRule and ns.isEmptyStarter(selectedItemRule)
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

ns.AuraPresetUI = ns.AuraPresetUI or {
    selected = {}, rule = nil, specID = nil, hover = nil, focus = nil, current = nil,
    cards = {}, tiles = {}, headings = {},
    creationActive = false, creationDraft = nil, previousSelection = nil,
}
-- Icon tile (frame incl. 2 px border around the 44 px icon) and the gap between tiles.
ns.AuraPresetUI.TILE_SIZE, ns.AuraPresetUI.TILE_GAP = 48, 6
-- Muted accent per category; the same dark palette as the rest of the window.
ns.AuraPresetUI.ACCENTS = {
    offensive = { 0.74, 0.34, 0.30 }, defensive = { 0.31, 0.47, 0.76 },
    healing = { 0.32, 0.64, 0.42 }, augmentation = { 0.58, 0.40, 0.76 },
}

ns.AuraPresetUI.categoryLabel = function(category)
    if category == "augmentation-offensive" then
        return L("Augmentation Support") .. " · " .. L("Offensive")
    elseif category == "augmentation-defensive" then
        return L("Augmentation Support") .. " · " .. L("Defensive")
    end
    return L(category:sub(1, 1):upper() .. category:sub(2))
end

ns.AuraPresetUI.displayName = function(entry)
    local spellID = tonumber(entry and (entry.auraID or entry.castID))
    if spellID and C_Spell and type(C_Spell.GetSpellName) == "function" then
        local ok, name = pcall(C_Spell.GetSpellName, spellID)
        if ok and (not issecretvalue or not issecretvalue(name)) and type(name) == "string" and name ~= "" then
            return name
        end
    end
    return entry and entry.name or "Preset"
end

-- The category word WoW plays for a catalog category (augmentation-defensive is defensive, the rest offensive).
ns.AuraPresetUI.cueFor = function(category)
    return category == "healing" and "healing"
        or (category == "defensive" or category == "augmentation-defensive") and "defensive"
        or "offensive"
end

-- The predefined cue of one preset effect: externals get a combined cue (offensive/defensive + "Somebody loves
-- you"), other externals "somebody-loves-you"; class effects by catalog category.
ns.AuraPresetUI.cueForEntry = function(entry, package)
    local category = entry and entry.category or package and package.category
    if (package and package.external) or (entry and entry.scope == "external") then
        if category == "offensive" or category == "augmentation-offensive" then return "offensive-external" end
        if category == "defensive" or category == "augmentation-defensive" then return "defensive-external" end
        return "somebody-loves-you"
    end
    return ns.AuraPresetUI.cueFor(category)
end

ns.AuraPresetUI.collectSelected = function(specID, selected)
    local catalog = ns.AuraPresets
    local packages, chosen, hasSelection = {}, {}, false
    if not (catalog and type(catalog.GetPackages) == "function") then return chosen, false end
    for _, package in ipairs(catalog.GetPackages(specID, true)) do
        local entries = {}
        for _, entry in ipairs(package.entries or {}) do
            local available = catalog.GetAvailability(entry)
            if selected and selected[entry.id] and available then
                entries[#entries + 1] = entry
                hasSelection = true
            end
        end
        if #entries > 0 then packages[#packages + 1] = { package = package, entries = entries } end
    end
    return packages, hasSelection
end

-- Pure data: the one group "Create aura" makes from the draft's manual triggers plus every ticked, available
-- effect. rows = manual triggers first, then preset effects (one row per aura ID). Every preset effect brings its
-- own category cue (categoryByAuraID: externals "somebody-loves-you", class effects by catalog category), so the
-- group itself carries none.
ns.AuraPresetUI.pendingGroup = function(specID)
    local ui = ns.AuraPresetUI
    local draft = ui.creationDraft
    local group = { rows = {}, spellIDs = {}, hasPresets = false }
    local seen = {}
    for _, spellID in ipairs(draft and draft.spellIDs or {}) do
        if not seen[spellID] then
            seen[spellID] = true
            local info, state = getSpellInfo(spellID)
            group.spellIDs[#group.spellIDs + 1] = spellID
            group.rows[#group.rows + 1] = {
                id = spellID, manual = true, hint = L("Manual"),
                name = info and info.name or (state == "pending" and L("Loading…") or L("Unknown ID")),
                icon = info and info.iconID or "Interface\\Icons\\INV_Misc_QuestionMark",
            }
        end
    end
    local packages = ui.collectSelected(specID, ui.selected)
    local cues, cueCount, categories, categoryCount, scopes, scopeCount = {}, 0, {}, 0, {}, 0
    local onlyCategory, onlyCue, onlyScope, anyExternal
    for _, selectedPackage in ipairs(packages) do
        local package = selectedPackage.package
        local nameCue, scope = ui.cueFor(package.category), package.external and "Externals" or "Class Specifics"
        if not cues[nameCue] then cues[nameCue], cueCount, onlyCue = true, cueCount + 1, nameCue end
        if not categories[package.category] then
            categories[package.category], categoryCount, onlyCategory = true, categoryCount + 1, package.category
        end
        if not scopes[scope] then scopes[scope], scopeCount, onlyScope = true, scopeCount + 1, scope end
        if package.external then anyExternal = true end
        for _, entry in ipairs(selectedPackage.entries) do
            group.hasPresets = true
            -- Cast and aura ID of one effect are one trigger: remember which cast stands for the aura.
            if type(entry.castID) == "number" and entry.castID ~= entry.auraID then
                group.castByAuraID = group.castByAuraID or {}
                group.castByAuraID[entry.auraID] = entry.castID
            end
            local cue = ui.cueForEntry(entry, package)
            group.categoryByAuraID = group.categoryByAuraID or {}
            group.categoryByAuraID[entry.auraID] = group.categoryByAuraID[entry.auraID] or cue
            if not seen[entry.auraID] then
                seen[entry.auraID] = true
                group.spellIDs[#group.spellIDs + 1] = entry.auraID
                group.rows[#group.rows + 1] = {
                    id = entry.auraID, entryID = entry.id, name = ui.displayName(entry), icon = ui.iconFor(entry),
                    hint = ns._Aura.cueLabel(cue), category = package.category, cue = cue,
                }
            end
        end
    end
    if #packages == 1 then group.presetID = "aura-preset:" .. packages[1].package.id end
    if #packages > 0 and not anyExternal and specID then group.specializationIDs = { specID } end

    local single = #group.rows == 1 and not group.rows[1].manual and group.rows[1] or nil
    local cueWord = cueCount == 1 and ns._Aura.cueLabel(onlyCue) or nil
    -- Preset groups say the name of whichever aura fired ({spell}); a manual-only group keeps its plain text.
    group.applyMessage = group.hasPresets and "{spell}" or L("Aura")
    local draftName = draft and draft.name
    if draftName and draftName ~= "" and draftName ~= L("New aura group") then
        group.name = draftName
    elseif not group.hasPresets then
        group.name = draftName or L("New aura group")
    elseif single then
        group.name = single.name
    elseif cueCount == 1 and scopeCount == 1 then
        group.name = L(onlyScope) .. " · "
            .. (categoryCount == 1 and ui.categoryLabel(onlyCategory) or cueWord)
    else
        group.name = L("Preset group")
    end
    return group
end

-- "Create aura": the draft becomes the one new rule (manual triggers plus all ticked preset effects).
ns.AuraPresetUI.createGroup = function()
    local ui = ns.AuraPresetUI
    local rule = ui.creationDraft
    if not (ui.creationActive and rule) then return end
    local specID = ns.Profiles and ns.Profiles.GetCurrentSpecialization and ns.Profiles.GetCurrentSpecialization()
    local group = ui.pendingGroup(specID)
    if group.hasPresets then
        rule.name = group.name
        rule.spellIDs = group.spellIDs
        rule.castByAuraID = group.castByAuraID
        rule.categoryByAuraID = group.categoryByAuraID
        rule.enabled = true
        rule.alertCategory = "none"
        rule.expireCategory = "none"
        rule.applyEnabled = true
        rule.applyMessage = group.applyMessage
        rule.expireEnabled = false
        rule.expireMessage = ""
        rule.expireSoundEnabled = false
        rule.expireSoundMediaName = nil
        rule.expireSoundKitID = DEFAULT_NOTIFICATION_SOUND_KIT
        rule.expireSoundChannel = "Master"
        if rule.screenProfiles then rule.screenProfiles.expire = ns.newScreenProfile(false, "") end
        rule.oneEffect = false
        rule.presetID = group.presetID
        rule.specializationIDs = group.specializationIDs
    end
    ns.registerNewRule(rule, "auras")
    table.insert(WoWraVoxDB.auras, rule)
    ui.finishCreation(false)
    addRuleMode = false
    selectedCategory, selectedAuraRule = "auras", rule
    rebuildAuraWatches()
    syncAllAuras(true)
    refreshList()
    updateDetails()
    setStatus(L("Aura group created."))
end

ns.AuraPresetUI.accentFor = function(category)
    local key = tostring(category):match("^augmentation") and "augmentation" or category
    return ns.AuraPresetUI.ACCENTS[key] or ns.AuraPresetUI.ACCENTS.offensive
end

ns.AuraPresetUI.iconFor = function(entry)
    local spellID = tonumber(entry and (entry.auraID or entry.castID))
    if spellID and C_Spell then
        if type(C_Spell.GetSpellTexture) == "function" then
            local ok, icon = pcall(C_Spell.GetSpellTexture, spellID)
            if ok and (type(icon) == "number" or type(icon) == "string")
                and (not issecretvalue or not issecretvalue(icon)) then
                return icon
            end
        end
        if type(C_Spell.GetSpellInfo) == "function" then
            local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
            if ok and type(info) == "table" and (not issecrettable or not issecrettable(info)) then
                local iconID = info.iconID
                if (type(iconID) == "number" or type(iconID) == "string")
                    and (not issecretvalue or not issecretvalue(iconID)) then
                    return iconID
                end
            end
        end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- Pure data for the preset chooser (no widgets): sections -> packages -> entries, plus the flat items[id] lookup.
-- Nothing is selected until the player ticks it; an entry that is not available is never selected.
ns.AuraPresetUI.model = function(specID)
    local ui, catalog = ns.AuraPresetUI, ns.AuraPresets
    local model = { sections = {}, items = {}, selectedCount = 0 }
    if not (catalog and type(catalog.GetPackages) == "function") then return model end
    local categoryOrder = {
        offensive = 1, defensive = 2, healing = 3,
        ["augmentation-offensive"] = 4, ["augmentation-defensive"] = 5,
    }
    local packages = catalog.GetPackages(specID, true)
    table.sort(packages, function(a, b)
        if a.external ~= b.external then return not a.external end
        local ao = categoryOrder[a.category] or 99
        local bo = categoryOrder[b.category] or 99
        if ao ~= bo then return ao < bo end
        return a.id < b.id
    end)
    local sectionByKey = {}
    for _, package in ipairs(packages) do
        local key = package.external and "Externals" or "Class Specifics"
        local section = sectionByKey[key]
        if not section then
            section = { key = key, title = L(key), packages = {} }
            sectionByKey[key] = section
            model.sections[#model.sections + 1] = section
        end
        local label = ui.categoryLabel(package.category)
        local count = #(package.entries or {})
        local pkg = {
            id = package.id, package = package, category = package.category, external = package.external == true,
            label = label, count = count, blocked = 0, entries = {}, anyAvailable = false, allSelected = true,
            accent = ui.accentFor(package.category),
        }
        for _, entry in ipairs(package.entries or {}) do
            local available, reason = catalog.GetAvailability(entry)
            local selectable = catalog.IsSelectable(entry)
            if not selectable then pkg.blocked = pkg.blocked + 1 end
            local castMap
            if type(entry.castID) == "number" and entry.castID ~= entry.auraID then
                castMap = { castByAuraID = { [entry.auraID] = entry.castID } }
            end
            local item = {
                entry = entry, id = entry.id, name = ui.displayName(entry), icon = ui.iconFor(entry),
                category = package.category, categoryLabel = label,
                available = available == true, selectable = selectable == true,
                -- Blocked entries show a player-facing sentence, never the internal source-review note.
                reason = (not available) and L(selectable and reason or "Blocked pending source review.") or nil,
                strong = catalog.IsStrong and catalog.IsStrong(entry) == true or false,
                sourceCount = entry.sourceCount or 0,
                canSpeak = ns._Aura.addonCanSpeak(entry.auraID, castMap) == true,
                combatText = select(3, ns._Aura.combatInfo(entry.auraID, castMap)),
            }
            item.selected = item.available and ui.selected[entry.id] == true
            if item.available then
                pkg.anyAvailable = true
                if not item.selected then pkg.allSelected = false end
            end
            if item.selected then model.selectedCount = model.selectedCount + 1 end
            pkg.entries[#pkg.entries + 1] = item
            model.items[item.id] = item
        end
        if not pkg.anyAvailable then pkg.allSelected = false end
        pkg.title = label .. " · " .. string.format(L(count == 1 and "%d effect" or "%d effects"), count)
            .. (pkg.blocked > 0 and string.format(L(" (%d blocked)"), pkg.blocked) or "")
        section.packages[#section.packages + 1] = pkg
    end
    return model
end

-- Click on a tile: available effects toggle; any click makes it the effect the detail bar keeps showing.
ns.AuraPresetUI.toggleEntry = function(item)
    local ui = ns.AuraPresetUI
    if not item then return end
    ui.focus = item.id
    if item.available then ui.selected[item.id] = not (ui.selected[item.id] == true) end
end

-- Package switch: selects every available effect of the package, or clears them when all are selected.
ns.AuraPresetUI.togglePackage = function(pkg)
    local ui = ns.AuraPresetUI
    if not pkg then return end
    local value = not pkg.allSelected
    for _, item in ipairs(pkg.entries) do
        if item.available then ui.selected[item.id] = value end
    end
end

-- Texts of the detail bar for one model item (nil = nothing hovered or clicked yet).
ns.AuraPresetUI.describe = function(item)
    if not item then
        return { name = "", meta = "", output = "", hint = L("Hover or click an effect for details.") }
    end
    local parts = { item.categoryLabel }
    if item.selectable then
        parts[#parts + 1] = item.strong and L("Strong") or string.format(L("Basic (%d sources)"), item.sourceCount)
    end
    if item.available then
        local condition = item.entry.talentCondition or {}
        parts[#parts + 1] = condition.kind == "selected-talent" and L("Talent selected")
            or condition.kind == "spell-known" and L("Spell known") or L("No talent needed")
    else
        parts[#parts + 1] = item.reason
    end
    return {
        name = item.name, meta = table.concat(parts, " · "), hint = "",
        output = item.combatText,
    }
end

ns.AuraPresetUI.updateDetail = function()
    local ui = ns.AuraPresetUI
    local detail = ui.detail
    if not detail then return end
    local id = ui.hover or ui.focus
    local item = id and ui.current and ui.current.items[id] or nil
    local text = ui.describe(item)
    detail.icon:SetShown(item ~= nil)
    if item then detail.icon:SetTexture(item.icon) end
    detail.name:SetText(text.name)
    detail.meta:SetText(text.meta)
    detail.output:SetText(text.output)
    detail.hint:SetText(text.hint)
end

ns.AuraPresetUI.applyTile = function(tile)
    local item = tile.item
    if not item then return end
    local r, g, b = 0.22, 0.22, 0.25
    if item.selected then
        r, g, b = 1, 0.82, 0.2
    elseif not item.available then
        r, g, b = 0.15, 0.15, 0.17
        if tile.hovered then r, g, b = 0.3, 0.3, 0.33 end
    elseif tile.hovered then
        r, g, b = 0.88, 0.9, 0.96
    end
    tile.border:SetColorTexture(r, g, b, 1)
    local shade = item.available and 1 or 0.4
    tile.icon:SetDesaturated(not item.available)
    tile.icon:SetVertexColor(shade, shade, shade)
    tile.check:SetShown(item.selected)
    tile.checkBg:SetShown(item.selected)
    tile.lock:SetShown(not item.available)
end

ns.AuraPresetUI.makeTile = function()
    local ui = ns.AuraPresetUI
    local tile = CreateFrame("Button", nil, ui.child)
    tile:SetSize(ui.TILE_SIZE, ui.TILE_SIZE)
    tile.border = tile:CreateTexture(nil, "BACKGROUND")
    tile.border:SetAllPoints()
    tile.border:SetColorTexture(0.22, 0.22, 0.25, 1)
    tile.icon = tile:CreateTexture(nil, "ARTWORK")
    tile.icon:SetPoint("TOPLEFT", tile, "TOPLEFT", 2, -2)
    tile.icon:SetPoint("BOTTOMRIGHT", tile, "BOTTOMRIGHT", -2, 2)
    tile.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    tile.checkBg = tile:CreateTexture(nil, "OVERLAY")
    tile.checkBg:SetSize(16, 16)
    tile.checkBg:SetPoint("BOTTOMRIGHT", tile, "BOTTOMRIGHT", -2, 2)
    tile.checkBg:SetColorTexture(0, 0, 0, 0.7)
    tile.check = tile:CreateTexture(nil, "OVERLAY", nil, 1)
    tile.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    tile.check:SetSize(22, 22)
    tile.check:SetPoint("CENTER", tile.checkBg, "CENTER", 0, 0)
    tile.lock = tile:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    tile.lock:SetPoint("CENTER", tile, "CENTER", 0, 0)
    tile.lock:SetText("×")
    tile.lock:SetTextColor(0.9, 0.35, 0.3)
    tile:SetScript("OnEnter", function(self)
        self.hovered = true
        if self.item then ui.hover = self.item.id end
        ui.applyTile(self)
        ui.updateDetail()
        if GameTooltip and self.item then
            local item = self.item
            local entry = item.entry or {}
            local spellID = tonumber(entry.auraID) or tonumber(entry.castID)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            -- Real spell tooltip; plain name only when the spell cannot be resolved.
            local shown = spellID and pcall(GameTooltip.SetSpellByID, GameTooltip, spellID)
            if not shown then GameTooltip:SetText(item.name) end
            if spellID then
                local castRule = { castByAuraID = { [spellID] = entry.castID or spellID } }
                local _, label, explanation = ns._Aura.combatInfo(spellID, castRule)
                GameTooltip:AddLine(label, 0.88, 0.75, 0.4, true)
                GameTooltip:AddLine(explanation, 0.8, 0.8, 0.8, true)
            end
            if not item.available and item.reason then
                GameTooltip:AddLine(item.reason, 0.9, 0.35, 0.3, true)
            end
            GameTooltip:Show()
        end
    end)
    tile:SetScript("OnLeave", function(self)
        self.hovered = false
        if self.item and ui.hover == self.item.id then ui.hover = nil end
        ui.applyTile(self)
        ui.updateDetail()
        if GameTooltip then GameTooltip:Hide() end
    end)
    tile:SetScript("OnClick", function(self)
        if not self.item then return end
        ui.toggleEntry(self.item)
        ui.refresh()
    end)
    ui.tiles[#ui.tiles + 1] = tile
    return tile
end

ns.AuraPresetUI.makeCard = function()
    local ui = ns.AuraPresetUI
    local card = CreateFrame("Frame", nil, ui.child, "BackdropTemplate")
    card:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    card:SetBackdropColor(0.085, 0.09, 0.105, 1)
    card:SetBackdropBorderColor(0.24, 0.21, 0.15, 1)
    card.accent = card:CreateTexture(nil, "ARTWORK")
    card.accent:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
    card.accent:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 1, 1)
    card.accent:SetWidth(4)
    card.title = createLabel(card, "", "WoWraVoxFontNormal")
    card.title:SetPoint("LEFT", card, "TOPLEFT", 16, -19)
    card.title:SetJustifyH("LEFT")
    card.toggle = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
    card.toggle:SetSize(96, 22)
    card.toggle:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -8)
    ns.Skin.Register(card.toggle, "button")
    ui.cards[#ui.cards + 1] = card
    return card
end

-- Draws the model: one wide card per package (accent bar, title, select switch) with a wrapping tile grid.
ns.AuraPresetUI.draw = function(model)
    local ui = ns.AuraPresetUI
    if not (ui.scroll and ui.child) then return end
    local width = ui.scroll:GetWidth() or 0
    ui.drawnWidth = width
    local cardWidth = math.max(320, width - 4)
    ui.child:SetWidth(cardWidth)
    for _, frame in ipairs(ui.cards) do frame:Hide() end
    for _, frame in ipairs(ui.tiles) do frame:Hide() end
    for _, frame in ipairs(ui.headings) do frame:Hide() end
    local pitch = ui.TILE_SIZE + ui.TILE_GAP
    local columns = math.max(1, math.floor((cardWidth - 16 - 12 + ui.TILE_GAP) / pitch))
    local y, cardIndex, tileIndex, headingIndex = -2, 0, 0, 0
    for _, section in ipairs(model.sections) do
        headingIndex = headingIndex + 1
        local heading = ui.headings[headingIndex]
        if not heading then
            heading = ui.child:CreateFontString(nil, "OVERLAY", "WoWraVoxFontNormal")
            heading:SetTextColor(1, 0.82, 0.2)
            heading:SetJustifyH("LEFT")
            ui.headings[headingIndex] = heading
        end
        heading:ClearAllPoints()
        heading:SetPoint("TOPLEFT", ui.child, "TOPLEFT", 2, y)
        heading:SetText(section.title)
        heading:Show()
        y = y - 24
        for _, pkg in ipairs(section.packages) do
            cardIndex = cardIndex + 1
            local card = ui.cards[cardIndex] or ui.makeCard()
            local rows = math.max(1, math.ceil(#pkg.entries / columns))
            local height = 40 + rows * pitch - ui.TILE_GAP + 10
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", ui.child, "TOPLEFT", 0, y)
            card:SetSize(cardWidth, height)
            card.accent:SetColorTexture(pkg.accent[1], pkg.accent[2], pkg.accent[3], 1)
            card.title:SetText(pkg.title)
            card.toggle:SetText(pkg.allSelected and L("Clear") or L("Select all"))
            card.toggle:SetEnabled(pkg.anyAvailable)
            card.toggle:SetScript("OnClick", function()
                ui.togglePackage(pkg)
                ui.refresh()
            end)
            card:Show()
            for index, item in ipairs(pkg.entries) do
                tileIndex = tileIndex + 1
                local tile = ui.tiles[tileIndex] or ui.makeTile()
                local column, row = (index - 1) % columns, math.floor((index - 1) / columns)
                tile:SetParent(card)
                tile:ClearAllPoints()
                tile:SetPoint("TOPLEFT", card, "TOPLEFT", 16 + column * pitch, -(40 + row * pitch))
                tile.item = item
                tile.hovered = ui.hover == item.id
                tile.icon:SetTexture(item.icon)
                ui.applyTile(tile)
                tile:Show()
            end
            y = y - height - 8
        end
        y = y - 4
    end
    ui.child:SetHeight(math.max(1, -y + 4))
end

-- Widgets of the chooser live in the creation view's preset panel (built once with it).
ns.AuraPresetUI.build = function(panel)
    local ui = ns.AuraPresetUI
    ui.label = createLabel(panel, "PRESETS", "GameFontNormalLarge")
    ui.label:SetPoint("TOPLEFT", panel, "TOPLEFT", ns.Layout.PAD, -14)
    ui.label:SetTextColor(1, 0.82, 0.2)
    ui.countLabel = createLabel(panel, "", "WoWraVoxFontNormal")
    ui.countLabel:SetPoint("TOPRIGHT", panel, "TOPRIGHT", ns.Layout.RIGHT, -17)
    ui.countLabel:SetJustifyH("RIGHT")

    ui.scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    ui.scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -44)
    ui.scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -27, 90)
    ui.child = CreateFrame("Frame", nil, ui.scroll)
    ui.child:SetSize(1, 1)
    ui.scroll:SetScrollChild(ui.child)
    ui.scroll:HookScript("OnSizeChanged", function(self, width)
        ui.child:SetWidth(math.max(1, width - 4))
        if ui.creationActive and ui.drawnWidth ~= width then ui.refresh() end
    end)
    ns.Skin.Register(ui.scroll, "scrollTrack")
    ns.Skin.Register(ui.scroll, "scrollThumb")

    -- Fixed detail bar: hovered effect, else the last clicked one, else a hint.
    local detail = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    detail:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)
    detail:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 10)
    detail:SetHeight(72)
    detail:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    detail:SetBackdropColor(0.045, 0.05, 0.065, 1)
    detail:SetBackdropBorderColor(0.3, 0.25, 0.15, 1)
    detail.icon = detail:CreateTexture(nil, "ARTWORK")
    detail.icon:SetSize(40, 40)
    detail.icon:SetPoint("LEFT", detail, "LEFT", 14, 0)
    detail.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    detail.name = createLabel(detail, "", "GameFontNormalLarge")
    detail.name:SetPoint("TOPLEFT", detail, "TOPLEFT", 66, -9)
    detail.name:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    detail.name:SetJustifyH("LEFT")
    detail.name:SetMaxLines(1)
    detail.meta = createLabel(detail, "", "WoWraVoxFontHighlightSmall")
    detail.meta:SetPoint("TOPLEFT", detail.name, "BOTTOMLEFT", 0, -5)
    detail.meta:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    detail.meta:SetJustifyH("LEFT")
    detail.meta:SetMaxLines(1)
    detail.output = createLabel(detail, "", "WoWraVoxFontHighlightSmall")
    detail.output:SetPoint("TOPLEFT", detail.meta, "BOTTOMLEFT", 0, -4)
    detail.output:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    detail.output:SetJustifyH("LEFT")
    detail.output:SetMaxLines(1)
    detail.output:SetTextColor(0.72, 0.78, 0.86)
    detail.hint = createLabel(detail, "", "GameFontDisable")
    detail.hint:SetPoint("LEFT", detail, "LEFT", 16, 0)
    ui.detail = detail
end

ns.AuraPresetUI.refresh = function()
    local ui = ns.AuraPresetUI
    if not ui.creationActive then return end
    local rule = selectedAura()
    local catalog = ns.AuraPresets
    if not (rule and catalog and type(catalog.GetPackages) == "function") then return end
    local specID = ns.Profiles and ns.Profiles.GetCurrentSpecialization and ns.Profiles.GetCurrentSpecialization()
    if ui.rule ~= rule or ui.specID ~= specID then
        ui.selected, ui.rule, ui.specID, ui.hover, ui.focus = {}, rule, specID, nil, nil
    end
    local model = ui.model(specID)
    ui.current = model
    ui.draw(model)
    ui.updateDetail()
    if ui.countLabel then ui.countLabel:SetText(string.format(L("%d selected"), model.selectedCount)) end
    ui.refreshOverview()
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
    -- Item rules reuse this panel as their member list (header plus four member rows); spell rules as the one-row
    -- trigger panel (dropdown, Learn, status line). Every category stacks its panels with the same 6 px gaps.
    local isItem = not isAura and selectedCategory == "items"
    local isSkill = not isAura and selectedCategory == "skills"
    local auraTriggerRows = isAura and selectedAura() and math.max(1, math.min(6, #(selectedAura().spellIDs or {}))) or 1
    local triggerPanelHeight = isItem and 190 or isSkill and 74 or (72 + auraTriggerRows * ns.Layout.MEMBER_ROW_H + 30)
    triggerPanel:SetHeight(triggerPanelHeight)
    triggerLabel:ClearAllPoints()
    triggerLabel:SetPoint("TOPLEFT", triggerPanel, "TOPLEFT", ns.Layout.PAD, -10)
    triggerHelpButton:ClearAllPoints()
    triggerHelpButton:SetPoint("LEFT", triggerLabel, "RIGHT", 6, 0)
    triggerHelpButton:SetShown(isAura)
    triggerInputBox:ClearAllPoints()
    triggerInputBox:SetPoint("TOPLEFT", triggerPanel, "TOPLEFT", ns.Layout.FIELD_X, -13)
    triggerInputBox:SetPoint("RIGHT", isAura and auraEditor.skillLearnButton or triggerAddButton, "LEFT", -8, 0)
    triggerInputBox:SetHeight(30)
    triggerInputBox:SetTextInsets(24, 6, 0, 0)
    triggerInputBox.searchIcon:ClearAllPoints()
    triggerInputBox.searchIcon:SetPoint("LEFT", triggerInputBox, "LEFT", 7, 0)
    triggerAddButton:ClearAllPoints()
    triggerAddButton:SetSize(ns.Layout.BUTTON_W, 30)
    triggerAddButton:SetPoint("TOPRIGHT", triggerPanel, "TOPRIGHT", ns.Layout.RIGHT, -13)
    auraEditor.skillLearnButton:ClearAllPoints()
    auraEditor.skillLearnButton:SetSize(isAura and 76 or ns.Layout.BUTTON_W, 30)
    if isAura then
        auraEditor.skillLearnButton:SetPoint("RIGHT", triggerAddButton, "LEFT", -6, 0)
    else
        auraEditor.skillLearnButton:SetPoint("TOPRIGHT", triggerPanel, "TOPRIGHT", ns.Layout.RIGHT, -13)
    end
    triggerStatus:ClearAllPoints()
    triggerStatus:SetPoint("TOPLEFT", triggerPanel, "TOPLEFT", ns.Layout.PAD, -51)
    if auraEditor.batchSealsButton then
        auraEditor.batchSealsButton:ClearAllPoints()
        auraEditor.batchSealsButton:SetPoint("TOPRIGHT", triggerPanel, "TOPRIGHT", ns.Layout.RIGHT, -46)
        triggerStatus:SetPoint("RIGHT", auraEditor.batchSealsButton, "LEFT", -6, 0)
        auraEditor.batchSealsButton:SetShown(false) -- offered in "Add rule" for Paladins instead
    else
        triggerStatus:SetPoint("RIGHT", triggerPanel, "RIGHT", ns.Layout.RIGHT, 0)
    end
    triggerScroll:ClearAllPoints()
    triggerScroll:SetPoint("TOPLEFT", triggerPanel, "TOPLEFT", 10, -70)
    local showTrackingLegend = isAura and not addRuleMode
        and not (ns.AuraPresetUI and ns.AuraPresetUI.creationActive)
    triggerLegendLine:SetShown(showTrackingLegend)
    triggerScroll:SetPoint("BOTTOMRIGHT", triggerPanel, "BOTTOMRIGHT", -27, showTrackingLegend and 27 or 8)
    triggerInputBox:SetShown(isAura)
    triggerPlaceholder:SetShown(isAura and query == "")
    triggerAddButton:SetShown(isAura or isItem)
    triggerStatus:SetShown(isAura or isItem)

    local messageY = triggerHeadingY - triggerPanelHeight - 6
    local voiceY
    local voiceExpanded = ns.Layout.isPanelExpanded(auraEditor.voice)
    local voiceHeight = voiceExpanded and 118 or 34
    if isAura then
        auraEditor.skillTriggerLabel:Hide()
        auraEditor.skillTriggerDropdown:Hide()
        auraEditor.skillLearnButton:SetShown(selectedAura() ~= nil and selectedAura().builtin ~= true)
        auraEditor.skillLearningStatus:Hide()
        ns.setNotificationPanelShown(ns.notificationPanels.ready, false)
        local tabsY = messageY - ns.layoutTimeline(messageY) - 6
        local tabBar = ns.timeline.tabBar
        tabBar:ClearAllPoints()
        tabBar:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", ns.Layout.PAD, tabsY)
        tabBar:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", ns.Layout.RIGHT, tabsY)
        tabBar:SetFrameLevel(ns.notificationPanels.apply.frame:GetFrameLevel() + 10)
        tabBar:Show()
        local panelY = tabsY - 30
        local key = ns.SelectedMarkerKey(selectedAura())
        local panel = key == "apply" and ns.notificationPanels.apply or key == "expire" and ns.notificationPanels.expire
            or ns.notificationPanels.beforeExpire
        for _, candidate in ipairs({ ns.notificationPanels.apply, ns.notificationPanels.expire, ns.notificationPanels.beforeExpire }) do
            if candidate ~= panel then ns.setNotificationPanelShown(candidate, false) end
        end
        ns.setNotificationPanelShown(panel, true)
        layoutNotificationPanel(panel, panelY)
        voiceY = panelY - panel.frame:GetHeight() - 6
    else
        auraEditor.skillTriggerLabel:ClearAllPoints()
        auraEditor.skillTriggerLabel:SetPoint("TOPLEFT", triggerPanel, "TOPLEFT", ns.Layout.PAD, -22)
        ns.Layout.placeDropdown(auraEditor.skillTriggerDropdown, triggerPanel, cols.col1, -13, cols.col1Width)
        auraEditor.skillLearnButton:ClearAllPoints()
        auraEditor.skillLearnButton:SetSize(ns.Layout.BUTTON_W, 30)
        auraEditor.skillLearnButton:SetPoint("TOPRIGHT", triggerPanel, "TOPRIGHT", ns.Layout.RIGHT, -13)
        auraEditor.skillLearningStatus:ClearAllPoints()
        auraEditor.skillLearningStatus:SetPoint("TOPLEFT", triggerPanel, "TOPLEFT", ns.Layout.PAD, -51)
        auraEditor.skillLearningStatus:SetPoint("RIGHT", triggerPanel, "RIGHT", ns.Layout.RIGHT, 0)
        auraEditor.skillTriggerLabel:SetShown(isSkill)
        auraEditor.skillTriggerDropdown:SetShown(isSkill)
        auraEditor.skillLearnButton:SetShown(isSkill)
        auraEditor.skillLearningStatus:SetShown(isSkill)
        ns.setNotificationPanelShown(ns.notificationPanels.apply, false)
        ns.setNotificationPanelShown(ns.notificationPanels.expire, false)
        ns.setNotificationPanelShown(ns.notificationPanels.beforeExpire, false)
        if ns.timeline.frame then ns.timeline.frame:Hide() end
        if ns.timeline.tabBar then ns.timeline.tabBar:Hide() end
        ns.setNotificationPanelShown(ns.notificationPanels.ready, true)
        layoutNotificationPanel(ns.notificationPanels.ready, messageY)
        voiceY = messageY - ns.notificationPanels.ready.frame:GetHeight() - 6
    end
    auraEditor.voicePanel:ClearAllPoints()
    auraEditor.voicePanel:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 0, voiceY)
    auraEditor.voicePanel:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", 0, voiceY)
    auraEditor.voicePanel:SetHeight(voiceHeight)
    -- TTS panel on the same visible columns as the panels above: Voice = col1, Volume = col2, Speed = col3.
    auraEditor.voiceHeading:ClearAllPoints()
    auraEditor.voiceHeading:SetPoint("TOPLEFT", auraEditor.voicePanel, "TOPLEFT", ns.Layout.PAD + 22, -10) -- 22 = room for the chevron
    for _, control in ipairs(auraEditor.voice.controls or {}) do control:SetShown(voiceExpanded) end
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
    auraEditor.minimumContentHeight = math.max(620, contentHeight)
    auraEditor:SetHeight(math.max(auraEditor.minimumContentHeight, viewportHeight))
end

local function makeSectionLabel(parent, text, x, y, layoutLater)
    local label = createLabel(parent, text, "GameFontNormalLarge")
    if not layoutLater then label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y) end
    label:SetTextColor(1, 0.82, 0.2)
    return label
end

selectedAura = function()
    return selectedCategory == "auras" and selectedAuraRule or nil
end

local function ruleIsCurrent(category, rule)
    if type(rule) ~= "table" or not WoWraVoxDB then return false end
    for _, candidate in ipairs(WoWraVoxDB[category] or {}) do
        if candidate == rule then return true end
    end
    return false
end

local function findBuiltinBloodlustRule()
    for _, rule in ipairs(WoWraVoxDB and WoWraVoxDB.auras or {}) do
        if type(rule) == "table" and rule.builtin == true and rule.presetID == "heroism-bloodlust" then
            return rule
        end
    end
end

-- Keep an existing selection when it still belongs to active profile. Otherwise show the stable built-in
-- Bloodlust rule first, then the first available category. Add-rule view stays open while pointers are repaired.
function ns.SelectInitialRule()
    local aura = ruleIsCurrent("auras", selectedAuraRule) and selectedAuraRule or nil
    local item = ruleIsCurrent("items", selectedItemRule) and selectedItemRule or nil
    local skill = ruleIsCurrent("skills", selectedSkillRule) and selectedSkillRule or nil
    selectedAuraRule = aura or (WoWraVoxDB and WoWraVoxDB.auras and WoWraVoxDB.auras[1])
    selectedItemRule = item or (WoWraVoxDB and WoWraVoxDB.items and WoWraVoxDB.items[1])
    selectedSkillRule = skill or (WoWraVoxDB and WoWraVoxDB.skills and WoWraVoxDB.skills[1])

    local current = selectedCategory == "auras" and aura
        or selectedCategory == "items" and item
        or selectedCategory == "skills" and skill
    if current then
        return selectedCategory, selectedAuraRule, selectedItemRule, selectedSkillRule
    end

    local bloodlust = findBuiltinBloodlustRule()
    if bloodlust then
        selectedCategory, selectedAuraRule = "auras", bloodlust
    elseif selectedAuraRule then
        selectedCategory = "auras"
    elseif selectedItemRule then
        selectedCategory = "items"
    elseif selectedSkillRule then
        selectedCategory = "skills"
    else
        selectedCategory = "auras"
    end
    return selectedCategory, selectedAuraRule, selectedItemRule, selectedSkillRule
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
    local message = trim(row.text:GetText()) ~= ""
        and ns.formatRuleNotificationMessage(rule, row.text:GetText(), ns.previewContext(rule)) or "WoWraVox"

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

-- One-line member text: the name keeps the FontString colour, "- id" (and a note) is dimmed by a colour code.
function ns.memberRowText(name, id, note)
    local parts = {}
    if id ~= nil and tostring(id) ~= "" then parts[#parts + 1] = tostring(id) end
    if note ~= nil and note ~= "" then parts[#parts + 1] = tostring(note) end
    name = tostring(name or "")
    if #parts == 0 then return name end
    return name .. " |cff8c929a· " .. table.concat(parts, " · ") .. "|r"
end

function ns.setupMemberRow(row)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", row, "LEFT", 3, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.title = row:CreateFontString(nil, "OVERLAY", "WoWraVoxFontHighlightSmall")
    row.title:SetPoint("LEFT", row.icon, "RIGHT", 7, 0)
    row.title:SetPoint("RIGHT", row, "RIGHT", -34, 0)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)
    row.title:SetMaxLines(1)
    row.remove = CreateFrame("Button", nil, row)
    row.remove:SetSize(22, 22)
    row.remove:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.remove.mark = row.remove:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    row.remove.mark:SetPoint("CENTER", row.remove, "CENTER", 0, 0)
    row.remove.mark:SetText("×")
    row.remove.mark:SetTextColor(0.92, 0.38, 0.32)
    row.remove:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
end

function ns.setupSpellSearchRow(row)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(26, 26)
    row.icon:SetPoint("LEFT", row, "LEFT", 5, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.title = createLabel(row, "", "WoWraVoxFontHighlightSmall")
    row.title:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -2)
    row.title:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.title:SetJustifyH("LEFT")
    row.title:SetMaxLines(1)
    row.idText = createLabel(row, "", "GameFontDisableSmall")
    row.idText:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
    row.idText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.idText:SetJustifyH("LEFT")
    row.idText:SetMaxLines(1)
end

local function updateSelectedTriggers()
    local rule = selectedAura()
    if not (triggerScroll and triggerChild and rule) then return end
    for _, itemRow in ipairs(ns.itemMemberRows) do itemRow:Hide() end

    local cdmStatuses = ns.AuraCDM and ns.AuraCDM.GetEffectStatuses
        and ns.AuraCDM.GetEffectStatuses(rule) or {}
    local validCount, pendingCount, invalidCount = 0, 0, 0
    for index, spellID in ipairs(rule.spellIDs or {}) do
        local info, state = getSpellInfo(spellID)
        if state == "valid" then validCount = validCount + 1
        elseif state == "pending" then pendingCount = pendingCount + 1
        else invalidCount = invalidCount + 1 end

        local row = triggerRows[index]
        if not row then
            row = CreateFrame("Frame", nil, triggerChild)
            row:SetHeight(ns.Layout.MEMBER_ROW_H)
            ns.setupMemberRow(row)
            -- Per trigger: count every rank of this spell (Lay on Hands rank 1, 2, 3 ...).
            row.ranks = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            row.ranks:SetSize(22, 22)
            row.ranks:SetPoint("RIGHT", row.remove, "LEFT", -54, 0)
            row.ranksLabel = row:CreateFontString(nil, "OVERLAY", "WoWraVoxFontNormalSmall")
            row.ranksLabel:SetPoint("LEFT", row.ranks, "RIGHT", 0, 0)
            row.ranksLabel:SetText(L("Ranks"))
            row.ranks:SetScript("OnClick", function(self)
                local parent = self:GetParent()
                local auraRule = selectedAura()
                if not (auraRule and parent.spellID) then return end
                auraRule.rankIDs = type(auraRule.rankIDs) == "table" and auraRule.rankIDs or {}
                local checked = self:GetChecked()
                auraRule.rankIDs[parent.spellID] = checked == true or checked == 1
                rebuildAuraWatches()
                syncAllAuras(true)
            end)
            addHelpTooltip(row.ranks, "All ranks", "Every rank of this spell counts (Lay on Hands rank 1, 2 and 3). The ranks are found once in the background and remembered.")
            ns.Skin.Register(row.ranks, "checkbox")
            row.actionButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.actionButton:SetSize(82, 22)
            row.actionButton:SetPoint("RIGHT", row.ranks, "LEFT", -6, 0)
            row.actionButton:SetScript("OnClick", function(self)
                local parent = self:GetParent()
                if parent.openTrackingSettings then parent:openTrackingSettings() end
            end)
            row.actionButton:HookScript("OnEnter", function(self)
                local parent = self:GetParent()
                local status = AURA_TRACKING_STATUS[parent.cdmStatusKey]
                if not status then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local title = parent.cdmStatusKey == "tracked" and "Click to open CDM" or "Click to set up"
                ns.fillHelpTooltip(GameTooltip, title, status.help)
                GameTooltip:Show()
            end)
            row.actionButton:HookScript("OnLeave", function()
                GameTooltip:Hide()
                ns.resetTooltipFonts()
            end)
            ns.Skin.Register(row.actionButton, "button")
            row:EnableMouse(true)
            row.remove:SetScript("OnClick", function(self)
                local parent = self:GetParent()
                local auraRule = selectedAura()
                if not (auraRule and parent.spellID) or ns.isBuiltinTrigger(auraRule, parent.spellID) then return end
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
                ns.AuraPresetUI.refreshOverview()
            end)
            row:SetScript("OnEnter", function(self)
                if not self.spellID then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local ok = pcall(GameTooltip.SetSpellByID, GameTooltip, self.spellID)
                if not ok then GameTooltip:SetText(self.spellName or L("Unknown ID")) end
                GameTooltip:AddLine("ID: " .. self.spellID, 0.72, 0.78, 0.86)
                ns._Aura.addCombatTooltip(self.spellID, self.rule, self.cdmStatuses)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row.openTrackingSettings = function(self)
                if self.cdmStatusKey == "tracked" then
                    local ok, reason = false, "unavailable"
                    if ns.AuraCDM and ns.AuraCDM.OpenSettings then ok, reason = ns.AuraCDM.OpenSettings() end
                    if not ok and DEFAULT_CHAT_FRAME then
                        local message = reason == "combat" and L("Open Advanced Cooldown Settings after combat.")
                            or L("Open Advanced Cooldown Settings from Edit Mode.")
                        DEFAULT_CHAT_FRAME:AddMessage("|cffd8b65aWoWraVox:|r " .. message)
                    end
                    return
                end
                if self.cdmStatusKey ~= "available" or not StaticPopup_Show then return end
                local prompt = string.format(L("%s (ID %d) is available for your class/spec but not assigned to Tracked Buffs or Bars. Open Advanced Cooldown Settings and assign it manually. WoWraVox cannot add it automatically. Your category cue remains available."),
                    self.spellName or L("Unknown ID"), self.spellID)
                StaticPopup_Show("WOWRAVOX_CDM_TRACK_AURA", prompt, nil, { spellID = self.spellID })
            end
            row:SetScript("OnMouseUp", function(self, button)
                if button == "LeftButton" and self.openTrackingSettings then
                    self:openTrackingSettings()
                end
            end)
            addHelpTooltip(row.remove, "Remove trigger", "Remove this spell ID from the aura rule. Triggers of built-in rules cannot be removed.")
            ns.Skin.Register(row, "memberRow")
            ns.Skin.Register(row.remove, "dangerButton")
            ns.skinIconFrame(row.icon)
            triggerRows[index] = row
        end

        row.spellID = spellID
        row.remove:SetEnabled(not ns.isBuiltinTrigger(rule, spellID))
        row.ranks:SetChecked(ns.TriggerTracksRanks(rule, spellID))
        row.spellName = info and info.name or (state == "pending" and L("Loading…") or L("Unknown ID"))
        row.icon:SetTexture(info and info.iconID or "Interface\\Icons\\INV_Misc_QuestionMark")
        row.rule = rule
        row.cdmStatuses = cdmStatuses
        if state == "valid" then
            local trackingStatus = auraTrackingPresentation(spellID, rule, cdmStatuses)
            local color = trackingStatus.color
            row.cdmStatusKey = trackingStatus.key
            local isClickable = trackingStatus.key == "tracked" or trackingStatus.key == "available"
            row.actionButton:SetShown(isClickable)
            row.actionButton:SetText(L(trackingStatus.key == "tracked" and "Open CDM" or "Set up"))
            row.actionButton:SetEnabled(isClickable)
            row.title:ClearAllPoints()
            row.title:SetPoint("LEFT", row.icon, "RIGHT", 7, 0)
            if isClickable then
                row.title:SetPoint("RIGHT", row.actionButton, "LEFT", -6, 0)
            else
                row.title:SetPoint("RIGHT", row.ranks, "LEFT", -6, 0)
            end
            local hex = string.format("%02x%02x%02x", math.floor(color[1] * 255 + 0.5),
                math.floor(color[2] * 255 + 0.5), math.floor(color[3] * 255 + 0.5))
            row.title:SetText("|cff" .. hex .. row.spellName .. "|r |cff8c929a· " .. spellID .. "|r"
                .. " |cff" .. hex .. "· " .. L(trackingStatus.label) .. "|r")
            row.title:SetTextColor(0.93, 0.93, 0.96)
        else
            row.cdmStatusKey = nil
            row.actionButton:Hide()
            row.title:ClearAllPoints()
            row.title:SetPoint("LEFT", row.icon, "RIGHT", 7, 0)
            row.title:SetPoint("RIGHT", row, "RIGHT", -34, 0)
            row.title:SetPoint("RIGHT", row.ranks, "LEFT", -6, 0)
            local note = state == "pending" and L("loading") or L("invalid")
            row.title:SetText(ns.memberRowText(row.spellName, spellID, note))
            row.title:SetTextColor(state == "pending" and 0.75 or 1, state == "pending" and 0.78 or 0.65, state == "pending" and 0.84 or 0.38)
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", triggerChild, "TOPLEFT", 2, -((index - 1) * ns.Layout.MEMBER_ROW_H))
        row:SetPoint("RIGHT", triggerChild, "RIGHT", -2, 0)
        row:Show()
    end
    for index = #(rule.spellIDs or {}) + 1, #triggerRows do triggerRows[index]:Hide() end
    triggerChild:SetHeight(math.max(1, #(rule.spellIDs or {}) * ns.Layout.MEMBER_ROW_H))
    triggerScroll:SetVerticalScroll(math.min(triggerScroll:GetVerticalScroll(), math.max(0, triggerChild:GetHeight() - triggerScroll:GetHeight())))

    local count = #(rule.spellIDs or {})
    local summary = count == 1 and L("1 trigger") or string.format(L("%d triggers"), count)
    if count > 0 then summary = summary .. " · " .. string.format(L("%d valid"), validCount) end
    if pendingCount > 0 then summary = summary .. " · " .. string.format(L("%d loading"), pendingCount) end
    if invalidCount > 0 then summary = summary .. " · " .. string.format(L("%d invalid"), invalidCount) end
    triggerStatus:SetText(summary)
    triggerStatus:SetTextColor(invalidCount > 0 and 1 or 0.72, invalidCount > 0 and 0.4 or 0.78, invalidCount > 0 and 0.3 or 0.86)
end

-- "NEW AURA GROUP" overview at the bottom of the Add Aura view: what Create aura will make, one compact row per
-- trigger (icon, name · id · category hint, x). The x removes a manual trigger or unticks a preset effect.
ns.AuraPresetUI.OVERVIEW_HEIGHT = 120
ns.AuraPresetUI.removeRow = function(data)
    local ui = ns.AuraPresetUI
    if not (data and ui.creationActive) then return end
    if data.manual then
        local draft = ui.creationDraft
        for index, spellID in ipairs(draft and draft.spellIDs or {}) do
            if spellID == data.id then
                table.remove(draft.spellIDs, index)
                break
            end
        end
        updateSelectedTriggers()
        ui.refreshOverview()
    elseif data.entryID then
        ui.selected[data.entryID] = false
        ui.refresh()
    end
end

ns.AuraPresetUI.buildOverview = function(panel)
    local ui = ns.AuraPresetUI
    ui.ovPanel = panel
    ui.ovHeading = createLabel(panel, "NEW AURA GROUP", "WoWraVoxFontNormal")
    ui.ovHeading:SetPoint("TOPLEFT", panel, "TOPLEFT", ns.Layout.PAD, -11)
    ui.ovHeading:SetTextColor(1, 0.82, 0.2)
    ui.ovCount = createLabel(panel, "", "WoWraVoxFontNormalSmall")
    ui.ovCount:SetPoint("TOPRIGHT", panel, "TOPRIGHT", ns.Layout.RIGHT, -13)
    ui.ovCount:SetJustifyH("RIGHT")
    ui.ovName = createLabel(panel, "", "WoWraVoxFontHighlight")
    ui.ovName:SetPoint("LEFT", ui.ovHeading, "RIGHT", 10, 0)
    ui.ovName:SetPoint("RIGHT", ui.ovCount, "LEFT", -10, 0)
    ui.ovName:SetJustifyH("LEFT")
    ui.ovName:SetWordWrap(false)
    ui.ovName:SetMaxLines(1)
    ui.ovEmpty = createLabel(panel, "Nothing selected yet.", "GameFontDisable")
    ui.ovEmpty:SetPoint("LEFT", panel, "LEFT", ns.Layout.PAD, -10)
    ui.ovScroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    ui.ovScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -30)
    ui.ovScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -27, 8)
    ui.ovChild = CreateFrame("Frame", nil, ui.ovScroll)
    ui.ovChild:SetSize(1, 1)
    ui.ovScroll:SetScrollChild(ui.ovChild)
    ui.ovScroll:HookScript("OnSizeChanged", function(self, width) ui.ovChild:SetWidth(math.max(1, width - 4)) end)
    ns.Skin.Register(ui.ovScroll, "scrollTrack")
    ns.Skin.Register(ui.ovScroll, "scrollThumb")
    ui.ovRows = {}
end

ns.AuraPresetUI.makeOverviewRow = function()
    local ui = ns.AuraPresetUI
    local row = CreateFrame("Frame", nil, ui.ovChild)
    row:SetHeight(ns.Layout.MEMBER_ROW_H)
    ns.setupMemberRow(row)
    row.remove:SetScript("OnClick", function() ui.removeRow(row.data) end)
    addHelpTooltip(row.remove, "Remove from group",
        "Remove this trigger from the new group. A preset effect is unticked in the list above.")
    ns.Skin.Register(row, "memberRow")
    ns.Skin.Register(row.remove, "dangerButton")
    ns.skinIconFrame(row.icon)
    ui.ovRows[#ui.ovRows + 1] = row
    return row
end

ns.AuraPresetUI.refreshOverview = function()
    local ui = ns.AuraPresetUI
    if not (ui.creationActive and ui.ovScroll) then return end
    local specID = ns.Profiles and ns.Profiles.GetCurrentSpecialization and ns.Profiles.GetCurrentSpecialization()
    local group = ui.pendingGroup(specID)
    ui.pending = group
    local count = #group.rows
    ui.ovName:SetText(group.name)
    ui.ovCount:SetText(string.format(L(count == 1 and "%d effect" or "%d effects"), count))
    ui.ovEmpty:SetShown(count == 0)
    for index, data in ipairs(group.rows) do
        local row = ui.ovRows[index] or ui.makeOverviewRow()
        row.data = data
        row.icon:SetTexture(data.icon)
        row.title:SetText(ns.memberRowText(data.name, data.id, data.hint))
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", ui.ovChild, "TOPLEFT", 2, -((index - 1) * ns.Layout.MEMBER_ROW_H))
        row:SetPoint("RIGHT", ui.ovChild, "RIGHT", -2, 0)
        row:Show()
    end
    for index = count + 1, #ui.ovRows do ui.ovRows[index]:Hide() end
    ui.ovChild:SetHeight(math.max(1, count * ns.Layout.MEMBER_ROW_H))
end

-- Item rules list their members in the trigger panel: icon (click = pick another item), name, a tag that
-- switches item <-> slot tracking, and x to remove. Rows are built once and refilled.
ns.itemMemberRows = {}

function ns.createItemMemberRow(index)
    local row = CreateFrame("Frame", nil, triggerChild)
    row:SetHeight(ns.Layout.MEMBER_ROW_H)
    row.iconButton = CreateFrame("Button", nil, row)
    row.iconButton:SetSize(20, 20)
    row.iconButton:SetPoint("LEFT", row, "LEFT", 3, 0)
    row.icon = row.iconButton:CreateTexture(nil, "ARTWORK")
    row.icon:SetAllPoints(row.iconButton)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.iconButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    row.title = row:CreateFontString(nil, "OVERLAY", "WoWraVoxFontHighlightSmall")
    row.title:SetPoint("LEFT", row.iconButton, "RIGHT", 7, 0)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)
    row.title:SetMaxLines(1)
    row.tag = CreateFrame("Button", nil, row)
    row.tag:SetHeight(12)
    row.tag.text = row.tag:CreateFontString(nil, "OVERLAY", "WoWraVoxFontNormalSmall")
    row.tag.pad = ns.Skin.Data() and 12 or 0 -- texture skins: the tag art has 8 px end caps
    row.tag.text:SetPoint("LEFT", row.tag, "LEFT", row.tag.pad / 2, 0)
    row.remove = CreateFrame("Button", nil, row)
    row.remove:SetSize(22, 22)
    row.remove:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.remove.mark = row.remove:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    row.remove.mark:SetPoint("CENTER", row.remove, "CENTER", 0, 0)
    row.remove.mark:SetText("×")
    row.remove.mark:SetTextColor(0.92, 0.38, 0.32)
    row.remove:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    -- one line: icon | name · id (cut off, never wrapped) | item/slot tag | x
    row.tag:SetPoint("RIGHT", row.remove, "LEFT", -6, 0)
    row.title:SetPoint("RIGHT", row.tag, "LEFT", -8, 0)

    row.iconButton:SetScript("OnClick", function()
        local rule = selectedItem()
        if not (rule and ns.BeginItemPicker) then return end
        saveDetails()
        ns.BeginItemPicker(rule, index)
    end)
    row.tag:SetScript("OnClick", function()
        local rule = selectedItem()
        local member = rule and ns.itemMembers(rule)[index]
        if not member then return end
        saveDetails()
        local ok, reason = ns.setItemMemberMode(rule, index, member.slotID == nil)
        if not ok then
            setStatus(reason == "duplicate" and "Item already tracked."
                or (member.slotID and "No item in this equipment slot." or "Equip the item to track its slot."), true)
            return
        end
        ns.queueItemScan(0.1)
        refreshList()
        updateDetails()
    end)
    row.remove:SetScript("OnClick", function()
        local rule = selectedItem()
        if not rule then return end
        saveDetails()
        local ok, reason = ns.removeItemMember(rule, index)
        if not ok then
            if reason == "last" then setStatus("A rule needs at least one item.", true) end
            return
        end
        refreshList()
        updateDetails()
    end)
    row:SetScript("OnEnter", function(self)
        if not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if not pcall(GameTooltip.SetItemByID, GameTooltip, self.itemID) then GameTooltip:SetText(self.title:GetText() or "") end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    addHelpTooltip(row.iconButton, "Change item", "Click to pick another equipped item for this rule.")
    addHelpTooltip(row.tag, "Item or slot",
        "Click to switch between this exact item and whatever is equipped in its slot. A swapped-in item never announces its equip lockout.")
    addHelpTooltip(row.remove, "Remove item", "Remove this entry from the rule.")
    ns.Skin.Register(row, "memberRow")
    ns.Skin.Register(row.tag, "tag")
    ns.Skin.Register(row.remove, "dangerButton")
    ns.skinIconFrame(row.icon)
    ns.itemMemberRows[index] = row
    return row
end

function ns.updateItemMembers()
    local rule = selectedItem()
    if not (triggerScroll and triggerChild and rule) then return end
    for _, auraRow in ipairs(triggerRows) do auraRow:Hide() end
    local members = ns.itemMembers(rule)
    for index, member in ipairs(members) do
        local row = ns.itemMemberRows[index] or ns.createItemMemberRow(index)
        local name, icon, equippedSlot = ns.itemMemberInfo(member)
        row.itemID = member.slotID and ns.getEquippedItemID(member.slotID) or member.itemID
        row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        row.title:SetText(ns.memberRowText(name or L("Not equipped"), row.itemID))
        -- A member whose item is not worn right now cannot announce anything: shown in amber.
        row.title:SetTextColor(equippedSlot and 0.93 or 1, equippedSlot and 0.93 or 0.65, equippedSlot and 0.96 or 0.25)
        row.tag.text:SetText(member.slotID and (ns.slotName(member.slotID) .. " · " .. L("Slot")) or L("Item"))
        row.tag:SetWidth(math.max(1, row.tag.text:GetStringWidth() + 4 + row.tag.pad))
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", triggerChild, "TOPLEFT", 2, -((index - 1) * ns.Layout.MEMBER_ROW_H))
        row:SetPoint("RIGHT", triggerChild, "RIGHT", -2, 0)
        row:Show()
    end
    for index = #members + 1, #ns.itemMemberRows do ns.itemMemberRows[index]:Hide() end
    triggerChild:SetHeight(math.max(1, #members * ns.Layout.MEMBER_ROW_H))
    triggerScroll:SetVerticalScroll(math.min(triggerScroll:GetVerticalScroll(), math.max(0, triggerChild:GetHeight() - triggerScroll:GetHeight())))
    triggerStatus:SetText(#members == 0 and L("Choose an equipped item")
        or #members == 1 and L("1 item") or string.format(L("%d items"), #members))
    triggerStatus:SetTextColor(0.72, 0.78, 0.86)
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
    ns.AuraPresetUI.refreshOverview()
    setStatus(#additions == 1 and L("1 trigger added") or string.format(L("%d triggers added"), #additions))
    return true
end

ns.SkillTracking.isSealFamilyRule = function(rule)
    local family = auraTrackerConfig().families and auraTrackerConfig().families.seals
    return type(family) == "table" and rule and tostring(family.ruleID) == tostring(rule.id)
end

ns.SkillTracking.addAuraID = function(rule, spellID, castSpellID, auraName)
    if selectedAura() ~= rule or type(spellID) ~= "number" or spellID <= 0 or spellID ~= math.floor(spellID) then
        return false
    end
    if rule.builtin then return false end
    if ns.SkillTracking.isSealFamilyRule(rule) then
        if not validStoredSpellID(castSpellID) or type(auraName) ~= "string" then return false end
        local family = auraTrackerConfig().families.seals
        local match
        for _, row in ipairs(family.spells or {}) do
            if row.mappingVerified ~= true and (row.spellID == castSpellID or row.castID == castSpellID)
                and row.name == auraName then
                if match then return false end
                match = row
            end
        end
        if not match then return false end
        local evidence = { source = "learning", confirmed = true, castID = match.castID, auraID = spellID }
        if not ns.AuraTrackerFamily.ConfirmMapping(family, match.spellID, match.castID, spellID, evidence) then
            return false
        end
        normalizeAuraTrackerData(WoWraVoxDB)
        syncAuraTrackerSealRule()
        if ns.AuraCDM and type(ns.AuraCDM.RefreshSignals) == "function" then
            pcall(ns.AuraCDM.RefreshSignals)
        end
        if ns._Aura.rebuildAuraWatches then ns._Aura.rebuildAuraWatches() end
        if ns._Aura.syncAllAuras then ns._Aura.syncAllAuras(true) end
        if optionsFrame and optionsFrame:IsShown() and refreshList then refreshList() end
        queueAuraTrackerUpdate()
        return true
    end
    return addTriggerIDs({ spellID })
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
        local exactHit
        for _, result in ipairs(results) do
            if result.name:lower() == query:lower() then exactHit = exactHit or result end
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
        if exactHit then
            -- Every ID with this exact name is added together: one name can belong to several spells (one per spec).
            local exactIDs = {}
            for _, result in ipairs(results) do
                if result.name:lower() == query:lower() then exactIDs[#exactIDs + 1] = result.id end
            end
            table.sort(exactIDs)
            triggerAddButton.exactResult = {
                query = query, rule = selectedAuraRule, generation = searchGeneration, id = exactIDs[1], ids = exactIDs,
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
    searchPopup.empty = createLabel(searchPopup, "No matching spells.", "WoWraVoxFontHighlightSmall")
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
        ns.setupSpellSearchRow(row)
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
    if panel.categoryChoice then
        rule[eventKey == "expire" and "expireCategory" or "alertCategory"] = panel.categoryChoice.screenValue or "none"
    end
    if panel.warningPercent and panel.warningPercentEdited then
        rule.beforeExpirePercent = math.max(0, math.min(100, math.floor(panel.warningPercent:GetValue() + 0.5)))
        rule.beforeExpireSeconds = nil
        panel.warningPercentEdited = false
    end
    saveScreenRowProfile(panel.screen, rule)
end

local function loadNotificationPanel(panel, rule, eventKey)
    panel.ttsEnabled:SetChecked(eventKey == "ready" and rule.readyEnabled ~= false or rule[eventKey .. "Enabled"])
    panel.ttsMessage:SetText(eventKey == "ready" and rule.message or rule[eventKey .. "Message"] or "")
    if panel.warningPercent then
        local legacySeconds = rule.beforeExpirePercent == nil and rule.beforeExpireSeconds
        local value = legacySeconds and 5 or rule.beforeExpirePercent or 5
        panel.warningPercentEdited = false
        panel.warningPercent:SetValue(value)
        panel.warningValue:SetText(legacySeconds and string.format(L("%d s (legacy)"), legacySeconds)
            or (tostring(value) .. "%"))
    end
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
        local category = NOTIFICATION_CUE_ALIASES[rule[eventKey == "expire" and "expireCategory" or "alertCategory"]] or "none"
        panel.categoryChoice.screenValue = category
        UIDropDownMenu_SetSelectedValue(panel.categoryChoice, category)
        local categoryLabel = category == "none" and ns._Aura.noneCueLabel(rule, eventKey)
            or ns._Aura.cueLabel(category)
        UIDropDownMenu_SetText(panel.categoryChoice, categoryLabel)
    end
    loadScreenRowProfile(panel.screen, rule)
    ns.Layout.ensurePanelState(panel, rule)
    ns.setNotificationPanelShown(panel, true)
end

function saveDetails()
    if editorLoading or addRuleMode then return end
    local auraRule = selectedAura()
    if auraRule and ruleNameBox then
        auraRule.name = trim(ruleNameBox:GetText())
        saveNotificationPanel(ns.notificationPanels.apply, auraRule, "apply")
        saveNotificationPanel(ns.notificationPanels.expire, auraRule, "expire")
        local nodePanel = ns.notificationPanels.beforeExpire
        if nodePanel.loadedKey and not ns.Markers.IsEndpoint(nodePanel.loadedKey) and ns.findMarker(auraRule, nodePanel.loadedKey) then
            saveNotificationPanel(nodePanel, auraRule, nodePanel.loadedKey)
        end
    else
        local readyRule = selectedItem() or selectedSkill()
        if readyRule and ruleNameBox then
            readyRule.name = trim(ruleNameBox:GetText())
            saveNotificationPanel(ns.notificationPanels.ready, readyRule, "ready")
        end
    end
    refreshList()
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
    ns.Layout.ensurePanelState(auraEditor.voice, rule)

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
    auraEditor.exportButton:SetShown(auraRule ~= nil and not auraRule.builtin)
    if auraRule then
        local firstID = auraRule.spellIDs[1]
        local info = firstID and getSpellInfo(firstID)
        auraEditor.ruleIcon:SetTexture(info and info.iconID or "Interface\\Icons\\Spell_Nature_Rejuvenation")
        auraEditor.heading:SetText(L("AURA RULE"))
        auraEditor.oneEffectCheck:Show()
        auraEditor.oneEffectLabel:Show()
        auraEditor.oneEffectCheck:SetChecked(auraRule.oneEffect == true)
        auraEditor.oneEffectCheck:SetEnabled(not auraRule.builtin)
        auraEditor.allRanksCheck:Hide()
        auraEditor.allRanksLabel:Hide()
        auraEditor.iconButton:Hide()
        itemSourceText:Hide()
        triggerLabel:SetText(L("TRIGGERS"))
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
        local nodeKey = ns.SelectedMarkerKey(auraRule)
        local nodePanel = ns.notificationPanels.beforeExpire
        nodePanel.loadedKey = nil
        if not ns.Markers.IsEndpoint(nodeKey) then
            nodePanel.eventKey, nodePanel.key, nodePanel.screen.eventKey = nodeKey, nodeKey, nodeKey
            loadNotificationPanel(nodePanel, auraRule, nodeKey)
            nodePanel.loadedKey = nodeKey
            nodePanel.heading:SetText(ns.markerTitle(ns.findMarker(auraRule, nodeKey), auraRule))
        end
        layoutSharedEditor(true)
        if not keepTriggerQuery then triggerInputBox:SetText("") end
        updateSelectedTriggers()
        ns.AuraPresetUI.refresh()
    elseif itemRule or skillRule then
        local readyRule = itemRule or skillRule
        local skillInfo = skillRule and getSpellInfo(skillRule.spellID)
        auraEditor.ruleIcon:SetTexture(readyRule.icon or (skillInfo and skillInfo.iconID) or "Interface\\Icons\\INV_Misc_QuestionMark")
        auraEditor.heading:SetText(L(itemRule and "ITEM RULE" or "SPELL COOLDOWN"))
        auraEditor.oneEffectCheck:Hide()
        auraEditor.oneEffectLabel:Hide()
        auraEditor.allRanksCheck:Hide()
        auraEditor.allRanksLabel:Hide()
        auraEditor.iconButton:SetShown(itemRule ~= nil)
        -- Item rules list their members in the trigger panel; spell cooldown rules show their trigger row there.
        triggerLabel:SetShown(itemRule ~= nil)
        if itemRule then triggerLabel:SetText(L("ITEMS")) end
        triggerInputBox:Hide()
        triggerPlaceholder:Hide()
        triggerAddButton:SetShown(itemRule ~= nil)
        if itemRule then
            triggerAddButton:SetText(L("Add item"))
            triggerAddButton:SetEnabled(true)
        end
        triggerStatus:SetShown(itemRule ~= nil)
        triggerScroll.backdrop:Show()
        triggerScroll:SetShown(itemRule ~= nil)
        for _, auraRow in ipairs(triggerRows) do auraRow:Hide() end
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
        ns.itemHelpButton:SetShown(itemRule ~= nil)
        if itemRule then
            local choosingStarter = ns.isEmptyStarter(itemRule)
            ns.updateItemMembers()
            if choosingStarter then
                itemSourceText:SetText(L("Choose an equipped item"))
                itemSourceText:SetTextColor(1, 0.82, 0.2)
                testItemButton:SetText(L("Choose item"))
                testItemButton:SetEnabled(true)
                testItemButton:SetScript("OnClick", function() if ns.BeginItemPicker then ns.BeginItemPicker() end end)
            else
                itemSourceText:SetText("")
                testItemButton:SetText(L("Test"))
                if ns.TestCurrentReady then testItemButton:SetScript("OnClick", ns.TestCurrentReady) end
            end
        else
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
        creationView.importButton:Show()
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

ns.ShowAddRuleView = showAddRuleView
ns.AuraPresetUI.beginCreation = function()
    local ui = ns.AuraPresetUI
    if ui.creationActive or not (creationView.manualPanel and creationView.presetPanel) then return end
    ui.previousSelection = {
        category = selectedCategory, aura = selectedAuraRule, item = selectedItemRule, skill = selectedSkillRule,
    }
    ui.creationDraft = newAuraRule()
    ui.creationActive = true
    selectedCategory, selectedAuraRule = "auras", ui.creationDraft
    ui.selected, ui.rule, ui.specID, ui.hover, ui.focus = {}, nil, nil, nil, nil

    creationView.heading:SetText(L("ADD AURA"))
    creationView.auraButton:Hide()
    creationView.itemButton:Hide()
    creationView.skillButton:Hide()
    creationView.importButton:Hide()
    skillSearchBox:Hide()
    skillSearchStatus:Hide()
    creationView.manualPanel:ClearAllPoints()
    creationView.manualPanel:SetPoint("TOPLEFT", creationView, "TOPLEFT", 12, -52)
    creationView.manualPanel:SetPoint("TOPRIGHT", creationView, "TOPRIGHT", -12, -52)
    creationView.manualPanel:SetHeight(190)
    creationView.presetPanel:ClearAllPoints()
    creationView.presetPanel:SetPoint("TOPLEFT", creationView.manualPanel, "BOTTOMLEFT", 0, -6)
    -- Fixed window: 799 px view = 52 top + manual 190 + gap + presets (~380) + gap + overview 120 + 46 buttons.
    creationView.overviewPanel:ClearAllPoints()
    creationView.overviewPanel:SetPoint("BOTTOMLEFT", creationView, "BOTTOMLEFT", 12, 46)
    creationView.overviewPanel:SetPoint("BOTTOMRIGHT", creationView, "BOTTOMRIGHT", -12, 46)
    creationView.overviewPanel:SetHeight(ns.AuraPresetUI.OVERVIEW_HEIGHT)
    creationView.presetPanel:SetPoint("BOTTOMRIGHT", creationView.overviewPanel, "TOPRIGHT", 0, 6)
    creationView.manualPanel:Show()
    creationView.presetPanel:Show()
    creationView.overviewPanel:Show()
    creationView.backButton:Show()
    creationView.createAuraButton:Show()

    for _, control in ipairs({ triggerLabel, triggerHelpButton, triggerInputBox, triggerPlaceholder, triggerAddButton, triggerStatus, triggerLegendLine, triggerScroll }) do
        control:SetParent(creationView.manualPanel)
        control:ClearAllPoints()
        control:Show()
    end
    triggerScroll.backdrop = creationView.manualPanel
    triggerLabel:SetText(L("TRIGGERS"))
    triggerLabel:SetPoint("TOPLEFT", creationView.manualPanel, "TOPLEFT", ns.Layout.PAD, -10)
    triggerLegendLine:SetPoint("BOTTOMLEFT", creationView.manualPanel, "BOTTOMLEFT", ns.Layout.PAD, 7)
    triggerLegendLine:SetPoint("RIGHT", creationView.manualPanel, "RIGHT", ns.Layout.RIGHT, 0)
    triggerHelpButton:SetPoint("LEFT", triggerLabel, "RIGHT", 6, 0)
    triggerHelpButton:Show()
    triggerInputBox:SetPoint("TOPLEFT", creationView.manualPanel, "TOPLEFT", ns.Layout.FIELD_X, -13)
    triggerInputBox:SetPoint("RIGHT", triggerAddButton, "LEFT", -8, 0)
    triggerInputBox:SetHeight(30)
    triggerPlaceholder:SetPoint("LEFT", triggerInputBox, "LEFT", 23, 0)
    triggerPlaceholder:SetPoint("RIGHT", triggerInputBox, "RIGHT", -8, 0)
    triggerAddButton:SetSize(ns.Layout.BUTTON_W, 30)
    triggerAddButton:SetPoint("TOPRIGHT", creationView.manualPanel, "TOPRIGHT", ns.Layout.RIGHT, -13)
    triggerAddButton:SetText(L("Add"))
    triggerAddButton:SetEnabled(false)
    triggerStatus:SetPoint("TOPLEFT", creationView.manualPanel, "TOPLEFT", ns.Layout.PAD, -51)
    triggerStatus:SetPoint("RIGHT", creationView.manualPanel, "RIGHT", ns.Layout.RIGHT, 0)
    triggerScroll:SetPoint("TOPLEFT", creationView.manualPanel, "TOPLEFT", 10, -70)
    triggerScroll:SetPoint("BOTTOMRIGHT", creationView.manualPanel, "BOTTOMRIGHT", -27, 27)

    triggerInputBox:SetText("")
    triggerPlaceholder:Show()
    updateSelectedTriggers()
    ui.refresh()
end

ns.AuraPresetUI.finishCreation = function(restoreSelection)
    local ui = ns.AuraPresetUI
    if not ui.creationActive then return end
    searchGeneration = searchGeneration + 1
    ns._Aura.cancelPartialSpellSearch()
    if searchPopup then searchPopup:Hide() end
    for _, control in ipairs({ triggerLabel, triggerHelpButton, triggerInputBox, triggerPlaceholder, triggerAddButton, triggerStatus, triggerLegendLine, triggerScroll }) do
        control:SetParent(triggerPanel)
        control:ClearAllPoints()
    end
    triggerScroll.backdrop = triggerPanel
    triggerLegendLine:SetPoint("BOTTOMLEFT", triggerPanel, "BOTTOMLEFT", ns.Layout.PAD, 7)
    triggerLegendLine:SetPoint("RIGHT", triggerPanel, "RIGHT", ns.Layout.RIGHT, 0)
    triggerPlaceholder:SetPoint("LEFT", triggerInputBox, "LEFT", 23, 0)
    triggerPlaceholder:SetPoint("RIGHT", triggerInputBox, "RIGHT", -8, 0)
    triggerInputBox:SetText("")
    ui.creationActive = false
    ui.creationDraft = nil
    ui.selected, ui.rule, ui.specID, ui.hover, ui.focus = {}, nil, nil, nil, nil
    creationView.manualPanel:Hide()
    creationView.presetPanel:Hide()
    creationView.overviewPanel:Hide()
    creationView.backButton:Hide()
    creationView.createAuraButton:Hide()
    creationView.heading:SetText(L("ADD RULE"))
    creationView.auraButton:Show()
    creationView.itemButton:Show()
    creationView.skillButton:Show()
    creationView.importButton:Show()
    local previous = ui.previousSelection
    ui.previousSelection = nil
    if restoreSelection and previous then
        selectedCategory = previous.category
        selectedAuraRule = ruleIsCurrent("auras", previous.aura) and previous.aura or nil
        selectedItemRule = ruleIsCurrent("items", previous.item) and previous.item or nil
        selectedSkillRule = ruleIsCurrent("skills", previous.skill) and previous.skill or nil
        local selected = selectedCategory == "auras" and selectedAuraRule
            or selectedCategory == "items" and selectedItemRule
            or selectedCategory == "skills" and selectedSkillRule
        if not selected then ns.SelectInitialRule() end
    end
    updateSelectedTriggers()
    ui.refresh()
end

ns.CancelAddRuleView = function()
    ns.AuraPresetUI.finishCreation(true)
    addRuleMode = false
    resetSkillCreationSearch()
    updateDetails()
end

local function buildEditorShell()
detailPanel = CreateFrame("Frame", nil, optionsFrame)
detailPanel:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 394, -64)
detailPanel:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -ns.Layout.MARGIN, ns.Layout.MARGIN + ns.Layout.statusHeight)

detailPanel.emptyText = createLabel(detailPanel, "Select a rule or add an aura group or item.", "WoWraVoxFontHighlight")
detailPanel.emptyText:SetPoint("CENTER")
detailPanel.emptyText:SetWidth(360)
detailPanel.emptyText:SetJustifyH("CENTER")

editorScroll = CreateFrame("ScrollFrame", nil, detailPanel, "UIPanelScrollFrameTemplate")
editorScroll:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", 0, -2)
editorScroll:SetPoint("BOTTOMRIGHT", detailPanel, "BOTTOMRIGHT", -8, 0)
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
ns.skinIconFrame(auraEditor.ruleIcon)
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
auraEditor.enabledLabel = createLabel(auraEditor.rulePanel, "Active", "WoWraVoxFontNormalSmall")
auraEditor.enabledLabel:SetPoint("LEFT", ruleEnabledCheck, "RIGHT", 4, 0)
-- Aura groups only; updateDetails shows it for user groups and hides it for built-in ones.
auraEditor.exportButton = CreateFrame("Button", nil, auraEditor.rulePanel, "UIPanelButtonTemplate")
auraEditor.exportButton:SetSize(90, 24)
auraEditor.exportButton:SetPoint("LEFT", auraEditor.enabledLabel, "RIGHT", 18, 0)
auraEditor.exportButton:SetText(L("Export"))
auraEditor.exportButton:SetScript("OnClick", function()
    local rule = selectedAura()
    if rule then ns.ShareUI.openExport(rule) end
end)
ns.Skin.Register(auraEditor.exportButton, "button")
auraEditor.exportButton:Hide()

-- Aura rules only: all triggers count as one effect (announce the first start and the last end).
auraEditor.oneEffectCheck = CreateFrame("CheckButton", nil, auraEditor.rulePanel, "UICheckButtonTemplate")
auraEditor.oneEffectCheck:SetSize(24, 24)
auraEditor.oneEffectCheck:SetPoint("TOPLEFT", auraEditor.rulePanel, "TOPLEFT", 90, -87)
auraEditor.oneEffectLabel = createLabel(auraEditor.rulePanel, "Treat triggers as one effect", "WoWraVoxFontNormalSmall")
auraEditor.oneEffectLabel:SetPoint("LEFT", auraEditor.oneEffectCheck, "RIGHT", 4, 0)
-- Spell ranks: every rank of a configured spell counts as that spell (SpellRanks.lua).
auraEditor.allRanksCheck = CreateFrame("CheckButton", nil, auraEditor.rulePanel, "UICheckButtonTemplate")
auraEditor.allRanksCheck:SetSize(24, 24)
auraEditor.allRanksCheck:SetPoint("LEFT", auraEditor.oneEffectLabel, "RIGHT", 18, 0)
auraEditor.allRanksLabel = createLabel(auraEditor.rulePanel, "Track all ranks", "WoWraVoxFontNormalSmall")
auraEditor.allRanksLabel:SetPoint("LEFT", auraEditor.allRanksCheck, "RIGHT", 4, 0)

    auraEditor.specFilter = CreateFrame("Frame", nil, auraEditor.rulePanel, "UIDropDownMenuTemplate")
    ns.Layout.setDropdownWidth(auraEditor.specFilter, 138)
    auraEditor.specFilterLabel = createLabel(auraEditor.rulePanel, "Specs", "WoWraVoxFontNormalSmall")
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
ns.Skin.Register(auraEditor.specFilter, "dropdown")

end

local function buildTriggerControls()
    triggerPanel = CreateFrame("Frame", nil, auraEditor, "BackdropTemplate")
    stylePanel(triggerPanel, 0.07, 0.075, 0.085)
    triggerLabel = makeSectionLabel(triggerPanel, "TRIGGERS", 12, -8, true)
    triggerHelpButton = CreateFrame("Button", nil, triggerPanel)
    triggerHelpButton:SetSize(18, 18)
    triggerHelpButton.label = triggerHelpButton:CreateFontString(nil, "OVERLAY", "WoWraVoxFontNormalSmall")
    triggerHelpButton.label:SetAllPoints()
    triggerHelpButton.label:SetText("?")
    triggerHelpButton.label:SetTextColor(0.75, 0.78, 0.84)
    triggerHelpButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    local trackingLegend = {}
    local trackingLegendText = {}
    for _, key in ipairs({ "direct", "ownCast", "tracked", "available", "unavailable", "unlearned", "unknown" }) do
        local status = AURA_TRACKING_STATUS[key]
        local label = L(status.label)
        trackingLegend[#trackingLegend + 1] = { text = label, r = status.color[1], g = status.color[2], b = status.color[3] }
        local hex = string.format("%02x%02x%02x", math.floor(status.color[1] * 255 + 0.5),
            math.floor(status.color[2] * 255 + 0.5), math.floor(status.color[3] * 255 + 0.5))
        trackingLegendText[#trackingLegendText + 1] = "|cff" .. hex .. label .. "|r"
    end
    addHelpTooltip(triggerHelpButton, "Effect status colors",
        "Each trigger row shows its combat tracking status. The legend at the bottom maps colors to statuses. The action button on CDM rows opens settings or a setup prompt.",
        trackingLegend)
    triggerLegendLine = triggerPanel:CreateFontString(nil, "OVERLAY", "WoWraVoxFontHighlightSmall")
    triggerLegendLine:SetPoint("BOTTOMLEFT", triggerPanel, "BOTTOMLEFT", ns.Layout.PAD, 7)
    triggerLegendLine:SetPoint("RIGHT", triggerPanel, "RIGHT", ns.Layout.RIGHT, 0)
    triggerLegendLine:SetHeight(14)
    triggerLegendLine:SetJustifyH("LEFT")
    triggerLegendLine:SetWordWrap(false)
    triggerLegendLine:SetMaxLines(1)
    triggerLegendLine:SetText(L("Tracking colors:") .. " " .. table.concat(trackingLegendText, " |cff8c929a·|r "))
    triggerLegendLine:Hide()
    triggerInputBox = createEditBox(triggerPanel, 300, 24)
    triggerInputBox.searchIcon = triggerInputBox:CreateTexture(nil, "ARTWORK")
    triggerInputBox.searchIcon:SetSize(14, 14)
    triggerInputBox.searchIcon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    triggerInputBox:SetMaxLetters(180)
    triggerPlaceholder = createLabel(triggerPanel, "Spell ID recommended; name search may be incomplete", "GameFontDisableSmall")
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
    -- An exact name with several IDs goes through Add, which adds all of them.
    local exactResult = triggerAddButton.exactResult
    if exactResult and exactResult.query == trim(self:GetText()) and exactResult.rule == selectedAura()
        and exactResult.generation == searchGeneration then
        triggerAddButton:Click()
        return
    end
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
    if selectedAura() and not ns.AuraPresetUI.creationActive then layoutSharedEditor(true) end
end)
triggerAddButton = CreateFrame("Button", nil, triggerPanel, "UIPanelButtonTemplate")
triggerAddButton:SetSize(80, 24)
triggerAddButton:SetText(L("Add"))
triggerAddButton:SetEnabled(false)
triggerAddButton:SetScript("OnClick", function()
    if selectedItem() then
        -- Item rules: "Add item" opens the picker for one more member (or fills the starter rule).
        saveDetails()
        if ns.BeginItemPicker then
            ns.BeginItemPicker(nil, nil, not ns.isEmptyStarter(selectedItemRule) and selectedItemRule or nil)
        end
        return
    end
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
        addTriggerIDs(exactResult.ids or { exactResult.id })
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
ns.Skin.Register(triggerAddButton, "button")
triggerStatus = createLabel(triggerPanel, "", "WoWraVoxFontNormalSmall")
auraEditor.batchSealsButton = CreateFrame("Button", nil, triggerPanel, "UIPanelButtonTemplate")
auraEditor.batchSealsButton:SetSize(104, 22)
auraEditor.batchSealsButton:SetText(L("Add all Seals"))
local _, playerClass = UnitClass("player")
auraEditor.isPaladin = playerClass == "PALADIN"
auraEditor.batchSealsButton:SetShown(false)
auraEditor.batchSealsButton:SetScript("OnClick", function()
    local rule = selectedAura()
    if not rule or rule.builtin == true then return end
    local locale = GetLocale and GetLocale() or ""
    local filter = locale ~= "enUS" and locale ~= "deDE" and trim(triggerInputBox:GetText()) or nil
    local added, status, familyRuleID = ns.syncAuraTrackerSeals(filter, true)
    if familyRuleID then
        for _, candidate in ipairs(WoWraVoxDB and WoWraVoxDB.auras or {}) do
            if tostring(candidate.id) == tostring(familyRuleID) then
                selectRule(candidate, "auras")
                break
            end
        end
    end
    local message = status == "partially-mapped" and "Seal family added; some mappings await Blizzard CDM evidence."
        or status == "ready" and added == 0 and "All matching Seals are already added."
        or status == "ready" and string.format(L("Added %d seal candidates."), added)
        or status == "unmapped-until-cdm" and "Seal candidates saved; aura mapping waits for Blizzard CDM evidence."
        or status == "manual-filter-required" and "Enter a localized name filter first."
        or status == "paladin-only" and "All Seals is available only to Paladins."
        or status == "combat-or-unavailable" and "Add all Seals after combat."
        or status == "no-candidates" and "No matching learned Seals found."
        or string.format(L("Added %d seal candidates."), added)
    triggerStatus:SetText(L(message))
    triggerStatus:SetTextColor(status == "ready" and 0.72 or 1,
        status == "ready" and 0.78 or 0.72, status == "ready" and 0.86 or 0.3)
end)
ns.Skin.Register(auraEditor.batchSealsButton, "button")
addHelpTooltip(auraEditor.batchSealsButton, L("Add all Seals"),
    L("Collect all learned Seals into one tracker family. Aura IDs require Blizzard CDM evidence."))
triggerScroll = CreateFrame("ScrollFrame", nil, triggerPanel, "UIPanelScrollFrameTemplate")
triggerScroll.backdrop = triggerPanel
triggerChild = CreateFrame("Frame", nil, triggerScroll)
triggerChild:SetSize(1, 1)
triggerScroll:SetScrollChild(triggerChild)
triggerScroll:HookScript("OnSizeChanged", function(self, width)
    triggerChild:SetWidth(math.max(1, width - 4))
    updateSelectedTriggers()
    ns.updateItemMembers()
end)
ns.Skin.Register(triggerScroll, "scrollTrack")
ns.Skin.Register(triggerScroll, "scrollThumb")
itemSourceText = createLabel(auraEditor, "", "WoWraVoxFontNormalSmall")

end

local function createScreenChoiceDropdown(parent, width, choices, valueOf, textOf, onChange)
    local dropdown = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
    ns.Layout.setDropdownWidth(dropdown, width)
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
    ns.Skin.Register(dropdown, "dropdown")
    return dropdown
end

local function buildScreenRow(parent, labelText, y, eventKey)
    local row = {}
    row.eventKey = eventKey
    row.enabled = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    row.label = createLabel(parent, labelText, "WoWraVoxFontNormalSmall")
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
    ns.Skin.Register(row.color, "swatchFrame")
    ns.Skin.Register(row.preview, "button")
    ns.Skin.Register(row.anchor, "button")
    return row
end

-- Heading row of a panel (needs panel.frame, .heading, .key, .collapsible): the whole 34 px row is the click
-- target, chevron at PAD, grey hint on the right. Only collapsible panels (Application, Expiration, TTS) show it
-- and get the skin header art; the Ready panel builds it hidden. Create it before the panel's controls so they
-- stay on top of the row.
ns.Layout.buildPanelHeader = function(panel, title)
    panel.headerButton = CreateFrame("Button", nil, panel.frame)
    panel.headerButton:SetPoint("TOPLEFT", panel.frame, "TOPLEFT", 0, 0)
    panel.headerButton:SetPoint("TOPRIGHT", panel.frame, "TOPRIGHT", 0, 0)
    panel.headerButton:SetHeight(34)
    panel.headerButton:SetFrameLevel(panel.frame:GetFrameLevel() + 1)
    panel.headerButton:SetHighlightTexture("Interface\\Buttons\\WHITE8X8", "ADD")
    panel.headerButton:GetHighlightTexture():SetAlpha(0.07)
    panel.headerIndicator = panel.headerButton:CreateTexture(nil, "ARTWORK")
    panel.headerIndicator:SetSize(16, 16)
    panel.headerIndicator:SetPoint("LEFT", panel.headerButton, "LEFT", ns.Layout.PAD, 0)
    panel.headerHint = panel.headerButton:CreateFontString(nil, "OVERLAY", "WoWraVoxFontHighlightSmall")
    panel.headerHint:SetPoint("RIGHT", panel.headerButton, "RIGHT", ns.Layout.RIGHT, 0)
    panel.headerHint:SetTextColor(0.6, 0.6, 0.62)
    if panel.collapsible and ns.Skin.Data() then
        -- the header art (child frame) would cover a heading that belongs to panel.frame
        panel.heading:SetParent(panel.headerButton)
    end
    if panel.collapsible then
        ns.Skin.Register(panel.headerButton, "panelHeader")
        ns.Skin.Register(panel.headerIndicator, "chevron")
    end
    ns.Layout.refreshPanelHeader(panel)
    panel.headerButton:SetScript("OnClick", function()
        if not panel.collapsible then return end
        ns.Layout.setPanelExpanded(panel, not ns.Layout.isPanelExpanded(panel))
        if panel.ttsEnabled then ns.setNotificationPanelShown(panel, true) end
        layoutSharedEditor(selectedCategory == "auras")
    end)
    addHelpTooltip(panel.headerButton, title, "Click to expand or collapse this panel.")
end

-- A finished rank scan (SpellRanks.lua) can add IDs to watch: rebuild and re-read the current auras.
if ns.SpellRanks then
    ns.SpellRanks.OnScanned(function()
        rebuildAuraWatches()
        syncAllAuras(true)
        if updateDetails and selectedCategory == "auras" then pcall(updateDetails) end
    end)
end

local function buildAuraNotificationPanel(eventKey, title)
    local panel = {}
    panel.eventKey = eventKey
    panel.key = eventKey
    panel.collapsible = eventKey ~= "ready"
    panel.expanded = true
    panel.frame = CreateFrame("Frame", nil, auraEditor, "BackdropTemplate")
    panel.frame:SetHeight(162)
    stylePanel(panel.frame, 0.09, 0.095, 0.105)
    panel.heading = makeSectionLabel(panel.frame, title, 12, -8)
    ns.Layout.buildPanelHeader(panel, title)
    if false and eventKey == "beforeExpire" then -- positions are edited on the timeline now
        panel.warningLabel = createLabel(panel.frame, L("Warn at remaining duration"), "WoWraVoxFontNormalSmall")
        panel.warningValue = createLabel(panel.frame, "5%", "WoWraVoxFontHighlightSmall")
        panel.warningPercent = makeVolumeSlider(panel.frame, "TOPLEFT", panel.frame, ns.Layout.FIELD_X, -108,
            function(value)
                panel.warningPercentEdited = true
                panel.warningValue:SetText(tostring(value) .. "%")
                saveDetails()
            end, 0, 100, 1, 180)
        addHelpTooltip(panel.warningPercent, L("Early warning"),
            L("0% warns just before expiry; 100% warns at application. Enable TTS, Sound, or on-screen text below. Percentage warnings need readable duration and expiration."))
    end

    panel.ttsEnabled = CreateFrame("CheckButton", nil, panel.frame, "UICheckButtonTemplate")
    panel.ttsLabel = createLabel(panel.frame, "TTS", "WoWraVoxFontNormal")
    panel.ttsMessage = createEditBox(panel.frame, 300, 24)
    panel.ttsTest = CreateFrame("Button", nil, panel.frame, "UIPanelButtonTemplate")
    panel.ttsTest:SetSize(72, 24)
    panel.ttsTest:SetText(L("Test"))

    panel.soundEnabled = CreateFrame("CheckButton", nil, panel.frame, "UICheckButtonTemplate")
    panel.soundLabel = createLabel(panel.frame, "Sound", "WoWraVoxFontNormal")
    panel.soundChoice = createScreenChoiceDropdown(panel.frame, 140, NOTIFICATION_SOUND_CHOICES,
        function(choice) return choice.kind == "media" and choice.value or choice.soundKitID end,
        notificationSoundChoiceText,
        function(value)
            panel.soundChoice.screenValue = value
            saveDetails()
        end)
    panel.soundChannel = createScreenChoiceDropdown(panel.frame, 108, NOTIFICATION_SOUND_CHANNELS,
        function(choice) return choice.value end,
        function(choice) return L(choice.key) end,
        function(value)
            panel.soundChannel.screenValue = value
            saveDetails()
        end)
    panel.soundTest = CreateFrame("Button", nil, panel.frame, "UIPanelButtonTemplate")
    panel.soundTest:SetSize(56, 24)
    panel.soundTest:SetText(L("Test"))
    panel.soundTest:SetScript("OnClick", function()
        saveDetails()
        local rule = selectedRule()
        if rule and ns.playNotificationSound(rule, panel.eventKey) then
            setStatus("Sound test sent to WoW. Check audio in game.")
        else
            setStatus("Sound test could not be sent to WoW.", true)
        end
    end)
    ns.Skin.Register(panel.ttsTest, "button")
    ns.Skin.Register(panel.soundTest, "button")
    if eventKey == "apply" or eventKey == "expire" then
        panel.combatHint = createLabel(panel.frame, "Combat: hidden effects may use the configured category instead of your text.", "WoWraVoxFontHighlightSmall")
        panel.combatHint:SetJustifyH("LEFT")
        panel.combatHint:SetTextColor(0.72, 0.72, 0.72)
        panel.combatHint:SetWordWrap(true)
        panel.categoryLabel = createLabel(panel.frame,
            eventKey == "apply" and L("Application category") or L("Expiration category"), "WoWraVoxFontNormalSmall")
        panel.categoryChoice = createScreenChoiceDropdown(panel.frame, 142, NOTIFICATION_CUE_CHOICES,
            function(choice) return choice.value end,
            function(choice)
                if choice.value == "none" then return ns._Aura.noneCueLabel(selectedRule(), eventKey) end
                return L(choice.label)
            end,
            function(value)
                panel.categoryChoice.screenValue = value
                saveDetails()
                rebuildAuraWatches()
                syncAllAuras(true)
            end)
        if eventKey == "apply" then
            addHelpTooltip(panel.categoryChoice, "Application category", "Choose a category sound for this effect. It can announce effects hidden in combat, when custom text is unavailable. A registered category sound replaces custom text without a duplicate announcement. Per effect uses each preset effect's own category.")
        else
            addHelpTooltip(panel.categoryChoice, "Expiration category", "Choose the category sound for expiration independently of application. Native category sounds require successful registration. Not used by rules that treat their triggers as one effect.")
        end
    end
    if eventKey == "apply" or eventKey == "expire" then
        addHelpTooltip(panel.ttsMessage, "Spoken text", nil, {
            { text = "Type {spell} to say the name of the aura that triggered.", font = { "Fonts\\ARIALN.TTF", 13, "" } },
        })
    end
    panel.screen = buildScreenRow(panel.frame, "On-screen text", -89, eventKey)
    ns.screenControls[eventKey] = panel.screen
    ns.notificationPanels[eventKey] = panel
    return panel
end

do
-- Timeline of an aura rule (Markers.lua): a line 0..100 % with one diamond per node, tabs (Start, 1, 2, ..., End)
-- underneath. Click a diamond or a tab to edit that node's output below; click the line to add a node; drag inner
-- nodes; give a node its timing as a percentage, seconds after the start or seconds before the end.
local timeline = {}
ns.timeline = timeline

local ANCHOR_CHOICES = {
    { value = "percent", label = "Percent of the duration", unit = "%" },
    { value = "start", label = "Seconds after start", unit = "s after start" },
    { value = "end", label = "Seconds before end", unit = "s before end" },
}

function ns.SelectedMarkerKey(rule)
    rule = rule or selectedAura()
    if rule and type(rule.markers) == "table" then
        for _, marker in ipairs(rule.markers) do
            if marker.key == selectedMarkerKey then return selectedMarkerKey end
        end
    end
    selectedMarkerKey = "apply"
    return selectedMarkerKey
end

function ns.SelectMarker(key)
    if key == selectedMarkerKey then return end
    saveDetails()
    selectedMarkerKey = key
    updateDetails()
end

local function timelineDuration(rule)
    if not (rule and ns.MarkerTimers) then return nil, true end
    local spellID = rule.spellIDs and rule.spellIDs[1]
    return ns.MarkerTimers.DurationFor(rule, spellID, nil, ns.learnedDurations and ns.learnedDurations())
end
ns.timelineDuration = timelineDuration

local function formatNumber(value)
    if not value then return "" end
    local text = string.format("%.2f", value):gsub("0+$", ""):gsub("%.$", "")
    return text
end

-- Inner nodes are numbered 1, 2, 3 ... from left to right; the number is shown on the line, the tab and the title.
local function markerNumber(rule, key)
    local n = 0
    for _, marker in ipairs(rule and rule.markers or {}) do
        if not ns.Markers.IsEndpoint(marker.key) then
            n = n + 1
            if marker.key == key then return n end
        end
    end
end
ns.markerNumber = markerNumber

local function timingText(marker)
    return ns.Markers.TimingText(marker, formatNumber)
end

local function markerTitle(marker, rule)
    if marker.key == "apply" then return L("Start") end
    if marker.key == "expire" then return L("End") end
    local number = markerNumber(rule or selectedAura(), marker.key)
    return L("Node") .. " " .. tostring(number or "?") .. "  ·  " .. timingText(marker)
end
ns.markerTitle = markerTitle

local function findMarker(rule, key)
    for _, marker in ipairs(rule and rule.markers or {}) do
        if marker.key == key then return marker end
    end
end
ns.findMarker = findMarker

local function applyTiming(anchor)
    local rule = selectedAura()
    if not rule or editorLoading then return end
    local key = ns.SelectedMarkerKey(rule)
    if ns.Markers.IsEndpoint(key) then return end
    local value = tonumber((timeline.valueBox:GetText():gsub(",", ".")))
    local selectedNode = findMarker(rule, key)
    local current = selectedNode and selectedNode.anchor or "percent"
    -- Switching the anchor keeps the spot on the line: the value is recomputed, not reused.
    if anchor and anchor ~= current then value = nil end
    ns.Markers.SetTiming(rule, key, anchor or current, value, timelineDuration(rule))
    updateDetails()
end

local function applyDurationOverride()
    local rule = selectedAura()
    if not rule or editorLoading then return end
    local value = tonumber((timeline.durationBox:GetText():gsub(",", ".")))
    rule.durationOverride = value and value > 0 and value or nil
    updateDetails()
end

local function addNodeAt(rule, at)
    saveDetails()
    local key = ns.Markers.Add(rule, at)
    rule[key .. "Enabled"] = true
    rule[key .. "Message"] = ""
    ns.normalizeNotificationSettings(rule, "auras")
    selectedMarkerKey = key
    updateDetails()
end

local function buildTimelinePanel()
    local frame = CreateFrame("Frame", nil, auraEditor, "BackdropTemplate")
    frame:SetHeight(166)
    stylePanel(frame, 0.09, 0.095, 0.105)
    timeline.frame = frame
    timeline.heading = makeSectionLabel(frame, L("Timeline"), 12, -8)

    local track = CreateFrame("Frame", nil, frame)
    track:SetHeight(34)
    timeline.track = track
    -- Clicking the line itself adds a node at that spot.
    track:EnableMouse(true)
    track:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        local rule = selectedAura()
        local left, width = self:GetLeft(), self:GetWidth()
        if not (rule and left and width and width > 0) then return end
        local x = GetCursorPosition() / self:GetEffectiveScale()
        addNodeAt(rule, ns.Markers.ClampInner(math.floor((x - left) / width * 1000 + 0.5) / 10))
    end)
    addHelpTooltip(track, "Timeline", "Click the line to add a node there. Drag a node to move it. Click a selected node again to remove it.")
    StaticPopupDialogs["WOWRAVOX_REMOVE_NODE"] = StaticPopupDialogs["WOWRAVOX_REMOVE_NODE"] or {
        text = L("Remove %s?"),
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function(_, data)
            if not (data and data.rule) then return end
            if ns.Markers.Remove(data.rule, data.key) then
                ns.normalizeNotificationSettings(data.rule, "auras")
                if selectedMarkerKey == data.key then selectedMarkerKey = "apply" end
                updateDetails()
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    local line = track:CreateTexture(nil, "BACKGROUND")
    line:SetColorTexture(0.35, 0.29, 0.18, 0.95)
    line:SetHeight(6)
    line:SetPoint("LEFT", track, "LEFT", 0, 0)
    line:SetPoint("RIGHT", track, "RIGHT", 0, 0)
    timeline.handles = {}
    timeline.tabs = {}
    -- The tabs switch what the output panel below shows, so they sit on that panel's top edge.
    timeline.tabBar = CreateFrame("Frame", nil, auraEditor)
    timeline.tabBar:SetHeight(30)

    timeline.addButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    timeline.addButton:SetSize(120, 24)
    timeline.addButton:SetText("+ " .. L("New node"))
    timeline.addButton:SetScript("OnClick", function()
        local rule = selectedAura()
        if rule then addNodeAt(rule, 90) end
    end)
    timeline.removeButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    timeline.removeButton:SetSize(120, 24)
    timeline.removeButton:SetText(L("Remove node"))
    timeline.removeButton:SetScript("OnClick", function()
        local rule = selectedAura()
        if not rule then return end
        local key = ns.SelectedMarkerKey(rule)
        StaticPopup_Show("WOWRAVOX_REMOVE_NODE", markerTitle(findMarker(rule, key) or { key = key, at = 0 }, rule),
            nil, { rule = rule, key = key })
    end)
    ns.Skin.Register(timeline.addButton, "button")
    ns.Skin.Register(timeline.removeButton, "button")

    timeline.timingLabel = createLabel(frame, "Timing", "WoWraVoxFontNormal")
    timeline.anchorChoice = createScreenChoiceDropdown(frame, 190, ANCHOR_CHOICES,
        function(choice) return choice.value end,
        function(choice) return L(choice.label) end,
        function(value) applyTiming(value) end)
    timeline.valueBox = createEditBox(frame, 70, 28)
    timeline.valueUnit = createLabel(frame, "%", "WoWraVoxFontHighlight")
    timeline.durationLabel = createLabel(frame, "Duration", "WoWraVoxFontNormal")
    timeline.durationBox = createEditBox(frame, 70, 28)
    timeline.durationHint = createLabel(frame, "", "WoWraVoxFontHighlight")
    timeline.durationHint:SetTextColor(0.72, 0.72, 0.72)
    for _, box in ipairs({ timeline.valueBox, timeline.durationBox }) do box:SetMaxLetters(10) end
    timeline.valueBox:HookScript("OnEditFocusLost", function() applyTiming(nil) end)
    timeline.durationBox:HookScript("OnEditFocusLost", applyDurationOverride)
    addHelpTooltip(timeline.addButton, "New node", "Adds a notification moment between start and end. Drag it on the line or type its position.")
    addHelpTooltip(timeline.removeButton, "Remove node", "Removes the selected node. Start and end stay; switch their outputs off instead.")
    addHelpTooltip(timeline.anchorChoice, "Timing", "Percent of the duration, seconds after the start (works without a known duration) or seconds before the end (needs a duration).")
    addHelpTooltip(timeline.valueBox, "Timing", "Percent or seconds, depending on the timing on the left. Decimals allowed.")
    addHelpTooltip(timeline.durationBox, "Duration", "Duration in seconds. Empty uses the last readable duration of this effect. In combat a hidden duration is estimated from it; the end (100 %) always waits for the real end of the effect.")
end

local function handleFor(index)
    local handle = timeline.handles[index]
    if handle then return handle end
    handle = CreateFrame("Button", nil, timeline.track)
    handle:SetSize(28, 28)
    handle.border = handle:CreateTexture(nil, "ARTWORK", nil, 1)
    handle.border:SetTexture("Interface\\Buttons\\WHITE8X8")
    handle.border:SetSize(20, 20)
    handle.border:SetPoint("CENTER")
    handle.border:SetRotation(math.rad(45))
    handle.tex = handle:CreateTexture(nil, "ARTWORK", nil, 2)
    handle.tex:SetTexture("Interface\\Buttons\\WHITE8X8")
    handle.tex:SetSize(16, 16)
    handle.tex:SetPoint("CENTER")
    handle.tex:SetRotation(math.rad(45))
    handle.number = handle:CreateFontString(nil, "OVERLAY", "WoWraVoxFontNormal")
    handle.number:SetPoint("CENTER", 0, 0)
    handle.number:SetTextColor(0.05, 0.05, 0.05)
    handle.label = handle:CreateFontString(nil, "OVERLAY", "WoWraVoxFontHighlight")
    handle.label:SetPoint("TOP", handle, "BOTTOM", 0, -2)
    handle:RegisterForClicks("LeftButtonUp")
    -- Press: select (and arm a drag for inner nodes). Release without moving on a node that was already
    -- selected: ask whether to remove it. Release after moving: the node takes the new position.
    handle:SetScript("OnMouseDown", function(self)
        self.wasSelected = self.key == ns.SelectedMarkerKey()
        self.downX = GetCursorPosition()
        self.dragAt, self.moved = nil, false
        ns.SelectMarker(self.key)
        if self.key and not ns.Markers.IsEndpoint(self.key) then self.dragging = true end
    end)
    handle:SetScript("OnMouseUp", function(self)
        local dragging = self.dragging
        self.dragging = false
        local rule = selectedAura()
        if not rule then return end
        if dragging and self.moved and self.dragAt then
            ns.Markers.Move(rule, self.key, math.floor(self.dragAt * 10 + 0.5) / 10, nil, timelineDuration(rule))
            updateDetails()
        elseif self.wasSelected and not ns.Markers.IsEndpoint(self.key) then
            StaticPopup_Show("WOWRAVOX_REMOVE_NODE", markerTitle(findMarker(rule, self.key) or { key = self.key, at = 0 }, rule),
                nil, { rule = rule, key = self.key })
        end
    end)
    handle:SetScript("OnUpdate", function(self)
        if not self.dragging then return end
        if not self.moved and math.abs(GetCursorPosition() - (self.downX or 0)) < 3 then return end
        self.moved = true
        local left, width = timeline.track:GetLeft(), timeline.track:GetWidth()
        if not (left and width and width > 0) then return end
        local x = GetCursorPosition() / timeline.track:GetEffectiveScale()
        local at = ns.Markers.ClampInner((x - left) / width * 100)
        self.dragAt = at
        self:ClearAllPoints()
        self:SetPoint("CENTER", timeline.track, "LEFT", width * at / 100, 0)
        -- Show the value in the node's own timing while dragging.
        local marker = findMarker(selectedAura(), self.key)
        local duration = timelineDuration(selectedAura())
        if marker and marker.anchor == "start" and duration then
            self.label:SetText("+" .. formatNumber(duration * at / 100) .. " s")
        elseif marker and marker.anchor == "end" and duration then
            self.label:SetText("-" .. formatNumber(duration * (100 - at) / 100) .. " s")
        else
            self.label:SetText(formatNumber(at) .. " %")
        end
    end)
    timeline.handles[index] = handle
    return handle
end

local function tabFor(index)
    local tab = timeline.tabs[index]
    if tab then return tab end
    tab = CreateFrame("Button", nil, timeline.tabBar, "BackdropTemplate")
    tab:SetHeight(28)
    tab:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    tab.text = tab:CreateFontString(nil, "OVERLAY", "WoWraVoxFontNormal")
    tab.text:SetPoint("CENTER", 0, 0)
    -- Covers the panel's top border under the active tab, so tab and panel read as one shape.
    tab.join = tab:CreateTexture(nil, "OVERLAY")
    tab.join:SetColorTexture(0.09, 0.095, 0.105, 1)
    tab.join:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 1, 0)
    tab.join:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -1, 0)
    tab.join:SetHeight(7)
    tab:SetScript("OnClick", function(self) ns.SelectMarker(self.key) end)
    tab:SetScript("OnEnter", function(self) if not self.selected then self.text:SetTextColor(1, 1, 1) end end)
    tab:SetScript("OnLeave", function(self) if not self.selected then self.text:SetTextColor(0.62, 0.62, 0.62) end end)
    timeline.tabs[index] = tab
    return tab
end

function ns.refreshTimeline(rule)
    if not timeline.frame then return end
    local duration, estimated = timelineDuration(rule)
    if rule and rule.markers then ns.Markers.Resolve(rule, duration) end
    local markers = rule and rule.markers or {}
    local selected = ns.SelectedMarkerKey(rule)
    local width = math.max(1, timeline.track:GetWidth())
    local previousTab
    for index, marker in ipairs(markers) do
        local endpoint = ns.Markers.IsEndpoint(marker.key)
        local number = not endpoint and markerNumber(rule, marker.key) or nil
        local isSelected = marker.key == selected

        local handle = handleFor(index)
        handle.key = marker.key
        handle:ClearAllPoints()
        handle:SetPoint("CENTER", timeline.track, "LEFT", width * marker.at / 100, 0)
        handle.number:SetText(number and tostring(number) or "")
        local labelText = timingText(marker)
        if marker.anchor == "percent" and duration then
            local seconds = ns.Markers.Seconds(marker, duration)
            if seconds then labelText = labelText .. "  ·  -" .. formatNumber(duration - seconds) .. " s" end
        end
        handle.label:SetText(marker.key == "apply" and L("Start") or marker.key == "expire" and L("End") or labelText)
        if isSelected then
            handle.tex:SetVertexColor(1, 0.82, 0.2)
        elseif endpoint then
            handle.tex:SetVertexColor(0.55, 0.55, 0.55)
        else
            handle.tex:SetVertexColor(0.85, 0.7, 0.35)
        end
        handle.border:SetVertexColor(0.05, 0.04, 0.02, 1)
        -- Start/End labels sit under the line, node labels above it: a node next to an end never covers its label.
        handle.label:ClearAllPoints()
        if endpoint then
            handle.label:SetPoint("TOP", handle, "BOTTOM", 0, -2)
        else
            handle.label:SetPoint("BOTTOM", handle, "TOP", 0, 2)
        end
        local size = endpoint and 12 or 16
        handle.tex:SetSize(size, size)
        handle.border:SetSize(size + 4, size + 4)
        -- Inner nodes always lie above Start/End, so a node next to an end stays clickable.
        handle:SetFrameLevel(timeline.track:GetFrameLevel() + (isSelected and 4 or endpoint and 1 or 2))
        -- Start/End can also be picked by their label under the line (a node may sit on top of their diamond).
        handle:SetHitRectInsets(0, 0, 0, endpoint and -18 or 0)
        handle:Show()

        -- Tabs in line order: Start, 1 · 90 %, 2 · -2 s, ..., End.
        local tab = tabFor(index)
        tab.key, tab.selected = marker.key, isSelected
        tab.text:SetText(marker.key == "apply" and L("Start") or marker.key == "expire" and L("End")
            or (tostring(number) .. "  ·  " .. timingText(marker)))
        tab:SetWidth(math.max(64, tab.text:GetStringWidth() + 32))
        -- Inactive tabs sit on the panel's top edge; the active one is taller, panel-coloured and
        -- runs into the panel (its join strip hides the border below it), like a file-folder tab.
        local sink = isSelected and 7 or 0
        tab:ClearAllPoints()
        tab:SetPoint("BOTTOMLEFT", previousTab or timeline.tabBar, previousTab and "BOTTOMRIGHT" or "BOTTOMLEFT",
            previousTab and 2 or 14, -sink + (previousTab and previousTab.sink or 0))
        tab.sink = sink
        previousTab = tab
        tab:SetHeight((isSelected and 30 or 25) + sink)
        tab.text:ClearAllPoints()
        tab.text:SetPoint("CENTER", tab, "CENTER", 0, sink / 2)
        tab.join:SetShown(isSelected)
        tab:SetFrameLevel(ns.notificationPanels.apply.frame:GetFrameLevel() + (isSelected and 12 or 1))
        tab:SetBackdropColor(isSelected and 0.09 or 0.035, isSelected and 0.095 or 0.037, isSelected and 0.105 or 0.045, 1)
        tab:SetBackdropBorderColor(isSelected and 0.88 or 0.3, isSelected and 0.68 or 0.25, isSelected and 0.24 or 0.16, 1)
        tab.text:SetTextColor(isSelected and 1 or 0.62, isSelected and 0.82 or 0.62, isSelected and 0.2 or 0.62)
        tab:Show()
    end
    for index = #markers + 1, #timeline.handles do timeline.handles[index]:Hide() end
    for index = #markers + 1, #timeline.tabs do timeline.tabs[index]:Hide() end

    local marker = findMarker(rule, selected)
    local nodeSelected = marker ~= nil and not ns.Markers.IsEndpoint(selected)
    if nodeSelected then
        local anchor = marker.anchor or "percent"
        timeline.anchorChoice.screenValue = anchor
        UIDropDownMenu_SetSelectedValue(timeline.anchorChoice, anchor)
        for _, choice in ipairs(ANCHOR_CHOICES) do
            if choice.value == anchor then
                UIDropDownMenu_SetText(timeline.anchorChoice, L(choice.label))
                timeline.valueUnit:SetText(L(choice.unit))
            end
        end
        timeline.valueBox:SetText(formatNumber(anchor == "percent" and marker.at or marker.offset))
    end
    timeline.durationBox:SetText(rule and rule.durationOverride and formatNumber(rule.durationOverride) or "")
    local learnedText
    if rule and rule.durationOverride then
        learnedText = L("set by you")
    elseif duration then
        learnedText = string.format(L("learned: %s s"), formatNumber(duration))
    else
        learnedText = L("unknown until the effect was seen once")
    end
    if duration and estimated then learnedText = learnedText .. " · " .. L("estimated in combat") end
    if nodeSelected and marker.anchor == "end" and not duration then
        learnedText = L("seconds before the end need a duration")
    end
    timeline.durationHint:SetText(learnedText)
    -- The property row belongs to the selected node: shown only for an inner node, never as empty fields.
    for _, region in ipairs({ timeline.timingLabel, timeline.anchorChoice, timeline.valueBox, timeline.valueUnit,
        timeline.durationLabel, timeline.durationBox, timeline.durationHint, timeline.removeButton }) do
        region:SetShown(nodeSelected)
    end
    timeline.frame:SetHeight(nodeSelected and 146 or 108)
end

function ns.layoutTimeline(y)
    local frame = timeline.frame
    if not frame then return 0 end
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", auraEditor, "TOPLEFT", 0, y)
    frame:SetPoint("TOPRIGHT", auraEditor, "TOPRIGHT", 0, y)
    timeline.addButton:ClearAllPoints()
    timeline.addButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", ns.Layout.RIGHT, -6)
    timeline.removeButton:ClearAllPoints()
    timeline.removeButton:SetPoint("RIGHT", timeline.addButton, "LEFT", -8, 0)
    timeline.track:ClearAllPoints()
    timeline.track:SetPoint("TOPLEFT", frame, "TOPLEFT", ns.Layout.PAD + 28, -48)
    timeline.track:SetPoint("TOPRIGHT", frame, "TOPRIGHT", ns.Layout.RIGHT - 28, -48)
    timeline.timingLabel:ClearAllPoints()
    timeline.timingLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", ns.Layout.PAD, -114)
    timeline.anchorChoice:ClearAllPoints()
    timeline.anchorChoice:SetPoint("LEFT", timeline.timingLabel, "RIGHT", -6, -2)
    ns.Layout.setDropdownWidth(timeline.anchorChoice, 190)
    timeline.valueBox:ClearAllPoints()
    timeline.valueBox:SetPoint("LEFT", timeline.anchorChoice, "RIGHT", -4, 2)
    timeline.valueUnit:ClearAllPoints()
    timeline.valueUnit:SetPoint("LEFT", timeline.valueBox, "RIGHT", 6, 0)
    timeline.durationLabel:ClearAllPoints()
    timeline.durationLabel:SetPoint("LEFT", timeline.valueUnit, "RIGHT", 24, 0)
    timeline.durationBox:ClearAllPoints()
    timeline.durationBox:SetPoint("LEFT", timeline.durationLabel, "RIGHT", 10, 0)
    timeline.durationHint:ClearAllPoints()
    timeline.durationHint:SetPoint("LEFT", timeline.durationBox, "RIGHT", 8, 0)
    timeline.durationHint:SetPoint("RIGHT", frame, "RIGHT", ns.Layout.RIGHT, 0)
    timeline.durationHint:SetJustifyH("LEFT")
    frame:Show()
    ns.refreshTimeline(selectedAura())
    return frame:GetHeight()
end
ns.buildTimelinePanel = buildTimelinePanel
end

local function buildMessageControls()
    ns.buildTimelinePanel()
    local applyPanel = buildAuraNotificationPanel("apply", L("Start"))
    local expirePanel = buildAuraNotificationPanel("expire", L("End"))
    buildAuraNotificationPanel("beforeExpire", L("Node"))
    local readyPanel = buildAuraNotificationPanel("ready", "Ready")
    applyEnabledCheck, applyMessageBox, testApplyButton = applyPanel.ttsEnabled, applyPanel.ttsMessage, applyPanel.ttsTest
    expireEnabledCheck, expireMessageBox, testExpireButton = expirePanel.ttsEnabled, expirePanel.ttsMessage, expirePanel.ttsTest
    readyLabel, readyMessageBox, testItemButton = readyPanel.ttsLabel, readyPanel.ttsMessage, readyPanel.ttsTest
    -- Round "?" next to the Ready heading (item rules only): explains the {item}/{slot} wildcards.
    local help = CreateFrame("Button", nil, readyPanel.frame)
    help:SetSize(18, 18)
    help:SetPoint("LEFT", readyPanel.heading, "RIGHT", 8, 0)
    help:SetFrameLevel(readyPanel.headerButton:GetFrameLevel() + 2)
    help.bg = help:CreateTexture(nil, "BACKGROUND")
    help.bg:SetAllPoints(help)
    help.bg:SetColorTexture(0.2, 0.21, 0.25, 1)
    help.mask = help:CreateMaskTexture()
    help.mask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask","CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    help.mask:SetAllPoints(help)
    help.bg:AddMaskTexture(help.mask)
    help.mark = help:CreateFontString(nil, "OVERLAY", "WoWraVoxFontNormalSmall")
    help.mark:SetPoint("CENTER", help, "CENTER", 0, 0)
    help.mark:SetText("?")
    help:Hide()
    -- The default tooltip font draws { } almost like [ ]: lines with braces use Arial Narrow. WoW's standard fonts
    -- have no italics, so the example is set apart by its light-blue colour instead.
    local braceFont = { "Fonts\\ARIALN.TTF", 13, "" }
    addHelpTooltip(help, "Wildcards", nil, {
        { text = "Type them with curly braces: {item} and {slot}.", font = braceFont },
        { text = "{item} - name of the item that became ready", font = braceFont },
        { text = "{slot} - its slot, for example Trinket 1", font = braceFont },
        { text = "Example:", r = 1, g = 0.82, b = 0.2 },
        { text = "{item} ready  =>  Blazebinder's Hoof ready", r = 0.624, g = 0.878, b = 1, font = braceFont },
        { text = "Trinket ready  =>  stays the same", r = 0.624, g = 0.878, b = 1 },
        { text = "Works in the spoken text and the on-screen text." },
    })
    ns.Skin.Register(help, "helpButton", { hide = { help.bg, help.mark } })
    ns.itemHelpButton = help
    -- Source hint ("Choose an equipped item" / "Spellbook · ID n") sits in the Ready heading row, right-aligned.
    itemSourceText:SetParent(readyPanel.frame)
    itemSourceText:SetJustifyH("RIGHT")
    itemSourceText:SetPoint("TOPRIGHT", readyPanel.frame, "TOPRIGHT", ns.Layout.RIGHT, -12)
    itemSourceText:SetWidth(300)
    auraEditor.skillTriggerLabel = createLabel(triggerPanel, "Trigger", "WoWraVoxFontNormalSmall")
    auraEditor.skillTriggerDropdown = CreateFrame("Frame", nil, triggerPanel, "UIDropDownMenuTemplate")
    ns.Layout.setDropdownWidth(auraEditor.skillTriggerDropdown, 180)
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
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    ns.Skin.Register(auraEditor.skillTriggerDropdown, "dropdown")
    auraEditor.skillLearnButton = CreateFrame("Button", nil, triggerPanel, "UIPanelButtonTemplate")
    auraEditor.skillLearnButton:SetSize(ns.Layout.BUTTON_W, 30)
    auraEditor.skillLearnButton:SetText(L("Learn"))
    auraEditor.skillLearnButton:SetScript("OnClick", function()
        if ns.SkillTracking.learning then
            ns.SkillTracking.StopLearning()
        elseif selectedAura() then
            if not ns.SkillTracking.StartAuraLearning(selectedAura()) then
                setStatus(L("Select an aura rule with at least one spell ID before learning."), true)
            end
        elseif not ns.SkillTracking.StartLearning(selectedSkill()) then
            setStatus(L("Select a valid spell rule before learning."), true)
        end
    end)
    ns.Skin.Register(auraEditor.skillLearnButton, "button")
    auraEditor.skillLearningStatus = createLabel(triggerPanel, "", "WoWraVoxFontHighlightSmall")
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
    auraEditor.voice = { key = "voice", collapsible = true, expanded = true, frame = auraEditor.voicePanel, heading = auraEditor.voiceHeading }
    ns.Layout.buildPanelHeader(auraEditor.voice, "TTS")
    auraEditor.voiceLabel = createLabel(auraEditor.voicePanel, "Voice", "WoWraVoxFontNormalSmall")
    voiceDropdown = createVoiceDropdown(auraEditor.voicePanel, "TOPLEFT", auraEditor.voicePanel, 12, -43, function(voiceID)
    local rule = selectedAura() or selectedItem() or selectedSkill()
    if rule then rule.voiceID = voiceID end
    end)
    auraEditor.volumeLabel = createLabel(auraEditor.voicePanel, "Volume", "WoWraVoxFontNormalSmall")
    volumeSlider = makeVolumeSlider(auraEditor.voicePanel, "TOPLEFT", auraEditor.voicePanel, 0, -43, function(value)
    local rule = selectedAura() or selectedItem() or selectedSkill()
    if rule then rule.volume = value; volumeValue:SetText(tostring(value)) end
end)
volumeValue = createLabel(auraEditor.voicePanel, "80", "WoWraVoxFontHighlight")
volumeValue:SetPoint("LEFT", volumeSlider, "RIGHT", 8, 0)
auraEditor.speedLabel = createLabel(auraEditor.voicePanel, "Speech speed", "WoWraVoxFontNormalSmall")
auraEditor.speedSlider = makeVolumeSlider(auraEditor.voicePanel, "TOPLEFT", auraEditor.voicePanel, 0, -43, function(value)
    local rule = selectedAura() or selectedItem() or selectedSkill()
    if rule then rule.speechSpeed = value; auraEditor.speedValue:SetText(tostring(value) .. "%") end
end, 100, 200, 10, 90)
auraEditor.speedValue = createLabel(auraEditor.voicePanel, "100%", "WoWraVoxFontHighlight")
auraEditor.speedValue:SetPoint("LEFT", auraEditor.speedSlider, "RIGHT", 8, 0)
if auraEditor.speedSlider.Low then auraEditor.speedSlider.Low:SetText("100%") end
if auraEditor.speedSlider.High then auraEditor.speedSlider.High:SetText("200%") end
auraEditor.voice.controls = { auraEditor.voiceLabel, voiceDropdown, auraEditor.volumeLabel, volumeSlider, volumeValue,
    auraEditor.speedLabel, auraEditor.speedSlider, auraEditor.speedValue }

end

local function buildCreationView()
creationView = CreateFrame("Frame", nil, detailPanel, "BackdropTemplate")
creationView:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", ns.Layout.MARGIN, -ns.Layout.MARGIN)
creationView:SetPoint("BOTTOMRIGHT", detailPanel, "BOTTOMRIGHT", -ns.Layout.MARGIN, ns.Layout.MARGIN)
    stylePanel(creationView, 0.105, 0.115, 0.13)
    creationView.heading = makeSectionLabel(creationView, "ADD RULE", ns.Layout.PAD, -15)
    creationView.manualPanel = CreateFrame("Frame", nil, creationView, "BackdropTemplate")
    stylePanel(creationView.manualPanel, 0.07, 0.075, 0.085)
    creationView.presetPanel = CreateFrame("Frame", nil, creationView, "BackdropTemplate")
    stylePanel(creationView.presetPanel, 0.07, 0.075, 0.085)
    ns.AuraPresetUI.build(creationView.presetPanel)
    creationView.overviewPanel = CreateFrame("Frame", nil, creationView, "BackdropTemplate")
    stylePanel(creationView.overviewPanel, 0.07, 0.075, 0.085)
    ns.AuraPresetUI.buildOverview(creationView.overviewPanel)
    creationView.manualPanel:Hide()
    creationView.presetPanel:Hide()
    creationView.overviewPanel:Hide()
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
    button.title = createLabel(button, title, "WoWraVoxFontNormal")
    button.title:SetPoint("TOPLEFT", button.icon, "TOPRIGHT", 12, -14)
    button.description = createLabel(button, description, "WoWraVoxFontHighlightSmall")
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
    creationView.importButton = CreateFrame("Button", nil, creationView, "BackdropTemplate")
    styleCreationOption(creationView.importButton, "Interface\\Icons\\INV_Misc_Note_01", "Import", "Paste a group someone shared with you.", -322)
    creationView.importButton:SetScript("OnClick", function() ns.ShareUI.openImport() end)
    -- Paladins: one rule with every learned Seal (the Codex seal family).
    creationView.sealsButton = CreateFrame("Button", nil, creationView, "BackdropTemplate")
    styleCreationOption(creationView.sealsButton, "Interface\\Icons\\Spell_Holy_RighteousnessAura", "All Seals",
        "Paladin: one aura rule with every Seal you know.", -408)
    creationView.sealsButton:SetScript("OnClick", function()
        local added, status, familyRuleID = ns.syncAuraTrackerSeals(nil, true)
        for _, candidate in ipairs(WoWraVoxDB and WoWraVoxDB.auras or {}) do
            if familyRuleID and tostring(candidate.id) == tostring(familyRuleID) then
                selectRule(candidate, "auras")
                break
            end
        end
        if status ~= "ready" and status ~= "partially-mapped" then
            setStatus(status == "combat-or-unavailable" and "Add all Seals after combat."
                or status == "no-candidates" and "No matching learned Seals found."
                or status == "manual-filter-required" and "Enter a localized name filter first."
                or "Seals could not be added.", true)
        end
    end)
    local _, classFile = UnitClass("player")
    creationView.sealsButton:SetShown(classFile == "PALADIN")

    skillSearchBox = createEditBox(creationView, 330, 24)
    skillSearchBox:SetPoint("TOP", creationView, "TOP", 0, -60)
    skillSearchBox:SetMaxLetters(120)
    skillSearchBox:Hide()
    skillSearchStatus = createLabel(creationView, "Type a spell name or ID from your spellbook.", "WoWraVoxFontNormalSmall")
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
    skillSearchPopup.empty = createLabel(skillSearchPopup, "No spellbook matches.", "WoWraVoxFontHighlightSmall")
    skillSearchPopup.empty:SetPoint("CENTER")
    for index = 1, 6 do
        local row = CreateFrame("Button", nil, skillSearchPopup)
        row:SetPoint("TOPLEFT", skillSearchPopup, "TOPLEFT", 5, -4 - (index - 1) * 36)
        row:SetPoint("TOPRIGHT", skillSearchPopup, "TOPRIGHT", -5, -4 - (index - 1) * 36)
        row:SetHeight(34)
        ns.setupSpellSearchRow(row)
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
        creationView.importButton:Hide()
        skillSearchBox:Show()
        skillSearchStatus:Show()
        skillSearchBox:SetFocus()
    end)
    creationView.cancelButton = CreateFrame("Button", nil, creationView, "UIPanelButtonTemplate")
creationView.cancelButton:SetSize(100, 26)
creationView.cancelButton:SetPoint("BOTTOMRIGHT", creationView, "BOTTOMRIGHT", -12, 10)
    creationView.cancelButton:SetText(L("Cancel"))
    creationView.cancelButton:SetScript("OnClick", function()
        ns.CancelAddRuleView()
end)
    ns.Skin.Register(creationView.cancelButton, "button")
    creationView.backButton = CreateFrame("Button", nil, creationView, "UIPanelButtonTemplate")
    creationView.backButton:SetSize(92, 26)
    creationView.backButton:SetPoint("BOTTOMLEFT", creationView, "BOTTOMLEFT", 12, 10)
    creationView.backButton:SetText(L("Back"))
    creationView.backButton:SetScript("OnClick", function()
        ns.AuraPresetUI.finishCreation(true)
        updateDetails()
    end)
    creationView.backButton:Hide()
    ns.Skin.Register(creationView.backButton, "button")
    creationView.createAuraButton = CreateFrame("Button", nil, creationView, "UIPanelButtonTemplate")
    creationView.createAuraButton:SetSize(ns.Layout.BUTTON_W, 26)
    creationView.createAuraButton:SetPoint("RIGHT", creationView.cancelButton, "LEFT", -8, 0)
    creationView.createAuraButton:SetText(L("Create aura"))
    creationView.createAuraButton:SetScript("OnClick", ns.AuraPresetUI.createGroup)
    creationView.createAuraButton:Hide()
    ns.Skin.Register(creationView.createAuraButton, "button")
    creationView:HookScript("OnHide", function()
        if ns.AuraPresetUI.creationActive then ns.AuraPresetUI.finishCreation(true) end
    end)
creationView:Hide()

end

-- Export and import windows for aura groups. The rules live in ShareGroups.lua; this part only draws them.
-- Wrapped in an immediately called function: its helpers are not top-level locals of this chunk (200 limit).
(function()
ns.ShareUI = ns.ShareUI or {}
local shareUI = ns.ShareUI
local IMPORT_ROWS = 12
local TEXT_LINES = 8 -- spoken, screen, sound and category cue for application and expiration
local TEXT_AREA_HEIGHT = 128
local UNKNOWN_SPELL_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local function shareWindow(name, title, width, height)
    local frame = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    frame:SetSize(width, height)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetFrameLevel(50)
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
    frame:SetBackdropColor(0.025, 0.03, 0.04, 0.98)
    frame:SetBackdropBorderColor(0.7, 0.55, 0.2, 1)
    frame:Hide()
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, name) end
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -14)
    frame.title:SetText(title)
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    return frame
end

local function scrollEditBox(parent, width, height)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(GameFontHighlightSmall)
    edit:SetWidth(width)
    edit:SetHeight(height)
    edit:SetTextInsets(4, 4, 4, 4)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(edit)
    return scroll, edit
end

local function buildExportFrame()
    local frame = shareWindow("WoWraVoxExportWindow", L("EXPORT GROUP"), 560, 330)
    frame.hint = frame:CreateFontString(nil, "OVERLAY", "WoWraVoxFontHighlightSmall")
    frame.hint:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 0, -8)
    frame.hint:SetText(L("Copy this text (Ctrl+C) and send it to a friend.") .. "\n"
        .. L("Aura tracker layout and seal-family settings stay local and are not included in shared rules."))
    local scroll, edit = scrollEditBox(frame, 500, 200)
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -58)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -32, 48)
    frame.edit = edit
    local selectAll = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    selectAll:SetSize(110, 26)
    selectAll:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 12)
    selectAll:SetText(L("Select all"))
    selectAll:SetScript("OnClick", function()
        edit:SetFocus()
        edit:HighlightText()
    end)
    ns.Skin.Register(selectAll, "button")
    shareUI.exportFrame = frame
    return frame
end

function shareUI.openExport(rule)
    local ok, text = ns.ShareGroups.Export(rule)
    if not ok then
        setStatus(text, true)
        return
    end
    local frame = shareUI.exportFrame or buildExportFrame()
    frame.edit:SetText(text)
    frame.edit:SetHeight(math.max(200, math.ceil(#text / 60) * 14))
    frame.edit:SetCursorPosition(0)
    frame:Show()
    frame.edit:SetFocus()
    frame.edit:HighlightText()
end

-- The item rule constructor, for ShareGroups.ToItemRules (newItemRule is a local of this file).
ns.newItemRule = newItemRule

-- A trinket rule: its first member tracks a trinket slot (13 or 14).
local function isTrinketRule(rule)
    local first = type(rule) == "table" and ns.itemMembers(rule)[1] or nil
    return type(first) == "table" and (first.slotID == 13 or first.slotID == 14)
end

-- What Ctrl-click on an item rule shares: every trinket rule (WoWraVoxDB.items, at most MAX_SHARED_ITEMS, the clicked
-- one always among them) when the clicked rule is a trinket rule, otherwise only the clicked rule.
local MAX_SHARED_ITEMS = 8
function shareUI.groupForRule(rule)
    if not isTrinketRule(rule) then return { rule } end
    local group, included = {}, false
    local items = type(WoWraVoxDB) == "table" and type(WoWraVoxDB.items) == "table" and WoWraVoxDB.items or {}
    for _, other in ipairs(items) do
        if #group < MAX_SHARED_ITEMS and isTrinketRule(other) then
            group[#group + 1] = other
            if other == rule then included = true end
        end
    end
    if not included then group[math.min(#group + 1, MAX_SHARED_ITEMS)] = rule end
    return group
end

-- Ctrl-click on an aura group or item rule row. The export text stays in memory; only the short marker goes into
-- the chat box.
function shareUI.postToChat(rule)
    local ok, text, name
    if type(rule.members) == "table" then
        local group = shareUI.groupForRule(rule)
        ok, text = ns.ShareGroups.ExportItems(group)
        name = #group > 1 and L("Trinkets") or rule.name
    else
        ok, text = ns.ShareGroups.Export(rule)
        name = rule.name
    end
    if not ok then
        setStatus(text == "builtin" and "Built-in rules cannot be shared." or text, true)
        return
    end
    if not ns.ShareChat then return end
    ns.ShareChat.SendToChat(text, name)
end

local function importRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(520, 18)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * 18))
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.text = row:CreateFontString(nil, "OVERLAY", "WoWraVoxFontHighlightSmall")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.text:SetWidth(490) -- a long item rule name is cut ("...") instead of running out of the window
    row.text:SetWordWrap(false)
    row.text:SetJustifyH("LEFT")
    row:Hide()
    return row
end

local function clearPreview(frame)
    frame.summary:SetText("")
    frame.effects:SetText("")
    for _, line in ipairs(frame.notes) do line:SetText("") end
    for _, row in ipairs(frame.rows) do row:Hide() end
    frame.more:SetText("")
    for _, line in ipairs(frame.textLines) do line:SetText("") end
end

-- Texts the group speaks or shows. Label grey, text white; "||" is stored and shown as one "|" by the font.
-- Each text wraps to the window width. The scroll area keeps the window layout fixed and shows long texts in full.
local function showTexts(frame, texts)
    local total = 0
    for index, line in ipairs(frame.textLines) do
        local entry = texts[index]
        if entry then
            line:SetText("|cff9a9a9a" .. entry.label .. ":|r |cffffffff" .. entry.text .. "|r")
            total = total + line:GetStringHeight() + (index > 1 and 4 or 0)
        else
            line:SetText("")
        end
    end
    frame.textChild:SetHeight(math.max(TEXT_AREA_HEIGHT, total + 4))
end

local function showPreview(frame, preview)
    frame.summary:SetText(L("Name") .. ": " .. (preview.name ~= "" and preview.name or L("New aura group")))
    frame.effects:SetText(string.format(L("%d effects"), preview.effects))
    for index, line in ipairs(frame.notes) do line:SetText(preview.notes[index] or "") end
    for index, row in ipairs(frame.rows) do
        local data = preview.rows[index]
        if data then
            row.icon:SetTexture(data.icon or UNKNOWN_SPELL_ICON)
            if data.known then
                row.text:SetText(string.format("%s · %d", data.name, data.spellID))
                row.text:SetTextColor(0.9, 0.9, 0.9)
            else
                row.text:SetText(string.format("%s · %s", string.format(L("Spell ID %d"), data.spellID), L("Unknown spell")))
                row.text:SetTextColor(1, 0.35, 0.25)
            end
            row:Show()
        else
            row:Hide()
        end
    end
    local hidden = #preview.rows - IMPORT_ROWS
    frame.more:SetText(hidden > 0 and string.format(L("+ %d more"), hidden) or "")
    showTexts(frame, preview.texts or {})
end

-- One row per member, entry by entry (the entry name in front unless the row already says it), then what each
-- rule will say. An item the client has no name for yet is shown as "Item <id>" in yellow, not as an error.
local function showItemPreview(frame, preview)
    local lines, members = {}, 0
    for _, entry in ipairs(preview.entries) do
        for _, member in ipairs(entry.members) do
            members = members + 1
            local text = member.itemName or member.slotName or ""
            if member.slotName and member.itemName then text = member.slotName .. " · " .. member.itemName end
            if not text:find(entry.name, 1, true) then text = entry.name .. " · " .. text end
            lines[#lines + 1] = { text = text, icon = member.icon, known = member.known }
        end
    end
    frame.summary:SetText(L("Item rules") .. ": " .. #preview.entries)
    frame.effects:SetText(members == 1 and L("1 item") or string.format(L("%d items"), members))
    for index, line in ipairs(frame.notes) do line:SetText(preview.notes[index] or "") end
    for index, row in ipairs(frame.rows) do
        local data = lines[index]
        if data then
            row.icon:SetTexture(data.icon or UNKNOWN_SPELL_ICON)
            row.text:SetText(data.text)
            if data.known then row.text:SetTextColor(0.9, 0.9, 0.9) else row.text:SetTextColor(1, 0.82, 0.2) end
            row:Show()
        else
            row:Hide()
        end
    end
    frame.more:SetText(#lines > IMPORT_ROWS and string.format(L("+ %d more"), #lines - IMPORT_ROWS) or "")
    local texts = {}
    for _, entry in ipairs(preview.entries) do
        if entry.message ~= "" then texts[#texts + 1] = { label = entry.name, text = entry.message } end
    end
    showTexts(frame, texts)
end

local function refreshImportButtons(frame)
    frame.importButton:SetEnabled(ns.ShareGroups.CanImport(frame.preview, frame.edit:GetText()))
end

local function runCheck(frame)
    local preview, errorKey = ns.ShareGroups.Check(frame.edit:GetText())
    frame.preview = preview
    if preview then
        frame.error:SetText(L("Check passed. Click Import to add the group."))
        frame.error:SetTextColor(0.55, 0.86, 0.62)
        if preview.kind == "item-group" then showItemPreview(frame, preview) else showPreview(frame, preview) end
    else
        frame.error:SetText(L(errorKey))
        frame.error:SetTextColor(1, 0.35, 0.25)
        clearPreview(frame)
    end
    refreshImportButtons(frame)
end

local function runImport(frame)
    local preview = frame.preview
    if not ns.ShareGroups.CanImport(preview, frame.edit:GetText()) then
        refreshImportButtons(frame)
        return
    end
    if preview.kind == "item-group" then
        -- Every entry becomes its own new item rule; nothing existing is touched.
        local rules = ns.ShareGroups.ToItemRules(preview.group)
        if #rules == 0 then
            refreshImportButtons(frame)
            return
        end
        if ns.AuraPresetUI and ns.AuraPresetUI.creationActive then ns.AuraPresetUI.finishCreation(true) end
        for _, newRule in ipairs(rules) do
            ns.registerNewRule(newRule, "items")
            table.insert(WoWraVoxDB.items, newRule)
        end
        frame:Hide()
        ns.queueItemScan(0.1)
        refreshList()
        updateDetails()
        selectRule(rules[1], "items")
        setStatus("Items imported.")
        return
    end
    local rule = ns.ShareGroups.ToRule(preview.group, preview.meta)
    if ns.AuraPresetUI and ns.AuraPresetUI.creationActive then ns.AuraPresetUI.finishCreation(true) end
    ns.registerNewRule(rule, "auras")
    table.insert(WoWraVoxDB.auras, rule)
    frame:Hide()
    rebuildAuraWatches()
    syncAllAuras(true)
    selectRule(rule, "auras")
    setStatus("Group imported.")
end

local function buildImportFrame()
    local frame = shareWindow("WoWraVoxImportWindow", L("IMPORT GROUP"), 560, 702)
    frame.hint = frame:CreateFontString(nil, "OVERLAY", "WoWraVoxFontHighlightSmall")
    frame.hint:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 0, -8)
    frame.hint:SetText(L("Paste a group text here, then click Check. Import always creates a new group."))
    local scroll, edit = scrollEditBox(frame, 500, 90)
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -58)
    scroll:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -32, -58)
    scroll:SetHeight(90)
    frame.edit = edit
    frame.error = frame:CreateFontString(nil, "OVERLAY", "WoWraVoxFontNormalSmall")
    frame.error:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 2, -6)
    frame.error:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
    frame.error:SetJustifyH("LEFT")
    frame.summary = frame:CreateFontString(nil, "OVERLAY", "WoWraVoxFontNormal")
    frame.summary:SetPoint("TOPLEFT", frame.error, "BOTTOMLEFT", 0, -14)
    frame.effects = frame:CreateFontString(nil, "OVERLAY", "WoWraVoxFontHighlightSmall")
    frame.effects:SetPoint("TOPLEFT", frame.summary, "BOTTOMLEFT", 0, -4)
    frame.notes = {}
    local anchor = frame.effects
    for index = 1, 3 do
        local line = frame:CreateFontString(nil, "OVERLAY", "WoWraVoxFontHighlightSmall")
        line:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -3)
        line:SetTextColor(1, 0.35, 0.25)
        frame.notes[index] = line
        anchor = line
    end
    local rowsHolder = CreateFrame("Frame", nil, frame)
    rowsHolder:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8)
    rowsHolder:SetSize(520, IMPORT_ROWS * 18)
    frame.rows = {}
    for index = 1, IMPORT_ROWS do frame.rows[index] = importRow(rowsHolder, index) end
    frame.more = frame:CreateFontString(nil, "OVERLAY", "WoWraVoxFontHighlightSmall")
    frame.more:SetPoint("TOPLEFT", rowsHolder, "BOTTOMLEFT", 0, -4)
    frame.textScroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    frame.textScroll:SetPoint("TOPLEFT", frame.more, "BOTTOMLEFT", 0, -6)
    frame.textScroll:SetSize(500, TEXT_AREA_HEIGHT)
    frame.textChild = CreateFrame("Frame", nil, frame.textScroll)
    frame.textChild:SetSize(500, TEXT_AREA_HEIGHT)
    frame.textScroll:SetScrollChild(frame.textChild)
    frame.textLines = {}
    for index = 1, TEXT_LINES do
        local line = frame.textChild:CreateFontString(nil, "OVERLAY", "WoWraVoxFontHighlightSmall")
        line:SetWidth(480)
        line:SetWordWrap(true)
        line:SetJustifyH("LEFT")
        if index == 1 then
            line:SetPoint("TOPLEFT", frame.textChild, "TOPLEFT", 2, 0)
        else
            line:SetPoint("TOPLEFT", frame.textLines[index - 1], "BOTTOMLEFT", 0, -4)
        end
        frame.textLines[index] = line
    end
    frame.checkButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.checkButton:SetSize(110, 26)
    frame.checkButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 12)
    frame.checkButton:SetText(L("Check"))
    frame.checkButton:SetScript("OnClick", function() runCheck(frame) end)
    frame.importButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.importButton:SetSize(110, 26)
    frame.importButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 12)
    frame.importButton:SetText(L("Import"))
    frame.importButton:SetScript("OnClick", function() runImport(frame) end)
    frame.importButton:Disable()
    ns.Skin.Register(frame.checkButton, "button")
    ns.Skin.Register(frame.importButton, "button")
    edit:SetScript("OnTextChanged", function(self)
        if frame.preview and frame.preview.text ~= self:GetText() then
            frame.preview = nil
            clearPreview(frame)
            frame.error:SetText(L("Text changed. Check it again before importing."))
            frame.error:SetTextColor(1, 0.82, 0.2)
        end
        refreshImportButtons(frame)
    end)
    shareUI.importFrame = frame
    return frame
end

-- text (optional): a group text received by chat link. It is put in the box and checked at once; Import stays manual.
-- An open window with the user's own text is never overwritten by a received text: it only says so.
function shareUI.openImport(text)
    local frame = shareUI.importFrame or buildImportFrame()
    local received = type(text) == "string" and text ~= ""
    local wasShown = frame:IsShown()
    local ownText = frame.edit:GetText()
    if received and wasShown and ownText ~= "" and ownText ~= text then
        setStatus("Import window already has text. Clear it first.", true)
        if not frame.preview then
            frame.error:SetText(L("Import window already has text. Clear it first."))
            frame.error:SetTextColor(1, 0.82, 0.2)
        end
        return
    end
    frame.edit:SetText("")
    frame.preview = nil
    clearPreview(frame)
    frame.error:SetText(L("Paste a group text, then click Check."))
    frame.error:SetTextColor(0.72, 0.78, 0.86)
    refreshImportButtons(frame)
    frame:Show()
    if not wasShown then frame.edit:SetFocus() end
    if received then
        frame.edit:SetText(text)
        frame.edit:SetCursorPosition(0)
        runCheck(frame)
    end
end

end)()

local function wireScreenRow(row, helpText)
    row.text:HookScript("OnTextChanged", updatePreviewButtons)
    row.enabled:SetScript("OnClick", function()
        saveDetails()
        ns.Layout.setPanelExpanded(ns.notificationPanels[row.eventKey] or ns.notificationPanels.beforeExpire, true)
        showScreenRow(row, true)
        layoutSharedEditor(selectedCategory == "auras")
        if selectedAura() then
            rebuildAuraWatches()
            syncAllAuras(true)
        end
        updatePreviewButtons()
    end)
    row.preview:SetScript("OnClick", function()
        saveDetails()
        local rule = selectedRule()
        if rule and ns.showScreenText(rule, row.eventKey,
            ns.formatRuleNotificationMessage(rule, row.text:GetText(), ns.previewContext(rule)), true) then
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
    addHelpTooltip(row.anchor, "Anchor", "Unlock the on-screen text and drag it where you want it. A grid fills the screen and the text snaps to its lines (grid every 10 px) and to the centre lines; hold Shift to place it freely. Click again to lock.")
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
    elseif selectedSkill() and not editorLoading then
        local checked = ruleEnabledCheck:GetChecked()
        selectedSkillRule.enabled = checked == true or checked == 1
        ns.SkillTracking.ResetRule(selectedSkillRule)
        scanSkillRules()
        refreshList()
    end
end)
auraEditor.oneEffectCheck:SetScript("OnClick", function(self)
    if editorLoading or not selectedAura() or selectedAuraRule.builtin then return end
    saveDetails()
    local checked = self:GetChecked()
    selectedAuraRule.oneEffect = checked == true or checked == 1
    rebuildAuraWatches()
    syncAllAuras(true)
end)
auraEditor.allRanksCheck:SetScript("OnClick", function(self)
    if editorLoading or not selectedAura() then return end
    saveDetails()
    local checked = self:GetChecked()
    selectedAuraRule.allRanks = checked == true or checked == 1
    rebuildAuraWatches()
    syncAllAuras(true)
end)
addHelpTooltip(auraEditor.allRanksCheck, "Track all ranks",
    "Every rank of a spell you added counts as that spell (Lay on Hands rank 1, 2 and 3). The ranks are found once in the background and remembered.")
ns.Skin.Register(auraEditor.allRanksCheck, "checkbox")
addHelpTooltip(auraEditor.oneEffectCheck, "Treat triggers as one effect",
    "Announces when the first trigger appears and when the last one is gone. Use it for an effect that applies several auras, such as Bloodlust and its Sated debuff.")
for _, panel in pairs(ns.notificationPanels) do
    local notificationPanel = panel
    panel.ttsEnabled:SetScript("OnClick", function()
        if selectedAura() then onAuraToggle() else saveDetails() end
        ns.Layout.setPanelExpanded(notificationPanel, true)
        ns.setNotificationPanelShown(notificationPanel, true)
        layoutSharedEditor(selectedCategory == "auras")
    end)
    panel.soundEnabled:SetScript("OnClick", function()
        if selectedAura() then onAuraToggle() else saveDetails() end
        ns.Layout.setPanelExpanded(notificationPanel, true)
        ns.setNotificationPanelShown(notificationPanel, true)
        layoutSharedEditor(selectedCategory == "auras")
    end)
    addHelpTooltip(panel.ttsEnabled, "TTS", "Speak a message when this event occurs.")
    addHelpTooltip(panel.soundEnabled, "Sound", "Play a Blizzard sound when this event occurs.")
    addHelpTooltip(panel.soundChoice, "Sound", "Choose a Blizzard sound effect.")
    addHelpTooltip(panel.soundChannel, "Audio channel", "Choose the WoW playback channel for this sound.")
    addHelpTooltip(panel.soundTest, "Test notification", "Play the selected sound on the selected channel.")
end

ns.notificationPanels.beforeExpire.ttsTest:SetScript("OnClick", function()
    saveDetails()
    local rule = selectedAuraRule
    local key = ns.notificationPanels.beforeExpire.eventKey
    if rule and not playTTS(rule.voiceID, ns.formatRuleNotificationMessage(rule, rule[key .. "Message"], ns.previewContext(rule)), rule.volume, rule.speechSpeed) then
        setStatus("TTS test could not be sent to WoW.", true)
    else
        setStatus("TTS test sent to WoW. Check audio in game.")
    end
end)
testApplyButton:SetScript("OnClick", function()
    saveDetails()
    if selectedAuraRule and not playTTS(selectedAuraRule.voiceID, ns.formatRuleNotificationMessage(selectedAuraRule, selectedAuraRule.applyMessage, ns.previewContext(selectedAuraRule)), selectedAuraRule.volume, selectedAuraRule.speechSpeed) then
        setStatus("TTS test could not be sent to WoW.", true)
    else
        setStatus("TTS test sent to WoW. Check audio in game.")
    end
end)
testExpireButton:SetScript("OnClick", function()
    saveDetails()
    if selectedAuraRule and not playTTS(selectedAuraRule.voiceID, ns.formatRuleNotificationMessage(selectedAuraRule, selectedAuraRule.expireMessage, ns.previewContext(selectedAuraRule)), selectedAuraRule.volume, selectedAuraRule.speechSpeed) then
        setStatus("TTS test could not be sent to WoW.", true)
    else
        setStatus("TTS test sent to WoW. Check audio in game.")
    end
end)
function ns.TestCurrentReady()
    saveDetails()
    local readyRule = selectedItem() or selectedSkill()
    local message = readyRule and ns.formatRuleNotificationMessage(readyRule, readyRule.message, ns.previewContext(readyRule)) or ""
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
addHelpTooltip(triggerAddButton, "Add triggers", "Spell IDs are the most reliable lookup. Name search depends on names available to the client and may be incomplete. Review the effect before adding.")
addHelpTooltip(triggerInputBox, "Spell lookup", "Spell IDs are the most reliable lookup. Name search depends on names available to the client and may be incomplete. Review the effect before adding.")
addHelpTooltip(applyEnabledCheck, "TTS", "Speak a message when this aura event occurs.")
addHelpTooltip(applyMessageBox, "Notification message", "Message spoken when the aura appears.")
addHelpTooltip(testApplyButton, "Test notification", "Preview this message with the selected voice and volume.")
addHelpTooltip(expireEnabledCheck, "TTS", "Speak a message when this aura event occurs.")
addHelpTooltip(expireMessageBox, "Notification message", "Message spoken when the aura expires naturally.")
addHelpTooltip(testExpireButton, "Test notification", "Preview this message with the selected voice and volume.")
addHelpTooltip(readyMessageBox, "Ready notification", "Message spoken when the observed item cooldown is ready.")
addHelpTooltip(testItemButton, "Test notification", "Preview this message with the selected voice and volume.")
addHelpTooltip(auraEditor.skillTriggerDropdown, "Spell trigger", "Choose a spell cooldown, charge, or successful cast event to monitor.")
addHelpTooltip(auraEditor.skillLearnButton, "Learning Mode", "For spell rules, observe the cast and cooldown. For aura rules, observe aura IDs and Cooldown Manager visibility for 20 seconds.")
addHelpTooltip(voiceDropdown.Button or voiceDropdown, "Voice", "Select the voice for this rule.")
addHelpTooltip(volumeSlider, "Volume", "Set the speech volume from 0 to 100.")
addHelpTooltip(auraEditor.speedSlider, "Speech speed", "Set the speech speed from 100% to 200%.")
addHelpTooltip(creationView.auraButton, "Aura", "Track buff, debuff, or item-effect auras.")
addHelpTooltip(creationView.itemButton, "Equipped item", "Choose an equipped item and announce when its cooldown is ready.")
addHelpTooltip(creationView.skillButton, "Spell cooldown", "Choose a spell from your spellbook and announce when its cooldown is ready.")
addHelpTooltip(creationView.cancelButton, "Cancel", "Return to the selected rule without creating a new one.")
updatePreviewButtons()
-- Checkboxes last: their OnClick scripts were set above and must not run after the skin's HookScript hooks.
ns.Skin.Register(ruleEnabledCheck, "checkbox")
ns.Skin.Register(auraEditor.oneEffectCheck, "checkbox")
for _, panel in pairs(ns.notificationPanels) do
    ns.Skin.Register(panel.ttsEnabled, "checkbox")
    ns.Skin.Register(panel.soundEnabled, "checkbox")
    ns.Skin.Register(panel.screen.enabled, "checkbox")
end
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
    ns.itemPickerReplaceRule, ns.itemPickerReplaceIndex, ns.itemPickerAddRule = nil, nil, nil
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
    -- Picker modes: replace member `replaceIndex` of replaceRule, add a member to addRule, fill the starter
    -- rule, or (none of them) create a new rule.
    local replaceRule, replaceIndex, addRule = ns.itemPickerReplaceRule, ns.itemPickerReplaceIndex or 1, ns.itemPickerAddRule
    local starterRule = selectedItemRule and selectedItemRule.starter == "trinket" and selectedItemRule or nil
    local trackSlot = ns.pickerTracksSlot(slotID)
    local replaceValid, addValid = false, false
    for _, rule in ipairs(WoWraVoxDB.items) do
        if rule == replaceRule then replaceValid = true end
        if rule == addRule then addValid = true end
    end
    if not replaceValid then replaceRule = nil end
    if not addValid then addRule = nil end
    for _, rule in ipairs(WoWraVoxDB.items) do
        if ns.itemRuleIsDuplicate(rule, itemID, slotID, trackSlot) then
            -- Picking the member that is being replaced again is not worth a message.
            local sameMember = rule == replaceRule
                and not ns.itemRuleIsDuplicate(rule, itemID, slotID, trackSlot, replaceIndex)
            addRuleMode = false
            stopItemPicker()
            selectedCategory = "items"
            selectedItemRule = rule
            refreshList()
            updateDetails()
            optionsFrame:Show()
            if (replaceRule or addRule) and not sameMember then setStatus("Item already tracked.") end
            return
        end
    end

    local name, icon = getItemInfo(itemID, slotID)
    local rule = replaceRule or addRule or starterRule
    if rule and rule == addRule and not rule.starter then
        ns.addItemMember(rule, { itemID = itemID, slotID = trackSlot and slotID or nil })
    elseif rule then
        ns.retargetItemRule(rule, replaceRule and replaceIndex or 1, itemID, name, icon, trackSlot and slotID or nil)
    else
        rule = newItemRule(itemID, trackSlot and ns.slotName(slotID) or name, icon, trackSlot and slotID or nil)
        if trackSlot then rule.message = ns.slotDefaultMessage(slotID) end
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

-- replaceRule + replaceIndex: pick a new item for that member (default the first); addRule: pick one more
-- member for that rule; neither: fill the starter rule or create a new rule.
local function beginItemPicker(replaceRule, replaceIndex, addRule)
    if InCombatLockdown and InCombatLockdown() then
        setStatus("Item selection is blocked in combat.", true)
        return
    end
    ns.itemPickerReplaceRule, ns.itemPickerReplaceIndex, ns.itemPickerAddRule = replaceRule, replaceIndex, addRule
    pickerActive = true
    pickerRetries = 0
    if pickerPrompt then
        local check = pickerPrompt.slotCheck
        -- Replacing a slot member keeps slot mode unless the user unticks it.
        local replaced = replaceRule and ns.itemMembers(replaceRule)[replaceIndex or 1]
        check.userSet = replaced ~= nil and replaced.slotID ~= nil
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

    local characterShown = _G.CharacterFrame and CharacterFrame:IsShown()
    if ns.isForever then
        -- Opening the window from addon code taints Forever's CharacterFrame (it compares secret health values in
        -- OnShow and errors).  The OnShow hook above draws the overlays once the player opens it themself.
        if not characterShown then
            setStatus("Open your character window (C), then click an equipped item slot.")
        else
            setStatus("Click an equipped item slot.")
        end
        C_Timer.After(0.25, refreshPickerOverlays)
        return
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
    local title = createLabel(pickerPrompt, "WoWraVox  ·  " .. L("Item selection"), "WoWraVoxFontNormal")
    title:SetPoint("TOPLEFT", pickerPrompt, "TOPLEFT", 14, -10)
    title:SetTextColor(1, 0.82, 0.2)
    pickerPrompt:Hide()
    table.insert(UISpecialFrames, "WoWraVoxPickerPrompt")

    local message = createLabel(pickerPrompt, "Click an equipped slot in the character window. Press Esc to cancel.", "WoWraVoxFontHighlightSmall")
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
    local slotLabel = createLabel(pickerPrompt, "Track the slot, not the item", "WoWraVoxFontHighlightSmall")
    slotLabel:SetPoint("LEFT", pickerPrompt.slotCheck, "RIGHT", 2, 0)
    addHelpTooltip(pickerPrompt.slotCheck, "Track the slot, not the item",
        "Follow whatever is equipped in this slot, so swapping trinkets keeps one rule. Preset for the trinket slots.")
    pickerPrompt:HookScript("OnHide", function()
        if pickerActive then stopItemPicker() end
    end)
    ns.Skin.Register(pickerPrompt, "panel", { hide = { accent } })
    ns.Skin.Register(cancel, "button")
    ns.Skin.Register(pickerPrompt.slotCheck, "checkbox")
end

-- Interface skin (see Skin.lua): the choice is stored per profile and applied by the next /reload.
ns.SKIN_LABELS = { current = "WoWraVox", clean = "Clean" }

function ns.skinChosen()
    local chosen = WoWraVoxDB and WoWraVoxDB.settings and WoWraVoxDB.settings.skin
    return ns.Skin.IsValid(chosen) and chosen or "current"
end

-- Reload the UI (never in combat). Returns false when blocked.
function ns.reloadUI()
    if InCombatLockdown and InCombatLockdown() then return false end
    if saveDetails then saveDetails() end
    if C_UI and C_UI.Reload then C_UI.Reload() else ReloadUI() end
    return true
end

function ns.SkinCommand(message)
    local function say(text)
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffd8b65aWoWraVox:|r " .. text) end
    end
    local arg = trim(tostring(message or "")):lower()
    if arg == "wowravox" then arg = "current" end -- the UI name of the default skin
    local function display(name) return name == "current" and "WoWraVox (current)" or name end
    local function list(chosen, active)
        local names = {}
        for _, name in ipairs(ns.Skin.Names()) do names[#names + 1] = display(name) end
        say(string.format(L("Interface skin: %s (active: %s). Available: %s. Use /wvskin <name>."),
            display(chosen), display(active), table.concat(names, ", ")))
    end
    if arg == "errors" then
        local errors = ns.Skin.errors
        say(string.format("Skin errors: %d", #errors))
        for index = 1, math.min(5, #errors) do say(errors[index]) end
    elseif arg == "" then
        list(ns.skinChosen(), ns.Skin.Active())
    elseif not ns.Skin.IsValid(arg) then
        say(string.format(L("Unknown skin: %s"), arg))
    else
        ns.Skin.Set(arg)
        if arg == ns.Skin.Active() then
            list(arg, arg)
        elseif not ns.reloadUI() then
            say(L("Skin saved. Reload is blocked in combat; type /reload later."))
        end
    end
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
    ns.skinDivider(titleRule)
    local definitions = {
        { key = "tooltipIDs", text = "IDs in game tooltips", help = "Shows spell IDs for auras and spells, plus item and available effect IDs for items." },
    }
    local displayChecks = {}
    for index, definition in ipairs(definitions) do
        local check = CreateFrame("CheckButton", nil, settingsPanel, "UICheckButtonTemplate")
        check:SetSize(30, 30)
        check:SetChecked(WoWraVoxDB.settings[definition.key])
        local label = createLabel(settingsPanel, definition.text, "WoWraVoxFontHighlightSmall")
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
        ns.Layout.setDropdownWidth(dropdown, width)
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
        ns.Skin.Register(dropdown, "dropdown")
        return dropdown
    end

    -- Interface skin row (between the display checkboxes and PROFILES).
    local skinChoices = {}
    for index, name in ipairs(ns.Skin.Names()) do
        skinChoices[index] = { value = name, key = ns.SKIN_LABELS[name] or name }
    end
    local skinLabel = createLabel(settingsPanel, "Interface skin", "WoWraVoxFontNormalSmall")
    local skinStatus = createLabel(settingsPanel, "Skin changes after /reload.", "WoWraVoxFontHighlightSmall")
    skinStatus:SetJustifyH("LEFT")
    skinStatus:SetWordWrap(false)
    local skinDropdown = profileDropdown(112, skinChoices, function(name) ns.Skin.Set(name) end)
    local skinReload = CreateFrame("Button", nil, settingsPanel, "UIPanelButtonTemplate")
    skinReload:SetSize(100, 26)
    skinReload:SetText(L("Reload UI"))
    skinReload:SetScript("OnClick", function()
        if not ns.reloadUI() then setStatus("Reload is blocked in combat.", true) end
    end)
    local function refreshSkinChoice()
        local chosen = ns.skinChosen()
        skinDropdown.SetProfileValue(chosen, L(ns.SKIN_LABELS[chosen] or chosen))
    end
    refreshSkinChoice()

    local profileHeading = makeSectionLabel(settingsPanel, "PROFILES", ns.Layout.PAD, -104)
    local profileRule = settingsPanel:CreateTexture(nil, "ARTWORK")
    profileRule:SetTexture("Interface\\Buttons\\WHITE8X8")
    profileRule:SetHeight(1)
    profileRule:SetColorTexture(0.72, 0.55, 0.22, 0.9)
    ns.skinDivider(profileRule)
    local characterProfileLabel = createLabel(settingsPanel, "Profile", "WoWraVoxFontNormalSmall")
    characterProfileLabel:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", ns.Layout.PAD, -132)
    local characterProfileDropdown = profileDropdown(330, profileList, function(profileID)
        if ns.Profiles.AssignCharacterProfile(profileID) then
            if settingsPanel.RefreshProfileControls then settingsPanel.RefreshProfileControls() end
        end
    end)

    local profileNameLabel = createLabel(settingsPanel, "Profile name", "WoWraVoxFontNormalSmall")
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
    local debugLabel = createLabel(diagnosticsControls, L("Debug logging"), "WoWraVoxFontHighlightSmall")
    debugLabel:SetPoint("LEFT", debugCheck, "RIGHT", 4, 0)
    local testTTSButton = CreateFrame("Button", nil, diagnosticsControls, "UIPanelButtonTemplate")
    testTTSButton:SetSize(88, 24)
    testTTSButton:SetText(L("Test TTS"))
    local showLogButton = CreateFrame("Button", nil, diagnosticsControls, "UIPanelButtonTemplate")
    showLogButton:SetSize(88, 24)
    showLogButton:SetText(L("Show log"))
    local diagnosticsStatus = createLabel(diagnosticsControls, "", "WoWraVoxFontHighlightSmall")
    diagnosticsStatus:SetJustifyH("LEFT")
    diagnosticsStatus:SetWordWrap(true)

    local function refreshDiagnosticsStatus(status)
        status = status or (ns.AuraSoundFallback and ns.AuraSoundFallback.GetStatus()) or {}
        debugCheck:SetChecked(ns.SkillTracking.debugEnabled == true)
        if not status.available then
            diagnosticsStatus:SetText(L("Native aura sound API unavailable."))
        elseif status.queued then
            diagnosticsStatus:SetText(L("Sound changes pending until WoW restrictions end."))
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
        local skinShift = 40 -- height of the Interface skin row
        local sectionShift = (stackedChecks and 37 or 0) + skinShift
        for index, check in ipairs(displayChecks) do
            check:ClearAllPoints()
            local x = (index == 1 or stackedChecks) and ns.Layout.ROW_X or 340
            local y = -54 - (index == 2 and stackedChecks and 37 or 0)
            check:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", x, y)
        end
        -- Absolute y from the top, fixed at the collapsed panel height: a LEFT/RIGHT anchor is
        -- vertically centered and would drift when the diagnostics expander changes the height.
        local baseHeight = math.min((stackedChecks and 272 or (rowWidth >= 446 and 232 or 260)) + 36,
            math.max(220, UIParent:GetHeight() - 24))
        local collapsedHeight = baseHeight + skinShift
        local ruleY = -(baseHeight / 2 + 95 + sectionShift) + 0.5
        local skinY = -96 - (sectionShift - skinShift)
        skinLabel:ClearAllPoints()
        skinLabel:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", ns.Layout.PAD, skinY)
        skinDropdown:ClearAllPoints()
        skinDropdown:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", left - ns.Layout.EDITBOX_INSET - ns.Layout.DD_INSET_L, skinY + 3)
        skinReload:ClearAllPoints()
        skinReload:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", left + 142, skinY)
        skinStatus:ClearAllPoints()
        skinStatus:SetPoint("LEFT", skinReload, "RIGHT", 10, 0)
        skinStatus:SetPoint("RIGHT", settingsPanel, "RIGHT", ns.Layout.RIGHT, 0)
        skinStatus:SetShown(rowWidth >= 446)
        profileRule:ClearAllPoints()
        profileRule:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", ns.Layout.PAD, ruleY)
        profileRule:SetPoint("TOPRIGHT", settingsPanel, "TOPRIGHT", ns.Layout.RIGHT, ruleY)
        profileHeading:ClearAllPoints()
        profileHeading:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", ns.Layout.PAD, -104 - sectionShift)
        characterProfileLabel:ClearAllPoints()
        characterProfileLabel:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", ns.Layout.PAD, -132 - sectionShift)
        characterProfileDropdown:ClearAllPoints()
        characterProfileDropdown:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", left - ns.Layout.EDITBOX_INSET - ns.Layout.DD_INSET_L, -129 - sectionShift)
        ns.Layout.setDropdownWidth(characterProfileDropdown, math.min(429, rowWidth - 17))
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
        refreshSkinChoice()
        refreshDiagnosticsStatus()
    end
    settingsPanel.RefreshProfileControls()
    addHelpTooltip(characterProfileDropdown, "Profile", "Choose the profile used by this character.")
    addHelpTooltip(newProfileButton, "New profile", "Create a profile with the three starter rules.")
    addHelpTooltip(copyProfileButton, "Copy profile", "Copy the selected profile for this character.")
    addHelpTooltip(diagnosticsToggle, L("Combat diagnostics"), L("Temporary debug controls. Settings reset on /reload."))
    addHelpTooltip(skinDropdown, "Interface skin", "Choose the look of the WoWraVox window. The change applies after /reload.")
    for _, button in ipairs({ skinReload, newProfileButton, copyProfileButton, diagnosticsToggle, testTTSButton, showLogButton }) do
        ns.Skin.Register(button, "button")
    end
    ns.Skin.Register(debugCheck, "checkbox")
    for _, check in ipairs(displayChecks) do ns.Skin.Register(check, "checkbox") end
    settingsPanel:Hide()
end

ns.Layout.layoutOptionsColumns = function()
    if not (optionsFrame and listPanel and detailPanel) then return end
    local editorScrollOffset = editorScroll and editorScroll:GetVerticalScroll() or 0
    local listWidth = 362
    listPanel:SetWidth(listWidth)
    detailPanel:ClearAllPoints()
    detailPanel:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", ns.Layout.MARGIN + listWidth + ns.Layout.MARGIN, -64)
    detailPanel:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -ns.Layout.MARGIN, ns.Layout.MARGIN + ns.Layout.statusHeight)
    editorScroll:ClearAllPoints()
    editorScroll:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", 0, -2)
    editorScroll:SetPoint("BOTTOMRIGHT", detailPanel, "BOTTOMRIGHT", -8, 0)
    if statusText then
        statusText:ClearAllPoints()
        statusText:SetPoint("TOPLEFT", detailPanel, "BOTTOMLEFT", 0, -4)
        statusText:SetPoint("TOPRIGHT", detailPanel, "BOTTOMRIGHT", -8, -4)
        statusText:SetHeight(ns.Layout.statusHeight - 4)
        statusText:SetJustifyV("MIDDLE")
        statusText:SetWordWrap(true)
    end
    if listScroll then
        listChild:SetWidth(math.max(1, listScroll:GetWidth()))
        ns.Layout.requestRefreshList()
    end
    ns.Layout.clampEditorScroll(editorScrollOffset)
end

function ns.createOptions()
    optionsFrame = CreateFrame("Frame", "WoWraVoxOptions", UIParent, "BackdropTemplate")
    stylePanel(optionsFrame, 0.035, 0.04, 0.05, false)
    optionsFrame:SetScale(ns.Layout.getWindowScale())
    -- Height is the user's: drag the grip bottom right; stored per account, limited to the screen.
    local scale = optionsFrame:GetScale()
    local screenHeight = ((UIParent:GetHeight() or ns.Layout.maxHeight) - 24) / scale
    local savedHeight = type(WoWraVoxProfilesDB) == "table" and tonumber(WoWraVoxProfilesDB.windowHeight)
    optionsFrame:SetSize(ns.Layout.maxWidth,
        math.max(ns.Layout.minHeight, math.min(savedHeight or ns.Layout.maxHeight, screenHeight)))
    optionsFrame:SetPoint("CENTER")
    optionsFrame:SetResizable(true)
    if optionsFrame.SetResizeBounds then
        optionsFrame:SetResizeBounds(ns.Layout.maxWidth, ns.Layout.minHeight, ns.Layout.maxWidth, math.max(ns.Layout.minHeight, screenHeight))
    end
    local grip = CreateFrame("Button", nil, optionsFrame)
    grip:SetSize(18, 18)
    grip:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -4, 4)
    grip:SetFrameLevel(optionsFrame:GetFrameLevel() + 50)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then optionsFrame:StartSizing("BOTTOM") end
    end)
    grip:SetScript("OnMouseUp", function()
        optionsFrame:StopMovingOrSizing()
        if type(WoWraVoxProfilesDB) == "table" then
            WoWraVoxProfilesDB.windowHeight = math.floor(optionsFrame:GetHeight() + 0.5)
        end
    end)
    addHelpTooltip(grip, "Window height", "Drag to make the window taller or shorter.")
    optionsFrame:SetFrameStrata("DIALOG")
    optionsFrame:SetToplevel(true) -- the window clicked last sits on top of other DIALOG windows (e.g. TrisThreat)
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
    -- the window art has its own header: hide the addon-made header fills (registered here, once they exist)
    ns.Skin.Register(optionsFrame, "window", { hide = { headerBackground, headerShade, headerAccent } })

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
    ns.Skin.Register(closeButton, "dangerButton", { marks = { closeMarkA, closeMarkB } })

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
    ns.Skin.Register(optionsFrame.settingsButton, "button")
    if ns.Skin.Data() then optionsFrame.settingsButton:SetBackdrop(nil) end -- the button art replaces the backdrop

    optionsFrame.trackerButton = CreateFrame("Button", nil, header, "BackdropTemplate")
    optionsFrame.trackerButton:SetSize(36, 36)
    optionsFrame.trackerButton:SetPoint("RIGHT", optionsFrame.settingsButton, "LEFT", -6, 0)
    optionsFrame.trackerButton.icon = optionsFrame.trackerButton:CreateTexture(nil, "ARTWORK")
    optionsFrame.trackerButton.icon:SetTexture("Interface\\Icons\\Spell_Holy_AuraMastery")
    optionsFrame.trackerButton.icon:SetSize(24, 24)
    optionsFrame.trackerButton.icon:SetPoint("CENTER")
    optionsFrame.trackerButton:SetScript("OnClick", function() ns.OpenAuraTracker(true) end)
    addHelpTooltip(optionsFrame.trackerButton, "Aura tracker", "Open the aura tracker configuration.")
    ns.Skin.Register(optionsFrame.trackerButton, "button")
    if ns.Skin.Data() then optionsFrame.trackerButton:SetBackdrop(nil) end

    listPanel = CreateFrame("Frame", nil, optionsFrame, "BackdropTemplate")
    listPanel:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", ns.Layout.MARGIN, -64)
    listPanel:SetPoint("BOTTOMLEFT", optionsFrame, "BOTTOMLEFT", ns.Layout.MARGIN, ns.Layout.MARGIN)
    listPanel:SetWidth(362)
    stylePanel(listPanel, 0.115, 0.115, 0.11)
    local listHeading = createLabel(listPanel, "RULES", "WoWraVoxFontNormalSmall")
    listHeading:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 18, -12)
    listHeading:SetTextColor(1, 0.82, 0.2)
    local listSeparator = listPanel:CreateTexture(nil, "ARTWORK")
    listSeparator:SetColorTexture(0.46, 0.36, 0.16, 0.7)
    listSeparator:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 9, -25)
    listSeparator:SetPoint("TOPRIGHT", listPanel, "TOPRIGHT", -25, -25)
    listSeparator:SetHeight(1)
    ns.skinDivider(listSeparator)
    listScroll = CreateFrame("ScrollFrame", nil, listPanel, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 3, -30)
    listScroll:SetPoint("BOTTOMRIGHT", listPanel, "BOTTOMRIGHT", -25, 38)
    listChild = CreateFrame("Frame", nil, listScroll)
    listChild:SetSize(1, 1)
    listScroll:SetScrollChild(listChild)
    ns.Skin.Register(listScroll, "scrollTrack")
    ns.Skin.Register(listScroll, "scrollThumb")
    listEmptyText = createLabel(listPanel, "", "WoWraVoxFontHighlightSmall")
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
        ns.AuraPresetUI.beginCreation()
    end)
    creationView.itemButton:SetScript("OnClick", function()
        saveDetails()
        beginItemPicker()
    end)
    optionsFrame.addButton:SetScript("OnClick", function()
        saveDetails()
        showAddRuleView()
    end)
    ns.Skin.Register(optionsFrame.addButton, "button")

    statusText = createLabel(optionsFrame, "", "WoWraVoxFontNormalSmall")
    statusText:SetPoint("TOPLEFT", detailPanel, "BOTTOMLEFT", 0, -4)
    statusText:SetPoint("TOPRIGHT", detailPanel, "BOTTOMRIGHT", -8, -4)
    statusText:SetHeight(ns.Layout.statusHeight - 4)
    statusText:SetJustifyH("LEFT")
    statusText:SetJustifyV("MIDDLE")
    statusText:SetWordWrap(true)
    ns.Layout.layoutOptionsColumns()

    optionsFrame:HookScript("OnShow", function()
        refreshList()
        updateDetails()
    end)
    optionsFrame:HookScript("OnHide", function()
        ns.endScreenAnchor() -- close button, Esc, ToggleOptions: anchor mode ends with the window
        if settingsPanel then settingsPanel:Hide() end
        if searchPopup then searchPopup:Hide() end
        ns.AuraPresetUI.finishCreation(true)
        addRuleMode = false
        if creationView then creationView:Hide() end
    end)
    createPickerPrompt()
    auraTracker.createUI()
end

function ns.Profiles.ActivateUI()
    if not initializeDatabase() then return end
    ns.SkillTracking.CancelLearning(L("Profile changed."), true)
    ns.endScreenAnchor()
    ns.clearScreenFrames()
    ns._Aura.clearActiveState()
    ns._Aura.resetEventState()
    wipe(itemCooldownStates)
    ns.SkillTracking.ResetAll()
    auraBaselineComplete = false
    if ns.AuraPresetUI and ns.AuraPresetUI.creationActive then
        selectedCategory, selectedAuraRule = "auras", ns.AuraPresetUI.creationDraft
    else
        ns.SelectInitialRule()
    end
    lastRenderedRule = nil
    lastRenderedCategory = nil
    rebuildAuraWatches()
    syncAllAuras(true)
    if auraTracker.view then
        auraTracker.view:SetConfig(auraTracker.config())
        auraTracker.view:SetEditMode(false)
        if auraTracker.frame then
            auraTracker.frame.editButton:SetText(L("Configure"))
            auraTracker.frame.resetButton:Hide()
            auraTracker.frame.countdownCheck:Hide()
            auraTracker.frame.nameCheck:Hide()
            auraTracker.frame.stacksCheck:Hide()
            auraTracker.frame.allSealsButton:Hide()
            auraTracker.frame.cdmButton:Hide()
            auraTracker.frame.sealFilter:Hide()
        end
        auraTracker.view:Update(ns.getAuraTrackerEntries())
    end
    if optionsFrame and optionsFrame:IsShown() then
        refreshList()
        updateDetails()
        if ns.AuraPresetUI and ns.AuraPresetUI.creationActive then ns.AuraPresetUI.refresh() end
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
        ns.SelectInitialRule()
        refreshList()
        updateDetails()
        load.refresh = clock() - stamp
        SLASH_WOWRAVOXPROF1 = "/wvprof"
        SlashCmdList.WOWRAVOXPROF = ns.Prof.Command
        SLASH_WOWRAVOXSKIN1 = "/wvskin"
        SlashCmdList.WOWRAVOXSKIN = ns.SkinCommand
        SLASH_WOWRAVOX1 = "/wowravox"
        SLASH_WOWRAVOX2 = "/wvr"
        SlashCmdList.WOWRAVOX = ns.ToggleOptions
        SLASH_WOWRAVOXDEBUG1 = "/wvdebug"
        SLASH_WOWRAVOXDEBUG2 = "/wvrdebug"
        SlashCmdList.WOWRAVOXDEBUG = ns.SkillTracking.HandleDebugCommand
        SLASH_WOWRAVOXIMPORT1 = "/wvimport"
        SlashCmdList.WOWRAVOXIMPORT = function() ns.ShareUI.openImport() end
        SLASH_WOWRAVOXTRACKER1 = "/wvtracker"
        SlashCmdList.WOWRAVOXTRACKER = function() ns.OpenAuraTracker(true) end
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
        -- Flush the aliases before later chat/macro handlers can import them
        -- from a protected action-button execution path.
        if ChatFrameUtil and ChatFrameUtil.ImportAllListsToHash then
            ChatFrameUtil.ImportAllListsToHash()
        end
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterUnitEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
        self:RegisterEvent("PLAYER_TALENT_UPDATE")
        self:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
        self:RegisterUnitEvent("UNIT_AURA", "player")
        self:RegisterEvent("SPELLS_CHANGED")
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
            if optionsFrame and optionsFrame:IsShown() then updateDetails() end
        end)
    elseif event == "PLAYER_TALENT_UPDATE" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
        -- Talent changes alter which presets are available.  Drop the talent cache and redraw the open preset
        -- list once per burst; the player's ticks stay (collectSelected skips entries that became unavailable).
        local presets, ui = ns.AuraPresets, ns.AuraPresetUI
        if presets and presets.InvalidateTalentCache then presets.InvalidateTalentCache() end
        if ui and not ui.talentRefreshPending then
            ui.talentRefreshPending = true
            C_Timer.After(0.5, function()
                ui.talentRefreshPending = false
                if presets and presets.InvalidateTalentCache then presets.InvalidateTalentCache() end
                if ui.creationActive then ui.refresh() end
            end)
        end
    elseif event == "UNIT_AURA" then
        local unit, updateInfo = ...
        ns.SkillTracking.HandleEvent(event, ...)
        onUnitAuraUpdate(unit, updateInfo)
    elseif event == "SPELLS_CHANGED" then
        local tracker = auraTracker.config()
        if tracker.families and tracker.families.seals then
            if InCombatLockdown and InCombatLockdown() then
                auraTracker.sealSyncPending = true
            else
                auraTracker.scanSeals(tracker.sealNameFilter)
            end
        end
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
        ns.tryDebugReport("NoteCast", unit, castSpellID)
        ns._Aura.handleCast(unit, castGUID, castSpellID)
        ns.SkillTracking.HandleEvent(event, ...)
    elseif event == "PLAYER_LOGOUT" then
        ns.SkillTracking.CancelLearning(L("Player logged out."), true)
        if optionsFrame and optionsFrame:IsShown() then saveDetails() end
        ns.NormalizeAllProfiles()
        ns.Profiles.PrepareSavedVariables()
    elseif event == "PLAYER_REGEN_DISABLED" then
        ns.endScreenAnchor()
        if pickerActive then
            stopItemPicker()
            setStatus("Item selection was stopped when combat started.", true)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        queueAuraSync()
        ns.queueItemScan(0.05)
        if auraTracker.sealSyncPending then
            auraTracker.sealSyncPending = false
            local tracker = auraTracker.config()
            if tracker.families and tracker.families.seals then auraTracker.scanSeals(tracker.sealNameFilter) end
        end
    elseif event:find("^VOICE_CHAT_TTS_PLAYBACK_") then
        ns._Aura.onTTSEvent(event, ...)
    end
end
ns.eventFrame:SetScript("OnEvent", ns.onEvent)
