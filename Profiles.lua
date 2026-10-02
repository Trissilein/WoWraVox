local _, ns = ...

local Profiles = {}
ns.Profiles = Profiles
local activeProfileID

local function copyTable(value, isRoot)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do
        if not (isRoot and key == "spellSearchIndex") then
            result[key] = copyTable(child, false)
        end
    end
    return result
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s*(.-)%s*$", "%1"))
end

local function getCharacter()
    local name, realm
    if type(UnitFullName) == "function" then
        local ok
        ok, name, realm = pcall(UnitFullName, "player")
        if not ok then name, realm = nil, nil end
    end
    if not name or name == "" then
        if type(UnitName) ~= "function" then return nil end
        local ok
        ok, name, realm = pcall(UnitName, "player")
        if not ok then name, realm = nil, nil end
    end
    if type(name) ~= "string" or name == "" then return nil end
    if type(realm) ~= "string" or realm == "" then
        if type(GetNormalizedRealmName) == "function" then
            local ok, result = pcall(GetNormalizedRealmName)
            if ok then realm = result end
        end
        if (type(realm) ~= "string" or realm == "") and type(GetRealmName) == "function" then
            local ok, result = pcall(GetRealmName)
            if ok then realm = result end
        end
    end
    realm = type(realm) == "string" and realm or "Unknown realm"
    return (name .. "-" .. realm):lower(), name .. " - " .. realm
end

function Profiles.GetCurrentSpecialization()
    if type(GetSpecialization) ~= "function" or type(GetSpecializationInfo) ~= "function" then return nil end
    local ok, index = pcall(GetSpecialization)
    if not ok or type(index) ~= "number" or index < 1 or index ~= math.floor(index) then return nil end
    local infoOK, specID, specName = pcall(GetSpecializationInfo, index)
    if not infoOK or type(specID) ~= "number" or specID <= 0 then return nil end
    return specID, type(specName) == "string" and specName or tostring(specID)
end

function Profiles.GetCurrentClassInfo()
    if type(UnitClass) ~= "function" then return nil end
    local ok, name, _, classID = pcall(UnitClass, "player")
    if not ok or type(classID) ~= "number" or classID <= 0 then return nil end
    return classID, type(name) == "string" and name or tostring(classID)
end

local function getSpecializationRows(classID)
    local api = C_SpecializationInfo
    if not (api and type(api.GetNumSpecializationsForClassID) == "function"
        and type(api.GetSpecializationInfo) == "function") then return {} end
    local ok, count = pcall(api.GetNumSpecializationsForClassID, classID)
    if not ok or type(count) ~= "number" then return {} end
    local rows = {}
    for index = 1, count do
        local infoOK, specID, name = pcall(api.GetSpecializationInfo, index, false, false, nil, nil, nil, classID)
        if infoOK and type(specID) == "number" and specID > 0 then
            table.insert(rows, { id = specID, name = type(name) == "string" and name or tostring(specID) })
        end
    end
    return rows
end

function Profiles.GetCurrentClassSpecializations()
    local classID, className = Profiles.GetCurrentClassInfo()
    if not classID then return {}, nil end
    local rows = getSpecializationRows(classID)
    for _, row in ipairs(rows) do row.className = className end
    return rows, className
end

function Profiles.GetSpecializationLabel(specID)
    specID = tonumber(specID)
    local api = C_SpecializationInfo
    local classID
    if api and type(api.GetClassIDFromSpecID) == "function" then
        local ok, result = pcall(api.GetClassIDFromSpecID, specID)
        if ok then classID = result end
    end
    if type(classID) == "number" then
        for _, row in ipairs(getSpecializationRows(classID)) do
            if row.id == specID then
                local className
                if C_CreatureInfo and type(C_CreatureInfo.GetClassInfo) == "function" then
                    local ok, info = pcall(C_CreatureInfo.GetClassInfo, classID)
                    if ok and type(info) == "table" then className = info.className end
                end
                if not className and type(GetClassInfo) == "function" then
                    local ok, name = pcall(GetClassInfo, classID)
                    if ok then className = name end
                end
                return (type(className) == "string" and className ~= "" and (className .. " · ") or "") .. row.name
            end
        end
    end
    local key = "Spec ID %d"
    local messages = ns.Locales and ns.Locales[GetLocale and GetLocale() or "enUS"]
    return string.format((messages and messages[key]) or key, specID or 0)
end

function Profiles.NormalizeRuleSpecializations(rule)
    if type(rule) ~= "table" or type(rule.specializationIDs) ~= "table" then
        if type(rule) == "table" then rule.specializationIDs = nil end
        return
    end
    local result, seen = {}, {}
    for _, value in ipairs(rule.specializationIDs) do
        local specID = tonumber(value)
        if specID and specID > 0 and specID == math.floor(specID) and not seen[specID] then
            seen[specID] = true
            table.insert(result, specID)
        end
    end
    table.sort(result)
    rule.specializationIDs = #result > 0 and result or nil
end

function Profiles.RuleMatchesCurrentSpecialization(rule, currentID)
    local ids = type(rule) == "table" and rule.specializationIDs
    if type(ids) ~= "table" or #ids == 0 then return true end
    if currentID == nil then currentID = Profiles.GetCurrentSpecialization() end
    if not currentID then return false end
    for _, specID in ipairs(ids) do
        if specID == currentID then return true end
    end
    return false
end

local function getRoot()
    if WoWraVoxProfilesDB == nil then WoWraVoxProfilesDB = {} end
    local root = WoWraVoxProfilesDB
    if type(root) ~= "table"
        or (root.version ~= nil and root.version ~= 1)
        or (root.profiles ~= nil and type(root.profiles) ~= "table")
        or (root.characters ~= nil and type(root.characters) ~= "table") then
        return nil
    end
    local nextID = tonumber(root.nextProfileID)
    if root.nextProfileID ~= nil and (not nextID or nextID < 0 or nextID ~= math.floor(nextID)) then
        return nil
    end
    root.version = 1
    root.profiles = type(root.profiles) == "table" and root.profiles or {}
    root.characters = type(root.characters) == "table" and root.characters or {}
    root.shared = nil
    root.nextProfileID = math.max(0, math.floor(nextID or 0))
    return root
end

local function getProfile(id)
    local root = getRoot()
    local profile = root and root.profiles[id]
    return type(profile) == "table" and type(profile.data) == "table" and profile or nil
end

local function allocateProfileID(root)
    repeat
        root.nextProfileID = root.nextProfileID + 1
    until not root.profiles["profile-" .. tostring(root.nextProfileID)]
    return "profile-" .. tostring(root.nextProfileID)
end

local function normalizeProfileName(name)
    if type(name) ~= "string" then return "" end
    name = name:gsub("[%c]", "")
    return trim(name):sub(1, 40)
end

local function profileNameExists(root, name)
    local wanted = name:lower()
    for _, profile in pairs(root.profiles) do
        if type(profile) == "table" and type(profile.name) == "string" and profile.name:lower() == wanted then
            return true
        end
    end
    return false
end

local function createProfile(root, name, data)
    name = normalizeProfileName(name)
    if name == "" then return nil, "empty" end
    if profileNameExists(root, name) then return nil, "duplicate" end
    local id = allocateProfileID(root)
    root.profiles[id] = { name = name, data = copyTable(data, true) }
    return id
end

local function firstProfileID(root)
    for id, profile in pairs(root.profiles) do
        if type(profile) == "table" and type(profile.data) == "table" then return id end
    end
end

local function getCharacterBinding(root, create)
    local key, label = getCharacter()
    if not key then return nil end
    local binding = root.characters[key]
    if type(binding) ~= "table" then
        if not create then return nil end
        local templateID = getProfile(root.defaultProfileID) and root.defaultProfileID or firstProfileID(root)
        local template = templateID and root.profiles[templateID]
        if not template then return nil end
        local name = label
        local suffix = 2
        while profileNameExists(root, name) do
            name = label .. " (" .. tostring(suffix) .. ")"
            suffix = suffix + 1
        end
        local id = createProfile(root, name, template.data)
        if not id then return nil end
        binding = { profileID = id, specializations = {} }
        root.characters[key] = binding
    end
    binding.specializations = type(binding.specializations) == "table" and binding.specializations or {}
    if not getProfile(binding.profileID) then
        binding.profileID = getProfile(root.defaultProfileID) and root.defaultProfileID or firstProfileID(root)
    end
    if not getProfile(binding.profileID) then return nil end
    return binding
end

local function resolveCurrentProfile(root)
    local binding = getCharacterBinding(root, true)
    if not binding then return nil end
    return binding.profileID
end

function Profiles.Prepare()
    local root = getRoot()
    if not root or not firstProfileID(root) then return false end
    local profileID = resolveCurrentProfile(root)
    local profile = profileID and getProfile(profileID)
    if not profile then return false end
    if activeProfileID ~= profileID and type(Profiles.onBeforeChange) == "function" then
        Profiles.onBeforeChange()
    end
    activeProfileID = profileID
    WoWraVoxDB = profile.data
    return true
end

function Profiles.CreateInitialProfile()
    local root = getRoot()
    if not root or firstProfileID(root) or type(WoWraVoxDB) ~= "table" then return false end
    local id = createProfile(root, "Default", WoWraVoxDB)
    if not id then return false end
    root.defaultProfileID = id
    local key = getCharacter()
    if key then root.characters[key] = { profileID = id, specializations = {} } end
    activeProfileID = id
    WoWraVoxDB = root.profiles[id].data
    return true
end

function Profiles.ActivateCurrent()
    local previous = activeProfileID
    if not Profiles.Prepare() then return false end
    return true, previous ~= activeProfileID
end

function Profiles.GetProfiles()
    local result = {}
    local root = getRoot()
    if not root then return result end
    for id, profile in pairs(root.profiles) do
        if type(profile) == "table" and type(profile.data) == "table" then
            table.insert(result, { id = id, name = profile.name or id })
        end
    end
    table.sort(result, function(a, b) return a.name:lower() < b.name:lower() end)
    return result
end

function Profiles.ForEachProfileData(callback)
    if type(callback) ~= "function" then return end
    local root = getRoot()
    if not root then return end
    for _, profile in pairs(root.profiles) do
        if type(profile) == "table" and type(profile.data) == "table" then
            callback(profile.data)
        end
    end
end

function Profiles.PrepareSavedVariables()
    local root = getRoot()
    if not root then return end
    root.shared = nil
    Profiles.ForEachProfileData(function(data) data.spellSearchIndex = nil end)
    local active = activeProfileID and getProfile(activeProfileID)
    if active and active.data == WoWraVoxDB then
        WoWraVoxDB = nil
    end
end

function Profiles.GetCharacterProfileID()
    local root = getRoot()
    local binding = root and getCharacterBinding(root, false)
    return binding and binding.profileID or nil
end

function Profiles.GetProfileName(id)
    local profile = id and getProfile(id)
    return profile and profile.name or nil
end

local function activateAndNotify(previous)
    local ok, changed = Profiles.ActivateCurrent()
    if ok and changed and type(Profiles.onChanged) == "function" then Profiles.onChanged(previous, activeProfileID) end
    return ok
end

function Profiles.AssignCharacterProfile(profileID)
    local root = getRoot()
    if not root or not getProfile(profileID) then return false end
    local binding = getCharacterBinding(root, true)
    if not binding then return false end
    local previous = activeProfileID
    binding.profileID = profileID
    activateAndNotify(previous)
    return true
end

function Profiles.CreateCharacterProfile(name)
    local root = getRoot()
    if not root then return nil, "invalid-profile-database" end
    if type(ns.CreateStarterDatabase) ~= "function" then return nil, "defaults-unavailable" end
    local id, errorCode = createProfile(root, name, ns.CreateStarterDatabase())
    if not id then return nil, errorCode end
    if not Profiles.AssignCharacterProfile(id) then
        root.profiles[id] = nil
        return nil, "no-character"
    end
    return id
end

function Profiles.CopyProfile(name, sourceID)
    local root = getRoot()
    if not root then return nil, "invalid-profile-database" end
    sourceID = sourceID or Profiles.GetCharacterProfileID()
    local source = sourceID and getProfile(sourceID)
    if not source then return nil, "missing" end
    if type(Profiles.onBeforeChange) == "function" then Profiles.onBeforeChange() end
    local id, errorCode = createProfile(root, name, source.data)
    if not id then return nil, errorCode end
    if not Profiles.AssignCharacterProfile(id) then
        root.profiles[id] = nil
        return nil, "no-character"
    end
    return id
end
