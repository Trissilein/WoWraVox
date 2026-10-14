local ui = ns.AuraPresetUI
local currentSpec = 66
ns.Profiles.GetCurrentSpecialization = function() return currentSpec, "Protection" end
ns.Profiles.RuleMatchesCurrentSpecialization = function(rule, specID)
    local ids = rule and rule.specializationIDs
    if type(ids) ~= "table" or #ids == 0 then return true end
    for _, id in ipairs(ids) do if id == specID then return true end end
    return false
end
local realNormalizeRuleSpecializations = ns.Profiles.NormalizeRuleSpecializations
ns.Profiles.NormalizeRuleSpecializations = function() end

local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. detail) or "")) end
    print("PASS " .. name)
end

local function contains(list, value)
    for _, item in ipairs(list or {}) do if item == value then return true end end
    return false
end

local function unique(list)
    local seen = {}
    for _, value in ipairs(list or {}) do
        if seen[value] then return false end
        seen[value] = true
    end
    return true
end

local function copyTable(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copyTable(child) end
    return result
end

-- Recording stand-in for WoW frames: every method exists, a few are remembered so the tests can read them back.
-- Only the addon's own drawing logic is exercised here, not how WoW renders it.
local function mockFrame(kind)
    local frame = { kind = kind, scripts = {}, children = {}, shown = true }
    local remembered = {
        SetText = "text", SetEnabled = "enabled", SetShown = "shown", SetTexture = "texture",
        SetDesaturated = "desaturated", SetParent = "parent", SetTextColor = "textColor",
    }
    local methods = {}
    function methods.Show(self) self.shown = true end
    function methods.Hide(self) self.shown = false end
    function methods.IsShown(self) return self.shown end
    function methods.GetWidth() return 900 end
    function methods.GetHeight() return 400 end
    function methods.SetScript(self, name, handler) self.scripts[name] = handler end
    function methods.HookScript(self, name, handler) self.scripts[name] = handler end
    function methods.SetColorTexture(self, r, g, b, a) self.color = { r, g, b, a } end
    function methods.SetVertexColor(self, r, g, b) self.vertex = { r, g, b } end
    function methods.SetSize(self, w, h) self.width, self.height = w, h end
    function methods.SetWidth(self, w) self.width = w end
    function methods.SetHeight(self, h) self.height = h end
    function methods.SetPoint(self, ...) self.lastPoint = { ... } end
    function methods.CreateTexture(self) local child = mockFrame("texture"); self.children[#self.children + 1] = child; return child end
    function methods.CreateFontString(self) local child = mockFrame("text"); self.children[#self.children + 1] = child; return child end
    setmetatable(frame, { __index = function(_, name)
        if methods[name] then return methods[name] end
        local field = remembered[name]
        if field then return function(self, value) self[field] = value end end
        return function() end
    end })
    return frame
end
CreateFrame = function(kind) return mockFrame(kind) end

local function emptyRule(name)
    return {
        id = name, name = name, spellIDs = {}, enabled = false,
        applyEnabled = false, applyMessage = "", expireEnabled = false, expireMessage = "",
        alertCategory = "none", expireCategory = "none", applySoundEnabled = false,
        expireSoundEnabled = false, screenProfiles = {}, voiceID = 7, volume = 100, speechSpeed = 100,
    }
end

local function filledRule()
    return {
        id = "filled", name = "Already configured", spellIDs = { 999 }, enabled = true,
        applyEnabled = true, applyMessage = "Keep me", alertCategory = "defensive",
    }
end

local function setKnown(...)
    knownSpells = {}
    for index = 1, select("#", ...) do knownSpells[select(index, ...)] = true end
end

local function resetDatabase()
    local filled = filledRule()
    local currentEmpty = emptyRule("Current empty")
    local otherEmpty = emptyRule("Other empty")
    WoWraVoxDB = {
        version = 5, nextRuleID = 10, settings = {},
        auras = { filled, currentEmpty, otherEmpty }, items = {}, skills = {},
    }
    selectedCategory, selectedAuraRule = "auras", currentEmpty
    selectedItemRule, selectedSkillRule = nil, nil
    ui.selected, ui.rule, ui.specID = {}, nil, nil
    return filled, currentEmpty, otherEmpty
end

-- Real catalog availability: Protection Sentinel is learned/selected, Avenging Wrath is known,
-- Divine Shield is unlearned; blocked rows stay unavailable even when selected by the test.
-- Nothing is pre-selected: the player ticks every entry individually.
local selfBuffs = {}
C_Spell.IsSelfBuff = function(spellID) return selfBuffs[spellID] == true end
setKnown(385438, 31884, 498, 10060)
local filled, currentEmpty, otherEmpty = resetDatabase()
ui.build(mockFrame("Frame"))
ui.buildOverview(mockFrame("Frame"))
ui.creationActive, ui.creationDraft = true, currentEmpty

local function findEntry(id)
    for _, list in ipairs({ ns.AuraPresets.entries, ns.AuraPresets.externals }) do
        for _, entry in ipairs(list) do if entry.id == id then return entry end end
    end
end

local function findPackage(model, id)
    for _, section in ipairs(model.sections) do
        for _, pkg in ipairs(section.packages) do if pkg.id == id then return pkg end end
    end
end

local function countItems(model)
    local total = 0
    for _ in pairs(model.items) do total = total + 1 end
    return total
end

local model = ui.model(66)
check("model has a class and an external section", #model.sections == 2
    and model.sections[1].key == "Class Specifics" and model.sections[2].key == "Externals")
check("model pre-selects nothing", model.selectedCount == 0 and next(ui.selected) == nil
    and model.items["paladin-protection-sentinel"].selected == false
    and model.items["paladin-protection-avenging-wrath"].selected == false
    and model.items["power-infusion"].selected == false)
check("learned entries are available without a reason", model.items["paladin-protection-sentinel"].available == true
    and model.items["paladin-protection-sentinel"].reason == nil)
check("unlearned entry is unavailable with a reason",
    model.items["paladin-class-divine-shield"] and model.items["paladin-class-divine-shield"].available == false
    and type(model.items["paladin-class-divine-shield"].reason) == "string")
do
    local defensive = findPackage(model, "class:66:defensive")
    check("package carries category, count and flags", defensive and defensive.category == "defensive"
        and defensive.count == #defensive.entries and defensive.anyAvailable == true and defensive.allSelected == false
        and defensive.title:find(tostring(defensive.count) .. " effects", 1, true) ~= nil, defensive and defensive.title)
    check("accent color per category", findPackage(model, "class:66:defensive").accent[3] > 0.7
        and findPackage(model, "class:66:offensive").accent[1] > 0.7
        and findPackage(model, "external:offensive").accent[1] > 0.7)
end

do
    -- Ardent Defender may be verified, so blocked rows are checked on Arms (71), where Die by the Sword stays blocked.
    local savedSpec = currentSpec
    currentSpec = 71
    local armsModel = ui.model(71)
    local blocked = armsModel.items["warrior-arms-die-by-the-sword"]
    local internalNote = findEntry("warrior-arms-die-by-the-sword").blockedReason
    check("blocked entry is unavailable with the player sentence, not the internal note",
        blocked and blocked.available == false and blocked.selectable == false
        and blocked.reason == "Blocked pending source review."
        and (internalNote == nil or blocked.reason:find(internalNote, 1, true) == nil), blocked and blocked.reason)
    local armsDefensive = findPackage(armsModel, "class:71:defensive")
    check("package title counts blocked entries", armsDefensive and armsDefensive.blocked >= 1
        and armsDefensive.title:find(" blocked)", 1, true) ~= nil, armsDefensive and armsDefensive.title)
    ui.toggleEntry(blocked)
    check("a blocked entry cannot be selected", ui.selected["warrior-arms-die-by-the-sword"] == nil
        and ui.focus == "warrior-arms-die-by-the-sword")
    ui.focus = nil
    currentSpec = savedSpec
end

-- Icons: spell texture first, then the spell info icon, then the question mark.
do
    local sentinelEntry = findEntry("paladin-protection-sentinel")
    C_Spell.GetSpellTexture = function(spellID) return 5000 + spellID end
    check("icon comes from the aura's spell texture", ui.model(66).items["paladin-protection-sentinel"].icon
        == 5000 + sentinelEntry.auraID)
    C_Spell.GetSpellTexture = nil
    check("icon falls back to the spell info icon", ui.model(66).items["paladin-protection-sentinel"].icon == 1)
    local realInfo = C_Spell.GetSpellInfo
    C_Spell.GetSpellInfo = function() return nil end
    check("icon falls back to the question mark",
        ui.model(66).items["paladin-protection-sentinel"].icon == "Interface\\Icons\\INV_Misc_QuestionMark")
    C_Spell.GetSpellInfo = realInfo
end

-- canSpeak: a differing cast ID is bundled with the aura ID (one trigger); the cast ID decides.
do
    local sentinelEntry, power = findEntry("paladin-protection-sentinel"), findEntry("power-infusion")
    check("fixture: Sentinel is cast with another ID than its aura", sentinelEntry.castID ~= sentinelEntry.auraID
        and power.castID == power.auraID)
    selfBuffs = { [sentinelEntry.castID] = true }
    check("canSpeak follows the bundled cast ID", ui.model(66).items["paladin-protection-sentinel"].canSpeak == true)
    selfBuffs = { [sentinelEntry.auraID] = true }
    check("canSpeak ignores the aura ID when a cast ID is bundled",
        ui.model(66).items["paladin-protection-sentinel"].canSpeak == false)
    selfBuffs = { [power.auraID] = true }
    check("canSpeak uses the aura ID when cast and aura ID are the same", ui.model(66).items["power-infusion"].canSpeak == true)
    selfBuffs = {}
    check("canSpeak is false for a non-self buff", ui.model(66).items["power-infusion"].canSpeak == false)
end

-- Source strength: three publishers = strong, two = basic (fixture externals).
do
    local function fixture(id, sources)
        return {
            id = id, name = id, scope = "external", category = "offensive", castID = 900001, auraID = 900001,
            playerAura = true, talentCondition = { kind = "none", external = true }, status = "verified",
            sources = sources, sourceCount = ns.AuraPresets.CountSources(sources), mappingEvidence = "direct-aura",
        }
    end
    local weak = fixture("harness-weak", { "maxroll", "warcraft-wiki" })
    local strong = fixture("harness-strong", { "wowhead", "icy-veins", "method" })
    table.insert(ns.AuraPresets.externals, weak)
    table.insert(ns.AuraPresets.externals, strong)
    local fixtureModel = ui.model(66)
    local weakItem, strongItem = fixtureModel.items["harness-weak"], fixtureModel.items["harness-strong"]
    check("two sources are available but not strong", weakItem.available == true and weakItem.strong == false
        and weakItem.sourceCount == 2)
    check("three sources are strong", strongItem.available == true and strongItem.strong == true
        and strongItem.sourceCount == 3)
    check("detail text names the strength", ui.describe(weakItem).meta:find("Basic (2 sources)", 1, true) ~= nil
        and ui.describe(strongItem).meta:find("Strong", 1, true) ~= nil, ui.describe(weakItem).meta)
    table.remove(ns.AuraPresets.externals)
    table.remove(ns.AuraPresets.externals)
    check("strength flag matches the catalog helper for every shown entry", (function()
        for _, item in pairs(model.items) do
            if item.strong ~= ns.AuraPresets.IsStrong(item.entry) then return false end
        end
        return true
    end)())
end

-- Detail texts.
do
    selfBuffs = { [findEntry("power-infusion").castID] = true }
    local speaks = ui.describe(ui.model(66).items["power-infusion"])
    check("detail bar says the addon speaks the aura", speaks.output == "The addon speaks this aura."
        and speaks.name == "Spell 10060" and speaks.meta:find("Offensive", 1, true) == 1
        and speaks.meta:find("No talent needed", 1, true) ~= nil, speaks.meta)
    selfBuffs = {}
    local silent = ui.describe(ui.model(66).items["power-infusion"])
    check("detail bar says WoW plays the category word", silent.output
        == "WoW plays the category word (the addon cannot read this aura in combat).")
    local unlearned = ui.describe(ui.model(66).items["paladin-class-divine-shield"])
    check("detail bar shows why an effect is unavailable", unlearned.meta:find(
        ui.model(66).items["paladin-class-divine-shield"].reason, 1, true) ~= nil, unlearned.meta)
    check("detail bar hint without an effect", ui.describe(nil).hint == "Hover or click an effect for details."
        and ui.describe(nil).name == "")
end

-- Selecting: entry tiles toggle available effects only; the package switch selects/clears available ones.
ui.refresh()
check("refresh draws the counter", ui.countLabel.text == "0 selected" and ui.importButton == nil)
ui.toggleEntry(ui.model(66).items["paladin-protection-sentinel"])
ui.refresh()
check("ticking an available effect counts it", ui.selected["paladin-protection-sentinel"] == true
    and ui.countLabel.text == "1 selected")
ui.toggleEntry(ui.model(66).items["paladin-protection-sentinel"])
ui.refresh()
check("unticking counts it out again", ui.countLabel.text == "0 selected")
ui.toggleEntry(ui.model(66).items["paladin-class-divine-shield"])
check("an unavailable effect cannot be ticked", ui.selected["paladin-class-divine-shield"] == nil)

do
    local defensive = findPackage(ui.model(66), "class:66:defensive")
    ui.togglePackage(defensive)
    local after = findPackage(ui.model(66), "class:66:defensive")
    local onlyAvailable = true
    for _, item in ipairs(after.entries) do
        if item.available ~= (ui.selected[item.id] == true) then onlyAvailable = false end
        if not item.available and ui.selected[item.id] ~= nil then onlyAvailable = false end
    end
    check("package switch selects available effects only", after.allSelected == true and onlyAvailable
        and ui.selected["paladin-protection-sentinel"] == true and ui.selected["paladin-class-divine-shield"] == nil)
    ui.togglePackage(after)
    local cleared = findPackage(ui.model(66), "class:66:defensive")
    check("package switch clears them again", cleared.allSelected == false and ui.model(66).selectedCount == 0
        and ui.selected["paladin-protection-sentinel"] == false)
end

-- Widgets (mocked): cards and tiles are drawn from the model, hover/click drive the detail bar.
do
    ui.selected, ui.hover, ui.focus = {}, nil, nil
    ui.refresh()
    local drawn = ui.model(66)
    local cardCount, tileCount = 0, 0
    for _, card in ipairs(ui.cards) do if card.shown then cardCount = cardCount + 1 end end
    for _, tile in ipairs(ui.tiles) do if tile.shown then tileCount = tileCount + 1 end end
    local packageCount = 0
    for _, section in ipairs(drawn.sections) do packageCount = packageCount + #section.packages end
    check("one card per package and one tile per effect", cardCount == packageCount and tileCount == countItems(drawn),
        cardCount .. "/" .. packageCount .. " " .. tileCount .. "/" .. countItems(drawn))
    check("detail bar starts with the hint", ui.detail.hint.text == "Hover or click an effect for details."
        and ui.detail.name.text == "")
    local function tileFor(id)
        for _, tile in ipairs(ui.tiles) do if tile.shown and tile.item and tile.item.id == id then return tile end end
    end
    local sentinelTile, shieldTile = tileFor("paladin-protection-sentinel"), tileFor("paladin-class-divine-shield")
    check("unavailable tile is desaturated with a cross, available one is not",
        shieldTile.icon.desaturated == true and shieldTile.lock.shown == true
        and sentinelTile.icon.desaturated == false and sentinelTile.lock.shown == false,
        tostring(shieldTile.lock.shown) .. "/" .. tostring(sentinelTile.lock.shown))
    sentinelTile.scripts.OnEnter(sentinelTile)
    check("hover shows the effect in the detail bar", ui.detail.name.text == "Spell 389539"
        and ui.detail.meta.text ~= "" and ui.detail.output.text ~= "" and ui.detail.hint.text == "")
    check("hover lightens the border", sentinelTile.border.color[1] > 0.8)
    sentinelTile.scripts.OnLeave(sentinelTile)
    check("leaving without a click restores the hint", ui.detail.name.text == "" and ui.detail.hint.text ~= "")
    sentinelTile.scripts.OnClick(sentinelTile)
    check("click selects, gold border, check mark, counter",
        ui.selected["paladin-protection-sentinel"] == true and sentinelTile.border.color[1] == 1
        and sentinelTile.border.color[3] < 0.3 and sentinelTile.check.shown == true
        and ui.countLabel.text == "1 selected")
    check("detail bar keeps the clicked effect without hover", ui.detail.name.text == "Spell 389539")
    shieldTile.scripts.OnClick(shieldTile)
    check("click on an unavailable tile selects nothing but shows it",
        ui.selected["paladin-class-divine-shield"] == nil
        and ui.detail.name.text == "Spell " .. findEntry("paladin-class-divine-shield").auraID)
    local defensiveCard
    for _, card in ipairs(ui.cards) do
        if card.shown and card.title.text:find("Defensive", 1, true) and card.title.text:find("effect", 1, true) then
            defensiveCard = defensiveCard or card
        end
    end
    check("package card has a Select all switch", defensiveCard and defensiveCard.toggle.text == "Select all"
        and defensiveCard.toggle.enabled == true)
    ui.selected = {}
    defensiveCard.toggle.scripts.OnClick()
    check("package switch becomes Clear once all available effects are selected", defensiveCard.toggle.text == "Clear"
        and ui.selected["paladin-protection-sentinel"] == true)
    defensiveCard.toggle.scripts.OnClick()
    check("Clear removes the selection", defensiveCard.toggle.text == "Select all" and ui.model(66).selectedCount == 0)
    ui.selected, ui.hover, ui.focus = {}, nil, nil
    ui.refresh()
end

-- Tile tooltip (mocked GameTooltip): hover shows the real spell, unavailable tiles add the reason, leaving hides.
do
    local calls, failSpell = {}, false
    local function rec(name) return function(self, ...) calls[#calls + 1] = { name, self, ... } end end
    GameTooltip = {
        SetOwner = rec("SetOwner"), SetText = rec("SetText"), AddLine = rec("AddLine"),
        Show = rec("Show"), Hide = rec("Hide"),
        SetSpellByID = function(self, id)
            calls[#calls + 1] = { "SetSpellByID", self, id }
            if failSpell then error("spell unavailable") end
        end,
    }
    local function callsNamed(name)
        local found = {}
        for _, call in ipairs(calls) do if call[1] == name then found[#found + 1] = call end end
        return found
    end
    local function tileFor(id)
        for _, tile in ipairs(ui.tiles) do if tile.shown and tile.item and tile.item.id == id then return tile end end
    end
    local sentinelTile, shieldTile = tileFor("paladin-protection-sentinel"), tileFor("paladin-class-divine-shield")
    local sentinelAura = findEntry("paladin-protection-sentinel").auraID

    sentinelTile.scripts.OnEnter(sentinelTile)
    check("tooltip owner is the hovered tile, anchored right", calls[1][1] == "SetOwner"
        and calls[1][3] == sentinelTile and calls[1][4] == "ANCHOR_RIGHT")
    check("tooltip shows the spell for the aura ID", #callsNamed("SetSpellByID") == 1
        and callsNamed("SetSpellByID")[1][3] == sentinelAura, tostring(sentinelAura))
    check("available tile adds no reason line", #callsNamed("AddLine") == 0 and #callsNamed("SetText") == 0)
    check("tooltip is shown on hover", #callsNamed("Show") == 1)
    sentinelTile.scripts.OnLeave(sentinelTile)
    check("leaving hides the tooltip", #callsNamed("Hide") == 1)

    calls = {}
    shieldTile.scripts.OnEnter(shieldTile)
    local reasonLines = callsNamed("AddLine")
    check("unavailable tile adds the localized reason line", #reasonLines == 1
        and shieldTile.item.reason ~= nil and reasonLines[1][3] == shieldTile.item.reason)
    shieldTile.scripts.OnLeave(shieldTile)

    calls, failSpell = {}, true
    sentinelTile.scripts.OnEnter(sentinelTile)
    check("failed spell lookup falls back to the item name", #callsNamed("SetText") == 1
        and callsNamed("SetText")[1][3] == sentinelTile.item.name)

    GameTooltip = nil
    ui.selected, ui.hover, ui.focus = {}, nil, nil
    ui.refresh()
end

-- PLAYER_TALENT_UPDATE: ticks stay, the list redraws once (throttled), the talent cache is dropped.
local timers = {}
local realTimer, realInvalidate = C_Timer, ns.AuraPresets.InvalidateTalentCache
C_Timer = { After = function(_, callback) timers[#timers + 1] = callback end }
local invalidated = 0
ns.AuraPresets.InvalidateTalentCache = function() invalidated = invalidated + 1; realInvalidate() end
ui.selected["paladin-protection-sentinel"] = true
ui.selected["paladin-protection-avenging-wrath"] = true
local refreshes, realRefresh = 0, ui.refresh
ui.refresh = function() refreshes = refreshes + 1; return realRefresh() end
setKnown(31884, 498, 10060)
ns.onEvent(ns.eventFrame, "PLAYER_TALENT_UPDATE")
ns.onEvent(ns.eventFrame, "ACTIVE_TALENT_GROUP_CHANGED")
ns.onEvent(ns.eventFrame, "PLAYER_TALENT_UPDATE")
check("talent burst queues one redraw", #timers == 1 and refreshes == 0 and invalidated >= 1)
check("talent event keeps the player's ticks and chooser state",
    ui.selected["paladin-protection-sentinel"] == true and ui.rule == currentEmpty and ui.specID == 66)
timers[1]()
check("throttled redraw runs once while the preset list is open", refreshes == 1)
check("unlearned Sentinel is no longer offered, selected or imported",
    ui.selected["paladin-protection-sentinel"] == true
    and ui.model(66).items["paladin-protection-sentinel"].available == false
    and ui.model(66).items["paladin-protection-sentinel"].selected == false
    and #ns.AuraPresetUI.collectSelected(66, { ["paladin-protection-sentinel"] = true }) == 0)
ui.creationActive = false
ns.onEvent(ns.eventFrame, "PLAYER_TALENT_UPDATE")
timers[2]()
check("no redraw when the preset list is not open", refreshes == 1)
ui.refresh, ns.AuraPresets.InvalidateTalentCache, C_Timer = realRefresh, realInvalidate, realTimer
ui.creationActive = true
setKnown(385438, 31884, 498, 10060)
ui.selected, ui.rule, ui.specID = {}, nil, nil
ui.refresh()
check("learned Sentinel is offered again, still unticked", ui.model(66).items["paladin-protection-sentinel"].available == true
    and ui.model(66).items["paladin-protection-sentinel"].selected == false)
ui.creationActive, ui.creationDraft = false, nil

-- Test-only catalog fixtures: a second effect with the sentinel's aura ID (dedupe) and a second defensive effect.
local sentinel
for _, entry in ipairs(ns.AuraPresets.entries) do
    if entry.id == "paladin-protection-sentinel" then sentinel = entry break end
end
local function cloneSentinel(id, name, auraID, castID)
    local clone = {}
    for key, value in pairs(sentinel or {}) do clone[key] = value end
    clone.id, clone.name = id, name
    if auraID then clone.auraID = auraID end
    if castID then clone.castID = castID end
    table.insert(ns.AuraPresets.entries, clone)
end
cloneSentinel("harness-duplicate-sentinel", "Sentinel duplicate")
cloneSentinel("harness-second-defensive", "Second defensive", 900002, 900002)

local PI, SENTINEL, WRATH = "power-infusion", "paladin-protection-sentinel", "paladin-protection-avenging-wrath"
local SHIELD, ARDENT = "paladin-class-divine-shield", "paladin-protection-ardent-defender"
local piAura, sentinelAura = findEntry(PI).auraID, findEntry(SENTINEL).auraID
local wrathAura = findEntry(WRATH).auraID

-- Starts a fresh Add Aura draft with the given manual triggers and ticked effects.
local function beginDraft(manualIDs, ...)
    local draft = emptyRule("New aura group")
    for _, id in ipairs(manualIDs or {}) do draft.spellIDs[#draft.spellIDs + 1] = id end
    ui.creationActive, ui.creationDraft = true, draft
    selectedCategory, selectedAuraRule = "auras", draft
    ui.selected = {}
    for index = 1, select("#", ...) do ui.selected[select(index, ...)] = true end
    return draft
end

local function rowIDs(group)
    local ids = {}
    for _, row in ipairs(group.rows) do ids[#ids + 1] = row.id end
    return ids
end

local function sameList(a, b)
    if #a ~= #b then return false end
    for index = 1, #a do if a[index] ~= b[index] then return false end end
    return true
end

-- pendingGroup: pure data of the one group "Create aura" will make.
do
    beginDraft(nil, PI)
    local group = ui.pendingGroup(66)
    check("one external effect: its name, own cue 'offensive-external', no spec, no cast map",
        #group.rows == 1 and group.rows[1].id == piAura and group.rows[1].name == "Spell " .. piAura
        and group.name == "Spell " .. piAura and group.categoryByAuraID[piAura] == "offensive-external"
        and group.rows[1].cue == "offensive-external" and group.rows[1].hint == "Offensive · Somebody loves you"
        and group.cue == nil and group.mixed == nil
        and group.specializationIDs == nil and group.castByAuraID == nil and sameList(group.spellIDs, { piAura })
        and group.applyMessage == "{spell}" and group.presetID == "aura-preset:external:offensive",
        group.name .. " " .. tostring(group.categoryByAuraID[piAura]))

    beginDraft(nil, SENTINEL)
    group = ui.pendingGroup(66)
    check("one class effect keeps its cast ID bundle and the spec",
        group.categoryByAuraID[sentinelAura] == "defensive" and group.castByAuraID
        and group.castByAuraID[sentinelAura] == 31884 and group.rows[1].hint == "Defensive"
        and group.specializationIDs and group.specializationIDs[1] == 66 and #group.specializationIDs == 1)

    beginDraft(nil, SENTINEL, "harness-second-defensive", "harness-duplicate-sentinel")
    group = ui.pendingGroup(66)
    check("uniform class category: per-effect cues, scoped name, {spell} text, duplicate aura collapses",
        group.categoryByAuraID[sentinelAura] == "defensive" and group.categoryByAuraID[900002] == "defensive"
        and #group.rows == 2
        and sameList(rowIDs(group), { sentinelAura, 900002 }) and unique(group.spellIDs)
        and group.name == "Class Specifics · Defensive" and group.applyMessage == "{spell}"
        and group.presetID == "aura-preset:class:66:defensive"
        and group.specializationIDs[1] == 66 and group.castByAuraID[sentinelAura] == 31884,
        group.name .. " " .. #group.rows)

    beginDraft(nil, PI, WRATH)
    group = ui.pendingGroup(66)
    check("class and external effects keep their own cues, group is global and has a neutral name",
        group.categoryByAuraID[wrathAura] == "offensive" and group.categoryByAuraID[piAura] == "offensive-external"
        and group.specializationIDs == nil
        and group.name == "Preset group" and group.presetID == nil and group.applyMessage == "{spell}", group.name)

    beginDraft(nil, SENTINEL, WRATH)
    group = ui.pendingGroup(66)
    check("mixed categories: every effect keeps its own cue, generic name, no mixed flag",
        group.categoryByAuraID[sentinelAura] == "defensive" and group.categoryByAuraID[wrathAura] == "offensive"
        and group.mixed == nil and group.name == "Preset group"
        and group.applyMessage == "{spell}" and group.presetID == nil and #group.rows == 2
        and group.specializationIDs and group.specializationIDs[1] == 66)

    beginDraft(nil, SENTINEL, WRATH, PI)
    group = ui.pendingGroup(66)
    check("mixed with an external effect: no spec filter", group.specializationIDs == nil
        and #group.rows == 3 and group.categoryByAuraID[piAura] == "offensive-external")

    beginDraft({ 777001 })
    group = ui.pendingGroup(66)
    check("manual only: one manual row, no cue map, draft name kept",
        #group.rows == 1 and group.rows[1].manual == true and group.rows[1].id == 777001
        and group.categoryByAuraID == nil and group.hasPresets == false and group.name == "New aura group"
        and group.specializationIDs == nil and group.castByAuraID == nil)

    beginDraft({ 777001, piAura }, PI)
    group = ui.pendingGroup(66)
    check("manual first, preset duplicate by aura ID counted once",
        sameList(rowIDs(group), { 777001, piAura }) and group.rows[1].manual and group.rows[2].manual
        and group.categoryByAuraID[piAura] == "offensive-external" and group.name == "Externals · Offensive", group.name)

    beginDraft({ 777001 }, SENTINEL)
    group = ui.pendingGroup(66)
    check("manual and preset effect: manual row first, preset row second",
        sameList(rowIDs(group), { 777001, sentinelAura }) and group.rows[1].manual and not group.rows[2].manual
        and group.rows[2].entryID == SENTINEL and group.categoryByAuraID[sentinelAura] == "defensive"
        and group.name == "Class Specifics · Defensive" and group.specializationIDs[1] == 66)

    local renamed = beginDraft(nil, PI)
    renamed.name = "My own group"
    check("a renamed draft keeps its name", ui.pendingGroup(66).name == "My own group")

    beginDraft(nil, SHIELD, ARDENT)
    check("unavailable or blocked effects are never part of the group", #ui.pendingGroup(66).rows == 0)
end

-- cueForEntry: externals get the combined word by their category; class effects keep their category cue.
do
    local cueOf = ui.cueForEntry
    check("cueForEntry: external offensive/defensive (incl. augmentation) get the combined cue",
        cueOf(findEntry("power-infusion"), nil) == "offensive-external"
        and cueOf(findEntry("pain-suppression"), nil) == "defensive-external"
        and cueOf(findEntry("ebon-might-received"), nil) == "offensive-external"
        and cueOf(findEntry("blistering-scales"), nil) == "defensive-external")
    check("cueForEntry: external healing and class effects keep their cues",
        cueOf({ category = "healing", scope = "external" }, nil) == "somebody-loves-you"
        and cueOf(nil, { external = true, category = "healing" }) == "somebody-loves-you"
        and cueOf(findEntry(SENTINEL), nil) == "defensive" and cueOf(findEntry(WRATH), nil) == "offensive")
end

-- Overview widgets (mocked): header, rows, empty state, mixed hint, removing rows.
do
    beginDraft(nil)
    ui.rule, ui.specID = ui.creationDraft, 66
    ui.refreshOverview()
    check("overview of nothing shows the empty hint", ui.ovEmpty.shown == true and ui.ovMixed == nil
        and ui.ovCount.text == "0 effects" and ui.ovName.text == "New aura group")
    local draft = beginDraft({ 777001 }, SENTINEL)
    ui.rule, ui.specID = draft, 66
    ui.refresh()
    local shownRows = 0
    for _, row in ipairs(ui.ovRows) do if row.shown then shownRows = shownRows + 1 end end
    check("overview lists manual and preset rows with name, id and hint", shownRows == 2 and ui.ovEmpty.shown == false
        and ui.ovCount.text == "2 effects" and ui.ovName.text == "Class Specifics · Defensive"
        and ui.ovRows[1].title.text:find("777001", 1, true) ~= nil and ui.ovRows[1].title.text:find("Manual", 1, true) ~= nil
        and ui.ovRows[2].title.text:find("Spell " .. sentinelAura, 1, true) ~= nil
        and ui.ovRows[2].title.text:find("Defensive", 1, true) ~= nil, ui.ovRows[2].title.text)
    ui.selected[WRATH] = true
    ui.ovName.text = nil
    ui.refresh()
    check("mixed categories: no warning line, each row shows its own cue",
        ui.ovMixed == nil and ui.ovName.text == "Preset group" and ui.ovCount.text == "3 effects"
        and ui.ovRows[3].title.text:find("Offensive", 1, true) ~= nil, ui.ovRows[3].title.text)
    ui.ovRows[3].remove.scripts.OnClick()
    check("x on a preset row unticks that effect and redraws the overview",
        ui.selected[WRATH] == false and ui.countLabel.text == "1 selected" and ui.ovCount.text == "2 effects"
        and ui.ovRows[3].shown == false)
    ui.ovRows[1].remove.scripts.OnClick()
    check("x on a manual row removes the trigger from the draft and redraws the overview",
        #draft.spellIDs == 0 and ui.ovCount.text == "1 effect" and ui.ovRows[1].data.entryID == SENTINEL
        and ui.ovRows[2].shown == false, ui.ovCount.text)
    ui.selected = {}
    ui.refresh()
    check("overview is empty again after clearing", ui.ovEmpty.shown == true and ui.ovCount.text == "0 effects")
end

-- Create aura: exactly one rule from manual triggers and all ticked effects.
local savedFinishCreation = ui.finishCreation
local finished = 0
ui.finishCreation = function()
    finished = finished + 1
    ui.creationActive, ui.creationDraft = false, nil
end
addRuleMode = true

local function createFromDraft(manualIDs, ...)
    local draft = beginDraft(manualIDs, ...)
    local before = #WoWraVoxDB.auras
    ui.createGroup()
    return draft, #WoWraVoxDB.auras - before
end

local powerRule, added = createFromDraft(nil, PI)
check("Create aura with Power Infusion makes exactly one rule, the draft", added == 1
    and WoWraVoxDB.auras[#WoWraVoxDB.auras] == powerRule and finished == 1 and selectedAuraRule == powerRule
    and addRuleMode == false and ui.creationDraft == nil)
check("Power Infusion group is filled, enabled, per-effect cue, speaks {spell}",
    sameList(powerRule.spellIDs, { piAura }) and powerRule.name == "Spell " .. piAura and powerRule.enabled == true
    and powerRule.alertCategory == "none" and powerRule.applyEnabled == true
    and powerRule.categoryByAuraID[piAura] == "offensive-external" and next(powerRule.categoryByAuraID, piAura) == nil
    and powerRule.applyMessage == "{spell}" and powerRule.castByAuraID == nil
    and powerRule.specializationIDs == nil and powerRule.presetID == "aura-preset:external:offensive",
    powerRule.name .. " " .. tostring(powerRule.alertCategory))
check("the created group resolves its cue per effect (external offensive: Offensive · Somebody loves you)",
    ns._Aura.cueFor(powerRule, piAura) == "offensive-external" and ns._Aura.hasApplyCue(powerRule) == true
    and ns._Aura.cueLabel(ns._Aura.cueFor(powerRule, piAura)) == "Offensive · Somebody loves you"
    and ns._Aura.noneCueLabel(powerRule, "apply") == "Per effect"
    and ns._Aura.noneCueLabel(powerRule, "expire") == "No category cue")
check("created rule ends disabled", powerRule.expireEnabled == false and powerRule.expireMessage == ""
    and powerRule.expireSoundEnabled == false
    and powerRule.expireCategory == "none" and powerRule.oneEffect == false
    and powerRule.screenProfiles and powerRule.screenProfiles.expire and powerRule.screenProfiles.expire.enabled == false)
check("created rule has a rule ID", powerRule.id ~= nil)

addRuleMode = true
local sentinelRule
sentinelRule, added = createFromDraft(nil, SENTINEL)
check("Create aura with Sentinel bundles its cast ID, scopes it to the spec", added == 1
    and type(sentinelRule.castByAuraID) == "table" and sentinelRule.castByAuraID[sentinelAura] == 31884
    and next(sentinelRule.castByAuraID, sentinelAura) == nil
    and sentinelRule.specializationIDs and sentinelRule.specializationIDs[1] == 66
    and sentinelRule.alertCategory == "none" and sentinelRule.categoryByAuraID[sentinelAura] == "defensive"
    and sentinelRule.applyMessage == "{spell}",
    tostring(sentinelRule.castByAuraID))
check("castIDFor resolves the bundled cast and falls back to the aura ID",
    ns._Aura.castIDFor(sentinelRule, sentinelAura) == 31884 and ns._Aura.castIDFor(sentinelRule, 498) == 498
    and ns._Aura.castIDFor({ spellIDs = { 5 } }, 5) == 5 and ns._Aura.castIDFor(nil, 5) == 5)

local mixedRule
mixedRule, added = createFromDraft(nil, SENTINEL, WRATH, PI, SHIELD, ARDENT)
check("several packages still make exactly one rule with all available effects", added == 1
    and #mixedRule.spellIDs == 3 and contains(mixedRule.spellIDs, sentinelAura) and contains(mixedRule.spellIDs, wrathAura)
    and contains(mixedRule.spellIDs, piAura) and unique(mixedRule.spellIDs))
check("mixed group: no group cue, one cue per effect, {spell} text and no spec filter",
    mixedRule.alertCategory == "none" and mixedRule.applyMessage == "{spell}" and mixedRule.name == "Preset group"
    and mixedRule.categoryByAuraID[sentinelAura] == "defensive" and mixedRule.categoryByAuraID[wrathAura] == "offensive"
    and mixedRule.categoryByAuraID[piAura] == "offensive-external"
    and mixedRule.specializationIDs == nil and mixedRule.presetID == nil and mixedRule.applyEnabled == true
    and mixedRule.castByAuraID and mixedRule.castByAuraID[sentinelAura] == 31884)
check("blocked and unlearned effects were not created", not contains(mixedRule.spellIDs, findEntry(SHIELD).auraID)
    and not contains(mixedRule.spellIDs, findEntry(ARDENT).auraID))

local uniformRule
uniformRule, added = createFromDraft(nil, SENTINEL, "harness-second-defensive", "harness-duplicate-sentinel")
check("uniform category group: per-effect cues, scoped name, one preset ID", added == 1
    and uniformRule.alertCategory == "none" and uniformRule.applyMessage == "{spell}"
    and uniformRule.categoryByAuraID[sentinelAura] == "defensive" and uniformRule.categoryByAuraID[900002] == "defensive"
    and uniformRule.name == "Class Specifics · Defensive" and uniformRule.presetID == "aura-preset:class:66:defensive"
    and sameList(uniformRule.spellIDs, { sentinelAura, 900002 }), uniformRule.name)

local manualRule
manualRule, added = createFromDraft({ 777001 })
check("manual-only draft behaves as before", added == 1 and sameList(manualRule.spellIDs, { 777001 })
    and manualRule.name == "New aura group" and manualRule.alertCategory == "none" and manualRule.applyEnabled == false
    and manualRule.applyMessage == "" and manualRule.castByAuraID == nil and manualRule.presetID == nil
    and manualRule.categoryByAuraID == nil
    and manualRule.specializationIDs == nil)

local combinedRule
combinedRule, added = createFromDraft({ 777002 }, PI)
check("manual trigger plus preset effect land in the one rule", added == 1
    and sameList(combinedRule.spellIDs, { 777002, piAura }) and combinedRule.alertCategory == "none"
    and combinedRule.categoryByAuraID[piAura] == "offensive-external" and combinedRule.categoryByAuraID[777002] == nil
    and ns._Aura.cueFor(combinedRule, 777002) == "none"
    and combinedRule.applyEnabled == true and combinedRule.name == "Externals · Offensive", combinedRule.name)

local emptyDraftRule
emptyDraftRule, added = createFromDraft(nil)
check("an empty draft still creates an empty group as before", added == 1 and #emptyDraftRule.spellIDs == 0
    and emptyDraftRule.applyEnabled == false)

local countBefore = #WoWraVoxDB.auras
ui.creationActive, ui.creationDraft = false, nil
ui.createGroup()
check("Create aura does nothing when no creation is active", #WoWraVoxDB.auras == countBefore)
ui.finishCreation = savedFinishCreation
addRuleMode = false

-- The metadata and cast map of created rules survive a reload (real all-profile normalizer).
local importedRule = sentinelRule
local metadataID, metadataEntries = importedRule.presetID, importedRule.spellIDs
local reloadedRule = copyTable(importedRule)
local keptMapRule, garbageMapRule, junkMapRule = copyTable(sentinelRule), copyTable(sentinelRule), copyTable(sentinelRule)
garbageMapRule.castByAuraID = { [389539] = 31884, x = 5, [7] = "y", [-1] = 3, [8] = 2.5 }
garbageMapRule.categoryByAuraID = { [389539] = "healing", [7] = "bogus", [-1] = "offensive", [8.5] = "offensive",
    x = "defensive", [9] = 5, [10] = "none", [11] = "Somebody loves you" }
junkMapRule.castByAuraID = "junk"
junkMapRule.categoryByAuraID = "junk"
WoWraVoxProfilesDB = {
    version = 1, nextProfileID = 1, characters = {},
    profiles = { ["profile-1"] = { name = "Harness", data = {
        version = 5, settings = {}, auras = { reloadedRule, keptMapRule, garbageMapRule, junkMapRule }, items = {}, skills = {},
    } } },
}
ns.Profiles.NormalizeRuleSpecializations = realNormalizeRuleSpecializations
ns.NormalizeAllProfiles()
ns.Profiles.NormalizeRuleSpecializations = function() end
local persistedRule = WoWraVoxProfilesDB.profiles["profile-1"].data.auras[1]
check("normalized reload preserves created metadata",
    persistedRule.presetID == metadataID
    and persistedRule.specializationIDs and persistedRule.specializationIDs[1] == 66
    and #persistedRule.spellIDs == #importedRule.spellIDs
    and persistedRule.spellIDs[1] == importedRule.spellIDs[1])
do
    local persisted = WoWraVoxProfilesDB.profiles["profile-1"].data.auras
    local cleaned = persisted[3].castByAuraID
    check("normalization keeps a valid cast map", persisted[2].castByAuraID and persisted[2].castByAuraID[389539] == 31884)
    check("normalization drops garbage pairs from a cast map",
        cleaned and cleaned[389539] == 31884 and cleaned.x == nil and cleaned[7] == nil and cleaned[-1] == nil
        and cleaned[8] == nil)
    check("normalization drops a cast map that is not a table", persisted[4].castByAuraID == nil)
    local cues = persisted[3].categoryByAuraID
    check("normalization keeps a valid cue map", persisted[2].categoryByAuraID
        and persisted[2].categoryByAuraID[sentinelAura] == "defensive")
    check("normalization keeps only positive integer IDs with a valid cue (aliases become canonical)",
        cues and cues[389539] == "healing" and cues[11] == "somebody-loves-you" and cues[7] == nil
        and cues[-1] == nil and cues[8.5] == nil and cues.x == nil and cues[9] == nil and cues[10] == nil)
    check("normalization drops a cue map that is not a table", persisted[4].categoryByAuraID == nil)
    local onlyBadCues = { categoryByAuraID = { x = "defensive", [3] = "nope" } }
    ns._Aura.normalizeCategoryMap(onlyBadCues)
    check("a cue map without a valid pair becomes nil", onlyBadCues.categoryByAuraID == nil)
    local combinedCues = { categoryByAuraID = { [3] = "offensive-external", [4] = "Defensive · Somebody loves you", [5] = "nope" } }
    ns._Aura.normalizeCategoryMap(combinedCues)
    check("normalization accepts the combined external cues (label or key), drops unknown ones",
        combinedCues.categoryByAuraID[3] == "offensive-external" and combinedCues.categoryByAuraID[4] == "defensive-external"
        and combinedCues.categoryByAuraID[5] == nil)
    check("cue labels: the combined external cues read 'Offensive/Defensive · Somebody loves you'",
        ns._Aura.cueLabel("offensive-external") == "Offensive · Somebody loves you"
        and ns._Aura.cueLabel("defensive-external") == "Defensive · Somebody loves you"
        and ns._Aura.cueLabel("somebody-loves-you") == "Somebody loves you")
    local onlyGarbage = { castByAuraID = { x = 1, [3] = "a" } }
    ns._Aura.normalizeCastMap(onlyGarbage)
    check("a cast map without a valid pair becomes nil", onlyGarbage.castByAuraID == nil)
end
check("preset mapping metadata is no longer written", importedRule.presetEntries == nil
    and importedRule.presetCategory == nil and importedRule.presetSelectionDefault == nil)
check("the removed import button and function are gone", ui.importSelected == nil and ui.importButton == nil)

ui.creationActive, ui.creationDraft = true, otherEmpty
setKnown(31884, 498, 10060)
ns.onEvent(ns.eventFrame, "PLAYER_TALENT_UPDATE")
check("talent event leaves created metadata unchanged", importedRule.presetID == metadataID
    and importedRule.spellIDs == metadataEntries)
setKnown(385438, 31884, 498, 10060)

-- A profile/rule change resets selection state while leaving imported metadata untouched.
selectedAuraRule = otherEmpty
ui.selected = { ["manual-extra"] = true }
ui.rule, ui.specID = currentEmpty, currentSpec
ui.refresh()
check("profile change resets selection", ui.selected["manual-extra"] == nil and ui.rule == otherEmpty
    and ui.specID == currentSpec)
check("profile change does not rewrite imported metadata", importedRule.presetID == metadataID
    and importedRule.spellIDs == metadataEntries)

-- A specialization change also resets selection state and keeps imported metadata intact.
ui.selected = { ["manual-extra"] = true }
ui.rule, ui.specID = otherEmpty, currentSpec
currentSpec = 70
ui.refresh()
check("spec change resets selection", ui.selected["manual-extra"] == nil and ui.specID == 70)
check("spec change does not rewrite imported metadata", importedRule.presetID == metadataID
    and importedRule.spellIDs == metadataEntries)
currentSpec = 66
ui.refresh()
check("profile/spec return rebuilds an empty selection for the current rule", ui.specID == 66
    and ui.model(66).selectedCount == 0 and ui.model(66).items["paladin-protection-sentinel"].selected == false)
local cardCount, tileCount = #ui.cards, #ui.tiles
ui.refresh()
ui.refresh()
check("repeated refresh reuses the card and tile pools", #ui.cards == cardCount and #ui.tiles == tileCount)
