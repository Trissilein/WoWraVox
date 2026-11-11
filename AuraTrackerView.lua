local _, ns = ...

local View = {}
local DEFAULT_SIZE, DEFAULT_SPACING = 40, 6
local MIN_SIZE, MAX_SIZE = 16, 128
local function localized(key)
    local locale = type(GetLocale) == "function" and GetLocale() or "enUS"
    local dictionary = ns.Locales and ns.Locales[locale]
    return dictionary and dictionary[key] or key
end
local VALID_POINTS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true,
    LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local function field(value, key)
    local ok, result = pcall(function() return value and value[key] end)
    if ok then return result end
end

local function isSecret(value, tableValue)
    local checker = tableValue and issecrettable or issecretvalue
    if type(checker) ~= "function" then return false end
    local ok, result = pcall(checker, value)
    return not ok or result == true
end

local function safeTable(value)
    return type(value) == "table" and not isSecret(value, true)
end

local function safeKey(value)
    if type(value) ~= "string" and type(value) ~= "number" then return nil end
    if isSecret(value, false) then return nil end
    if type(value) == "number" and (value ~= value or value == math.huge or value == -math.huge) then return nil end
    return tostring(value)
end

local function firstKey(object, ...)
    for index = 1, select("#", ...) do
        local key = select(index, ...)
        local value = safeKey(field(object, key))
        if value then return value end
    end
end

local function safeNumber(value)
    if type(value) ~= "number" or isSecret(value, false) then return nil end
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
end

local function safeBoolean(value, fallback)
    if type(value) == "boolean" and not isSecret(value, false) then return value end
    return fallback
end

local function bounded(value, fallback, minimum, maximum)
    value = safeNumber(value) or fallback
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function safePoint(value, fallback)
    if type(value) == "string" and not isSecret(value, false) and VALID_POINTS[value] then return value end
    return fallback
end

local function callMethod(object, name, ...)
    local fn = field(object, name)
    if type(fn) ~= "function" then return false end
    return pcall(fn, object, ...)
end

local function callResult(object, name, ...)
    local fn = field(object, name)
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, object, ...)
    if ok then return result end
end

local function callResults(object, name, ...)
    local fn = field(object, name)
    if type(fn) ~= "function" then return false end
    return pcall(fn, object, ...)
end

local function show(object, visible)
    callMethod(object, visible and "Show" or "Hide")
end

local function copyIds(source)
    local result, seen = {}, {}
    if not safeTable(source) then return result end
    for _, value in ipairs(source) do
        local id = safeKey(value)
        if id and not seen[id] then
            seen[id] = true
            result[#result + 1] = id
        end
    end
    return result
end

local function normalizeGroup(id, source)
    if not id or not safeTable(source) then return nil end
    return {
        id = id,
        order = safeNumber(field(source, "order")),
        entryIds = copyIds(field(source, "entryIds")),
        point = safePoint(field(source, "point"), nil),
        relativePoint = safePoint(field(source, "relativePoint"), nil),
        x = safeNumber(field(source, "x")),
        y = safeNumber(field(source, "y")),
        size = bounded(field(source, "size"), DEFAULT_SIZE, MIN_SIZE, MAX_SIZE),
        spacing = bounded(field(source, "spacing"), DEFAULT_SPACING, 0, MAX_SIZE),
    }
end

function View.NormalizeConfig(source)
    if not safeTable(source) then source = {} end
    local result = {
        size = bounded(field(source, "size"), DEFAULT_SIZE, MIN_SIZE, MAX_SIZE),
        spacing = bounded(field(source, "spacing"), DEFAULT_SPACING, 0, MAX_SIZE),
        showCountdown = safeBoolean(field(source, "showCountdown"), true),
        showName = safeBoolean(field(source, "showName"), false),
        showStacks = safeBoolean(field(source, "showStacks"), true),
        groups = {},
        freeIcons = {},
        visibilityByEntry = {},
    }

    local groups = field(source, "groups")
    if safeTable(groups) then
        for key, value in pairs(groups) do
            local id = safeKey(field(value, "id")) or safeKey(key)
            local group = normalizeGroup(id, value)
            if group then result.groups[id] = group end
        end
    end

    local freeIcons = field(source, "freeIcons")
    if safeTable(freeIcons) then
        local seen = {}
        for index, value in ipairs(freeIcons) do
            local id, item
            if safeTable(value) then
                id = safeKey(field(value, "id"))
                item = value
            else
                id = safeKey(value)
                item = {}
            end
            if id and not seen[id] then
                seen[id] = true
                result.freeIcons[#result.freeIcons + 1] = {
                    id = id,
                    order = safeNumber(field(item, "order")) or index,
                    point = safePoint(field(item, "point"), nil),
                    relativePoint = safePoint(field(item, "relativePoint"), nil),
                    x = safeNumber(field(item, "x")),
                    y = safeNumber(field(item, "y")),
                    size = bounded(field(item, "size"), result.size, MIN_SIZE, MAX_SIZE),
                }
            end
        end
        table.sort(result.freeIcons, function(a, b)
            if a.order ~= b.order then return a.order < b.order end
            return a.id < b.id
        end)
    end

    local visibility = field(source, "visibilityByEntry")
    if safeTable(visibility) then
        for key, value in pairs(visibility) do
            local id = safeKey(key)
            if id and type(value) == "string" and not isSecret(value, false) and value == "dimInactive" then
                result.visibilityByEntry[id] = value
            end
        end
    end
    return result
end

local function sortedGroups(config)
    local groups = {}
    for _, group in pairs(config.groups) do groups[#groups + 1] = group end
    table.sort(groups, function(a, b)
        local aOrder, bOrder = a.order or 0, b.order or 0
        if aOrder ~= bOrder then return aOrder < bOrder end
        return a.id < b.id
    end)
    return groups
end

local function entryOrder(entry)
    return safeNumber(field(entry, "order")) or safeNumber(field(entry, "slot")) or 0
end

local function sortedEntryIds(entries)
    local ids = {}
    for id in pairs(entries) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b)
        local ea, eb = entries[a], entries[b]
        local oa, ob = entryOrder(ea), entryOrder(eb)
        if oa ~= ob then return oa < ob end
        return a < b
    end)
    return ids
end

local function getCombat()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, combat = pcall(InCombatLockdown)
    return ok and combat == true
end

local function createFrame(kind, parent, template)
    if type(CreateFrame) ~= "function" then return nil end
    local ok, frame = pcall(CreateFrame, kind, nil, parent, template)
    if ok then return frame end
end

local function createTexture(parent, layer)
    local ok, texture = callResults(parent, "CreateTexture", nil, layer)
    if ok then return texture end
end

local function setTexture(texture, value)
    if type(value) ~= "string" and type(value) ~= "number" then
        callMethod(texture, "SetTexture", nil)
        return
    end
    if isSecret(value, false) then
        callMethod(texture, "SetTexture", nil)
        return
    end
    callMethod(texture, "SetTexture", value)
end

local function entryTexture(entry)
    for _, key in ipairs({ "icon", "iconTexture", "texture" }) do
        local value = field(entry, key)
        if (type(value) == "string" or type(value) == "number") and not isSecret(value, false) then return value end
    end
end

local function entryPresence(entry)
    local presence = field(entry, "presence")
    if type(presence) == "string" and not isSecret(presence, false) then
        if presence == "active" or presence == "inactive" or presence == "unknown" then return presence end
    end
    local active = field(entry, "active")
    if not isSecret(active, false) and type(active) == "boolean" then
        return active and "active" or "inactive"
    end
    return "unknown"
end

local function setPosition(frame, parent, point, relativePoint, x, y)
    callMethod(frame, "ClearAllPoints")
    callMethod(frame, "SetPoint", point or "TOPLEFT", parent, relativePoint or point or "TOPLEFT", x or 0, y or 0)
end

local function safeLabel(value, fallback)
    if type(value) == "string" and not isSecret(value, false) then return value end
    return fallback or ""
end

local function buildLayout(config, entries)
    local assigned, groupIds, freeIds = {}, {}, {}
    local configuredFree = {}
    for _, free in ipairs(config.freeIcons) do configuredFree[free.id] = free end
    local groups = sortedGroups(config)
    for _, group in ipairs(groups) do
        local ids, seen = {}, {}
        for _, id in ipairs(group.entryIds) do
            if not configuredFree[id] then ids[#ids + 1], seen[id], assigned[id] = id, true, true end
        end
        local extras = {}
        for id, entry in pairs(entries) do
            if not assigned[id] and not configuredFree[id] and firstKey(entry, "groupId", "group") == group.id then
                extras[id] = entry
            end
        end
        for _, id in ipairs(sortedEntryIds(extras)) do
            if not seen[id] then ids[#ids + 1], assigned[id] = id, true end
        end
        group.slotIds = ids
        groupIds[group.id] = group
    end

    for _, free in ipairs(config.freeIcons) do
        if not assigned[free.id] then freeIds[#freeIds + 1] = free.id end
        assigned[free.id] = true
    end

    local dynamic = {}
    for id, entry in pairs(entries) do
        if not assigned[id] then
            local groupId = firstKey(entry, "groupId", "group")
            if groupId then
                local bucket = dynamic[groupId]
                if not bucket then bucket = {}; dynamic[groupId] = bucket end
                bucket[id] = entry
            else
                freeIds[#freeIds + 1] = id
            end
            assigned[id] = true
        end
    end

    local dynamicGroupIds = {}
    for id in pairs(dynamic) do dynamicGroupIds[#dynamicGroupIds + 1] = id end
    table.sort(dynamicGroupIds)
    for _, id in ipairs(dynamicGroupIds) do
        local group = groupIds[id]
        if not group then
            group = {
                id = id,
                order = 1000000,
                entryIds = {},
                size = config.size,
                spacing = config.spacing,
                slotIds = {},
            }
            groups[#groups + 1] = group
            groupIds[id] = group
        end
        for _, entryId in ipairs(sortedEntryIds(dynamic[id])) do
            group.slotIds[#group.slotIds + 1] = entryId
        end
    end

    local freeSet = {}
    for _, id in ipairs(freeIds) do freeSet[id] = true end
    for _, free in ipairs(config.freeIcons) do
        if entries[free.id] then freeSet[free.id] = true end
    end
    local unlisted = {}
    for id, entry in pairs(entries) do
        if not assigned[id] and not groupIds[firstKey(entry, "groupId", "group") or ""] then
            unlisted[id] = entry
        end
    end
    for _, id in ipairs(sortedEntryIds(unlisted)) do
        if not freeSet[id] then freeIds[#freeIds + 1] = id; freeSet[id] = true end
    end

    local freeOrder = {}
    for _, free in ipairs(config.freeIcons) do freeOrder[free.id] = free.order end
    table.sort(freeIds, function(a, b)
        local oa, ob = freeOrder[a], freeOrder[b]
        if oa and ob and oa ~= ob then return oa < ob end
        if oa then return true end
        if ob then return false end
        local ea, eb = entries[a], entries[b]
        local eaOrder, ebOrder = ea and entryOrder(ea) or 0, eb and entryOrder(eb) or 0
        if eaOrder ~= ebOrder then return eaOrder < ebOrder end
        return a < b
    end)
    return groups, groupIds, freeIds, configuredFree
end

local function positionConfig(config, id)
    return config.groups[id]
end

local function freeConfig(config, id)
    for _, item in ipairs(config.freeIcons) do
        if item.id == id then return item end
    end
end

function View.Create(parent, config, callbacks)
    local self = {
        config = View.NormalizeConfig(config),
        callbacks = safeTable(callbacks) and callbacks or {},
        groupFrames = {},
        iconFrames = {},
        lastEntries = {},
        lastDrawn = {},
        lastDrawnGroups = {},
        editMode = false,
        requestedEditMode = false,
        visibilityOverrides = {},
        pendingConfig = nil,
        pendingEditMode = nil,
        host = nil,
    }

    self.host = createFrame("Frame", parent)
    callMethod(self.host, "SetAllPoints", parent)
    if not field(self.host, "SetAllPoints") then
        callMethod(self.host, "SetPoint", "TOPLEFT", parent, "TOPLEFT", 0, 0)
        callMethod(self.host, "SetPoint", "BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    end

    local function fireLayoutChanged()
        local callback = field(self.callbacks, "onLayoutChange")
        if type(callback) == "function" then
            pcall(callback, View.NormalizeConfig(self.config))
        end
    end

    local function createButton(parentFrame, label, width, height)
        local button = createFrame("Button", parentFrame, "UIPanelButtonTemplate")
        callMethod(button, "SetSize", width, height)
        callMethod(button, "SetText", label)
        return button
    end

    local function makeToolbar()
        local toolbar = createFrame("Frame", self.host)
        callMethod(toolbar, "SetPoint", "TOPLEFT", self.host, "TOPLEFT", 4, -4)
        callMethod(toolbar, "SetSize", 190, 24)
        self.toolbar = toolbar
        self.addButton = createButton(toolbar, "Add entry", 88, 22)
        callMethod(self.addButton, "SetPoint", "TOPLEFT", toolbar, "TOPLEFT", 0, 0)
        self.groupButton = createButton(toolbar, "Add group", 88, 22)
        callMethod(self.groupButton, "SetPoint", "LEFT", self.addButton, "RIGHT", 4, 0)

        local popup = createFrame("Frame", self.host)
        callMethod(popup, "SetPoint", "TOPLEFT", self.addButton, "BOTTOMLEFT", 0, -2)
        callMethod(popup, "SetSize", 220, 284)
        popup.background = createTexture(popup, "BACKGROUND")
        callMethod(popup.background, "SetAllPoints", popup)
        callMethod(popup.background, "SetColorTexture", 0.05, 0.05, 0.05, 0.95)
        popup.scroll = createFrame("ScrollFrame", popup, "UIPanelScrollFrameTemplate")
        callMethod(popup.scroll, "SetPoint", "TOPLEFT", popup, "TOPLEFT", 4, -4)
        callMethod(popup.scroll, "SetPoint", "BOTTOMRIGHT", popup, "BOTTOMRIGHT", -24, 4)
        popup.content = createFrame("Frame", popup.scroll)
        callMethod(popup.scroll, "SetScrollChild", popup.content)
        callMethod(popup.content, "SetSize", 190, 1)
        popup.rows = {}
        self.rulePopup = popup
        show(popup, false)

        callMethod(self.addButton, "SetScript", "OnClick", function()
            if not self.editMode or getCombat() then return end
            local listRules = field(self.callbacks, "listRules")
            if type(listRules) ~= "function" then return end
            local ok, rules = pcall(listRules)
            if not ok or not safeTable(rules) then return end
            local count = 0
            for index, rule in ipairs(rules) do
                if safeTable(rule) then
                    local id = firstKey(rule, "id", "ruleID", "spellID")
                    if id then
                        count = count + 1
                        local row = popup.rows[count]
                        if not row then
                            row = createButton(popup.content, "", 188, 22)
                            popup.rows[count] = row
                        end
                        callMethod(row, "SetText", safeLabel(field(rule, "name"), id))
                        callMethod(row, "ClearAllPoints")
                        callMethod(row, "SetPoint", "TOPLEFT", popup.content, "TOPLEFT", 0, -((count - 1) * 23))
                        row.ruleId = id
                        callMethod(row, "SetScript", "OnClick", function(clicked)
                            if not getCombat() then
                                local callback = field(self.callbacks, "onAddEntry")
                                if type(callback) == "function" then pcall(callback, clicked.ruleId) end
                            end
                            show(popup, false)
                        end)
                        show(row, true)
                    end
                end
            end
            for index = count + 1, #popup.rows do show(popup.rows[index], false) end
            if count > 0 then
                callMethod(popup.content, "SetSize", 190, math.max(1, count * 23))
                show(popup, true)
            else
                show(popup, false)
            end
        end)
        callMethod(self.groupButton, "SetScript", "OnClick", function()
            if not self.editMode or getCombat() then return end
            local callback = field(self.callbacks, "onAddGroup")
            if type(callback) == "function" then pcall(callback) end
        end)
    end

    local function makeResizeHandle(frame, isGroup)
        local handle = createButton(frame, "◢", 12, 12)
        if not handle then return end
        callMethod(handle, "SetPoint", "BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        callMethod(handle, "SetScript", "OnMouseDown", function(_, button)
            if button and button ~= "LeftButton" then return end
            if not self.editMode or getCombat() then return end
            if type(field(frame, "StartSizing")) ~= "function" then return end
            frame.resizing = true
            frame.liveSize = nil
            callMethod(frame, "StartSizing", "BOTTOMRIGHT")
        end)
        callMethod(handle, "SetScript", "OnMouseUp", function()
            if not frame.resizing then return end
            callMethod(frame, "StopMovingOrSizing")
            frame.resizing = false
            if getCombat() then frame.liveSize = nil; return end
            local size = frame.liveSize or safeNumber(callResult(frame, "GetHeight")) or frame.layoutSize or DEFAULT_SIZE
            size = bounded(size, DEFAULT_SIZE, MIN_SIZE, MAX_SIZE)
            frame.liveSize = nil
            if isGroup then
                local group = self.config.groups[frame.layoutId]
                if not group then
                    local layout = frame.currentLayout or {}
                    local ok, point, relativeFrame, relativePoint, x, y = callResults(frame, "GetPoint", 1)
                    group = {
                        id = frame.layoutId,
                        order = layout.order or 1000000,
                        entryIds = copyIds(layout.slotIds),
                        point = safePoint(point, "TOPLEFT"),
                        relativePoint = safePoint(relativePoint, "TOPLEFT"),
                        x = safeNumber(x),
                        y = safeNumber(y),
                        size = size,
                        spacing = layout.spacing or self.config.spacing,
                    }
                    self.config.groups[frame.layoutId] = group
                end
                group.size = size
            else
                local item = freeConfig(self.config, frame.layoutId)
                if not item then
                    item = { id = frame.layoutId, order = #self.config.freeIcons + 1, size = size }
                    self.config.freeIcons[#self.config.freeIcons + 1] = item
                end
                item.size = size
            end
            self:Update(self.lastEntries)
            fireLayoutChanged()
        end)
        frame.resizeHandle = handle
    end

    local function makeGroupFrame(id)
        local frame = createFrame("Frame", self.host)
        if not frame then return nil end
        frame.layoutId = id
        frame.groupId = id
        frame.slots = {}
        frame.placeholder = createButton(frame, id, DEFAULT_SIZE, DEFAULT_SIZE)
        callMethod(frame.placeholder, "RegisterForDrag", "LeftButton")
        callMethod(frame.placeholder, "SetScript", "OnDragStart", function()
            if self.editMode and not getCombat() then callMethod(frame, "StartMoving") end
        end)
        callMethod(frame.placeholder, "SetScript", "OnDragStop", function()
            callMethod(frame, "StopMovingOrSizing")
            if self.editMode and not getCombat() then self:capturePosition(frame) end
        end)
        frame.resizeHandle = nil
        callMethod(frame, "SetResizable", true)
        if field(frame, "SetResizeBounds") then callMethod(frame, "SetResizeBounds", MIN_SIZE, MIN_SIZE, MAX_SIZE, MAX_SIZE) end
        if not field(frame, "SetResizeBounds") then
            callMethod(frame, "SetMinResize", MIN_SIZE, MIN_SIZE)
            callMethod(frame, "SetMaxResize", MAX_SIZE, MAX_SIZE)
        end
        callMethod(frame, "SetScript", "OnSizeChanged", function(target, _, height)
            if target.resizing and self.editMode and not getCombat() then
                target.liveSize = bounded(height, target.layoutSize or DEFAULT_SIZE, MIN_SIZE, MAX_SIZE)
                self:layoutGroup(target, target.currentLayout, true)
            end
        end)
        makeResizeHandle(frame, true)
        self.groupFrames[id] = frame
        return frame
    end

    local function makeIconFrame(id, parentFrame)
        local frame = createFrame("Button", parentFrame)
        if not frame then return nil end
        frame.layoutId = id
        frame.background = createTexture(frame, "BACKGROUND")
        callMethod(frame.background, "SetAllPoints", frame)
        callMethod(frame.background, "SetColorTexture", 0.04, 0.04, 0.04, 0.85)
        frame.icon = createTexture(frame, "ARTWORK")
        callMethod(frame.icon, "SetPoint", "TOPLEFT", frame, "TOPLEFT", 2, -2)
        callMethod(frame.icon, "SetPoint", "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
        frame.cooldown = createFrame("Cooldown", frame)
        callMethod(frame.cooldown, "SetAllPoints", frame)
        callMethod(frame.cooldown, "EnableMouse", false)
        frame.unknownMarker = callResult(frame, "CreateFontString", nil, "OVERLAY", "GameFontNormal")
        callMethod(frame.unknownMarker, "SetPoint", "CENTER", frame, "CENTER", 0, 0)
        callMethod(frame.unknownMarker, "SetText", "?")
        callMethod(frame.unknownMarker, "SetTextColor", 1, 0.75, 0.2)
        frame.sourceMarker = callResult(frame, "CreateFontString", nil, "OVERLAY", "GameFontNormalSmall")
        callMethod(frame.sourceMarker, "SetPoint", "BOTTOM", frame, "BOTTOM", 0, 1)
        callMethod(frame.sourceMarker, "SetTextColor", 0.9, 0.78, 0.42)
        frame.stackText = callResult(frame, "CreateFontString", nil, "OVERLAY", "NumberFontNormalSmall")
        callMethod(frame.stackText, "SetPoint", "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
        frame.nameText = callResult(frame, "CreateFontString", nil, "OVERLAY", "GameFontNormalSmall")
        callMethod(frame.nameText, "SetPoint", "BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 1)
        frame.removeButton = createButton(frame, "×", 14, 14)
        callMethod(frame.removeButton, "SetPoint", "TOPRIGHT", frame, "TOPRIGHT", 2, 2)
        frame.detachButton = createButton(frame, "F", 14, 14)
        callMethod(frame.detachButton, "SetPoint", "BOTTOMLEFT", frame, "BOTTOMLEFT", -2, -2)
        frame.visibilityButton = createButton(frame, "A", 14, 14)
        callMethod(frame.visibilityButton, "SetPoint", "TOPLEFT", frame, "TOPLEFT", -2, -2)
        frame.moveLeftButton = createButton(frame, "<", 14, 14)
        callMethod(frame.moveLeftButton, "SetPoint", "LEFT", frame, "LEFT", -8, 0)
        frame.moveRightButton = createButton(frame, ">", 14, 14)
        callMethod(frame.moveRightButton, "SetPoint", "RIGHT", frame, "RIGHT", 8, 0)
        callMethod(frame.removeButton, "SetScript", "OnClick", function()
            local entry = frame.entry
            local callback = field(self.callbacks, "onRemoveEntry")
            if self.editMode and not getCombat() and entry and type(callback) == "function" then
                pcall(callback, entry.id)
            end
        end)
        callMethod(frame.detachButton, "SetScript", "OnClick", function()
            local entry = frame.entry
            if self.editMode and not getCombat() and entry and frame.groupId then self:DetachEntry(entry.id) end
        end)
        callMethod(frame.visibilityButton, "SetScript", "OnClick", function()
            local entry = frame.entry
            if self.editMode and not getCombat() and entry then self:ToggleVisibility(entry.id) end
        end)
        callMethod(frame.moveLeftButton, "SetScript", "OnClick", function()
            local entry = frame.entry
            if self.editMode and not getCombat() and entry and frame.groupId then self:MoveEntry(entry.id, -1) end
        end)
        callMethod(frame.moveRightButton, "SetScript", "OnClick", function()
            local entry = frame.entry
            if self.editMode and not getCombat() and entry and frame.groupId then self:MoveEntry(entry.id, 1) end
        end)
        callMethod(frame, "SetScript", "OnEnter", function(self)
            local entry = self.entryData
            if not entry or not GameTooltip then return end
            local name = safeLabel(field(entry, "name"), "")
            local source = field(entry, "source")
            if type(source) ~= "string" or isSecret(source, false) then source = nil end
            local state = entryPresence(entry)
            local duration = field(entry, "durationObject")
            if name == "" and state ~= "unknown" and source ~= "cdm" then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if name ~= "" then GameTooltip:SetText(name) end
            if state == "unknown" then GameTooltip:AddLine(localized("Aura state is unknown."), 1, 0.75, 0.2, true) end
            if source == "cdm" and duration == nil then
                GameTooltip:AddLine(localized("Runtime only available in Blizzard CDM."), 0.9, 0.78, 0.42, true)
            end
            GameTooltip:Show()
        end)
        callMethod(frame, "SetScript", "OnLeave", function()
            if GameTooltip then GameTooltip:Hide() end
        end)
        callMethod(frame, "RegisterForDrag", "LeftButton")
        callMethod(frame, "SetScript", "OnDragStart", function()
            if not self.editMode or getCombat() then return end
            local target = frame.groupFrame or frame
            if type(field(target, "StartMoving")) == "function" then
                frame.movingTarget = target
                callMethod(target, "StartMoving")
            end
        end)
        callMethod(frame, "SetScript", "OnDragStop", function()
            local target = frame.movingTarget or frame
            callMethod(target, "StopMovingOrSizing")
            frame.movingTarget = nil
            if self.editMode and not getCombat() then self:capturePosition(target) end
        end)
        callMethod(frame, "SetResizable", true)
        if field(frame, "SetResizeBounds") then callMethod(frame, "SetResizeBounds", MIN_SIZE, MIN_SIZE, MAX_SIZE, MAX_SIZE) end
        if not field(frame, "SetResizeBounds") then
            callMethod(frame, "SetMinResize", MIN_SIZE, MIN_SIZE)
            callMethod(frame, "SetMaxResize", MAX_SIZE, MAX_SIZE)
        end
        callMethod(frame, "SetScript", "OnSizeChanged", function(target, width, height)
            if target.resizing and self.editMode and not getCombat() then
                target.liveSize = bounded(math.min(width or height, height or width), target.layoutSize or DEFAULT_SIZE, MIN_SIZE, MAX_SIZE)
                callMethod(target.icon, "SetSize", target.liveSize, target.liveSize)
                callMethod(target.cooldown, "SetSize", target.liveSize, target.liveSize)
            end
        end)
        makeResizeHandle(frame, false)
        self.iconFrames[id] = frame
        return frame
    end

    function self:layoutGroup(frame, layout, resizing)
        if not frame or not layout then return end
        frame.currentLayout = layout
        local size = frame.liveSize or layout.size or self.config.size
        local spacing = layout.spacing or self.config.spacing
        local count = #layout.slotIds
        local width = math.max(size, count * size + math.max(0, count - 1) * spacing)
        frame.layoutSize = size
        for index, id in ipairs(layout.slotIds) do
            local slot = self.iconFrames[id]
            if slot then
                callMethod(slot, "SetSize", size, size)
                callMethod(slot.icon, "SetAllPoints", slot)
                callMethod(slot.cooldown, "SetAllPoints", slot)
                callMethod(slot, "ClearAllPoints")
                callMethod(slot, "SetPoint", "TOPLEFT", frame, "TOPLEFT", (index - 1) * (size + spacing), 0)
            end
        end
        if not resizing and not frame.resizing then callMethod(frame, "SetSize", width, size) end
        callMethod(frame.placeholder, "SetSize", size, size)
        callMethod(frame.placeholder, "ClearAllPoints")
        callMethod(frame.placeholder, "SetPoint", "TOPLEFT", frame, "TOPLEFT", 0, 0)
        callMethod(frame.resizeHandle, "ClearAllPoints")
        callMethod(frame.resizeHandle, "SetPoint", "BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    end

    function self:ensureIcon(id, parentFrame, layoutLocked)
        local frame = self.iconFrames[id]
        if not frame then frame = makeIconFrame(id, parentFrame) end
        if frame and frame.parentRef ~= parentFrame and (not layoutLocked or not frame.parentRef) then
            callMethod(frame, "SetParent", parentFrame)
            callMethod(frame, "ClearAllPoints")
            frame.parentRef = parentFrame
            frame.layoutReady = false
        end
        return frame
    end

    function self:effectiveVisibility(id, entry)
        local value = self.config.visibilityByEntry[id]
        if value == "dimInactive" then return value end
        value = self.visibilityOverrides[id]
        if value then return value end
        value = self.config.visibilityByEntry[id]
        if not value then
            value = field(entry, "visibility")
            if type(value) ~= "string" or isSecret(value, false) or value ~= "dimInactive" then value = "activeOnly" end
        end
        return value
    end

    function self:drawIcon(id, entry, parentFrame, groupFrame, size, x, y, point, relativePoint, nextDrawn, layoutLocked)
        local frame = self:ensureIcon(id, parentFrame, layoutLocked)
        if not frame then return false end
        if not layoutLocked or not frame.groupFrame then
            frame.groupFrame = groupFrame
            frame.groupId = groupFrame and groupFrame.layoutId or nil
        end
        frame.entry = entry and { id = id, groupId = frame.groupId } or nil
        frame.layoutSize = size
        callMethod(frame.nameText, "SetWidth", math.max(1, math.floor(size / 2) - 2))
        callMethod(frame.stackText, "SetWidth", math.max(1, math.floor(size / 2) - 2))
        callMethod(frame.nameText, "SetJustifyH", "LEFT")
        callMethod(frame.stackText, "SetJustifyH", "RIGHT")
        if not layoutLocked or not frame.layoutReady then
            callMethod(frame, "SetSize", size, size)
            callMethod(frame, "ClearAllPoints")
            callMethod(frame, "SetPoint", point or "TOPLEFT", parentFrame, relativePoint or point or "TOPLEFT", x or 0, y or 0)
            frame.layoutReady = true
        end
        local presence = entry and entryPresence(entry) or "unknown"
        local active = presence == "active"
        local visibility = self:effectiveVisibility(id, entry)
        local visible = entry ~= nil and (active or presence == "unknown"
            or (visibility == "dimInactive" and presence == "inactive") or self.editMode)
        if not entry then visible = self.editMode end
        local alpha = active and 1 or 0.38
        callMethod(frame, "SetAlpha", alpha)
        local iconValue = entry and entryTexture(entry)
        setTexture(frame.icon, iconValue)
        frame.entryData = entry
        show(frame.unknownMarker, entry ~= nil and presence == "unknown" and visible)
        local source = entry and field(entry, "source")
        if type(source) ~= "string" or isSecret(source, false) then source = nil end
        local duration = entry and field(entry, "durationObject")
        local cdmOnly = source == "cdm" and duration == nil
        callMethod(frame.sourceMarker, "SetText", cdmOnly and localized("CDM") or "")
        show(frame.sourceMarker, cdmOnly and visible)
        local stacks = entry and field(entry, "stacks")
        local stackText
        if type(stacks) == "string" and not isSecret(stacks, false) then
            stackText = stacks
        elseif safeNumber(stacks) then
            stackText = tostring(stacks)
        end
        callMethod(frame.stackText, "SetText", stackText or "")
        show(frame.stackText, self.config.showStacks and visible and stackText ~= nil and stackText ~= "")
        local name = entry and safeLabel(field(entry, "name"), "") or ""
        callMethod(frame.nameText, "SetText", name)
        show(frame.nameText, self.config.showName and visible and name ~= "")
        show(frame, visible)
        show(frame.removeButton, self.editMode and entry ~= nil)
        show(frame.detachButton, self.editMode and entry ~= nil and frame.groupId ~= nil)
        show(frame.visibilityButton, self.editMode and entry ~= nil)
        callMethod(frame.visibilityButton, "SetText", visibility == "dimInactive" and "D" or "A")
        show(frame.moveLeftButton, self.editMode and entry ~= nil and frame.groupId ~= nil)
        show(frame.moveRightButton, self.editMode and entry ~= nil and frame.groupId ~= nil)

        local setDuration = field(frame.cooldown, "SetCooldownFromDurationObject")
        if self.config.showCountdown and duration ~= nil and type(setDuration) == "function" then
            local ok = pcall(setDuration, frame.cooldown, duration)
            show(frame.cooldown, ok and visible)
        else
            show(frame.cooldown, false)
        end
        if visible then nextDrawn[id] = true end
        return visible
    end

    local function entriesById(entries)
        local result = {}
        if not safeTable(entries) then return result end
        for _, entry in ipairs(entries) do
            if safeTable(entry) then
                local id = firstKey(entry, "id", "key", "ruleID")
                if id and not result[id] then result[id] = entry end
            end
        end
        return result
    end

    local function ensureGroupConfig(groupId, layout)
        local group = self.config.groups[groupId]
        if group then return group end
        local frame = self.groupFrames[groupId]
        local ok, point, relativeFrame, relativePoint, x, y = false, nil, nil, nil, nil, nil
        if frame then ok, point, relativeFrame, relativePoint, x, y = callResults(frame, "GetPoint", 1) end
        group = {
            id = groupId,
            order = layout.order or 1000000,
            entryIds = {},
            point = safePoint(point, "TOPLEFT"),
            relativePoint = safePoint(relativePoint, "TOPLEFT"),
            x = safeNumber(x),
            y = safeNumber(y),
            size = layout.size or self.config.size,
            spacing = layout.spacing or self.config.spacing,
        }
        self.config.groups[groupId] = group
        return group
    end

    function self:ToggleVisibility(id)
        if getCombat() then return false end
        id = safeKey(id)
        if not id then return false end
        local entry = entriesById(self.lastEntries)[id]
        if self:effectiveVisibility(id, entry) == "dimInactive" then
            self.config.visibilityByEntry[id] = nil
            self.visibilityOverrides[id] = "activeOnly"
        else
            self.config.visibilityByEntry[id] = "dimInactive"
            self.visibilityOverrides[id] = nil
        end
        self:Update(self.lastEntries)
        fireLayoutChanged()
        return true
    end

    function self:MoveEntry(id, offset)
        if getCombat() or (offset ~= -1 and offset ~= 1) then return false end
        id = safeKey(id)
        local frame = id and self.iconFrames[id]
        local groupId = frame and frame.groupId
        if not groupId then return false end
        local groups = buildLayout(self.config, entriesById(self.lastEntries))
        local layout
        for _, group in ipairs(groups) do
            if group.id == groupId then layout = group; break end
        end
        if not layout then return false end
        local index
        for slot, entryId in ipairs(layout.slotIds) do
            if entryId == id then index = slot; break end
        end
        local target = index and index + offset
        if not target or target < 1 or target > #layout.slotIds then return false end
        local ids = copyIds(layout.slotIds)
        ids[index], ids[target] = ids[target], ids[index]
        ensureGroupConfig(groupId, layout).entryIds = ids
        self:Update(self.lastEntries)
        fireLayoutChanged()
        return true
    end

    function self:DetachEntry(id)
        if getCombat() then return false end
        id = safeKey(id)
        local frame = id and self.iconFrames[id]
        local groupId = frame and frame.groupId
        if not groupId then return false end
        local groups = buildLayout(self.config, entriesById(self.lastEntries))
        local layout
        for _, group in ipairs(groups) do
            if group.id == groupId then layout = group; break end
        end
        if not layout then return false end
        local group = ensureGroupConfig(groupId, layout)
        local ids = {}
        for _, entryId in ipairs(layout.slotIds) do
            if entryId ~= id then ids[#ids + 1] = entryId end
        end
        group.entryIds = ids
        if not freeConfig(self.config, id) then
            self.config.freeIcons[#self.config.freeIcons + 1] = {
                id = id,
                order = #self.config.freeIcons + 1,
                size = frame.layoutSize or self.config.size,
            }
        end
        self:Update(self.lastEntries)
        fireLayoutChanged()
        return true
    end

    function self:Update(entries)
        if getCombat() then
            -- Aura state and native cooldown display still refresh while user layout waits.
        elseif self.pendingConfig or self.pendingEditMode ~= nil or self.pendingReset then
            self:applyPending()
        end
        self.lastEntries = safeTable(entries) and entries or {}
        local currentEntries = entriesById(self.lastEntries)
        local layoutLocked = getCombat()
        local groups, groupById, freeIds, freeById = buildLayout(self.config, currentEntries)
        local nextDrawn, nextGroups = {}, {}
        local defaultY = 0
        for _, layout in ipairs(groups) do
            local frame = self.groupFrames[layout.id] or makeGroupFrame(layout.id)
            if frame then
                local groupConfig = positionConfig(self.config, layout.id) or layout
                local size = layout.size or self.config.size
                local spacing = layout.spacing or self.config.spacing
                frame.layoutId = layout.id
                frame.layoutSize = size
                frame.currentLayout = layout
                if not layoutLocked or not frame.layoutReady then self:layoutGroup(frame, layout) end
                local x = groupConfig.x
                local y = groupConfig.y
                if x == nil then x = 0 end
                if y == nil then y = -defaultY end
                if not layoutLocked or not frame.layoutReady then
                    setPosition(frame, self.host, groupConfig.point, groupConfig.relativePoint, x, y)
                    frame.layoutReady = true
                end
                local anyVisible = false
                for index, id in ipairs(layout.slotIds) do
                    local entry = currentEntries[id]
                    local visible = self:drawIcon(id, entry, frame, frame, size, (index - 1) * (size + spacing), 0,
                        "TOPLEFT", "TOPLEFT", nextDrawn, layoutLocked)
                    anyVisible = anyVisible or visible
                end
                if #layout.slotIds == 0 then
                    show(frame.placeholder, self.editMode)
                    anyVisible = self.editMode
                else
                    show(frame.placeholder, false)
                end
                show(frame.resizeHandle, self.editMode)
                show(frame, anyVisible or self.editMode)
                nextGroups[layout.id] = true
                defaultY = defaultY + size + spacing
            end
        end

        for index, id in ipairs(freeIds) do
            local free = freeById[id]
            local entry = currentEntries[id]
            local size = free and free.size or self.config.size
            local x = free and free.x
            local y = free and free.y
            if x == nil then x = (index - 1) * (size + self.config.spacing) end
            if y == nil then y = -(defaultY + self.config.spacing) end
            local frame = self:ensureIcon(id, self.host, layoutLocked)
            local visible = self:drawIcon(id, entry, self.host, nil, size, x, y,
                free and free.point or "TOPLEFT", free and free.relativePoint or "TOPLEFT", nextDrawn, layoutLocked)
            if frame then show(frame.resizeHandle, self.editMode and visible) end
        end

        for id in pairs(self.lastDrawn) do
            if not nextDrawn[id] then
                local frame = self.iconFrames[id]
                show(frame, false)
                show(frame.cooldown, false)
            end
        end
        for id in pairs(self.lastDrawnGroups) do
            if not nextGroups[id] then show(self.groupFrames[id], false) end
        end
        self.lastDrawn, self.lastDrawnGroups = nextDrawn, nextGroups
        show(self.toolbar, self.editMode)
        if not self.editMode then show(self.rulePopup, false) end
    end

    function self:capturePosition(frame)
        local ok, point, relativeFrame, relativePoint, x, y = callResults(frame, "GetPoint", 1)
        if not ok then return end
        x, y = safeNumber(x), safeNumber(y)
        if x == nil or y == nil then return end
        local record
        if frame.groupId then
            record = self.config.groups[frame.groupId] or ensureGroupConfig(frame.groupId, frame.currentLayout or {})
        else
            record = freeConfig(self.config, frame.layoutId)
            if not record then
                record = { id = frame.layoutId, order = #self.config.freeIcons + 1, size = frame.layoutSize or self.config.size }
                self.config.freeIcons[#self.config.freeIcons + 1] = record
            end
        end
        if not record then return end
        record.point = safePoint(point, "TOPLEFT")
        record.relativePoint = safePoint(relativePoint, record.point)
        record.x, record.y = x, y
        if not frame.groupId then self:sortFreeByPosition() end
        fireLayoutChanged()
    end

    function self:sortFreeByPosition()
        local positions = {}
        for _, item in ipairs(self.config.freeIcons) do
            local frame = self.iconFrames[item.id]
            local ok, point, relativeFrame, relativePoint, x, y = false, nil, nil, nil, nil, nil
            if frame then ok, point, relativeFrame, relativePoint, x, y = callResults(frame, "GetPoint", 1) end
            positions[item.id] = {
                y = ok and safeNumber(y) or item.y or 0,
                x = ok and safeNumber(x) or item.x or 0,
            }
        end
        table.sort(self.config.freeIcons, function(a, b)
            local pa, pb = positions[a.id], positions[b.id]
            if pa.y ~= pb.y then return pa.y > pb.y end
            if pa.x ~= pb.x then return pa.x < pb.x end
            return a.id < b.id
        end)
        for index, item in ipairs(self.config.freeIcons) do item.order = index end
    end

    function self:applyPending()
        if getCombat() then return false end
        if self.pendingConfig then
            self.config = self.pendingConfig
            self.visibilityOverrides = {}
            self.pendingConfig = nil
        end
        if self.pendingReset then
            for _, group in pairs(self.config.groups) do group.x, group.y, group.point, group.relativePoint = nil, nil, nil, nil end
            for _, free in ipairs(self.config.freeIcons) do free.x, free.y, free.point, free.relativePoint = nil, nil, nil, nil end
            self.pendingReset = nil
        end
        if self.pendingEditMode ~= nil then
            self.requestedEditMode = self.pendingEditMode
            self.pendingEditMode = nil
        end
        self:setEditModeNow(self.requestedEditMode)
        return true
    end

    function self:setEditModeNow(enabled)
        self.editMode = enabled == true and not getCombat()
        for _, frame in pairs(self.groupFrames) do
            callMethod(frame, "SetMovable", self.editMode)
            callMethod(frame, "RegisterForDrag", "LeftButton")
            callMethod(frame, "SetScript", "OnDragStart", function(target)
                if self.editMode and not getCombat() then callMethod(target, "StartMoving") end
            end)
            callMethod(frame, "SetScript", "OnDragStop", function(target)
                callMethod(target, "StopMovingOrSizing")
                if self.editMode and not getCombat() then self:capturePosition(target) end
            end)
            show(frame.resizeHandle, self.editMode)
        end
        for _, frame in pairs(self.iconFrames) do
            callMethod(frame, "SetMovable", self.editMode and frame.groupFrame == nil)
            callMethod(frame, "EnableMouse", true)
            show(frame.removeButton, self.editMode and frame.entry ~= nil)
            show(frame.detachButton, self.editMode and frame.entry ~= nil and frame.groupId ~= nil)
            show(frame.visibilityButton, self.editMode and frame.entry ~= nil)
            show(frame.moveLeftButton, self.editMode and frame.entry ~= nil and frame.groupId ~= nil)
            show(frame.moveRightButton, self.editMode and frame.entry ~= nil and frame.groupId ~= nil)
            show(frame.resizeHandle, self.editMode and frame.groupFrame == nil and frame.entry ~= nil)
        end
        show(self.toolbar, self.editMode)
        if not self.editMode then show(self.rulePopup, false) end
    end

    function self:SetConfig(nextConfig)
        local normalized = View.NormalizeConfig(nextConfig)
        if getCombat() then
            self.pendingConfig = normalized
            self.config.visibilityByEntry = normalized.visibilityByEntry
            return false
        end
        self.config = normalized
        self.visibilityOverrides = {}
        self:Update(self.lastEntries)
        return true
    end

    function self:SetEditMode(enabled)
        self.requestedEditMode = enabled == true
        if getCombat() then
            self.pendingEditMode = self.requestedEditMode
            self:setEditModeNow(false)
            self:Update(self.lastEntries)
            return false
        end
        self.pendingEditMode = nil
        self:setEditModeNow(self.requestedEditMode)
        self:Update(self.lastEntries)
        return true
    end

    function self:ResetPosition()
        if getCombat() then
            self.pendingReset = true
            return false
        end
        for _, group in pairs(self.config.groups) do group.x, group.y, group.point, group.relativePoint = nil, nil, nil, nil end
        for _, free in ipairs(self.config.freeIcons) do free.x, free.y, free.point, free.relativePoint = nil, nil, nil, nil end
        self:Update(self.lastEntries)
        fireLayoutChanged()
        return true
    end

    makeToolbar()
    self.eventFrame = createFrame("Frame", self.host)
    if self.eventFrame then
        callMethod(self.eventFrame, "RegisterEvent", "PLAYER_REGEN_ENABLED")
        callMethod(self.eventFrame, "RegisterEvent", "PLAYER_REGEN_DISABLED")
        callMethod(self.eventFrame, "SetScript", "OnEvent", function(_, event)
            if event == "PLAYER_REGEN_DISABLED" then
                self:setEditModeNow(false)
                for _, frame in pairs(self.groupFrames) do
                    callMethod(frame, "StopMovingOrSizing")
                    frame.resizing, frame.liveSize = false, nil
                end
                for _, frame in pairs(self.iconFrames) do
                    callMethod(frame, "StopMovingOrSizing")
                    frame.movingTarget, frame.resizing, frame.liveSize = nil, false, nil
                end
                self:Update(self.lastEntries)
            elseif event == "PLAYER_REGEN_ENABLED" then
                self:applyPending()
                if not self.pendingConfig and self.pendingEditMode == nil then
                    self:setEditModeNow(self.requestedEditMode)
                    self:Update(self.lastEntries)
                end
            end
        end)
    end
    self:Update({})
    return self
end

ns.AuraTrackerView = View
