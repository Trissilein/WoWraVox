local _, ns = ...

-- Spell ranks (WoW Forever, Classic-era content): "Lay on Hands" rank 1/2/3 are different spell IDs. A rule with
-- `allRanks` treats every rank of a configured spell as that spell. A family = all spell IDs with the same name and
-- the same icon (the icon keeps NPC/boss spells of the same name out). Families are found by one background scan
-- over the spell IDs and kept in WoWraVoxProfilesDB.spellRanks, so each spell is scanned once.
local SpellRanks = {}
ns.SpellRanks = SpellRanks

SpellRanks.MAX_ID = 1500000
SpellRanks.CHUNK = 25000

local api = {
    name = function(id)
        if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
        return info and info.name
    end,
    icon = function(id)
        if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(id) end
    end,
    after = function(callback) C_Timer.After(0, callback) end,
}
SpellRanks.api = api  -- tests swap the functions

local familyOfID = {}  -- spellID -> list of IDs (session cache)
local pending, scanning = {}, false
local listeners = {}

local function plain(value)
    if value == nil then return nil end
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then return nil end
    end
    return value
end

local function identity(id)
    local okName, name = pcall(api.name, id)
    local okIcon, icon = pcall(api.icon, id)
    name, icon = okName and plain(name) or nil, okIcon and plain(icon) or nil
    if type(name) ~= "string" or name == "" then return nil end
    return name .. "|" .. tostring(icon)
end

local function store()
    if type(WoWraVoxProfilesDB) ~= "table" then return nil end
    WoWraVoxProfilesDB.spellRanks = type(WoWraVoxProfilesDB.spellRanks) == "table" and WoWraVoxProfilesDB.spellRanks or {}
    return WoWraVoxProfilesDB.spellRanks
end

-- All IDs of the family of `id`, or nil while unknown (a scan is queued).
function SpellRanks.FamilyOf(id)
    id = tonumber(id)
    if not id then return nil end
    if familyOfID[id] then return familyOfID[id] end
    local key = identity(id)
    if not key then return nil end
    local saved = store()
    local ids = saved and saved[key]
    if type(ids) == "table" then
        for _, member in ipairs(ids) do familyOfID[member] = ids end
        familyOfID[id] = familyOfID[id] or ids
        return ids
    end
    pending[key] = id
    return nil
end

-- True when a and b are the same spell or ranks of it (only known families count).
function SpellRanks.SameFamily(a, b)
    if a == b then return true end
    local family = SpellRanks.FamilyOf(a)
    if not family then return false end
    for _, member in ipairs(family) do
        if member == b then return true end
    end
    return false
end

-- IDs plus their known rank IDs (each once).
function SpellRanks.Expand(ids)
    local out, seen = {}, {}
    for _, id in ipairs(ids or {}) do
        for _, member in ipairs(SpellRanks.FamilyOf(id) or { id }) do
            if not seen[member] then seen[member] = true; out[#out + 1] = member end
        end
    end
    return out
end

function SpellRanks.OnScanned(callback) listeners[#listeners + 1] = callback end

-- Scans for every queued family in one pass (chunked, one chunk per frame). Returns false when idle.
function SpellRanks.RunScan()
    if scanning or not next(pending) then return false end
    scanning = true
    local wanted = pending
    pending = {}
    local found = {}
    for key in pairs(wanted) do found[key] = {} end
    local nextID = 1
    local function step()
        local last = math.min(nextID + SpellRanks.CHUNK - 1, SpellRanks.MAX_ID)
        for id = nextID, last do
            local okName, name = pcall(api.name, id)
            if okName and type(name) == "string" and name ~= "" then
                local key = identity(id)
                if key and found[key] then table.insert(found[key], id) end
            end
        end
        nextID = last + 1
        if nextID <= SpellRanks.MAX_ID then
            api.after(step)
            return
        end
        local saved = store() or {}
        for key, ids in pairs(found) do
            if #ids == 0 then ids = { wanted[key] } end
            saved[key] = ids
            for _, member in ipairs(ids) do familyOfID[member] = ids end
        end
        scanning = false
        for _, callback in ipairs(listeners) do pcall(callback) end
        SpellRanks.RunScan()
    end
    step()
    return true
end

function SpellRanks.Reset()
    familyOfID, pending, scanning = {}, {}, false
end
