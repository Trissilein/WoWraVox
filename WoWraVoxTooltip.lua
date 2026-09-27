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

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    local function enabled()
        return type(WoWraVoxDB) == "table" and type(WoWraVoxDB.settings) == "table" and WoWraVoxDB.settings.tooltipIDs
    end
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
