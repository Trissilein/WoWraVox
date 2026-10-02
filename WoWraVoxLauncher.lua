local addonName, ns = ...
local launcher

local function openSettings()
    if ns.ToggleOptions then ns.ToggleOptions() end
end

local function addTooltipLines(tooltip)
    tooltip:AddLine("WoWraVox", 1, 0.82, 0.2)
    tooltip:AddLine(ns.L("Click: open settings"), 0.85, 0.88, 0.94)
end

-- AddonCompartment callbacks named in WoWraVox.toc. The argument list is not documented on
-- warcraft.wiki.gg/wiki/TOC_format, so every argument is optional and checked before use.
function WoWraVox_OnAddonCompartmentClick()
    openSettings()
end

function WoWraVox_OnAddonCompartmentEnter(_, frame)
    if not GameTooltip then return end
    if type(frame) == "table" and frame.GetObjectType then
        GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
    else
        GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR")
    end
    addTooltipLines(GameTooltip)
    GameTooltip:Show()
end

function WoWraVox_OnAddonCompartmentLeave()
    if GameTooltip then GameTooltip:Hide() end
end

-- LibDataBroker launcher for Titan Panel and other displays. Retried on PLAYER_ENTERING_WORLD in case the
-- library loads after this addon.
local function registerBroker()
    if launcher or not LibStub then return end
    local broker = LibStub("LibDataBroker-1.1", true)
    if not broker then return end
    launcher = broker:NewDataObject(addonName, {
        type = "launcher",
        label = "WoWraVox",
        tocname = addonName,
        icon = "Interface\\AddOns\\WoWraVox\\Assets\\WoWraVoxIcon.tga",
        OnClick = openSettings,
        OnTooltipShow = addTooltipLines,
    })
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, event, loadedName)
    if event == "ADDON_LOADED" and loadedName ~= addonName then return end
    registerBroker()
    if launcher then frame:UnregisterAllEvents() end
end)
