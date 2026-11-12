local _, ns = ...

local function publicID(value)
    if issecretvalue and issecretvalue(value) then return nil end
    if type(value) == "number" and value > 0 and value == math.floor(value) then return value end
    return nil
end

local function field(data, key)
    local ok, value = pcall(function() return data[key] end)
    if not ok or (issecretvalue and issecretvalue(value)) then return nil end
    return value
end

local function hasOwnLine(tooltip, label)
    local ok, name = pcall(tooltip.GetName, tooltip)
    if not ok or not name then return true end
    local lineOK, count = pcall(tooltip.NumLines, tooltip)
    if not lineOK or type(count) ~= "number" then return true end
    for index = 1, count do
        local left = _G[name .. "TextLeft" .. index]
        if left then
            local textOK, text = pcall(left.GetText, left)
            if textOK and (not issecretvalue or not issecretvalue(text)) and text == label then
                return true
            end
        end
    end
    return false
end

local function addID(tooltip, label, id)
    id = publicID(id)
    if not id or hasOwnLine(tooltip, label) then return end
    local ok = pcall(tooltip.AddDoubleLine, tooltip, label, tostring(id), 0.83, 0.68, 0.35, 1, 1, 1)
    if ok then pcall(tooltip.Show, tooltip) end
end

local function decorateSpell(tooltip, data)
    local spellID = publicID(field(data, "id"))
    if not spellID then return end
    addID(tooltip, "WoWraVox Spell-ID", spellID)
end

local function observeSpell(data)
    local spellID = publicID(field(data, "id"))
    if spellID and ns.ObserveSpell then ns.ObserveSpell(spellID, "Seen aura/spell") end
end

local function decorateItem(tooltip, data)
    local itemID = publicID(field(data, "id"))
    if not itemID then return end
    addID(tooltip, "WoWraVox Item-ID", itemID)
    local associated = {}
    if C_Item and C_Item.GetItemSpell then
        local ok, _, spellID = pcall(C_Item.GetItemSpell, itemID)
        spellID = ok and publicID(spellID)
        if spellID then associated[spellID] = true end
    end
    if C_Item and C_Item.GetFirstTriggeredSpellForItem and C_Item.GetItemQualityByID then
        local qualityOK, quality = pcall(C_Item.GetItemQualityByID, itemID)
        if qualityOK and (not issecretvalue or not issecretvalue(quality)) and type(quality) == "number" then
            local spellOK, spellID = pcall(C_Item.GetFirstTriggeredSpellForItem, itemID, quality)
            spellID = spellOK and publicID(spellID)
            if spellID then associated[spellID] = true end
        end
    end
    local ids = {}
    for spellID in pairs(associated) do table.insert(ids, spellID) end
    table.sort(ids)
    if #ids == 0 or hasOwnLine(tooltip, "WoWraVox Item-Spell-ID") then return end
    local strings = {}
    for _, spellID in ipairs(ids) do table.insert(strings, tostring(spellID)) end
    local ok = pcall(tooltip.AddDoubleLine, tooltip, "WoWraVox Item-Spell-ID", table.concat(strings, ", "), 0.83, 0.68, 0.35, 1, 1, 1)
    if ok then pcall(tooltip.Show, tooltip) end
end

local function enabled()
    return type(WoWraVoxDB) == "table" and type(WoWraVoxDB.settings) == "table" and WoWraVoxDB.settings.tooltipIDs
end

local function addSpellID(tooltip, spellID)
    spellID = publicID(spellID)
    if not spellID then return end
    if ns.ObserveSpell then ns.ObserveSpell(spellID, "Seen aura/spell") end
    if enabled() then addID(tooltip, "WoWraVox Spell-ID", spellID) end
end

local function addAuraID(tooltip, aura)
    if aura then addSpellID(tooltip, field(aura, "spellId")) end
end

local function hookAuraByIndex(method)
    if not (GameTooltip[method] and C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
    hooksecurefunc(GameTooltip, method, function(tooltip, unit, index, filter)
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, index, filter)
        if ok then addAuraID(tooltip, aura) end
    end)
end

local function hookAuraByInstance(method)
    if not (GameTooltip[method] and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID) then return end
    hooksecurefunc(GameTooltip, method, function(tooltip, unit, auraInstanceID)
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, auraInstanceID)
        if ok then addAuraID(tooltip, aura) end
    end)
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.UnitAura, function(tooltip, data)
        if data then observeSpell(data) end
        if enabled() and tooltip and data then decorateSpell(tooltip, data) end
    end)
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, function(tooltip, data)
        if data then observeSpell(data) end
        if enabled() and tooltip and data then decorateSpell(tooltip, data) end
    end)
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if enabled() and tooltip and data then decorateItem(tooltip, data) end
    end)
end

if hooksecurefunc and GameTooltip then
    hooksecurefunc(GameTooltip, "SetSpellByID", function(tooltip, spellID)
        addSpellID(tooltip, spellID)
    end)
    hooksecurefunc(GameTooltip, "SetSpellBookItem", function(tooltip, slotIndex, bookType)
        if not (C_SpellBook and C_SpellBook.GetSpellBookItemInfo) then return end
        local ok, info = pcall(C_SpellBook.GetSpellBookItemInfo, slotIndex, bookType)
        if ok and info then addSpellID(tooltip, field(info, "spellID")) end
    end)
    hooksecurefunc(GameTooltip, "SetAction", function(tooltip, actionSlot)
        local ok, actionType, actionID, subType = pcall(GetActionInfo, actionSlot)
        if not ok then return end
        if actionType == "spell" then
            addSpellID(tooltip, actionID)
        elseif actionType == "macro" then
            if subType == "spell" then
                addSpellID(tooltip, actionID)
            elseif not subType and GetMacroSpell then
                local macroOK, spellID, _, legacySpellID = pcall(GetMacroSpell, actionID)
                if macroOK then addSpellID(tooltip, publicID(spellID) or legacySpellID) end
            end
        end
    end)
    hooksecurefunc(GameTooltip, "SetItemByID", function(tooltip, itemID)
        if enabled() then decorateItem(tooltip, { id = itemID }) end
    end)
    hookAuraByIndex("SetUnitAura")
    hookAuraByIndex("SetUnitBuff")
    hookAuraByIndex("SetUnitDebuff")
    hookAuraByInstance("SetUnitAuraByAuraInstanceID")
    hookAuraByInstance("SetUnitBuffByAuraInstanceID")
    hookAuraByInstance("SetUnitDebuffByAuraInstanceID")
end

-- Cooldown Manager buff icons show Blizzard's own tooltip, which carries no spell ID, and the aura data behind it
-- is hidden in combat. The viewer's configuration still names the spell, so the ID comes from there.
local function cdmInfoSpellIDs(info)
    if type(info) ~= "table" then return nil end
    local ids, seen = {}, {}
    local function add(id)
        id = publicID(id)
        if id and not seen[id] then
            seen[id] = true
            table.insert(ids, id)
        end
    end
    add(field(info, "overrideSpellID"))
    add(field(info, "overrideTooltipSpellID"))
    add(field(info, "spellID"))
    local linked = field(info, "linkedSpellIDs")
    if type(linked) == "table" and not (issecrettable and issecrettable(linked)) then
        for _, spellID in ipairs(linked) do add(spellID) end
    end
    return #ids > 0 and ids or nil
end

local function cdmSpellIDs(frame)
    local cdID = frame and frame.cooldownID
    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo) then return nil end
    if type(cdID) ~= "number" or (issecretvalue and issecretvalue(cdID)) then return nil end
    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
    if not ok then return nil end
    return cdmInfoSpellIDs(info)
end

local function scanCDMViewer(name, targets, found)
    local viewer = _G[name]
    local pool = viewer and viewer.itemFramePool
    if not (pool and type(pool.EnumerateActive) == "function") then return false end
    local ok = pcall(function()
        for frame in pool:EnumerateActive() do
            local ids = cdmSpellIDs(frame)
            for _, spellID in ipairs(ids or {}) do
                if targets[spellID] then found[spellID] = true end
            end
        end
    end)
    return ok
end

ns.AuraCDM = ns.AuraCDM or {}
function ns.AuraCDM.CheckTracked(targets)
    local found = {}
    if type(targets) ~= "table" then return found, false end
    local iconsKnown = scanCDMViewer("BuffIconCooldownViewer", targets, found)
    local barsKnown = scanCDMViewer("BuffBarCooldownViewer", targets, found)
    return found, iconsKnown and barsKnown
end

function ns.AuraCDM.GetEffectStatuses(rule)
    local statuses, auraTargets, targetToAuras = {}, {}, {}
    if type(rule) ~= "table" or type(rule.spellIDs) ~= "table" then return statuses end
    local function addTarget(auraID, spellID)
        if not publicID(spellID) then return end
        auraTargets[spellID] = true
        targetToAuras[spellID] = targetToAuras[spellID] or {}
        targetToAuras[spellID][auraID] = true
    end
    for _, auraID in ipairs(rule.spellIDs) do
        auraID = publicID(auraID)
        if auraID then
            local secrecy = ns._Aura and ns._Aura.auraSecrecy and ns._Aura.auraSecrecy(auraID) or "unknown"
            local combatState = ns._Aura and ns._Aura.combatInfo and ns._Aura.combatInfo(auraID, rule)
            if combatState == "spoken" then
                statuses[auraID] = { key = "direct" }
            else
                addTarget(auraID, auraID)
                local castID = ns._Aura and ns._Aura.castIDFor and ns._Aura.castIDFor(rule, auraID)
                addTarget(auraID, castID)
                statuses[auraID] = { key = combatState == "cast" and "ownCast" or "unknown", secrecy = secrecy }
            end
        end
    end
    if not next(auraTargets) then return statuses end

    local priority = { unknown = 1, unavailable = 2, unlearned = 3, ownCast = 4, available = 5, tracked = 6, direct = 7 }
    local function setStatus(auraID, key)
        local current = statuses[auraID]
        if not current or (priority[key] or 0) > (priority[current.key] or 0) then
            statuses[auraID] = { key = key, secrecy = current and current.secrecy }
        end
    end
    local tracked = ns.AuraCDM.CheckTracked(auraTargets)
    for spellID in pairs(tracked or {}) do
        for auraID in pairs(targetToAuras[spellID] or {}) do setStatus(auraID, "tracked") end
    end

    local api = C_CooldownViewer
    local categories = Enum and Enum.CooldownViewerCategory
    if not (api and type(api.GetCooldownViewerCategorySet) == "function"
        and type(api.GetCooldownViewerCooldownInfo) == "function" and categories) then
        return statuses
    end
    if type(api.IsCooldownViewerAvailable) == "function" then
        local ok, available = pcall(api.IsCooldownViewerAvailable)
        if not ok or available ~= true then return statuses end
    end
    local complete = true
    local function scanCategory(category, isTracked)
        if category == nil then complete = false; return end
        local ok, cooldownIDs = pcall(api.GetCooldownViewerCategorySet, category, true)
        if not ok or type(cooldownIDs) ~= "table" or (issecretvalue and issecretvalue(cooldownIDs))
            or (issecrettable and issecrettable(cooldownIDs)) then
            complete = false
            return
        end
        for _, cdID in ipairs(cooldownIDs) do
            cdID = publicID(cdID)
            if cdID then
                local infoOK, info = pcall(api.GetCooldownViewerCooldownInfo, cdID)
                if not infoOK then
                    complete = false
                elseif type(info) == "table" then
                    local matches = {}
                    for _, spellID in ipairs(cdmInfoSpellIDs(info) or {}) do
                        for auraID in pairs(targetToAuras[spellID] or {}) do matches[auraID] = true end
                    end
                    if next(matches) then
                        local hasAuraValue, selfAuraValue = field(info, "hasAura"), field(info, "selfAura")
                        local isKnown = field(info, "isKnown")
                        if hasAuraValue == nil or selfAuraValue == nil or isKnown == nil then complete = false end
                        local hasAura = hasAuraValue == true or selfAuraValue == true
                        if hasAura and isKnown == true then
                            for auraID in pairs(matches) do setStatus(auraID, isTracked and "tracked" or "available") end
                        elseif hasAura and isKnown == false then
                            for auraID in pairs(matches) do setStatus(auraID, "unlearned") end
                        end
                    end
                else
                    complete = false
                end
            end
        end
    end
    scanCategory(categories.HiddenPassive, false)
    scanCategory(categories.TrackedBuff, true)
    scanCategory(categories.TrackedBar, true)

    for auraID, status in pairs(statuses) do
        if status.key == "unknown" and complete then
            if status.secrecy == "always" or status.secrecy == "contextual" then
                status.key = "unavailable"
            end
        end
    end
    return statuses
end

local loweredMainWindow
local settingsHideHook

local function restoreMainWindowStrata()
    local state = loweredMainWindow
    loweredMainWindow = nil
    if state and state.frame and type(state.frame.SetFrameStrata) == "function" then
        pcall(state.frame.SetFrameStrata, state.frame, state.strata)
    end
end

function ns.AuraCDM.OpenSettings()
    if InCombatLockdown and InCombatLockdown() then return false, "combat" end
    local settings = _G.CooldownViewerSettings
    if not (settings and type(settings.ShowUIPanel) == "function") then return false, "unavailable" end

    local main = _G.WoWraVoxOptions
    local canLower = main and type(main.GetFrameStrata) == "function" and type(main.SetFrameStrata) == "function"
    if canLower and settingsHideHook ~= settings and type(settings.HookScript) == "function" then
        local hookOK = pcall(settings.HookScript, settings, "OnHide", restoreMainWindowStrata)
        if hookOK then settingsHideHook = settings end
    end

    local ok = pcall(settings.ShowUIPanel, settings)
    if ok and canLower and settingsHideHook == settings and not loweredMainWindow then
        local readOK, originalStrata = pcall(main.GetFrameStrata, main)
        if readOK and type(originalStrata) == "string" and originalStrata ~= "MEDIUM" then
            local lowerOK = pcall(main.SetFrameStrata, main, "MEDIUM")
            if lowerOK then loweredMainWindow = { frame = main, strata = originalStrata } end
        end
    elseif not ok then
        restoreMainWindowStrata()
    end
    return ok, ok and nil or "unavailable"
end

-- Whether a buff icon is lit: isActive, else wasSetFromAura, else an attached aura instance. nil while the answer is
-- hidden (a secret isActive is never second-guessed) or missing: only positive readings count, never an absence.
local function cdmFrameActive(frame)
    local ok, active, setFromAura, instanceID = pcall(function()
        return frame.isActive, frame.wasSetFromAura, frame.auraInstanceID
    end)
    if not ok then return nil end
    if issecretvalue and issecretvalue(active) then return nil end
    if type(active) == "boolean" then return active end
    if type(setFromAura) == "boolean" and not (issecretvalue and issecretvalue(setFromAura)) then return setFromAura end
    if type(instanceID) == "number" and not (issecretvalue and issecretvalue(instanceID)) then return true end
    return nil
end

-- The icon of a buff lights up and goes dark even while the aura behind it is hidden in combat: hand that to the aura
-- rules (ns._Aura.cdmSignal decides whether it is needed). active = the icon's own alert, nil = read the icon.
local function signalCDMFrame(frame, active, source)
    if active == nil then active = cdmFrameActive(frame) end
    local ids = cdmSpellIDs(frame)
    if ids and ns.SkillTracking and ns.SkillTracking.ObserveLearningCDM then
        pcall(ns.SkillTracking.ObserveLearningCDM, ids, active, source or "Cooldown Manager")
    end
    if active == nil then return end
    if ids and ns._Aura and ns._Aura.cdmSignal then pcall(ns._Aura.cdmSignal, ids, active) end
end

local CDM_STATE_HOOKS = {
    { "TriggerAuraAppliedAlert", true },
    { "TriggerAuraRemovedAlert", false },
    { "OnActiveStateChanged" },
}

local hookedCDMFrames = setmetatable({}, { __mode = "k" })
local hookedCDMPools = setmetatable({}, { __mode = "k" })

local function hookCDMFrame(frame)
    if not frame or hookedCDMFrames[frame] then return end
    hookedCDMFrames[frame] = true
    local ids = cdmSpellIDs(frame)
    if ids and ns.SkillTracking and ns.SkillTracking.ObserveLearningCDM then
        pcall(ns.SkillTracking.ObserveLearningCDM, ids, cdmFrameActive(frame), "Cooldown Manager row")
    end
    if type(frame.HookScript) == "function" then
        pcall(frame.HookScript, frame, "OnEnter", function(self)
            if not enabled() then return end
            local spellIDs = cdmSpellIDs(self)
            local spellID = spellIDs and spellIDs[1]
            if not spellID then return end
            if ns.ObserveSpell then ns.ObserveSpell(spellID, "Seen aura/spell") end
            addID(GameTooltip, "WoWraVox Spell-ID", spellID)
        end)
    end
    if not hooksecurefunc then return end
    for _, hook in ipairs(CDM_STATE_HOOKS) do
        local method, active = hook[1], hook[2]
        local observedMethod = method
        if type(frame[method]) == "function" then
            pcall(hooksecurefunc, frame, method, function(self) pcall(signalCDMFrame, self, active, observedMethod) end)
        end
    end
end

local function hookActiveCDMFrames(pool)
    pcall(function()
        for frame in pool:EnumerateActive() do hookCDMFrame(frame) end
    end)
end

local function hookCDMViewer(name)
    local viewer = _G[name]
    local pool = viewer and viewer.itemFramePool
    if not (pool and type(pool.EnumerateActive) == "function") then return end
    hookActiveCDMFrames(pool)
    if hookedCDMPools[pool] or type(pool.Acquire) ~= "function" or not hooksecurefunc then return end
    hookedCDMPools[pool] = true
    hooksecurefunc(pool, "Acquire", function() hookActiveCDMFrames(pool) end)
end

local function hookCDMViewers()
    hookCDMViewer("BuffIconCooldownViewer")
    hookCDMViewer("BuffBarCooldownViewer")
end

function ns.AuraCDM.RefreshSignals()
    if InCombatLockdown and InCombatLockdown() then return 0 end
    local count = 0
    for _, name in ipairs({ "BuffIconCooldownViewer", "BuffBarCooldownViewer" }) do
        local viewer = _G[name]
        local pool = viewer and viewer.itemFramePool
        if pool and type(pool.EnumerateActive) == "function" then
            pcall(function()
                for frame in pool:EnumerateActive() do
                    if cdmFrameActive(frame) == true then
                        signalCDMFrame(frame, true, "manual-refresh")
                        count = count + 1
                    end
                end
            end)
        end
    end
    return count
end

-- /wvcdm: what the lit buff icons of the Cooldown Manager expose right now, readable or SECRET. Run it in and out of
-- combat to see whether times can be taken from the icons.
local function probeValue(value)
    if issecretvalue and issecretvalue(value) then return "SECRET" end
    return tostring(value)
end

function ns.AuraCDM.Probe()
    local lines = { "combat=" .. tostring(InCombatLockdown and InCombatLockdown()) }
    for _, name in ipairs({ "BuffIconCooldownViewer", "BuffBarCooldownViewer" }) do
        local viewer = _G[name]
        local pool = viewer and viewer.itemFramePool
        if pool and type(pool.EnumerateActive) == "function" then
            pcall(function()
                for frame in pool:EnumerateActive() do
                    local ids = cdmSpellIDs(frame)
                    local parts = { name:sub(1, 8), "ids=" .. (ids and table.concat(ids, "/") or "?") }
                    local function add(label, fn)
                        local ok, value = pcall(fn)
                        parts[#parts + 1] = label .. "=" .. (ok and probeValue(value) or "error")
                    end
                    add("active", function() return frame.isActive end)
                    add("inst", function() return frame.auraInstanceID end)
                    local cd = frame.Cooldown or frame.cooldown
                    if cd and type(cd.GetCooldownTimes) == "function" then
                        add("cdStart", function() return (cd:GetCooldownTimes()) end)
                        add("cdDur", function() return select(2, cd:GetCooldownTimes()) end)
                    else
                        parts[#parts + 1] = "cooldown=" .. (cd and "noTimes" or "none")
                    end
                    add("durObj", function()
                        local obj = C_UnitAuras and C_UnitAuras.GetAuraDuration and C_UnitAuras.GetAuraDuration("player", frame.auraInstanceID)
                        return obj and "yes" or "nil"
                    end)
                    add("remain", function()
                        local obj = C_UnitAuras.GetAuraDuration("player", frame.auraInstanceID)
                        return obj:GetRemainingDuration()
                    end)
                    lines[#lines + 1] = table.concat(parts, " ")
                end
            end)
        end
    end
    return lines
end

if SlashCmdList then
    SLASH_WOWRAVOXCDM1 = "/wvcdm"
    SlashCmdList.WOWRAVOXCDM = function()
        for _, line in ipairs(ns.AuraCDM.Probe()) do print("|cff66ccffWVX CDM|r " .. line) end
    end
end

hookCDMViewers()
local cdmLoader = CreateFrame("Frame")
cdmLoader:RegisterEvent("PLAYER_ENTERING_WORLD")
cdmLoader:SetScript("OnEvent", function()
    if C_Timer and C_Timer.After then C_Timer.After(2, hookCDMViewers) end
end)
