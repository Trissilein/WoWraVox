local addonName, ns = ...
local launcher
local minimapButton

local function syncMinimapPosition()
    if not (minimapButton and WoWraVoxDB and WoWraVoxDB.minimap) then return end
    local angle = math.rad(WoWraVoxDB.minimap.angle or 220)
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
end

local function createMinimapButton()
    minimapButton = CreateFrame("Button", "WoWraVoxMinimapButton", Minimap)
    minimapButton:SetSize(31, 31)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:RegisterForDrag("LeftButton")
    local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\AddOns\\WoWraVox\\Assets\\WoWraVoxIcon.tga")
    icon:SetSize(21, 21)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(54, 54)
    border:SetPoint("CENTER", 11, -11)
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    minimapButton:SetScript("OnClick", function()
        if ns.ToggleOptions then ns.ToggleOptions() end
    end)
    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("WoWraVox", 1, 0.82, 0.2)
        GameTooltip:AddLine("Klick: Einstellungen öffnen", 0.85, 0.88, 0.94)
        GameTooltip:AddLine("Ziehen: Position ändern", 0.7, 0.75, 0.82)
        GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    minimapButton:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local x, y = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            local centerX, centerY = Minimap:GetCenter()
            if not (x and y and scale and centerX and centerY) then return end
            local atan2Function = math.atan2 or atan2
            if not atan2Function then return end
            WoWraVoxDB.minimap.angle = math.deg(atan2Function(y / scale - centerY, x / scale - centerX))
            syncMinimapPosition()
        end)
    end)
    minimapButton:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    syncMinimapPosition()
end

local function registerBroker()
    if launcher or not (WoWraVoxDB and LibStub) then return end
    local broker = LibStub("LibDataBroker-1.1", true)
    if not broker then return end
    launcher = broker:NewDataObject(addonName, {
        type = "launcher",
        label = "WoWraVox",
        tocname = addonName,
        icon = "Interface\\AddOns\\WoWraVox\\Assets\\WoWraVoxIcon.tga",
        OnClick = function()
            if ns.ToggleOptions then ns.ToggleOptions() end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("WoWraVox", 1, 0.82, 0.2)
            tooltip:AddLine("Klick: Einstellungen öffnen", 0.85, 0.88, 0.94)
        end,
    })
end

local function syncTitan()
    if not (launcher and Titan__InitializedPEW and TitanPanelSettings and TitanPanel_GetButtonNumber
        and TitanUtils_GetWhichBar and TitanPanel_RemoveButton
        and TitanUtils_AddButtonOnBar) then return end
    local settings = WoWraVoxDB and WoWraVoxDB.settings
    if not settings then return end
    local ok, currentBar = pcall(TitanUtils_GetWhichBar, addonName)
    if not ok then return end
    if settings.showTitan then
        if not currentBar then
            local bar = settings.titanBar or "Bar"
            if TitanVariables_GetFrameName and TitanBarDataVars then
                local frameName = TitanVariables_GetFrameName(bar)
                if not (frameName and TitanBarDataVars[frameName] and TitanBarDataVars[frameName].show) then
                    for _, candidate in pairs(TitanBarData or {}) do
                        local state = TitanBarDataVars[candidate.frame_name]
                        if state and state.show then bar = candidate.name; break end
                    end
                end
            end
            pcall(TitanUtils_AddButtonOnBar, bar, addonName)
        end
    elseif currentBar then
        settings.titanBar = currentBar
        pcall(TitanPanel_RemoveButton, addonName)
    end
end

function ns.UpdateLaunchers()
    if not (WoWraVoxDB and WoWraVoxDB.settings) then return end
    local button = minimapButton or _G.WoWraVoxMinimapButton
    if button then button:SetShown(WoWraVoxDB.settings.showMinimap == true) end
    registerBroker()
    syncTitan()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, event, loadedName)
    if event == "ADDON_LOADED" then
        if loadedName == addonName then
            if not WoWraVoxDB then return end
            createMinimapButton()
            ns.UpdateLaunchers()
        elseif loadedName == "Titan" then
            registerBroker()
            ns.UpdateLaunchers()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        registerBroker()
        C_Timer.After(1, ns.UpdateLaunchers)
        C_Timer.After(3, ns.UpdateLaunchers)
    end
end)
