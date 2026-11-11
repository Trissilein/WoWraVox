local _, ns = ...

local AuraTrackerFamily = {}
local LOCALE_PREFIXES = {
    enUS = "Seal of ",
    deDE = "Siegel ",
}

local function isSecret(value)
    if type(issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(issecretvalue, value)
    return not ok or secret == true
end

local function publicString(value)
    return type(value) == "string" and not isSecret(value) and value or nil
end

local function validSpellID(spellID)
    return type(spellID) == "number" and not isSecret(spellID)
        and spellID > 0 and spellID == math.floor(spellID)
end

local function matchesName(name, locale, manualSubstringFilter)
    name = publicString(name)
    if not name or name == "" then return false end

    local prefix = LOCALE_PREFIXES[locale]
    if prefix then return name:sub(1, #prefix) == prefix end

    manualSubstringFilter = publicString(manualSubstringFilter)
    if not manualSubstringFilter or manualSubstringFilter == "" then return false end
    local ok, matches = pcall(function()
        return name:lower():find(manualSubstringFilter:lower(), 1, true) ~= nil
    end)
    return ok and matches == true
end

-- Scan learned spellbook rows. Rows need numeric spellID and name; explicit learned=false rows are skipped.
-- Prefixes are fixed for enUS/deDE. Other locales need a non-empty literal substring filter.
-- Distinct spell IDs stay distinct, including ranks with different IDs.
function AuraTrackerFamily.ScanCandidates(spellbookRows, locale, manualSubstringFilter)
    local bySpellID = {}
    for _, row in ipairs(type(spellbookRows) == "table" and spellbookRows or {}) do
        local learned
        if type(row) == "table" then learned = row.learned end
        if type(row) == "table" and not (not isSecret(learned) and learned == false)
            and validSpellID(row.spellID) and matchesName(row.name, locale, manualSubstringFilter)
            and not bySpellID[row.spellID] then
            bySpellID[row.spellID] = { spellID = row.spellID, name = publicString(row.name) }
        end
    end

    local candidates = {}
    for _, candidate in pairs(bySpellID) do candidates[#candidates + 1] = candidate end
    table.sort(candidates, function(a, b) return a.spellID < b.spellID end)
    return candidates
end

-- Persist new candidates into one family out of combat. Existing spell rows, exclusions, and
-- notification settings stay untouched. New families are returned only when at least one row is added.
-- New rows keep learned spell ID as castID; auraID stays unknown until ConfirmMapping receives evidence.
function AuraTrackerFamily.Sync(family, candidates, inCombat)
    if not isSecret(inCombat) and inCombat == true then return family, 0 end
    if family ~= nil and (type(family) ~= "table" or type(family.spells) ~= "table"
        or (family.excludedSpellIDs ~= nil and type(family.excludedSpellIDs) ~= "table")) then
        return family, 0
    end

    local known = {}
    if family then
        for _, row in ipairs(family.spells) do
            if type(row) == "table" and validSpellID(row.spellID) then known[row.spellID] = true end
        end
    end

    local additions = {}
    for _, candidate in ipairs(type(candidates) == "table" and candidates or {}) do
        local spellID = type(candidate) == "table" and candidate.spellID or nil
        local name = type(candidate) == "table" and publicString(candidate.name) or nil
        if validSpellID(spellID) and type(name) == "string" and name ~= "" then
            local excluded = family and family.excludedSpellIDs and family.excludedSpellIDs[spellID] == true
            if not excluded and not known[spellID] then
                known[spellID] = true
                additions[#additions + 1] = { spellID = spellID, name = name }
            end
        end
    end

    if not family then
        if #additions == 0 then return nil, 0 end
        family = { spells = {}, excludedSpellIDs = {} }
    elseif #additions > 0 and family.excludedSpellIDs == nil then
        family.excludedSpellIDs = {}
    end

    for _, candidate in ipairs(additions) do
        family.spells[#family.spells + 1] = {
            spellID = candidate.spellID,
            name = candidate.name,
            castID = candidate.spellID,
            auraID = nil,
            mappingVerified = false,
        }
    end
    return family, #additions
end

-- Confirm cast/aura mapping only with explicit matching CDM or learning evidence.
-- Evidence shape: { source = "cdm"|"learning", confirmed = true, castID = n, auraID = n }.
function AuraTrackerFamily.ConfirmMapping(family, spellID, castID, auraID, evidence)
    if type(family) ~= "table" or type(family.spells) ~= "table" then return false, "family-required" end
    if not validSpellID(spellID) or not validSpellID(castID) or not validSpellID(auraID) then
        return false, "valid-spell-ids-required"
    end
    local source = type(evidence) == "table" and publicString(evidence.source) or nil
    local evidenceCastID = type(evidence) == "table" and validSpellID(evidence.castID) and evidence.castID or nil
    local evidenceAuraID = type(evidence) == "table" and validSpellID(evidence.auraID) and evidence.auraID or nil
    local confirmed = type(evidence) == "table" and not isSecret(evidence.confirmed) and evidence.confirmed == true
    if type(evidence) ~= "table" or (source ~= "cdm" and source ~= "learning")
        or not confirmed or evidenceCastID ~= castID or evidenceAuraID ~= auraID then
        return false, "matching-cdm-or-learning-evidence-required"
    end

    for _, row in ipairs(family.spells) do
        if type(row) == "table" and row.spellID == spellID then
            row.castID = castID
            row.auraID = auraID
            row.mappingVerified = true
            row.mappingEvidence = { source = source, confirmed = true, castID = castID, auraID = auraID }
            return true, row
        end
    end
    return false, "spell-not-found"
end

ns.AuraTrackerFamily = AuraTrackerFamily
