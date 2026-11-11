issecretvalue = function(value) return value == 999 end

local function check(name, condition)
    if not condition then error("FAIL " .. name) end
    print("PASS " .. name)
end

local familyHelpers = ns.AuraTrackerFamily
check("helpers are exported", type(familyHelpers) == "table")

local enUS = familyHelpers.ScanCandidates({
    { spellID = 203, name = "Seal of Example II", rank = 2 },
    { spellID = 101, name = "Seal of Example I", rank = 1 },
    { spellID = 303, name = "Greater Seal of Example" },
    { spellID = 404, name = "Seal of Unlearned", learned = false },
    { spellID = 505, name = "Seal of Example I", learned = true },
    { spellID = 0, name = "Seal of Invalid" },
}, "enUS", "ignored filter")
check("enUS matches exact Seal of prefix", #enUS == 3
    and enUS[1].spellID == 101 and enUS[2].spellID == 203 and enUS[3].spellID == 505)
check("rank IDs remain separate", enUS[1].spellID ~= enUS[2].spellID)

local deDE = familyHelpers.ScanCandidates({
    { spellID = 610, name = "Siegel der Probe" },
    { spellID = 611, name = "Seal of Probe" },
}, "deDE")
check("deDE uses Siegel prefix", #deDE == 1 and deDE[1].spellID == 610)

local otherLocale = familyHelpers.ScanCandidates({
    { spellID = 701, name = "Sceau de la paix" },
    { spellID = 702, name = "sceau de guerre" },
}, "frFR", "Sceau")
check("other locale uses literal case-insensitive substring", #otherLocale == 2
    and otherLocale[1].spellID == 701 and otherLocale[2].spellID == 702)
check("other locale needs non-empty filter", #familyHelpers.ScanCandidates({
    { spellID = 703, name = "Sceau de la paix" },
}, "frFR") == 0 and #familyHelpers.ScanCandidates({
    { spellID = 704, name = "anything" },
}, "frFR", "") == 0)

local empty, emptyAdded = familyHelpers.Sync(nil, {}, false)
check("no empty family is created", empty == nil and emptyAdded == 0)
local inCombat, combatAdded = familyHelpers.Sync(nil, enUS, true)
check("combat sync does not create or mutate family", inCombat == nil and combatAdded == 0)

local family, added = familyHelpers.Sync(nil, enUS, false)
check("out-of-combat sync persists matching spells", type(family) == "table" and added == 3
    and #family.spells == 3)
check("learned ID and aura ID remain separate", family.spells[1].castID == 101
    and family.spells[1].auraID == nil and family.spells[1].mappingVerified == false)
check("sync does not enable notifications", family.enabled == nil and family.applyEnabled == nil
    and family.expireEnabled == nil)

local sameFamily, repeatedAdded = familyHelpers.Sync(family, enUS, false)
check("sync is idempotent", sameFamily == family and repeatedAdded == 0 and #family.spells == 3)

local exclusions = family.excludedSpellIDs
exclusions[808] = true
local preservedFamily, exclusionAdded = familyHelpers.Sync(family, {
    { spellID = 808, name = "Seal of Excluded" },
    { spellID = 809, name = "Seal of New" },
}, false)
check("sync retains exclusions and skips excluded spells", preservedFamily == family
    and family.excludedSpellIDs == exclusions and exclusions[808] == true
    and exclusionAdded == 1 and #family.spells == 4 and family.spells[4].spellID == 809)

family.customNotificationSetting = false
familyHelpers.Sync(family, { { spellID = 810, name = "Seal of Another" } }, false)
check("sync preserves existing user settings", family.customNotificationSetting == false)

local protectedLookups = setmetatable({}, {
    __index = function(_, key)
        if key == 999 then error("secret spell ID used as a table key") end
    end,
})
local protectedFamily = { spells = {}, excludedSpellIDs = protectedLookups }
local _, protectedAdded = familyHelpers.Sync(protectedFamily, {
    { spellID = 999, name = "Secret candidate" },
}, false)
check("secret spell ID rejected before exclusion lookup", protectedAdded == 0)

local first = family.spells[1]
local confirmedWithoutEvidence = familyHelpers.ConfirmMapping(family, first.spellID, 101, 9001, nil)
check("mapping stays unverified without evidence", confirmedWithoutEvidence == false
    and first.auraID == nil and first.mappingVerified == false)
local mismatchedEvidence = familyHelpers.ConfirmMapping(family, first.spellID, 101, 9001, {
    source = "cdm", confirmed = true, castID = 101, auraID = 9002,
})
check("mapping rejects evidence for different IDs", mismatchedEvidence == false and first.auraID == nil)
local confirmed, mapped = familyHelpers.ConfirmMapping(family, first.spellID, 101, 9001, {
    source = "cdm", confirmed = true, castID = 101, auraID = 9001,
})
check("explicit CDM evidence confirms separate IDs", confirmed == true and mapped == first
    and first.castID == 101 and first.auraID == 9001 and first.mappingVerified == true
    and first.mappingEvidence.source == "cdm")

local learnedConfirmed = familyHelpers.ConfirmMapping(family, 809, 809, 811, {
    source = "learning", confirmed = true, castID = 809, auraID = 811,
})
check("explicit learning evidence is accepted", learnedConfirmed == true
    and family.spells[4].castID == 809 and family.spells[4].auraID == 811)

print("AURA_TRACKER_FAMILY_STATUS candidates=" .. tostring(#enUS)
    .. " persisted=" .. tostring(#family.spells))
