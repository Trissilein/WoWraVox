local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. detail) or "")) end
    print("PASS " .. name)
end

local catalog = ns.AuraPresets
check("catalog is exported", type(catalog) == "table")
local valid, errors = catalog.Validate()
check("catalog validates", valid, table.concat(errors or {}, "; "))

local expectedSpecs = {
    62, 63, 64, 65, 66, 70, 71, 72, 73, 102, 103, 104, 105,
    250, 251, 252, 253, 254, 255, 256, 257, 258, 259, 260, 261,
    262, 263, 264, 265, 266, 267, 268, 269, 270, 577, 581, 1467,
    1468, 1473, 1480,
}
check("all 40 specs are present", #catalog.specs == 40)
for _, specID in ipairs(expectedSpecs) do check("spec " .. specID, catalog.GetSpec(specID) ~= nil) end

local byID = {}
for _, entry in ipairs(catalog.entries) do
    check("entry has unique ID", not byID[entry.id], entry.id)
    byID[entry.id] = entry
    check(entry.id .. " has non-empty spec scope", type(entry.specIDs) == "table" and #entry.specIDs > 0)
    for _, specID in ipairs(entry.specIDs or {}) do
        check(entry.id .. " class matches spec " .. specID, entry.classID == catalog.GetSpec(specID).classID)
    end
    check(entry.id .. " has separate learning condition", type(entry.talentCondition) == "table")
    check(entry.id .. " has player aura data or explicit block", entry.auraID ~= nil or entry.status == "blocked")
    check(entry.id .. " default starts active", entry.defaultSelection.groupActive == true)
    check(entry.id .. " default category active", entry.defaultSelection.categoryActive == true)
    check(entry.id .. " default begin on/end off", entry.defaultSelection.beginAnnouncement == true
        and entry.defaultSelection.endAnnouncement == false)
    check(entry.id .. " is not pet/enemy/channel", not entry.target and not entry.channelled and not entry.summon)
    if entry.status == "blocked" then check(entry.id .. " blocked has reason", type(entry.blockedReason) == "string") end
    if entry.status == "verified" then
        check(entry.id .. " has named two-publisher gate", type(entry.sourceKey) == "string"
            and entry.sourceCount >= 2 and catalog.CountSources(entry.sources) == entry.sourceCount
            and entry.mappingEvidence ~= "pending")
        check(entry.id .. " passes selection gate", catalog.IsSelectable(entry))
    end
end
for _, entry in ipairs(catalog.externals) do
    check("external has unique ID", not byID[entry.id], entry.id)
    byID[entry.id] = entry
    check(entry.id .. " has no spec learning gate", entry.specIDs == nil)
    check(entry.id .. " has receiver trigger", type(entry.trigger) == "string")
    if entry.status == "blocked" then check(entry.id .. " blocked has reason", type(entry.blockedReason) == "string") end
    if entry.status == "verified" then
        check(entry.id .. " has named two-publisher gate", type(entry.sourceKey) == "string"
            and entry.sourceCount >= 2 and catalog.CountSources(entry.sources) == entry.sourceCount
            and entry.mappingEvidence ~= "pending")
        check(entry.id .. " passes selection gate", catalog.IsSelectable(entry))
    end
end

local function field(id, key)
    return byID[id] and byID[id][key]
end
local function pair(id, castID, auraID)
    check(id .. " cast ID", field(id, "castID") == castID)
    check(id .. " aura ID", field(id, "auraID") == auraID)
end

pair("paladin-protection-sentinel", 31884, 389539)
check("Sentinel keeps passive talent gate separate", field("paladin-protection-sentinel", "talentCondition").id == 385438)
pair("death-knight-blood-dancing-rune-weapon", 49028, 81256)
pair("mage-arcane-arcane-surge", 365350, 365362)
pair("mage-class-alter-time", 108978, 110909)
check("Alter Time stays blocked while competing cast mapping is unresolved",
    field("mage-class-alter-time", "status") == "blocked"
    and field("mage-class-alter-time", "mappingEvidence") == "direct-aura"
    and tostring(field("mage-class-alter-time", "blockedReason")):find("342245", 1, true) ~= nil)
pair("demon-hunter-havoc-metamorphosis", 191427, 162264)
pair("shaman-elemental-ascendance", 114050, 1219480)
pair("shaman-enhancement-doom-winds", 384352, 466772)
check("Ice Cold keeps passive talent gate separate", field("mage-class-ice-cold", "castID") == nil
    and field("mage-class-ice-cold", "auraID") == 414658
    and field("mage-class-ice-cold", "talentCondition").id == 414659)
check("Fortifying Brew keeps passive talent gate separate", field("monk-class-fortifying-brew", "castID") == nil
    and field("monk-class-fortifying-brew", "auraID") == 120954
    and field("monk-class-fortifying-brew", "talentCondition").id == 388917)
check("Preservation Temporal Burst keeps passive talent separate", field("evoker-preservation-temporal-burst", "castID") == nil
    and field("evoker-preservation-temporal-burst", "auraID") == 431698
    and field("evoker-preservation-temporal-burst", "status") == "blocked")
check("Augmentation Temporal Burst stays explicit but blocked", field("evoker-augmentation-temporal-burst", "castID") == nil
    and field("evoker-augmentation-temporal-burst", "status") == "blocked")
pair("prescience-received", 409311, 410089)
pair("ebon-might-received", 395152, 395152)
pair("evoker-augmentation-ebon-might", 395152, 395296)
pair("rogue-subtlety-shadow-dance", 185313, 185422)
check("received Ebon Might uses group aura", field("ebon-might-received", "auraID") == 395152)
check("own Ebon Might uses own damage aura", field("evoker-augmentation-ebon-might", "auraID") == 395296)
check("received and own Ebon Might remain distinct", field("ebon-might-received", "id") ~= field("evoker-augmentation-ebon-might", "id"))
check("enhancement and restoration Ascendance remain distinct", field("shaman-enhancement-ascendance", "id") ~= field("shaman-restoration-ascendance", "id"))
check("no Crusade standalone preset", not byID["paladin-retribution-crusade"])
check("no Last Stand extension preset", not byID["warrior-protection-last-stand"])
check("no Renewing Blaze extension preset", not byID["evoker-devastation-renewing-blaze"])
check("no Diffuse Magic passive preset", not byID["monk-class-diffuse-magic"])

check("Protection Avenging Wrath is offensive", field("paladin-protection-avenging-wrath", "category") == "offensive")
check("Protection Avenging Wrath is secondary hybrid", field("paladin-protection-avenging-wrath", "hybrid").role == "secondary"
    and field("paladin-protection-avenging-wrath", "defaultSelection").effectSelected == false)
check("Sentinel is primary hybrid", field("paladin-protection-sentinel", "hybrid").role == "primary")
check("talent variants carry an explicit group", field("druid-balance-celestial-alignment", "variantGroup") == "druid-balance-burst"
    and field("druid-balance-incarnation", "variantRole") == "variant")

local protDef = catalog.GetEntries(66, "defensive", true)
local protDefSelectable = catalog.GetEntries(66, "defensive", false)
local sawSentinel, sawSentinelSelectable = false, false
for _, entry in ipairs(protDef) do if entry.id == "paladin-protection-sentinel" then sawSentinel = true end end
for _, entry in ipairs(protDefSelectable) do if entry.id == "paladin-protection-sentinel" then sawSentinelSelectable = true end end
check("verified Sentinel stays visible in review view", sawSentinel)
check("verified Sentinel is selectable", sawSentinelSelectable)
local arcaneOffense = catalog.GetEntries(62, "offensive", true)
local arcaneOffenseSelectable = catalog.GetEntries(62, "offensive", false)
local sawArcaneSurge, sawSelectableArcaneSurge = false, false
for _, entry in ipairs(arcaneOffense) do if entry.id == "mage-arcane-arcane-surge" then sawArcaneSurge = true end end
for _, entry in ipairs(arcaneOffenseSelectable) do if entry.id == "mage-arcane-arcane-surge" then sawSelectableArcaneSurge = true end end
check("verified Arcane Surge is visible in review view", sawArcaneSurge)
check("verified Arcane Surge is selectable", sawSelectableArcaneSurge)
local feralOffense = catalog.GetEntries(103, "offensive", true)
local feralOffenseSelectable = catalog.GetEntries(103, "offensive", false)
local sawFeralIncarnation, sawSelectableFeralIncarnation = false, false
for _, entry in ipairs(feralOffense) do if entry.id == "druid-feral-incarnation" then sawFeralIncarnation = true end end
for _, entry in ipairs(feralOffenseSelectable) do if entry.id == "druid-feral-incarnation" then sawSelectableFeralIncarnation = true end end
check("blocked Feral Incarnation stays visible in review view", sawFeralIncarnation)
check("blocked Feral Incarnation is excluded from selectable view", not sawSelectableFeralIncarnation)
check("Arcane Surge keeps cast/aura split with direct-aura proof", field("mage-arcane-arcane-surge", "mappingEvidence") == "direct-aura"
    and field("mage-arcane-arcane-surge", "sourceCount") == 2)
check("Guardian of Ancient Kings is weak but selectable (two keys)", field("paladin-protection-guardian-of-ancient-kings", "status") == "verified"
    and field("paladin-protection-guardian-of-ancient-kings", "sourceCount") == 2 and not catalog.IsStrong(byID["paladin-protection-guardian-of-ancient-kings"]))
check("Survival Instincts is strong with three keys", catalog.IsStrong(byID["druid-feral-guardian-survival-instincts"]))
check("Touch of Karma stays blocked without proven buff ID", field("monk-windwalker-touch-of-karma", "status") == "blocked")
check("healing uses own category", #catalog.GetEntries(65, "healing", false) > 0)
check("Shifting Sands optional and not preselected", field("shifting-sands", "optional") == true
    and field("shifting-sands", "defaultSelection").effectSelected == false)

for _, id in ipairs({
    "power-infusion", "pain-suppression", "guardian-spirit", "ironbark",
    "life-cocoon", "blessing-of-sacrifice", "blessing-of-protection",
    "blessing-of-spellwarding", "time-dilation", "ebon-might-received",
    "prescience-received", "blistering-scales",
}) do
    check(id .. " external triad is released", field(id, "status") == "verified")
    check(id .. " external mapping is direct", field(id, "mappingEvidence") == "direct-aura")
end
check("Shifting Sands remains explicitly blocked", field("shifting-sands", "status") == "blocked"
    and field("shifting-sands", "blockedReason") ~= "")

do
    local oldPlayerSpell, oldClassTalents, oldTraits = IsPlayerSpell, C_ClassTalents, C_Traits
    IsPlayerSpell = function(spellID) return spellID == 31884 end
    C_ClassTalents = { GetActiveConfigID = function() return 77 end }
    C_Traits = {
        GetConfigInfo = function() return { treeIDs = { 1 } } end,
        GetTreeNodes = function() return {} end,
        GetNodeInfo = function() return nil end,
    }
    local available = catalog.GetAvailability(field("paladin-holy-avenging-wrath", "id") and byID["paladin-holy-avenging-wrath"])
    check("baseline spell-known survives empty trait tree", available == true)
    IsPlayerSpell, C_ClassTalents, C_Traits = oldPlayerSpell, oldClassTalents, oldTraits
    catalog.InvalidateTalentCache()
end
do
    local oldPlayerSpell, oldClassTalents, oldTraits = IsPlayerSpell, C_ClassTalents, C_Traits
    IsPlayerSpell = function(spellID) return spellID == 194223 or spellID == 102560 end
    C_ClassTalents = { GetActiveConfigID = function() return 88 end }
    C_Traits = {
        GetConfigInfo = function() return { treeIDs = { 1 } } end,
        GetTreeNodes = function() return { 7 } end,
        GetNodeInfo = function() return { activeEntry = { entryID = 9, rank = 1, spellID = 102560 } } end,
        GetEntryInfo = function() return { definitionID = 10 } end,
        GetDefinitionInfo = function() return { spellID = 102560 } end,
    }
    local base = byID["druid-balance-celestial-alignment"]
    local variant = byID["druid-balance-incarnation"]
    local baseAvailable, baseReason = catalog.GetAvailability(base)
    local variantAvailable = catalog.GetAvailability(variant)
    check("selected talent disables its base variant", baseAvailable == false and baseReason == "Variant talent is selected.")
    check("selected talent keeps its variant available", variantAvailable == true)
    IsPlayerSpell, C_ClassTalents, C_Traits = oldPlayerSpell, oldClassTalents, oldTraits
    catalog.InvalidateTalentCache()
end
do
    local oldPlayerSpell, oldClassTalents, oldTraits = IsPlayerSpell, C_ClassTalents, C_Traits
    IsPlayerSpell = function(spellID) return spellID == 45438 or spellID == 414659 end
    C_ClassTalents = { GetActiveConfigID = function() return 89 end }
    C_Traits = {
        GetConfigInfo = function() return { treeIDs = { 1 } } end,
        GetTreeNodes = function() return { 8 } end,
        GetNodeInfo = function() return { activeEntry = { entryID = 10, rank = 1, spellID = 414659 } } end,
        GetEntryInfo = function() return { definitionID = 11 } end,
        GetDefinitionInfo = function() return { spellID = 414659 } end,
    }
    local iceBlock = byID["mage-class-ice-block"]
    local iceCold = byID["mage-class-ice-cold"]
    local iceBlockAvailable, iceBlockReason = catalog.GetAvailability(iceBlock)
    local iceColdAvailable = catalog.GetAvailability(iceCold)
    check("selected blocked variant disables its base spell", iceBlockAvailable == false
        and iceBlockReason == "Variant talent is selected.")
    check("selected blocked variant remains blocked", iceColdAvailable == false
        and iceCold.status == "blocked")
    IsPlayerSpell, C_ClassTalents, C_Traits = oldPlayerSpell, oldClassTalents, oldTraits
    catalog.InvalidateTalentCache()
end
for _, id in ipairs({
    "mage-arcane-arcane-surge", "demon-hunter-havoc-metamorphosis",
    "shaman-elemental-ascendance", "shaman-enhancement-doom-winds",
    "evoker-preservation-temporal-burst", "prescience-received",
}) do
    check(id .. " keeps cast/aura IDs distinct where researched", field(id, "castID") ~= field(id, "auraID"))
end

-- Source gate: two distinct publishers select, one does not, three is strong.
local function gateProbe(sourceCount)
    return { status = "verified", castID = 1, auraID = 1, sourceCount = sourceCount, mappingEvidence = "same-spell-buff" }
end
check("two publishers pass the selection gate", catalog.IsSelectable(gateProbe(2)))
check("one publisher fails the selection gate", not catalog.IsSelectable(gateProbe(1)))
check("three publishers are strong", catalog.IsStrong(gateProbe(3)) and not catalog.IsStrong(gateProbe(2)))
check("repeated publisher keys count once", catalog.CountSources({ "wowhead", "wowhead", "method" }) == 2)
check("verified row carries three distinct publishers", #byID["warrior-arms-avatar"].sources == 3
    and catalog.CountSources(byID["warrior-arms-avatar"].sources) == 3 and catalog.IsStrong(byID["warrior-arms-avatar"]))
check("blocked row keeps its ledger claim count", byID["druid-feral-incarnation"].status == "blocked"
    and byID["druid-feral-incarnation"].sourceCount == 1)
do
    local entry = byID["warrior-arms-avatar"]
    local saved = entry.sourceCount
    entry.sourceCount = 1
    local valid = catalog.Validate()
    entry.sourceCount = saved
    check("validator rejects verified row with one publisher", not valid)
end

-- Talent cache: one tree walk per cache lifetime, rebuilt after InvalidateTalentCache().
do
    local oldPlayerSpell, oldClassTalents, oldTraits = IsPlayerSpell, C_ClassTalents, C_Traits
    local treeWalks = 0
    C_ClassTalents = { GetActiveConfigID = function() return 90 end }
    C_Traits = {
        GetConfigInfo = function() return { treeIDs = { 1 } } end,
        GetTreeNodes = function() treeWalks = treeWalks + 1; return { 7 } end,
        GetNodeInfo = function() return { activeEntry = { entryID = 9, rank = 1, spellID = 102560 } } end,
        GetEntryInfo = function() return { definitionID = 10 } end,
        GetDefinitionInfo = function() return { spellID = 102560 } end,
    }
    catalog.InvalidateTalentCache()
    check("cached talent lookup reports selected spell", catalog.IsTalentSelected(102560) == true)
    check("cached talent lookup reports unselected spell", catalog.IsTalentSelected(194223) == false)
    catalog.IsTalentSelected(102560)
    check("second talent lookup does not walk the tree again", treeWalks == 1)
    catalog.InvalidateTalentCache()
    catalog.IsTalentSelected(102560)
    check("invalidate forces exactly one new tree walk", treeWalks == 2)
    IsPlayerSpell, C_ClassTalents, C_Traits = oldPlayerSpell, oldClassTalents, oldTraits
    catalog.InvalidateTalentCache()
end
do
    -- Without trait APIs the spellbook fallback runs on every call, so a changed spellbook shows at once.
    local oldPlayerSpell, oldClassTalents, oldTraits = IsPlayerSpell, C_ClassTalents, C_Traits
    C_ClassTalents, C_Traits = nil, nil
    catalog.InvalidateTalentCache()
    IsPlayerSpell = function(spellID) return spellID == 5 end
    check("spellbook fallback reports known spell", catalog.IsTalentSelected(5) == true)
    IsPlayerSpell = function() return false end
    check("spellbook fallback is not cached", catalog.IsTalentSelected(5) == false)
    IsPlayerSpell, C_ClassTalents, C_Traits = oldPlayerSpell, oldClassTalents, oldTraits
    catalog.InvalidateTalentCache()
end

local missingScope = byID["warrior-arms-avatar"].specIDs
byID["warrior-arms-avatar"].specIDs = nil
local validWithoutScope = catalog.Validate()
byID["warrior-arms-avatar"].specIDs = missingScope
check("validator rejects missing class scope", not validWithoutScope)
local savedClassID = byID["warrior-arms-avatar"].classID
byID["warrior-arms-avatar"].classID = 2
local validWithClassMismatch = catalog.Validate()
byID["warrior-arms-avatar"].classID = savedClassID
check("validator rejects class/spec mismatch", not validWithClassMismatch)

local status = catalog.GetStatus()
check("status covers all entries", status.entries == #catalog.entries)
check("status has external audit split", status.externalVerified > 0 and status.externalBlocked > 0
    and status.externalVerified + status.externalBlocked == status.externals)
print(string.format("CATALOG_STATUS specs=%d entries=%d verified=%d blocked=%d externals=%d externalVerified=%d externalBlocked=%d",
    status.specs, status.entries, status.verified, status.blocked, status.externals,
    status.externalVerified, status.externalBlocked))
