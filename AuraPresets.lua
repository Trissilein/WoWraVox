local _, ns = ...

-- Static, reviewable preset catalog.  UI code must use status == "verified" as its
-- selection gate; blocked rows remain visible so missing evidence stays explicit.
local catalog = {
    version = 1,
    patch = "12.1.0",
    checkedAt = "2026-10-05",
    categories = { "offensive", "defensive", "healing", "augmentation-offensive", "augmentation-defensive" },
    existingBuiltinPresetIDs = { "heroism-bloodlust" },
    specs = {
        { classID = 1, classKey = "warrior", className = "Warrior", specID = 71, specKey = "arms", specName = "Arms", role = "DPS" },
        { classID = 1, classKey = "warrior", className = "Warrior", specID = 72, specKey = "fury", specName = "Fury", role = "DPS" },
        { classID = 1, classKey = "warrior", className = "Warrior", specID = 73, specKey = "protection", specName = "Protection", role = "TANK" },
        { classID = 2, classKey = "paladin", className = "Paladin", specID = 65, specKey = "holy", specName = "Holy", role = "HEALER" },
        { classID = 2, classKey = "paladin", className = "Paladin", specID = 66, specKey = "protection", specName = "Protection", role = "TANK" },
        { classID = 2, classKey = "paladin", className = "Paladin", specID = 70, specKey = "retribution", specName = "Retribution", role = "DPS" },
        { classID = 6, classKey = "death-knight", className = "Death Knight", specID = 250, specKey = "blood", specName = "Blood", role = "TANK" },
        { classID = 6, classKey = "death-knight", className = "Death Knight", specID = 251, specKey = "frost", specName = "Frost", role = "DPS" },
        { classID = 6, classKey = "death-knight", className = "Death Knight", specID = 252, specKey = "unholy", specName = "Unholy", role = "DPS" },
        { classID = 3, classKey = "hunter", className = "Hunter", specID = 253, specKey = "beast-mastery", specName = "Beast Mastery", role = "DPS" },
        { classID = 3, classKey = "hunter", className = "Hunter", specID = 254, specKey = "marksmanship", specName = "Marksmanship", role = "DPS" },
        { classID = 3, classKey = "hunter", className = "Hunter", specID = 255, specKey = "survival", specName = "Survival", role = "DPS" },
        { classID = 4, classKey = "rogue", className = "Rogue", specID = 259, specKey = "assassination", specName = "Assassination", role = "DPS" },
        { classID = 4, classKey = "rogue", className = "Rogue", specID = 260, specKey = "outlaw", specName = "Outlaw", role = "DPS" },
        { classID = 4, classKey = "rogue", className = "Rogue", specID = 261, specKey = "subtlety", specName = "Subtlety", role = "DPS" },
        { classID = 10, classKey = "monk", className = "Monk", specID = 268, specKey = "brewmaster", specName = "Brewmaster", role = "TANK" },
        { classID = 10, classKey = "monk", className = "Monk", specID = 270, specKey = "mistweaver", specName = "Mistweaver", role = "HEALER" },
        { classID = 10, classKey = "monk", className = "Monk", specID = 269, specKey = "windwalker", specName = "Windwalker", role = "DPS" },
        { classID = 8, classKey = "mage", className = "Mage", specID = 62, specKey = "arcane", specName = "Arcane", role = "DPS" },
        { classID = 8, classKey = "mage", className = "Mage", specID = 63, specKey = "fire", specName = "Fire", role = "DPS" },
        { classID = 8, classKey = "mage", className = "Mage", specID = 64, specKey = "frost", specName = "Frost", role = "DPS" },
        { classID = 5, classKey = "priest", className = "Priest", specID = 256, specKey = "discipline", specName = "Discipline", role = "HEALER" },
        { classID = 5, classKey = "priest", className = "Priest", specID = 257, specKey = "holy", specName = "Holy", role = "HEALER" },
        { classID = 5, classKey = "priest", className = "Priest", specID = 258, specKey = "shadow", specName = "Shadow", role = "DPS" },
        { classID = 9, classKey = "warlock", className = "Warlock", specID = 265, specKey = "affliction", specName = "Affliction", role = "DPS" },
        { classID = 9, classKey = "warlock", className = "Warlock", specID = 266, specKey = "demonology", specName = "Demonology", role = "DPS" },
        { classID = 9, classKey = "warlock", className = "Warlock", specID = 267, specKey = "destruction", specName = "Destruction", role = "DPS" },
        { classID = 11, classKey = "druid", className = "Druid", specID = 102, specKey = "balance", specName = "Balance", role = "DPS" },
        { classID = 11, classKey = "druid", className = "Druid", specID = 103, specKey = "feral", specName = "Feral", role = "DPS" },
        { classID = 11, classKey = "druid", className = "Druid", specID = 104, specKey = "guardian", specName = "Guardian", role = "TANK" },
        { classID = 11, classKey = "druid", className = "Druid", specID = 105, specKey = "restoration", specName = "Restoration", role = "HEALER" },
        { classID = 7, classKey = "shaman", className = "Shaman", specID = 262, specKey = "elemental", specName = "Elemental", role = "DPS" },
        { classID = 7, classKey = "shaman", className = "Shaman", specID = 263, specKey = "enhancement", specName = "Enhancement", role = "DPS" },
        { classID = 7, classKey = "shaman", className = "Shaman", specID = 264, specKey = "restoration", specName = "Restoration", role = "HEALER" },
        { classID = 12, classKey = "demon-hunter", className = "Demon Hunter", specID = 577, specKey = "havoc", specName = "Havoc", role = "DPS" },
        { classID = 12, classKey = "demon-hunter", className = "Demon Hunter", specID = 581, specKey = "vengeance", specName = "Vengeance", role = "TANK" },
        { classID = 12, classKey = "demon-hunter", className = "Demon Hunter", specID = 1480, specKey = "devourer", specName = "Devourer", role = "DPS" },
        { classID = 13, classKey = "evoker", className = "Evoker", specID = 1467, specKey = "devastation", specName = "Devastation", role = "DPS" },
        { classID = 13, classKey = "evoker", className = "Evoker", specID = 1468, specKey = "preservation", specName = "Preservation", role = "HEALER" },
        { classID = 13, classKey = "evoker", className = "Evoker", specID = 1473, specKey = "augmentation", specName = "Augmentation", role = "DPS" },
    },
    entries = {},
    externals = {},
}

local DEFAULT_SELECTION = {
    groupActive = true,
    categoryActive = true,
    beginAnnouncement = true,
    endAnnouncement = false,
    effectSelected = true,
}

local function copySelection()
    return {
        groupActive = DEFAULT_SELECTION.groupActive,
        categoryActive = DEFAULT_SELECTION.categoryActive,
        beginAnnouncement = DEFAULT_SELECTION.beginAnnouncement,
        endAnnouncement = DEFAULT_SELECTION.endAnnouncement,
        effectSelected = DEFAULT_SELECTION.effectSelected,
    }
end

local function addEntry(target, id, name, fields)
    fields.id = id
    fields.name = name
    fields.status = fields.status or "blocked"
    fields.playerAura = fields.playerAura ~= false
    fields.mainCategory = fields.mainCategory or fields.category
    fields.category = fields.category or fields.mainCategory
    fields.defaultSelection = fields.defaultSelection or copySelection()
    target[#target + 1] = fields
end

local function spec(fields, id)
    fields.specID = id
    fields.specIDs = { id }
    return fields
end

local function classWide(fields, ids)
    fields.specIDs = ids
    fields.scope = "class"
    return fields
end

-- Distinct publisher keys only; a repeated key does not add a source.
local function countSources(list)
    local seen, count = {}, 0
    for _, key in ipairs(list or {}) do
        if type(key) == "string" and key ~= "" and not seen[key] then
            seen[key] = true
            count = count + 1
        end
    end
    return count
end
catalog.CountSources = countSources

-- Explicit publisher keys; sourceCount is derived from them, never hard-coded.
local function verifiedFrom(fields, sourceKey, sources, mapping)
    fields.status = "verified"
    fields.sourceKey = sourceKey
    fields.sources = sources
    fields.sourceCount = countSources(sources)
    fields.mappingEvidence = mapping or "same-spell-buff"
    return fields
end

-- Every guide pack and external pack in .agents/preset-sources.md (private working ledger, not shipped) lists these three publishers.
-- Verified rows all have three claims in the ledger, so they get the full list.
local function verified(fields, sourceKey, mapping)
    return verifiedFrom(fields, sourceKey, { "wowhead", "icy-veins", "method" }, mapping)
end

-- Blocked rows take the ledger's claim count ("n/3"). The ledger does not name which
-- publisher is missing, so no publisher keys are invented for them.
local function blocked(fields, sourceKey, reason, sourceCount, mapping)
    fields.status = "blocked"
    fields.sourceKey = sourceKey
    fields.sourceCount = sourceCount or 0
    fields.blockedReason = reason
    fields.mappingEvidence = mapping or "pending"
    return fields
end

-- Warrior
addEntry(catalog.entries, "warrior-arms-avatar", "Avatar", verified(spec({
    classID = 1, category = "offensive", castID = 107574, auraID = 107574,
    talentCondition = { kind = "selected-talent", id = 107574, selected = true },
}, 71), "guide:warrior/arms"))
addEntry(catalog.entries, "warrior-arms-die-by-the-sword", "Die by the Sword", blocked(spec({
    classID = 1, category = "defensive", castID = 118038, auraID = 118038,
    talentCondition = { kind = "selected-talent", id = 118038, selected = true },
}, 71), "guide:warrior/arms", "direct player-aura page failed to verify; do not select", 3))
addEntry(catalog.entries, "warrior-fury-recklessness", "Recklessness", verified(spec({
    classID = 1, category = "offensive", castID = 1719, auraID = 1719,
    talentCondition = { kind = "selected-talent", id = 1719, selected = true },
}, 72), "guide:warrior/fury"))
addEntry(catalog.entries, "warrior-fury-avatar", "Avatar", verified(spec({
    classID = 1, category = "offensive", castID = 107574, auraID = 107574,
    talentCondition = { kind = "selected-talent", id = 107574, selected = true },
}, 72), "guide:warrior/fury"))
addEntry(catalog.entries, "warrior-fury-enraged-regeneration", "Enraged Regeneration", verified(spec({
    classID = 1, category = "defensive", castID = 184364, auraID = 184364,
    talentCondition = { kind = "spell-known", id = 184364 },
}, 72), "guide:warrior/fury"))
addEntry(catalog.entries, "warrior-protection-avatar", "Avatar", verified(spec({
    classID = 1, category = "offensive", castID = 107574, auraID = 107574,
    talentCondition = { kind = "selected-talent", id = 107574, selected = true },
}, 73), "guide:warrior/protection"))
addEntry(catalog.entries, "warrior-protection-shield-wall", "Shield Wall", verified(spec({
    classID = 1, category = "defensive", castID = 871, auraID = 871,
    talentCondition = { kind = "spell-known", id = 871 },
}, 73), "guide:warrior/protection"))
addEntry(catalog.entries, "warrior-class-spell-reflection", "Spell Reflection", verified(classWide({
    classID = 1, category = "defensive", castID = 23920, auraID = 23920,
    talentCondition = { kind = "spell-known", id = 23920 },
}, { 71, 72, 73 }), "guide:warrior/arms"))

-- Paladin
addEntry(catalog.entries, "paladin-holy-avenging-wrath", "Avenging Wrath", verified(spec({
    classID = 2, category = "healing", castID = 31884, auraID = 31884,
    talentCondition = { kind = "spell-known", id = 31884 },
}, 65), "guide:paladin/holy"))
addEntry(catalog.entries, "paladin-holy-aura-mastery", "Aura Mastery", verified(spec({
    classID = 2, category = "defensive", castID = 31821, auraID = 31821,
    talentCondition = { kind = "spell-known", id = 31821 },
}, 65), "guide:paladin/holy"))
addEntry(catalog.entries, "paladin-class-divine-protection", "Divine Protection", verified(classWide({
    classID = 2, category = "defensive", castID = 498, auraID = 498,
    talentCondition = { kind = "spell-known", id = 498 },
}, { 65, 66, 70 }), "guide:paladin/holy"))
addEntry(catalog.entries, "paladin-class-divine-shield", "Divine Shield", verified(classWide({
    classID = 2, category = "defensive", castID = 642, auraID = 642,
    talentCondition = { kind = "spell-known", id = 642 },
}, { 65, 66, 70 }), "guide:paladin/holy"))
addEntry(catalog.entries, "paladin-protection-avenging-wrath", "Avenging Wrath", verified(spec({
    classID = 2, category = "offensive", castID = 31884, auraID = 31884, optional = true,
    hybrid = { groupID = "paladin-protection-wings", role = "secondary", defaultSelected = false },
    defaultSelection = {
        groupActive = true, categoryActive = true, beginAnnouncement = true,
        endAnnouncement = false, effectSelected = false,
    },
    talentCondition = { kind = "spell-known", id = 31884 },
}, 66), "guide:paladin/protection"))
addEntry(catalog.entries, "paladin-protection-sentinel", "Sentinel", verified(spec({
    classID = 2, category = "defensive", castID = 31884, auraID = 389539,
    hybrid = { groupID = "paladin-protection-wings", role = "primary", defaultSelected = true },
    talentCondition = { kind = "selected-talent", id = 385438, selected = true },
}, 66), "guide:paladin/protection", "direct-aura"))
addEntry(catalog.entries, "paladin-protection-ardent-defender", "Ardent Defender", verifiedFrom(spec({
    classID = 2, category = "defensive", castID = 31850, auraID = 31850,
    talentCondition = { kind = "spell-known", id = 31850 },
}, 66), "guide:paladin/protection", { "method", "warcraft-wiki" }, "same-spell-buff"))
addEntry(catalog.entries, "paladin-protection-guardian-of-ancient-kings", "Guardian of Ancient Kings", verifiedFrom(spec({
    classID = 2, category = "defensive", castID = 86659, auraID = 86659,
    talentCondition = { kind = "spell-known", id = 86659 },
}, 66), "guide:paladin/protection", { "method", "warcraft-wiki" }, "same-spell-buff"))
addEntry(catalog.entries, "paladin-retribution-avenging-wrath", "Avenging Wrath", verified(spec({
    classID = 2, category = "offensive", castID = 31884, auraID = 31884,
    talentCondition = { kind = "spell-known", id = 31884 },
}, 70), "guide:paladin/retribution"))

-- Death Knight
addEntry(catalog.entries, "death-knight-class-anti-magic-shell", "Anti-Magic Shell", verified(classWide({
    classID = 6, category = "defensive", castID = 48707, auraID = 48707,
    talentCondition = { kind = "spell-known", id = 48707 },
}, { 250, 251, 252 }), "guide:death-knight/blood"))
addEntry(catalog.entries, "death-knight-class-icebound-fortitude", "Icebound Fortitude", verified(classWide({
    classID = 6, category = "defensive", castID = 48792, auraID = 48792,
    talentCondition = { kind = "spell-known", id = 48792 },
}, { 250, 251, 252 }), "guide:death-knight/blood"))
addEntry(catalog.entries, "death-knight-class-lichborne", "Lichborne", verified(classWide({
    classID = 6, category = "defensive", castID = 49039, auraID = 49039,
    talentCondition = { kind = "spell-known", id = 49039 },
}, { 250, 251, 252 }), "guide:death-knight/blood"))
addEntry(catalog.entries, "death-knight-blood-vampiric-blood", "Vampiric Blood", verified(spec({
    classID = 6, category = "defensive", castID = 55233, auraID = 55233,
    talentCondition = { kind = "spell-known", id = 55233 },
}, 250), "guide:death-knight/blood"))
addEntry(catalog.entries, "death-knight-blood-dancing-rune-weapon", "Dancing Rune Weapon", verified(spec({
    classID = 6, category = "defensive", castID = 49028, auraID = 81256,
    talentCondition = { kind = "spell-known", id = 49028 },
}, 250), "guide:death-knight/blood", "direct-aura"))
addEntry(catalog.entries, "death-knight-frost-pillar-of-frost", "Pillar of Frost", verified(spec({
    classID = 6, category = "offensive", castID = 51271, auraID = 51271,
    talentCondition = { kind = "spell-known", id = 51271 },
}, 251), "guide:death-knight/frost"))

-- Hunter
addEntry(catalog.entries, "hunter-beast-mastery-bestial-wrath", "Bestial Wrath", verified(spec({
    classID = 3, category = "offensive", castID = 19574, auraID = 19574,
    talentCondition = { kind = "spell-known", id = 19574 },
}, 253), "guide:hunter/beast-mastery"))
addEntry(catalog.entries, "hunter-marksmanship-trueshot", "Trueshot", verifiedFrom(spec({
    classID = 3, category = "offensive", castID = 288613, auraID = 288613,
    talentCondition = { kind = "spell-known", id = 288613 },
}, 254), "guide:hunter/marksmanship", { "method", "warcraft-wiki" }, "same-spell-buff"))
addEntry(catalog.entries, "hunter-survival-takedown", "Takedown", blocked(spec({
    classID = 3, category = "offensive", castID = 1250646, auraID = nil,
    talentCondition = { kind = "selected-talent", id = 1250646, selected = true },
}, 255), "guide:hunter/survival", "player aura ID is not verified; do not treat cast as aura", 3))
addEntry(catalog.entries, "hunter-class-aspect-of-the-turtle", "Aspect of the Turtle", verified(classWide({
    classID = 3, category = "defensive", castID = 186265, auraID = 186265,
    talentCondition = { kind = "spell-known", id = 186265 },
}, { 253, 254, 255 }), "guide:hunter/beast-mastery"))
addEntry(catalog.entries, "hunter-class-survival-of-the-fittest", "Survival of the Fittest", verified(classWide({
    classID = 3, category = "defensive", castID = 264735, auraID = 264735,
    talentCondition = { kind = "spell-known", id = 264735 },
}, { 253, 254, 255 }), "guide:hunter/beast-mastery"))

-- Rogue
addEntry(catalog.entries, "rogue-outlaw-adrenaline-rush", "Adrenaline Rush", verified(spec({
    classID = 4, category = "offensive", castID = 13750, auraID = 13750,
    talentCondition = { kind = "spell-known", id = 13750 },
}, 260), "guide:rogue/outlaw"))
addEntry(catalog.entries, "rogue-subtlety-shadow-blades", "Shadow Blades", verified(spec({
    classID = 4, category = "offensive", castID = 121471, auraID = 121471,
    talentCondition = { kind = "spell-known", id = 121471 },
}, 261), "guide:rogue/subtlety"))
addEntry(catalog.entries, "rogue-subtlety-shadow-dance", "Shadow Dance", verified(spec({
    classID = 4, category = "offensive", castID = 185313, auraID = 185422,
    talentCondition = { kind = "spell-known", id = 185313 },
}, 261), "guide:rogue/subtlety"))
addEntry(catalog.entries, "rogue-class-feint", "Feint", verified(classWide({
    classID = 4, category = "defensive", castID = 1966, auraID = 1966,
    talentCondition = { kind = "spell-known", id = 1966 },
}, { 259, 260, 261 }), "guide:rogue/assassination"))
addEntry(catalog.entries, "rogue-class-evasion", "Evasion", verified(classWide({
    classID = 4, category = "defensive", castID = 5277, auraID = 5277,
    talentCondition = { kind = "spell-known", id = 5277 },
}, { 259, 260, 261 }), "guide:rogue/assassination"))
addEntry(catalog.entries, "rogue-class-cloak-of-shadows", "Cloak of Shadows", verified(classWide({
    classID = 4, category = "defensive", castID = 31224, auraID = 31224,
    talentCondition = { kind = "spell-known", id = 31224 },
}, { 259, 260, 261 }), "guide:rogue/assassination"))

-- Monk
addEntry(catalog.entries, "monk-windwalker-zenith", "Zenith", verifiedFrom(spec({
    classID = 10, category = "offensive", castID = 1249625, auraID = 1249625,
    talentCondition = { kind = "selected-talent", id = 1249625, selected = true },
}, 269), "guide:monk/windwalker", { "method", "warcraft-wiki" }, "same-spell-buff"))
addEntry(catalog.entries, "monk-windwalker-touch-of-karma", "Touch of Karma", blocked(spec({
    classID = 10, category = "defensive", castID = 122470, auraID = 122470,
    talentCondition = { kind = "spell-known", id = 122470 },
}, 269), "guide:monk/windwalker",
    "Wowhead 122470 served the MoP Classic page (retail URL not found); buff 125174 unreachable (403), so the buff ID is unproven", 2))
addEntry(catalog.entries, "monk-class-fortifying-brew", "Fortifying Brew", blocked(classWide({
    classID = 10, category = "defensive", castID = nil, auraID = 120954,
    talentCondition = { kind = "selected-talent", id = 388917, selected = true },
}, { 268, 270, 269 }), "guide:monk/brewmaster", "talent 388917 is passive modifier; active cast mapping still unverified", 3, "direct-aura"))
addEntry(catalog.entries, "monk-brewmaster-celestial-brew", "Celestial Brew", verified(spec({
    classID = 10, category = "defensive", castID = 322507, auraID = 322507,
    variantGroup = "monk-brewmaster-brew", variantRole = "base",
    talentCondition = { kind = "spell-known", id = 322507 },
}, 268), "guide:monk/brewmaster"))
addEntry(catalog.entries, "monk-brewmaster-celestial-infusion", "Celestial Infusion", blocked(spec({
    classID = 10, category = "defensive", castID = 1241059, auraID = nil,
    variantGroup = "monk-brewmaster-brew", variantRole = "variant",
    talentCondition = { kind = "selected-talent", id = 1241059, selected = true },
}, 268), "guide:monk/brewmaster", "passive/talent modifier aura ID not verified; keep separate from Celestial Brew", 3))
addEntry(catalog.entries, "monk-mistweaver-thunder-focus-tea", "Thunder Focus Tea", verified(spec({
    classID = 10, category = "healing", castID = 116680, auraID = 116680,
    talentCondition = { kind = "spell-known", id = 116680 },
}, 270), "guide:monk/mistweaver"))

-- Mage
addEntry(catalog.entries, "mage-arcane-arcane-surge", "Arcane Surge", verifiedFrom(spec({
    classID = 8, category = "offensive", castID = 365350, auraID = 365362,
    talentCondition = { kind = "selected-talent", id = 365350, selected = true },
}, 62), "guide:mage/arcane", { "method", "warcraft-wiki" }, "direct-aura"))
addEntry(catalog.entries, "mage-fire-combustion", "Combustion", verifiedFrom(spec({
    classID = 8, category = "offensive", castID = 190319, auraID = 190319,
    talentCondition = { kind = "spell-known", id = 190319 },
}, 63), "guide:mage/fire", { "method", "warcraft-wiki" }, "same-spell-buff"))
addEntry(catalog.entries, "mage-class-ice-block", "Ice Block", verified(classWide({
    classID = 8, category = "defensive", castID = 45438, auraID = 45438,
    variantGroup = "mage-immunity", variantRole = "base",
    talentCondition = { kind = "spell-known", id = 45438 },
}, { 62, 63, 64 }), "guide:mage/arcane"))
addEntry(catalog.entries, "mage-class-ice-cold", "Ice Cold", blocked(classWide({
    classID = 8, category = "defensive", castID = nil, auraID = 414658,
    variantGroup = "mage-immunity", variantRole = "variant",
    talentCondition = { kind = "selected-talent", id = 414659, selected = true },
}, { 62, 63, 64 }), "guide:mage/arcane", "talent 414659 is passive modifier; active Ice Block cast mapping still unverified", 3, "direct-aura"))
addEntry(catalog.entries, "mage-class-alter-time", "Alter Time", blocked(classWide({
    classID = 8, category = "defensive", castID = 108978, auraID = 110909,
    talentCondition = { kind = "spell-known", id = 108978 },
}, { 62, 63, 64 }), "guide:mage/arcane",
    "player aura 110909 is directly shown, but current spec-specific cast mapping is unresolved; competing 342245 -> 342246 remains open",
    3, "direct-aura"))

-- Priest
addEntry(catalog.entries, "priest-class-desperate-prayer", "Desperate Prayer", verified(classWide({
    classID = 5, category = "defensive", castID = 19236, auraID = 19236,
    talentCondition = { kind = "spell-known", id = 19236 },
}, { 256, 257, 258 }), "guide:priest/discipline"))
addEntry(catalog.entries, "priest-class-fade", "Fade", blocked(classWide({
    classID = 5, category = "defensive", castID = 586, auraID = 586,
    talentCondition = { kind = "selected-talent", id = nil, selected = true, unresolved = true },
}, { 256, 257, 258 }), "guide:priest/discipline", "defensive talent condition ID not verified", 3))
addEntry(catalog.entries, "priest-shadow-voidform", "Voidform", verified(spec({
    classID = 5, category = "offensive", castID = 228260, auraID = 194249,
    talentCondition = { kind = "spell-known", id = 228260 },
}, 258), "guide:priest/shadow", "direct-aura"))
addEntry(catalog.entries, "priest-shadow-dispersion", "Dispersion", verified(spec({
    classID = 5, category = "defensive", castID = 47585, auraID = 47585,
    talentCondition = { kind = "spell-known", id = 47585 },
}, 258), "guide:priest/shadow"))
addEntry(catalog.entries, "priest-holy-apotheosis", "Apotheosis", verified(spec({
    classID = 5, category = "healing", castID = 200183, auraID = 200183,
    talentCondition = { kind = "selected-talent", id = 200183, selected = true },
}, 257), "guide:priest/holy"))
addEntry(catalog.entries, "priest-discipline-evangelism", "Evangelism / Archangel", blocked(spec({
    classID = 5, category = "healing", castID = 472433, auraID = nil,
    talentCondition = { kind = "selected-talent", id = 472433, selected = true },
}, 256), "guide:priest/discipline", "third guide plus player eigenbuff aura mapping still open", 2))

-- Warlock
addEntry(catalog.entries, "warlock-class-unending-resolve", "Unending Resolve", verified(classWide({
    classID = 9, category = "defensive", castID = 104773, auraID = 104773,
    talentCondition = { kind = "spell-known", id = 104773 },
}, { 265, 266, 267 }), "guide:warlock/affliction"))
addEntry(catalog.entries, "warlock-class-dark-pact", "Dark Pact", verified(classWide({
    classID = 9, category = "defensive", castID = 108416, auraID = 108416,
    talentCondition = { kind = "spell-known", id = 108416 },
}, { 265, 266, 267 }), "guide:warlock/affliction"))

-- Druid
addEntry(catalog.entries, "druid-balance-celestial-alignment", "Celestial Alignment", verified(spec({
    classID = 11, category = "offensive", castID = 194223, auraID = 194223,
    variantGroup = "druid-balance-burst", variantRole = "base",
    talentCondition = { kind = "spell-known", id = 194223 },
}, 102), "guide:druid/balance"))
addEntry(catalog.entries, "druid-balance-incarnation", "Incarnation", verified(spec({
    classID = 11, category = "offensive", castID = 102560, auraID = 102560,
    variantGroup = "druid-balance-burst", variantRole = "variant",
    talentCondition = { kind = "selected-talent", id = 102560, selected = true },
}, 102), "guide:druid/balance"))
addEntry(catalog.entries, "druid-feral-berserk", "Berserk", verified(spec({
    classID = 11, category = "offensive", castID = 106951, auraID = 106951,
    variantGroup = "druid-feral-burst", variantRole = "base",
    talentCondition = { kind = "spell-known", id = 106951 },
}, 103), "guide:druid/feral"))
addEntry(catalog.entries, "druid-feral-incarnation", "Incarnation", blocked(spec({
    classID = 11, category = "offensive", castID = 102543, auraID = 102543,
    variantGroup = "druid-feral-burst", variantRole = "variant",
    talentCondition = { kind = "selected-talent", id = 102543, selected = true },
}, 103), "guide:druid/feral",
    "aura ID unresolved: Wowhead 102543 effect 2 links 252071 (Prowl-linked buff); 102543 vs 252071 needs an in-game check; only one guide claim confirmed", 1))
addEntry(catalog.entries, "druid-guardian-incarnation", "Incarnation", blocked(spec({
    classID = 11, category = "defensive", castID = 102558, auraID = 102558,
    talentCondition = { kind = "selected-talent", id = 102558, selected = true },
}, 104), "guide:druid/guardian",
    "player aura ID 102558 not independently confirmed: Wowhead shows a Buff but no separate aura or trigger ID", 2))
addEntry(catalog.entries, "druid-restoration-incarnation", "Incarnation", verified(spec({
    classID = 11, category = "healing", castID = 33891, auraID = 33891,
    talentCondition = { kind = "selected-talent", id = 33891, selected = true },
}, 105), "guide:druid/restoration"))
addEntry(catalog.entries, "druid-class-barkskin", "Barkskin", verified(classWide({
    classID = 11, category = "defensive", castID = 22812, auraID = 22812,
    talentCondition = { kind = "spell-known", id = 22812 },
}, { 102, 103, 104, 105 }), "guide:druid/restoration"))
addEntry(catalog.entries, "druid-feral-guardian-survival-instincts", "Survival Instincts", verifiedFrom({
    classID = 11, category = "defensive", specIDs = { 103, 104 }, castID = 61336, auraID = 61336,
    talentCondition = { kind = "spell-known", id = 61336 }, scope = "class",
}, "guide:druid/feral", { "method", "warcraft-wiki", "maxroll" }, "same-spell-buff"))

-- Shaman
addEntry(catalog.entries, "shaman-elemental-ascendance", "Ascendance", verified(spec({
    classID = 7, category = "offensive", castID = 114050, auraID = 1219480,
    talentCondition = { kind = "selected-talent", id = 114050, selected = true },
}, 262), "guide:shaman/elemental", "direct-aura"))
addEntry(catalog.entries, "shaman-enhancement-ascendance", "Ascendance", verified(spec({
    classID = 7, category = "offensive", castID = 114051, auraID = 114051,
    talentCondition = { kind = "selected-talent", id = 114051, selected = true },
}, 263), "guide:shaman/enhancement"))
addEntry(catalog.entries, "shaman-restoration-ascendance", "Ascendance", verified(spec({
    classID = 7, category = "healing", castID = 114052, auraID = 114052,
    talentCondition = { kind = "selected-talent", id = 114052, selected = true },
}, 264), "guide:shaman/restoration"))
addEntry(catalog.entries, "shaman-enhancement-doom-winds", "Doom Winds", verified(spec({
    classID = 7, category = "offensive", castID = 384352, auraID = 466772,
    talentCondition = { kind = "selected-talent", id = 384352, selected = true },
}, 263), "guide:shaman/enhancement", "direct-aura"))
addEntry(catalog.entries, "shaman-class-astral-shift", "Astral Shift", verified(classWide({
    classID = 7, category = "defensive", castID = 108271, auraID = 108271,
    talentCondition = { kind = "spell-known", id = 108271 },
}, { 262, 263, 264 }), "guide:shaman/restoration"))

-- Demon Hunter
addEntry(catalog.entries, "demon-hunter-havoc-metamorphosis", "Metamorphosis", verified(spec({
    classID = 12, category = "offensive", castID = 191427, auraID = 162264,
    talentCondition = { kind = "spell-known", id = 191427 },
}, 577), "guide:demon-hunter/havoc", "direct-aura"))
addEntry(catalog.entries, "demon-hunter-havoc-blur", "Blur", verified(spec({
    classID = 12, category = "defensive", castID = 198589, auraID = 212800,
    talentCondition = { kind = "spell-known", id = 198589 },
}, 577), "guide:demon-hunter/havoc", "direct-aura"))
addEntry(catalog.entries, "demon-hunter-vengeance-metamorphosis", "Metamorphosis", verified(spec({
    classID = 12, category = "defensive", castID = 187827, auraID = 187827,
    talentCondition = { kind = "spell-known", id = 187827 },
}, 581), "guide:demon-hunter/vengeance"))
addEntry(catalog.entries, "demon-hunter-vengeance-demon-spikes", "Demon Spikes", verified(spec({
    classID = 12, category = "defensive", castID = 203720, auraID = 203819,
    talentCondition = { kind = "spell-known", id = 203720 },
}, 581), "guide:demon-hunter/vengeance", "direct-aura"))
addEntry(catalog.entries, "demon-hunter-devourer-void-metamorphosis", "Void Metamorphosis", blocked(spec({
    classID = 12, category = "offensive", castID = 1217607, auraID = nil,
    talentCondition = { kind = "spell-known", id = 1217607 },
}, 1480), "guide:demon-hunter/devourer", "player aura ID is not verified; do not reuse Havoc Metamorphosis mapping", 3))
addEntry(catalog.entries, "demon-hunter-devourer-blur", "Blur", blocked(spec({
    classID = 12, category = "defensive", castID = 198589, auraID = nil,
    talentCondition = { kind = "spell-known", id = 198589 },
}, 1480), "guide:demon-hunter/devourer", "Devourer-specific Blur aura/gate is not verified; never assume Havoc mapping", 2))

-- Evoker
addEntry(catalog.entries, "evoker-devastation-dragonrage", "Dragonrage", verified(spec({
    classID = 13, category = "offensive", castID = 375087, auraID = 375087,
    talentCondition = { kind = "spell-known", id = 375087 },
}, 1467), "guide:evoker/devastation"))
addEntry(catalog.entries, "evoker-class-obsidian-scales", "Obsidian Scales", verified(classWide({
    classID = 13, category = "defensive", castID = 363916, auraID = 363916,
    talentCondition = { kind = "spell-known", id = 363916 },
}, { 1467, 1468, 1473 }), "guide:evoker/devastation"))
addEntry(catalog.entries, "evoker-class-zephyr", "Zephyr", blocked(classWide({
    classID = 13, category = "defensive", castID = 374227, auraID = 374227,
    talentCondition = { kind = "spell-known", id = 374227 },
}, { 1467, 1468, 1473 }), "guide:evoker/devastation",
    "not confirmed as a defensive cooldown: maxroll describes the AoE reduction without a cooldown classification; wiki 'Zephyr' is an NPC disambiguation page", 2))
addEntry(catalog.entries, "evoker-preservation-stasis", "Stasis", verified(spec({
    classID = 13, category = "healing", castID = 370537, auraID = 370537,
    talentCondition = { kind = "spell-known", id = 370537 },
}, 1468), "guide:evoker/preservation"))
addEntry(catalog.entries, "evoker-preservation-temporal-burst", "Temporal Burst", blocked(spec({
    classID = 13, category = "healing", castID = nil, auraID = 431698,
    talentCondition = { kind = "selected-talent", id = 431695, selected = true },
}, 1468), "guide:evoker/preservation", "431695 is a passive talent; the active Temporal Burst trigger is not safely mapped", 2, "direct-aura"))
addEntry(catalog.entries, "evoker-augmentation-ebon-might", "Ebon Might", verified(spec({
    classID = 13, category = "offensive", castID = 395152, auraID = 395296,
    talentCondition = { kind = "spell-known", id = 395152 },
}, 1473), "guide:evoker/augmentation", "direct-aura"))
addEntry(catalog.entries, "evoker-augmentation-temporal-burst", "Temporal Burst", blocked(spec({
    classID = 13, category = "offensive", castID = nil, auraID = 431698,
    talentCondition = { kind = "selected-talent", id = 431695, selected = true },
}, 1473), "guide:evoker/augmentation", "Augmentation trigger/cast mapping and third current guide claim remain open", 2, "direct-aura"))

-- External support. No class/spec learning condition applies. Receiver-side
-- auras are still gated by the same three-source + exact-aura rule as class rows.
local function externalFields(category, castID, auraID, trigger, extra)
    local fields = {
        scope = "external", classID = nil, specIDs = nil, category = category,
        castID = castID, auraID = auraID, playerAura = true, trigger = trigger,
        talentCondition = { kind = "none", external = true },
    }
    for key, value in pairs(extra or {}) do fields[key] = value end
    return fields
end

addEntry(catalog.externals, "power-infusion", "Power Infusion", verified(externalFields(
    "offensive", 10060, 10060, "received-aura", { sourceKey = "external:power-infusion" }),
    "external:power-infusion", "direct-aura"))
addEntry(catalog.externals, "pain-suppression", "Pain Suppression", verified(externalFields(
    "defensive", 33206, 33206, "received-aura", { sourceKey = "external:pain-suppression" }),
    "external:pain-suppression", "direct-aura"))
addEntry(catalog.externals, "guardian-spirit", "Guardian Spirit", verified(externalFields(
    "defensive", 47788, 47788, "received-aura", { sourceKey = "external:guardian-spirit" }),
    "external:guardian-spirit", "direct-aura"))
addEntry(catalog.externals, "ironbark", "Ironbark", verified(externalFields(
    "defensive", 102342, 102342, "received-aura", { sourceKey = "external:ironbark" }),
    "external:ironbark", "direct-aura"))
addEntry(catalog.externals, "life-cocoon", "Life Cocoon", verified(externalFields(
    "defensive", 116849, 116849, "received-aura", { sourceKey = "external:life-cocoon" }),
    "external:life-cocoon", "direct-aura"))
addEntry(catalog.externals, "blessing-of-sacrifice", "Blessing of Sacrifice", verified(externalFields(
    "defensive", 6940, 6940, "received-aura", { sourceKey = "external:blessing-of-sacrifice" }),
    "external:blessing-of-sacrifice", "direct-aura"))
addEntry(catalog.externals, "blessing-of-protection", "Blessing of Protection", verified(externalFields(
    "defensive", 1022, 1022, "received-aura", { sourceKey = "external:blessing-of-protection" }),
    "external:blessing-of-protection", "direct-aura"))
addEntry(catalog.externals, "blessing-of-spellwarding", "Blessing of Spellwarding", verified(externalFields(
    "defensive", 204018, 204018, "received-aura", { sourceKey = "external:blessing-of-spellwarding" }),
    "external:blessing-of-spellwarding", "direct-aura"))
addEntry(catalog.externals, "blessing-of-freedom", "Blessing of Freedom", verifiedFrom(externalFields(
    "defensive", 1044, 1044, "received-aura", { sourceKey = "external:blessing-of-freedom" }),
    "external:blessing-of-freedom", { "wowhead", "method" }, "direct-aura"))
addEntry(catalog.externals, "time-dilation", "Time Dilation", verified(externalFields(
    "defensive", 357170, 357170, "received-aura", { sourceKey = "external:time-dilation" }),
    "external:time-dilation", "direct-aura"))
addEntry(catalog.externals, "ebon-might-received", "Ebon Might (received)", verified(externalFields(
    "augmentation-offensive", 395152, 395152, "received-aura", { sourceKey = "external:ebon-might" }),
    "external:ebon-might", "direct-aura"))
addEntry(catalog.externals, "prescience-received", "Prescience (received)", verified(externalFields(
    "augmentation-offensive", 409311, 410089, "received-aura", { sourceKey = "external:prescience" }),
    "external:prescience", "direct-aura"))
addEntry(catalog.externals, "shifting-sands", "Shifting Sands", blocked(externalFields(
    "augmentation-offensive", 413984, 413984, "passive-ally-buff", {
        sourceKey = "external:shifting-sands", optional = true,
        defaultSelection = {
            groupActive = true, categoryActive = true, beginAnnouncement = true,
            endAnnouncement = false, effectSelected = false,
        },
    }), "external:shifting-sands",
    "passive support has no standalone external cooldown; trigger/import path still needs review", 1,
    "direct-aura"))
addEntry(catalog.externals, "blistering-scales", "Blistering Scales", verified(externalFields(
    "augmentation-defensive", 360827, 360827, "received-aura", { sourceKey = "external:blistering-scales" }),
    "external:blistering-scales", "direct-aura"))

local specByID = {}
for _, row in ipairs(catalog.specs) do specByID[row.specID] = row end

function catalog.GetSpec(specID)
    return specByID[tonumber(specID)]
end

-- Release gate: two independent publishers make an entry selectable; three make it "strong".
function catalog.IsSelectable(entry)
    return type(entry) == "table" and entry.status == "verified"
        and (type(entry.castID) == "number" or entry.passive == true)
        and type(entry.auraID) == "number"
        and (entry.sourceCount or 0) >= 2 and entry.mappingEvidence ~= "pending"
end

function catalog.IsStrong(entry)
    return type(entry) == "table" and (entry.sourceCount or 0) >= 3
end

function catalog.EntryMatchesSpec(entry, specID)
    if type(entry) ~= "table" then return false end
    specID = tonumber(specID)
    for _, id in ipairs(entry.specIDs or {}) do
        if id == specID then return true end
    end
    return false
end

function catalog.GetEntries(specID, category, includeBlocked)
    local result = {}
    for _, entry in ipairs(catalog.entries) do
        if catalog.EntryMatchesSpec(entry, specID)
            and (not category or entry.category == category)
            and (includeBlocked or catalog.IsSelectable(entry)) then
            result[#result + 1] = entry
        end
    end
    return result
end

-- Talent APIs expose the selected trait entry, while IsPlayerSpell also returns true for some
-- passive/hidden definitions. Prefer the active trait tree when it is available and only use the
-- spellbook fallback on clients that do not expose the trait APIs (for example the small test host).
-- Set of selected talent spell IDs, built by one walk of the active trait tree.
-- nil when the trait API is missing or the config is not ready; those calls fall back uncached.
local talentSet = nil

local function buildSelectedTalentSet()
    local classTalents = C_ClassTalents
    local traits = C_Traits
    if not (classTalents and traits and type(classTalents.GetActiveConfigID) == "function"
        and type(traits.GetConfigInfo) == "function" and type(traits.GetTreeNodes) == "function"
        and type(traits.GetNodeInfo) == "function") then
        return nil
    end
    local ok, configID = pcall(classTalents.GetActiveConfigID)
    if not ok or type(configID) ~= "number" or configID <= 0 then return nil end
    local configOK, configInfo = pcall(traits.GetConfigInfo, configID)
    if not configOK or type(configInfo) ~= "table" then return nil end
    local selected = {}
    for _, treeID in ipairs(configInfo.treeIDs or {}) do
        local nodesOK, nodeIDs = pcall(traits.GetTreeNodes, treeID)
        if nodesOK and type(nodeIDs) == "table" then
            for _, nodeID in ipairs(nodeIDs) do
                local nodeOK, nodeInfo = pcall(traits.GetNodeInfo, configID, nodeID)
                local active = nodeOK and type(nodeInfo) == "table" and nodeInfo.activeEntry
                local entryID = type(active) == "table" and active.entryID or nil
                local rank = type(active) == "table" and tonumber(active.rank) or 0
                if entryID and rank > 0 then
                    local entryInfo
                    if type(traits.GetEntryInfo) == "function" then
                        local entryOK, result = pcall(traits.GetEntryInfo, configID, entryID)
                        if entryOK then entryInfo = result end
                    end
                    local definitionID = type(entryInfo) == "table" and entryInfo.definitionID
                    local definitionInfo
                    if definitionID and type(traits.GetDefinitionInfo) == "function" then
                        local definitionOK, result = pcall(traits.GetDefinitionInfo, definitionID)
                        if definitionOK then definitionInfo = result end
                    end
                    local activeSpellID = type(active) == "table" and tonumber(active.spellID)
                    local definitionSpellID = type(definitionInfo) == "table" and tonumber(definitionInfo.spellID)
                    if activeSpellID then selected[activeSpellID] = true end
                    if definitionSpellID then selected[definitionSpellID] = true end
                end
            end
        end
    end
    return selected
end

-- Drop the cached talent set; call on talent or spec changes.
function catalog.InvalidateTalentCache()
    talentSet = nil
end

function catalog.IsTalentSelected(spellID)
    spellID = tonumber(spellID)
    if not spellID or spellID <= 0 then return false end
    if not talentSet then talentSet = buildSelectedTalentSet() end
    if talentSet then return talentSet[spellID] == true end
    if type(IsPlayerSpell) == "function" then
        local ok, known = pcall(IsPlayerSpell, spellID)
        if ok then return known == true end
    end
    if type(IsSpellKnown) == "function" then
        local ok, known = pcall(IsSpellKnown, spellID)
        if ok then return known == true end
    end
    return nil
end

local function selectedVariant(entry)
    if type(entry) ~= "table" or entry.variantRole ~= "base" or not entry.variantGroup then return false end
    for _, candidate in ipairs(catalog.entries) do
        local condition = candidate.talentCondition or {}
        if candidate.variantGroup == entry.variantGroup and candidate.variantRole == "variant"
            and condition.kind == "selected-talent" then
            if catalog.IsTalentSelected(condition.id) == true then return true end
        end
    end
    return false
end

function catalog.GetAvailability(entry)
    if not catalog.IsSelectable(entry) then
        return false, entry and entry.blockedReason or "Preset is blocked pending source review."
    end
    if selectedVariant(entry) then return false, "Variant talent is selected." end
    local condition = entry.talentCondition or {}
    local kind = condition.kind
    if kind == "none" or condition.external then return true end
    local spellID = tonumber(condition.id)
    if not spellID then return false, "Missing talent or spell condition." end
    if kind == "selected-talent" then
        local selected = catalog.IsTalentSelected(spellID)
        if selected == true then return true end
        if selected == false then return false, "Talent is not selected." end
        return false, "Talent selection is unavailable."
    end
    if kind == "spell-known" then
        local known
        if type(IsPlayerSpell) == "function" then
            local ok, result = pcall(IsPlayerSpell, spellID)
            if ok then known = result == true end
        end
        if known ~= true and type(IsSpellKnownOrOverridesKnown) == "function" then
            local ok, result = pcall(IsSpellKnownOrOverridesKnown, spellID)
            if ok then known = result == true end
        end
        if known ~= true and type(IsSpellKnown) == "function" then
            local ok, result = pcall(IsSpellKnown, spellID)
            if ok then known = result == true end
        end
        if known == true then return true end
        if known == false then return false, "Spell or talent is not learned." end
        return false, "Spellbook state is unavailable."
    end
    return false, "Unknown talent condition."
end

function catalog.GetPackages(specID, includeBlocked)
    local result, byKey = {}, {}
    local function add(entry, external)
        if not external and not catalog.EntryMatchesSpec(entry, specID) then return end
        if not includeBlocked and not catalog.IsSelectable(entry) then return end
        local category = entry.category or entry.mainCategory or "offensive"
        local key = external and "external:" .. category or "class:" .. tostring(specID) .. ":" .. category
        local package = byKey[key]
        if not package then
            package = {
                id = key, name = external and "Externals · " .. category or "Class Specifics · " .. category,
                category = category, external = external == true, entries = {},
            }
            byKey[key] = package
            result[#result + 1] = package
        end
        package.entries[#package.entries + 1] = entry
    end
    for _, entry in ipairs(catalog.entries) do add(entry, false) end
    for _, entry in ipairs(catalog.externals) do add(entry, true) end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

function catalog.GetStatus()
    local result = {
        specs = #catalog.specs, entries = 0, verified = 0, blocked = 0,
        externals = #catalog.externals, externalVerified = 0, externalBlocked = 0,
    }
    for _, entry in ipairs(catalog.entries) do
        result.entries = result.entries + 1
        if catalog.IsSelectable(entry) then result.verified = result.verified + 1 else result.blocked = result.blocked + 1 end
    end
    for _, entry in ipairs(catalog.externals) do
        if catalog.IsSelectable(entry) then result.externalVerified = result.externalVerified + 1 else result.externalBlocked = result.externalBlocked + 1 end
    end
    return result
end

function catalog.Validate()
    local errors, seenSpecs, seenEntries = {}, {}, {}
    if #catalog.specs ~= 40 then errors[#errors + 1] = "expected 40 specs" end
    for _, row in ipairs(catalog.specs) do
        if type(row.classID) ~= "number" or type(row.specID) ~= "number" then errors[#errors + 1] = "invalid spec IDs" end
        if seenSpecs[row.specID] then errors[#errors + 1] = "duplicate spec " .. tostring(row.specID) end
        seenSpecs[row.specID] = true
    end
    local function validateEntry(entry)
        if type(entry.id) ~= "string" or seenEntries[entry.id] then errors[#errors + 1] = "duplicate/invalid entry id" end
        seenEntries[entry.id] = true
        if type(entry.name) ~= "string" or type(entry.category) ~= "string" then errors[#errors + 1] = "missing entry identity/category" end
        if entry.castID ~= nil and (type(entry.castID) ~= "number" or entry.castID <= 0) then errors[#errors + 1] = entry.id .. " invalid cast ID" end
        if entry.auraID ~= nil and (type(entry.auraID) ~= "number" or entry.auraID <= 0) then errors[#errors + 1] = entry.id .. " invalid aura ID" end
        if type(entry.talentCondition) ~= "table" then errors[#errors + 1] = entry.id .. " missing talent condition" end
        if entry.status == "verified" and (entry.sourceCount or 0) < 2 then errors[#errors + 1] = entry.id .. " verified with fewer than two publishers" end
        if entry.status == "verified" and not catalog.IsSelectable(entry) then errors[#errors + 1] = entry.id .. " verified without release gate" end
        if entry.status == "blocked" and type(entry.blockedReason) ~= "string" then errors[#errors + 1] = entry.id .. " blocked without reason" end
        if entry.scope ~= "external" and (type(entry.specIDs) ~= "table" or #entry.specIDs == 0) then
            errors[#errors + 1] = entry.id .. " missing spec scope"
        end
        for _, specID in ipairs(entry.specIDs or {}) do
            if not seenSpecs[specID] then errors[#errors + 1] = entry.id .. " unknown spec " .. tostring(specID) end
            if specByID[specID] and entry.classID ~= specByID[specID].classID then
                errors[#errors + 1] = entry.id .. " class/spec mismatch for " .. tostring(specID)
            end
        end
        if entry.target == "enemy" or entry.target == "pet" or entry.channelled or entry.summon then errors[#errors + 1] = entry.id .. " forbidden non-player preset" end
    end
    for _, entry in ipairs(catalog.entries) do validateEntry(entry) end
    for _, entry in ipairs(catalog.externals) do
        validateEntry(entry)
        if entry.specIDs ~= nil then errors[#errors + 1] = entry.id .. " external has spec gate" end
    end
    return #errors == 0, errors
end

ns.AuraPresets = catalog
