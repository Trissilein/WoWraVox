local checks = 0
local frameSerial = 0
local combat = false
local frames = {}

local function check(name, condition)
    if not condition then error("FAIL " .. name) end
    checks = checks + 1
    print("PASS " .. name)
end

local function region(kind, parent)
    frameSerial = frameSerial + 1
    local object = {
        kind = kind,
        parent = parent,
        id = frameSerial,
        shown = true,
        scripts = {},
        setPointCalls = 0,
        setParentCalls = 0,
        setSizeCalls = 0,
    }
    function object:Show() self.shown = true end
    function object:Hide() self.shown = false end
    function object:SetSize(width, height)
        local changed = self.width ~= width or self.height ~= height
        self.width, self.height = width, height
        self.setSizeCalls = self.setSizeCalls + 1
        if changed and self.scripts.OnSizeChanged then self.scripts.OnSizeChanged(self, width, height) end
    end
    function object:GetWidth() return self.width or 0 end
    function object:GetHeight() return self.height or 0 end
    function object:SetWidth(width) self.width = width end
    function object:SetHeight(height) self.height = height end
    function object:SetJustifyH(value) self.justifyH = value end
    function object:SetPoint(point, relativeTo, relativePoint, x, y)
        self.point = { point, relativeTo, relativePoint, x, y }
        self.setPointCalls = self.setPointCalls + 1
    end
    function object:GetPoint() if self.point then return table.unpack(self.point) end end
    function object:ClearAllPoints() self.point = nil end
    function object:SetAllPoints(target) self.allPoints = target end
    function object:SetScrollChild(target) self.scrollChild = target end
    function object:SetParent(target) self.parent = target; self.setParentCalls = self.setParentCalls + 1 end
    function object:SetAlpha(value) self.alpha = value end
    function object:SetText(value) self.text = value end
    function object:SetTextColor(...) self.textColor = { ... } end
    function object:SetTexture(value) self.texture = value end
    function object:SetColorTexture(...) self.colorTexture = { ... } end
    function object:SetScript(name, callback) self.scripts[name] = callback end
    function object:RegisterEvent(event) self.events = self.events or {}; self.events[event] = true end
    function object:RegisterForDrag(...) self.dragButtons = { ... } end
    function object:EnableMouse(value) self.mouseEnabled = value end
    function object:SetMovable(value) self.movable = value end
    function object:SetResizable(value) self.resizable = value end
    function object:SetResizeBounds(...) self.resizeBounds = { ... } end
    function object:StartMoving() self.moving = true end
    function object:StartSizing(edge) self.sizing = edge end
    function object:StopMovingOrSizing() self.moving, self.sizing = false, nil end
    function object:CreateTexture(_, layer) return region("Texture:" .. tostring(layer), self) end
    function object:CreateFontString(_, layer, font) return region("FontString:" .. tostring(layer) .. ":" .. tostring(font), self) end
    function object:SetCooldownFromDurationObject(duration)
        self.durationCalls = (self.durationCalls or 0) + 1
        self.durationObject = duration
    end
    function object:Trigger(script, ...)
        local callback = self.scripts[script]
        if callback then return callback(self, ...) end
    end
    frames[#frames + 1] = object
    return object
end

function CreateFrame(kind, _, parent)
    return region(kind, parent)
end

UIParent = region("Frame", nil)
InCombatLockdown = function() return combat end
issecretvalue = function(value) return value == "SECRET" end
issecrettable = function() return false end
GameTooltip = region("Tooltip", UIParent)

local View = ns.AuraTrackerView
check("module API exists", type(View) == "table" and type(View.Create) == "function")

local defaults = View.NormalizeConfig({
    groups = { g = { entryIds = { "b", "a" } } },
    visibilityByEntry = { a = "activeOnly", b = "dimInactive" },
})
check("display defaults: native countdown and stacks on, name off",
    defaults.showCountdown == true and defaults.showStacks == true and defaults.showName == false)
check("config defaults: 40px icons, 6px spacing",
    defaults.size == 40 and defaults.spacing == 6 and defaults.groups.g.size == 40 and defaults.groups.g.spacing == 6)
check("visibility config omits default activeOnly", defaults.visibilityByEntry.a == nil
    and defaults.visibilityByEntry.b == "dimInactive")
check("group order retained", defaults.groups.g.entryIds[1] == "b" and defaults.groups.g.entryIds[2] == "a")

local durationMeta = {
    __tostring = function() error("duration must stay opaque") end,
    __eq = function() error("duration must not be compared") end,
}
local durationA = setmetatable({}, durationMeta)
local durationUnknown = setmetatable({}, durationMeta)
local config = {
    groups = {
        g = { order = 1, entryIds = { "a", "b", "u", "gone", "ua" }, x = 10, y = -20, size = 40, spacing = 6 },
    },
    freeIcons = { { id = "f", order = 1, x = 100, y = -20, size = 32 } },
    visibilityByEntry = { b = "dimInactive", u = "dimInactive" },
}
local layoutChanges, addedRules, removedRules, addedGroups = {}, {}, {}, 0
local foreignBlizzardFrame = CreateFrame("Button", nil, UIParent)
local foreignParent, foreignPointCalls, foreignSizeCalls = foreignBlizzardFrame.parent,
    foreignBlizzardFrame.setPointCalls, foreignBlizzardFrame.setSizeCalls
local view = View.Create(UIParent, config, {
    onLayoutChange = function(nextConfig) layoutChanges[#layoutChanges + 1] = nextConfig end,
    listRules = function() return { { id = "new-rule", name = "New Rule" } } end,
    onAddEntry = function(id) addedRules[#addedRules + 1] = id end,
    onRemoveEntry = function(id) removedRules[#removedRules + 1] = id end,
    onAddGroup = function() addedGroups = addedGroups + 1 end,
})

local entries = {
    { id = "u", groupId = "g", order = 3, presence = "unknown", icon = 103, name = "Unknown aura", stacks = 2, durationObject = durationUnknown },
    { id = "f", groupId = "g", presence = "active", icon = 106, durationObject = durationA, cdmFrame = foreignBlizzardFrame },
    { id = "b", groupId = "g", order = 2, presence = "inactive", icon = 102 },
    { id = "a", groupId = "g", order = 1, presence = "active", icon = 101, name = "Aura A", stacks = 3, durationObject = durationA },
    { id = "ua", groupId = "g", order = 5, presence = "unknown", icon = 105 },
}
view:Update(entries)
local group = view.groupFrames.g
local iconA, iconB, iconU, iconGone = view.iconFrames.a, view.iconFrames.b, view.iconFrames.u, view.iconFrames.gone
local function pointX(frame) local _, _, _, x = frame:GetPoint(); return x end
check("view owns frames under its host", iconA.parent == group and group.parent == view.host and group ~= foreignBlizzardFrame)
check("group slots fixed at 0, 46, 92, 138px", pointX(iconA) == 0 and pointX(iconB) == 46
    and pointX(iconU) == 92 and pointX(iconGone) == 138)
check("unknown remains visible while retaining stable slot",
    view.iconFrames.ua.shown and view.iconFrames.ua.unknownMarker.shown and pointX(view.iconFrames.ua) == 184)
check("dimInactive displays inactive entry dimmed", iconB.shown and iconB.alpha == 0.38)
check("dimInactive displays unknown entry with marker", iconU.shown and iconU.unknownMarker.shown)
check("missing entry has stable reserved slot", iconGone.shown == false and pointX(iconGone) == 138)
check("opaque duration sent only to native Cooldown", rawequal(iconA.cooldown.durationObject, durationA)
    and iconA.cooldown.durationCalls == 1 and rawequal(iconU.cooldown.durationObject, durationUnknown))
check("name hidden by default, stacks shown by default", iconA.nameText.shown == false and iconA.stackText.shown
    and iconA.stackText.text == "3" and iconA.nameText.width == 18 and iconA.stackText.width == 18)
check("foreign CDM frame untouched", foreignBlizzardFrame.parent == foreignParent
    and foreignBlizzardFrame.setPointCalls == foreignPointCalls and foreignBlizzardFrame.setSizeCalls == foreignSizeCalls)
check("free icon has independent size and position", view.iconFrames.f.width == 32 and pointX(view.iconFrames.f) == 100)

local iconCount, stableA = frameSerial, iconA
local changedEntries = {
    { id = "u", groupId = "g", order = 3, presence = "unknown", icon = 103, durationObject = durationUnknown },
    { id = "f", groupId = "g", presence = "active", icon = 106, durationObject = durationA },
    { id = "b", groupId = "g", order = 2, presence = "active", icon = 102 },
    { id = "a", groupId = "g", order = 1, presence = "active", icon = 101, durationObject = durationA },
    { id = "ua", groupId = "g", order = 5, presence = "unknown", icon = 105 },
}
view:Update(changedEntries)
check("frames reused across aura updates", view.iconFrames.a == stableA and frameSerial == iconCount)
check("aura updates continue and native cooldown refreshed", iconB.shown and iconA.cooldown.durationCalls == 2)

view:SetEditMode(true)
check("edit preview reveals inactive and empty slots", iconGone.shown and view.iconFrames.ua.shown and view.toolbar.shown)
view.iconFrames.ua.visibilityButton:Trigger("OnClick")
check("visibility control toggles entry to dimInactive",
    view.config.visibilityByEntry.ua == "dimInactive" and view.iconFrames.ua.unknownMarker.shown)
view.iconFrames.ua.visibilityButton:Trigger("OnClick")
check("visibility control toggles back to activeOnly",
    view.config.visibilityByEntry.ua == nil)
local _, _, _, groupX, groupY = group:GetPoint()
view.iconFrames.b.moveLeftButton:Trigger("OnClick")
check("group reorder swaps slots without moving group",
    view.config.groups.g.entryIds[1] == "b" and pointX(view.iconFrames.b) == 0
    and select(4, group:GetPoint()) == groupX and select(5, group:GetPoint()) == groupY)
check("move control at end of group safely no-ops", view:MoveEntry("ua", 1) == false)
view.iconFrames.b.detachButton:Trigger("OnClick")
check("detach moves icon to free list and reuses frame",
    view.iconFrames.b == iconB and iconB.parent == view.host and view.config.freeIcons[2].id == "b")
local savedOrderAndVisibility = false
for _, saved in ipairs(layoutChanges) do
    if saved.groups.g.entryIds[1] == "b" and saved.visibilityByEntry.ua == nil then
        savedOrderAndVisibility = true
    end
end
check("layout callback returns serializable visibility and order", savedOrderAndVisibility)

iconB:Trigger("OnDragStart")
iconB:SetPoint("TOPLEFT", view.host, "TOPLEFT", 0, -20)
iconB:Trigger("OnDragStop")
check("free icon drag reorders serialized array", view.config.freeIcons[1].id == "b"
    and view.config.freeIcons[2].id == "f")
iconB.resizeHandle:Trigger("OnMouseDown", "LeftButton")
iconB:SetSize(50, 50)
iconB.resizeHandle:Trigger("OnMouseUp")
check("free icon resize persists per-icon size", view.config.freeIcons[1].size == 50 and iconB.width == 50)

view.addButton:Trigger("OnClick")
check("toolbar lists host rules", view.rulePopup.shown and view.rulePopup.rows[1].text == "New Rule")
view.rulePopup.rows[1]:Trigger("OnClick")
check("toolbar adds selected rule by ID", addedRules[1] == "new-rule")
view.groupButton:Trigger("OnClick")
check("toolbar asks host to add group", addedGroups == 1)
iconA.removeButton:Trigger("OnClick")
check("entry removal delegated to host", removedRules[1] == "a")

local groupFramePoint = group:GetPoint()
group:Trigger("OnDragStart")
group:SetPoint("TOPLEFT", view.host, "TOPLEFT", 33, -44)
group:Trigger("OnDragStop")
check("group drag persists position", view.config.groups.g.x == 33 and view.config.groups.g.y == -44)
group.resizeHandle:Trigger("OnMouseDown", "LeftButton")
group:SetSize(group.width, 54)
group.resizeHandle:Trigger("OnMouseUp")
check("group resize persists size and fixed text regions", view.config.groups.g.size == 54
    and iconA.width == 54 and iconA.nameText.width == 25 and iconA.stackText.width == 25)

combat = true
view.eventFrame:Trigger("OnEvent", "PLAYER_REGEN_DISABLED")
local lockedX, lockedSize = view.config.groups.g.x, group.width
local pending = View.NormalizeConfig(view.config)
pending.groups.g.x, pending.groups.g.y, pending.groups.g.size = 99, -99, 70
pending.visibilityByEntry.ua = "dimInactive"
pending.visibilityByEntry.a = "dimInactive"
check("combat defers config layout", view:SetConfig(pending) == false
    and view.config.groups.g.x == lockedX and group.width == lockedSize)
local combatEntries = {
    { id = "a", groupId = "g", presence = "inactive", icon = 101, durationObject = durationA },
    { id = "u", groupId = "g", presence = "unknown", icon = 103 },
    { id = "b", groupId = "g", presence = "active", icon = 102 },
    { id = "ua", groupId = "g", presence = "unknown", icon = 105 },
}
view:Update(combatEntries)
check("combat does not block aura rendering", view.iconFrames.b.shown and view.iconFrames.a.shown
    and iconA.cooldown.durationCalls >= 3 and view.iconFrames.ua.unknownMarker.shown)
combat = false
view.eventFrame:Trigger("OnEvent", "PLAYER_REGEN_ENABLED")
check("deferred layout applies after combat", view.config.groups.g.x == 99 and view.config.groups.g.size == 70
    and pointX(group) == 99 and group.width >= 70)
combat = true
check("reset position waits during combat", view:ResetPosition() == false and view.config.groups.g.x == 99)
combat = false
view.eventFrame:Trigger("OnEvent", "PLAYER_REGEN_ENABLED")
check("deferred reset clears position", view.config.groups.g.x == nil and view.config.groups.g.y == nil)

local displayView = View.Create(UIParent, { showCountdown = false, showName = true, showStacks = false }, {})
local noTimer = setmetatable({}, durationMeta)
displayView:Update({ { id = "display", presence = "active", icon = 201, name = "Visible name", stacks = 4, durationObject = noTimer } })
local displayIcon = displayView.iconFrames.display
check("display options control labels and timer", displayIcon.nameText.shown and displayIcon.nameText.text == "Visible name"
    and displayIcon.stackText.shown == false and displayIcon.cooldown.durationCalls == nil)
displayView:Update({ { id = "cdm", presence = "active", icon = 202, source = "cdm" } })
local cdmIcon = displayView.iconFrames.cdm
check("CDM-only runtime gets explicit marker without guessed cooldown",
    cdmIcon.sourceMarker.shown and cdmIcon.sourceMarker.text == "CDM" and cdmIcon.cooldown.shown == false)

print("PASS all AuraTrackerView checks: " .. checks)
