-- Tests for ShareGroups.lua (export, parse, import logic) and the export/import windows in WoWraVox.lua.
-- Runs in the Fengari harness of tools/Test-ShareGroups.js. Mocked: C_EncodingUtil (serialise stores a deep copy
-- under a key; compression and Base64 are identity), UnitClass, C_Spell, and widget frames. Real CBOR, Deflate and
-- Base64 are NOT exercised here. In the game only a real export on one character and an import on another proves them.

local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. tostring(detail)) or "")) end
    print("PASS " .. name)
end

local Share = ns.ShareGroups

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[deepCopy(key)] = deepCopy(item) end
    return out
end

local function sameTable(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for key, item in pairs(a) do
        if not sameTable(item, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

local function has(lines, text)
    for _, line in ipairs(lines or {}) do
        if line == text then return true end
    end
    return false
end

local function loosePipes(s)
    return (s:gsub("||", "")):find("|", 1, true) ~= nil
end

local function ids(count, first)
    local out = {}
    for i = 1, count do out[i] = first + i - 1 end
    return out
end

-- Mock of C_EncodingUtil: "serialising" stores a deep copy and returns its key; the key is what Base64 passes through.
local store, counter = {}, 0
local function encode(payload)
    counter = counter + 1
    local key = "CBOR" .. counter
    store[key] = deepCopy(payload)
    return key
end
local realEncoding = {
    SerializeCBOR = function(value) return encode(value) end,
    DeserializeCBOR = function(source)
        if store[source] == nil then error("not a CBOR item") end
        return deepCopy(store[source])
    end,
    CompressString = function(source) return source end,
    DecompressString = function(source)
        if source == "BOMB" then return string.rep("x", 70 * 1024) end
        return source
    end,
    EncodeBase64 = function(source) return source end,
    DecodeBase64 = function(source) return source end,
}
C_EncodingUtil = realEncoding

-- Export text for a payload built by hand, bypassing Export's checks (what a hostile sender would send).
local function craft(group, class)
    return "WVX1:" .. encode({ v = 1, kind = "aura-group", class = class, group = group })
end

local playerClass = "MAGE"
UnitClass = function() return "Mage", playerClass, 8 end
local spells = { [48707] = { "Anti-Magic Shell", 136120 }, [100] = { "Charge", 132337 } }
C_Spell = {
    GetSpellInfo = function(spellID)
        local info = spells[spellID]
        if info then return { name = info[1], iconID = info[2] } end
        return nil
    end,
}

local function sampleRule()
    local rule = ns.newAuraRule()
    rule.id = 77
    rule.name = "Shield group"
    rule.enabled = false
    rule.spellIDs = { 48707, 100 }
    rule.castByAuraID = { [48707] = 100 }
    rule.categoryByAuraID = { [100] = "defensive" }
    rule.alertCategory = "offensive"
    rule.expireCategory = "none"
    rule.applyEnabled = true
    rule.applyMessage = "Shield up"
    rule.expireEnabled = true
    rule.expireMessage = "Shield gone"
    rule.oneEffect = true
    rule.specializationIDs = { 62, 63 }
    rule.applySoundEnabled = true
    rule.applySoundMediaName = "ding.ogg"
    rule.applySoundKitID = 8959
    rule.applySoundChannel = "SFX"
    rule.screenProfiles.apply.enabled = true
    rule.screenProfiles.apply.text = "Shield"
    rule.screenProfiles.apply.font = "Local font"
    rule.screenProfiles.apply.size = 99
    rule.voiceID = 42
    rule.volume = 15
    rule.speechSpeed = 180
    return rule
end

-- Round trip: export, parse, rule
local okExport, text = Share.Export(sampleRule())
check("export returns a WVX1 text", okExport and text:sub(1, 5) == "WVX1:", text)
local okParse, group, meta = Share.Parse(text)
check("parse accepts an own export", okParse, group)
check("round trip keeps the group fields", group.name == "Shield group" and sameTable(group.spellIDs, { 48707, 100 })
    and sameTable(group.castByAuraID, { [48707] = 100 }) and sameTable(group.categoryByAuraID, { [100] = "defensive" })
    and group.alertCategory == "offensive" and group.applyMessage == "Shield up" and group.oneEffect == true
    and group.applySoundKitID == 8959 and group.applySoundChannel == "SFX" and group.applySoundMediaName == "ding.ogg")
check("specialisations and screen text travel", sameTable(group.specializationIDs, { 62, 63 })
    and group.screenProfiles.apply.enabled == true and group.screenProfiles.apply.text == "Shield")
check("meta carries class and version", meta.class == "MAGE" and meta.version == 1, meta.class)

local leaked = { "id", "enabled", "builtin", "presetID", "voiceID", "volume", "speechSpeed" }
for _, key in ipairs(leaked) do
    check("not exported: " .. key, group[key] == nil)
end
check("not exported: screen font, size, colour, anchor", group.screenProfiles.apply.font == nil
    and group.screenProfiles.apply.size == nil and group.screenProfiles.apply.color == nil
    and group.screenProfiles.apply.anchor == nil)

local imported = Share.ToRule(group, meta)
check("ToRule: new rule without id, enabled", imported.id == nil and imported.enabled == true and imported.builtin == nil)
check("ToRule: sender's settings kept", imported.name == "Shield group" and sameTable(imported.spellIDs, { 48707, 100 })
    and imported.applyMessage == "Shield up" and imported.applySoundMediaName == "ding.ogg")
check("ToRule: local voice, volume, speed and font", imported.voiceID ~= 42 and imported.volume == 80
    and imported.speechSpeed == 100 and imported.screenProfiles.apply.font ~= "Local font"
    and imported.screenProfiles.apply.size == 32)
check("ToRule: specialisations kept for the same class", sameTable(imported.specializationIDs, { 62, 63 }))
local foreign = Share.ToRule(group, { class = "WARRIOR", version = 1 })
check("ToRule: specialisations dropped for another class", foreign.specializationIDs == nil)
-- Specialisation IDs must belong to the player's class (GetSpecializationInfoByID returns the class token as 6th value)
local specClasses = { [62] = "MAGE", [63] = "MAGE", [64] = "MAGE", [71] = "WARRIOR", [265] = "WARLOCK" }
GetSpecializationInfoByID = function(specID)
    local class = specClasses[specID]
    if not class then return nil end
    return specID, "Spec", "", 0, "DAMAGER", class, class
end
check("specs: own-class IDs are kept with the API present", sameTable(Share.ToRule(group, meta).specializationIDs, { 62, 63 }))
local _, wrongSpecGroup, wrongSpecMeta = Share.Parse(craft({ name = "Wrong specs", specializationIDs = { 62, 71 } }, "MAGE"))
check("specs: one ID of another class drops all specs", Share.ToRule(wrongSpecGroup, wrongSpecMeta).specializationIDs == nil)
check("specs: hint line for a class mismatch", has(Share.Describe(wrongSpecGroup, wrongSpecMeta).notes,
    "Its specializations do not fit your class and are not imported."))
local _, unknownSpecGroup, unknownSpecMeta = Share.Parse(craft({ name = "Unknown spec", specializationIDs = { 62, 999999 } }, "MAGE"))
check("specs: an ID the client does not know drops all specs", Share.ToRule(unknownSpecGroup, unknownSpecMeta).specializationIDs == nil)
check("specs: no hint when the specs fit", not has(Share.Describe(group, meta).notes,
    "Its specializations do not fit your class and are not imported."))
check("specs: only the class note for a group of another class", #Share.Describe(wrongSpecGroup,
    { class = "WARRIOR", version = 1 }).notes == 1)
GetSpecializationInfoByID = function() error("API broke") end
check("specs: a failing API keeps the old behaviour", sameTable(Share.ToRule(group, meta).specializationIDs, { 62, 63 }))
GetSpecializationInfoByID = nil
check("specs: without the API the old behaviour stays", sameTable(Share.ToRule(wrongSpecGroup, wrongSpecMeta).specializationIDs, { 62, 71 }))
check("Describe: other-class note", has(Share.Describe(group, { class = "WARRIOR", version = 1 }).notes,
    "This group was made for another class."))
check("Describe: no class note for own class", not has(Share.Describe(group, meta).notes,
    "This group was made for another class."))

-- Describe: names, icons, unknown IDs
local okMixed, mixedGroup, mixedMeta = Share.Parse(craft({ name = "Mixed", spellIDs = { 48707, 999999, 100, 888888 } }, "MAGE"))
check("mixed group parses", okMixed)
local preview = Share.Describe(mixedGroup, mixedMeta)
check("Describe: effects and unknown count", preview.effects == 4 and preview.unknown == 2, preview.unknown)
check("Describe: known row has name and icon", preview.rows[1].known and preview.rows[1].name == "Anti-Magic Shell"
    and preview.rows[1].icon == 136120)
check("Describe: unknown row marked", preview.rows[2].known == false and preview.rows[2].name == nil)
check("Describe: unknown note counts IDs", has(preview.notes, "2 spell IDs are unknown to this client."))

-- Describe: texts the group will speak or show (only enabled outputs, non-empty texts, fixed order)
local function describeFields(fields)
    local okText, textGroupParsed, textMeta = Share.Parse(craft(fields, "MAGE"))
    check("text group parses", okText, textGroupParsed)
    return Share.Describe(textGroupParsed, textMeta)
end
local allTexts = describeFields({ name = "Texts", applyEnabled = true, applyMessage = "Up", expireEnabled = true,
    expireMessage = "Down", screenProfiles = { apply = { enabled = true, text = "Shield up" },
    expire = { enabled = true, text = "Shield down" } } })
local labels = {}
local texts = {}
for index, entry in ipairs(allTexts.texts) do
    labels[index] = entry.label
    texts[index] = entry.text
end
check("texts: all four listed in order", sameTable(labels, { "Spoken on application", "Spoken on expiration",
    "Screen text on application", "Screen text on expiration" }), table.concat(labels, ", "))
check("texts: values as stored", sameTable(texts, { "Up", "Down", "Shield up", "Shield down" }), table.concat(texts, ", "))
local onlyEnabled = describeFields({ name = "Some", applyEnabled = false, applyMessage = "Hidden",
    expireEnabled = true, expireMessage = "Shown", screenProfiles = { apply = { enabled = false, text = "Hidden too" },
    expire = { enabled = true, text = "" } } })
check("texts: disabled outputs and empty screen text left out", #onlyEnabled.texts == 1
    and onlyEnabled.texts[1].label == "Spoken on expiration" and onlyEnabled.texts[1].text == "Shown", #onlyEnabled.texts)
local noFlag = describeFields({ name = "Unflagged", applyMessage = "Silent" })
check("texts: message without an enable flag is not listed", #noFlag.texts == 0)
local emptyText = describeFields({ name = "Empty", applyEnabled = true, applyMessage = "" })
check("texts: empty text skipped", #emptyText.texts == 0)
local escapedText = describeFields({ name = "Escaped", applyEnabled = true, applyMessage = "|cffff0000x|r" })
check("texts: cleaned text shown as stored, pipes doubled", #escapedText.texts == 1
    and escapedText.texts[1].text == "||cffff0000x||r", escapedText.texts[1] and escapedText.texts[1].text)
local plain = describeFields({ name = "Plain", spellIDs = { 100 } })
check("texts: group without texts keeps the old preview", #plain.texts == 0 and plain.name == "Plain" and plain.effects == 1
    and plain.unknown == 0 and #plain.notes == 0 and #plain.rows == 1 and plain.rows[1].name == "Charge")

-- Describe: sound and category cue per event
local soundPreview = describeFields({ name = "Sounds", applySoundEnabled = true, applySoundKitID = 8959,
    applySoundChannel = "SFX", expireSoundEnabled = true, expireSoundMediaName = "ding.ogg", expireSoundKitID = 11,
    alertCategory = "defensive", expireCategory = "offensive-external" })
local soundTexts = {}
for index, entry in ipairs(soundPreview.texts) do soundTexts[index] = entry.label .. ": " .. entry.text end
check("preview: sound with kit ID and channel, media name first, cues", sameTable(soundTexts, {
    "On application: Plays sound ID 8959 on SFX", "On expiration: Plays sound ding.ogg on Master",
    "On application: Category cue: Defensive", "On expiration: Category cue: Offensive · Somebody loves you" }),
    table.concat(soundTexts, " | "))
check("preview: sound of a disabled output is not listed", #describeFields({ name = "Off", applySoundEnabled = false,
    applySoundKitID = 8959, expireSoundKitID = 8959 }).texts == 0)
check("preview: category cue none is not listed", #describeFields({ name = "None", alertCategory = "none",
    expireCategory = "none" }).texts == 0)
local defaultSound = describeFields({ name = "Default sound", applySoundEnabled = true })
check("preview: enabled sound without own ID shows the default kit", #defaultSound.texts == 1
    and defaultSound.texts[1].text == "Plays sound ID " .. ns.newAuraRule().applySoundKitID .. " on Master",
    defaultSound.texts[1] and defaultSound.texts[1].text)
local fullPreview = describeFields({ name = "Everything", applyEnabled = true, applyMessage = "A", expireEnabled = true,
    expireMessage = "B", screenProfiles = { apply = { enabled = true, text = "C" }, expire = { enabled = true, text = "D" } },
    applySoundEnabled = true, applySoundKitID = 1, expireSoundEnabled = true, expireSoundKitID = 2,
    alertCategory = "healing", expireCategory = "bloodlust" })
check("preview: eight lines at most, all listed", #fullPreview.texts == 8, #fullPreview.texts)
check("preview: sound and cue lines never block the import", Share.Check(craft({ name = "Everything",
    applySoundEnabled = true, applySoundKitID = 1, alertCategory = "healing" }, "MAGE")) ~= nil)

-- Import keeps only whitelisted fields
local okExtra, extraGroup, extraMeta = Share.Parse(craft({ name = "Extra", spellIDs = { 100 }, id = 5, enabled = false,
    voiceID = 9, builtin = true, evil = "x" }, "MAGE"))
check("unknown and personal fields are dropped on import", okExtra and extraGroup.id == nil and extraGroup.enabled == nil
    and extraGroup.voiceID == nil and extraGroup.builtin == nil and extraGroup.evil == nil)
local extraRule = Share.ToRule(extraGroup, extraMeta)
check("imported rule never takes an id or built-in flag from the text", extraRule.id == nil and extraRule.builtin == nil)

-- Built-in rules
local builtinRule = sampleRule()
builtinRule.builtin = true
local okBuiltin, reason = Share.Export(builtinRule)
check("built-in rule cannot be exported", okBuiltin == false and reason == "builtin", reason)

-- Size limits
check("MAX_INPUT is exposed as 8192", Share.MAX_INPUT == 8192, Share.MAX_INPUT)
local okBig, errBig = Share.Parse("WVX1:" .. string.rep("A", Share.MAX_INPUT))
check("input over 8 KB is refused", okBig == false and errBig == "The export is too large.", errBig)
local okEdge, errEdge = Share.Parse("WVX1:" .. string.rep("A", Share.MAX_INPUT - 5))
check("input of exactly 8 KB is not refused for its size", okEdge == false and errEdge ~= "The export is too large.", errEdge)
local okOld, errOld = Share.Parse("WVX1:" .. string.rep("A", 10 * 1024))
check("input of 10 KB (old limit 24 KB) is refused", okOld == false and errOld == "The export is too large.", errOld)
local okBomb, errBomb = Share.Parse("WVX1:BOMB")
check("decompressed over 64 KB is refused", okBomb == false and errBomb == "The export is too large.", errBomb)

-- Count limits
check("100 spell IDs accepted", (Share.Parse(craft({ name = "Max", spellIDs = ids(100, 1001) }, "MAGE"))))
local okOver, errOver = Share.Parse(craft({ name = "Over", spellIDs = ids(101, 1001) }, "MAGE"))
check("101 spell IDs refused", okOver == false and errOver == "The export data is invalid.", errOver)
local function pairMap(count)
    local out = {}
    for i = 1, count do out[1000 + i] = 2000 + i end
    return out
end
check("100 cast pairs accepted", (Share.Parse(craft({ castByAuraID = pairMap(100) }, "MAGE"))))
check("101 cast pairs refused", (Share.Parse(craft({ castByAuraID = pairMap(101) }, "MAGE"))) == false)
check("8 specialisations accepted", (Share.Parse(craft({ specializationIDs = ids(8, 62) }, "MAGE"))))
check("9 specialisations refused", (Share.Parse(craft({ specializationIDs = ids(9, 62) }, "MAGE"))) == false)

-- Strict type and range checks
local badCases = {
    { "string spell ID", { spellIDs = { "12" } } },
    { "fractional spell ID", { spellIDs = { 1.5 } } },
    { "zero spell ID", { spellIDs = { 0 } } },
    { "negative spell ID", { spellIDs = { -3 } } },
    { "spell ID above 2^31-1", { spellIDs = { 2147483648 } } },
    { "NaN spell ID", { spellIDs = { 0 / 0 } } },
    { "spell list is text", { spellIDs = "12" } },
    { "list with a hole", { spellIDs = { [1] = 1, [3] = 3 } } },
    { "cast value is text", { castByAuraID = { [1] = "x" } } },
    { "name is a number", { name = 5 } },
    { "flag is text", { applyEnabled = "yes" } },
    { "sound kit zero", { applySoundKitID = 0 } },
    { "unknown alert cue", { alertCategory = "nonsense" } },
    { "none in the cue map", { categoryByAuraID = { [100] = "none" } } },
    { "unknown cue in the map", { categoryByAuraID = { [100] = "nonsense" } } },
    { "unknown sound channel", { applySoundChannel = "Voice" } },
    { "screen flag is text", { screenProfiles = { apply = { enabled = "yes", text = "" } } } },
    { "screen profiles not a table", { screenProfiles = "x" } },
}
for _, case in ipairs(badCases) do
    local okBad, errBad = Share.Parse(craft(case[2], "MAGE"))
    check("refused: " .. case[1], okBad == false and errBad == "The export data is invalid.", errBad)
end

-- Text escaping: no chat links, textures or colour codes survive
local okEsc, escGroup = Share.Parse(craft({ name = "|cffff0000x|r", applyMessage = "|TInterface\\Icons\\X:16|t",
    expireMessage = "|Hitem:1|h[x]|h", applySoundMediaName = "|Hx|h" }, "MAGE"))
check("escape: texts parse", okEsc)
check("escape: name keeps only doubled pipes", escGroup.name == "||cffff0000x||r" and not loosePipes(escGroup.name))
check("escape: messages and media name", not loosePipes(escGroup.applyMessage) and not loosePipes(escGroup.expireMessage)
    and not loosePipes(escGroup.applySoundMediaName))
local okCtl, ctlGroup = Share.Parse(craft({ name = "a\nb\0c\tz" }, "MAGE"))
check("control characters removed", okCtl and ctlGroup.name == "abcz", ctlGroup and ctlGroup.name)
local okLen, lenGroup = Share.Parse(craft({ name = string.rep("a", 300) }, "MAGE"))
check("text cut to 200 characters", okLen and #lenGroup.name == 200)
local okOdd, oddGroup = Share.Parse(craft({ name = string.rep("a", 199) .. "|" }, "MAGE"))
check("cut never leaves half an escaped pipe", okOdd and oddGroup.name == string.rep("a", 199) and not loosePipes(oddGroup.name))

-- Pipes stay stable when a group is passed on again (export -> import -> export -> import)
local function roundTrip(rule)
    local okOut, outText = Share.Export(rule)
    local okIn, inGroup, inMeta = Share.Parse(outText)
    check("pipe round trip parses", okOut and okIn, inGroup)
    return Share.ToRule(inGroup, inMeta), outText
end
for _, sample in ipairs({ "A|B", "A||B", "|cffff0000x|r", "end|", "|||", "a|b|c" }) do
    local source = ns.newAuraRule()
    source.name = sample
    source.applyEnabled = true
    source.applyMessage = sample
    source.screenProfiles.apply.enabled = true
    source.screenProfiles.apply.text = sample
    local first = roundTrip(source)
    local second = roundTrip(first)
    local third = roundTrip(second)
    check("pipes stable over two hops: " .. sample, second.name == first.name and third.name == first.name
        and second.applyMessage == first.applyMessage and third.applyMessage == first.applyMessage
        and second.screenProfiles.apply.text == first.screenProfiles.apply.text
        and third.screenProfiles.apply.text == first.screenProfiles.apply.text, first.name .. " / " .. second.name)
    check("pipes safe after the hops: " .. sample, not loosePipes(third.name) and not loosePipes(third.applyMessage))
end
local pipeSource = ns.newAuraRule()
pipeSource.name = "A|B"
local pipeOne = roundTrip(pipeSource)
check("export unescapes: A|B is stored as A||B and no longer grows", pipeOne.name == "A||B", pipeOne.name)
pipeSource.name = "A||B"
local pipeBack, pipeExport = roundTrip(pipeSource)
check("exporting a stored A||B sends A|B", store[pipeExport:sub(6)].group.name == "A|B", store[pipeExport:sub(6)].group.name)
check("stored A||B survives the hop unchanged", pipeBack.name == "A||B", pipeBack.name)

-- UTF-8: a cut never splits a character
local function validUTF8(s)
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        local len = b < 0x80 and 1 or (b >= 0xF0 and 4 or (b >= 0xE0 and 3 or (b >= 0xC0 and 2 or 0)))
        if len == 0 or i + len - 1 > #s then return false end
        for j = i + 1, i + len - 1 do
            local c = s:byte(j)
            if c < 0x80 or c >= 0xC0 then return false end
        end
        i = i + len
    end
    return true
end
for _, unit in ipairs({ "ä", "€", "😀" }) do
    for pad = 0, #unit do
        local name = string.rep("a", 200 - #unit + 1 - pad) .. string.rep(unit, 3)
        local okU, uGroup = Share.Parse(craft({ name = name, applyMessage = name }, "MAGE"))
        check("utf8 cut " .. unit .. " pad " .. pad, okU and #uGroup.name <= 200 and validUTF8(uGroup.name)
            and validUTF8(uGroup.applyMessage), uGroup and #uGroup.name)
    end
end
local okU2, uFull = Share.Parse(craft({ name = string.rep("ä", 100) }, "MAGE"))
check("utf8: 100 two-byte characters fit exactly", okU2 and uFull.name == string.rep("ä", 100))
local okU3, uOver = Share.Parse(craft({ name = string.rep("ä", 101) }, "MAGE"))
check("utf8: 101 two-byte characters cut to 100", okU3 and uOver.name == string.rep("ä", 100))
-- the " (2)" suffix cut in uniqueName
local _, uniGroup, uniMeta = Share.Parse(craft({ name = string.rep("ä", 100) }, "MAGE"))
WoWraVoxDB = { auras = { { name = uniGroup.name } } }
local uniName = Share.ToRule(uniGroup, uniMeta).name
check("utf8: suffix cut keeps the character whole", validUTF8(uniName) and #uniName <= 200 and uniName:sub(-4) == " (2)", uniName)
WoWraVoxDB = nil

-- Names: blanks are trimmed, an empty name becomes the default
local _, spaceGroup, spaceMeta = Share.Parse(craft({ name = "   \t " }, "MAGE"))
check("blank name is cleaned to empty", spaceGroup.name == "", spaceGroup.name)
check("blank name gets the default name", Share.ToRule(spaceGroup, spaceMeta).name == ns.newAuraRule().name)
local _, paddedGroup = Share.Parse(craft({ name = "  Padded name \n", applyMessage = " Go " }, "MAGE"))
check("name and message are trimmed", paddedGroup.name == "Padded name" and paddedGroup.applyMessage == "Go")
local _, cutSpace = Share.Parse(craft({ name = string.rep("a", 199) .. " b" }, "MAGE"))
check("a cut that ends on a blank is trimmed", cutSpace.name == string.rep("a", 199), #cutSpace.name)

-- Header, version and payload shape
local headerCases = {
    { "", "Not a WoWraVox export." },
    { "hello", "Not a WoWraVox export." },
    { "WVX1 CBOR1", "Not a WoWraVox export." },
    { "WVX2:CBOR1", "Unsupported export version." },
    { "WVX1:", "The export data is invalid." },
    { "WVX1:CBOR404", "The export data is invalid." },
}
for _, case in ipairs(headerCases) do
    local okHeader, errHeader = Share.Parse(case[1])
    check("header refused: " .. case[1], okHeader == false and errHeader == case[2], errHeader)
end
local okNil, errNil = Share.Parse(nil)
check("nil input refused without error", okNil == false and errNil == "Not a WoWraVox export.")
local okNum, errNum = Share.Parse(12)
check("number input refused without error", okNum == false and errNum == "Not a WoWraVox export.")
check("whitespace around the text is ignored", (Share.Parse("  \n" .. craft({ name = "ws" }, "MAGE") .. "\n ")))
local wrapped = craft({ name = "wrapped" }, "MAGE")
check("line breaks inside the text are ignored", (Share.Parse(wrapped:sub(1, 8) .. "\n" .. wrapped:sub(9))))
check("payload version 2 refused", select(2, Share.Parse("WVX1:" .. encode({ v = 2, kind = "aura-group",
    group = { name = "x" } }))) == "Unsupported export version.")
check("payload kind other than aura-group and item-group refused", select(2, Share.Parse("WVX1:" .. encode({ v = 1,
    kind = "skill-group", group = { name = "x" } }))) == "The export data is invalid.")
check("item-group payload without items refused (a group field does not count)", select(2, Share.Parse("WVX1:" .. encode({ v = 1,
    kind = "item-group", group = { name = "x" } }))) == "The export data is invalid.")
check("payload class in lower case refused", select(2, Share.Parse(craft({ name = "x" }, "mage")))
    == "The export data is invalid.")
check("payload without group refused", select(2, Share.Parse("WVX1:" .. encode({ v = 1, kind = "aura-group" })))
    == "The export data is invalid.")
check("payload that is not a table refused", select(2, Share.Parse("WVX1:" .. encode("text")))
    == "The export data is invalid.")

-- Junk never raises an error
local junk = { "WVX1:???", "WVX1:" .. string.rep("q", 500), "WVX1:CBOR0", "WVX1:\0\1\2", "WVX1:BOMB BOMB", {}, true }
for index, value in ipairs(junk) do
    local okCall, okJunk = pcall(Share.Parse, value)
    check("junk " .. index .. " raises no error", okCall and okJunk == false)
end

-- Client without C_EncodingUtil
C_EncodingUtil = nil
local okNoClient, errNoClient = Share.Export(sampleRule())
check("no C_EncodingUtil: export gives a friendly error", okNoClient == false and errNoClient == "This client cannot read exports.", errNoClient)
local okNoParse, errNoParse = Share.Parse(text)
check("no C_EncodingUtil: import gives a friendly error", okNoParse == false and errNoParse == "This client cannot read exports.", errNoParse)
C_EncodingUtil = realEncoding

-- Check and import gating
local checked = Share.Check(text)
check("Check returns a preview with the checked text", checked ~= nil and checked.text == text and checked.effects == 2)
check("CanImport: only for the checked text", Share.CanImport(checked, text) and not Share.CanImport(checked, text .. " ")
    and not Share.CanImport(nil, text))
local badPreview, badKey = Share.Check("nonsense")
check("Check of bad text gives the error text", badPreview == nil and badKey == "Not a WoWraVox export.")

-- Widget mocks for the windows (no real frames outside the game)
local widgetMethods = {}
local function newWidget(kind)
    return setmetatable({ kind = kind, shown = true, enabled = true, text = "", scripts = {} }, { __index = widgetMethods })
end
for _, name in ipairs({ "SetSize", "SetPoint", "SetFrameStrata", "SetToplevel", "SetFrameLevel", "SetBackdrop",
    "SetBackdropColor", "SetBackdropBorderColor", "SetWidth", "SetHeight", "SetMultiLine", "SetAutoFocus",
    "SetFontObject", "SetTextInsets", "SetCursorPosition", "SetFocus", "ClearFocus", "HighlightText", "SetTexture",
    "SetTexCoord", "SetJustifyH", "SetTextColor", "SetScrollChild", "SetHighlightTexture", "SetWordWrap" }) do
    widgetMethods[name] = function(self) return self end
end
function widgetMethods:SetText(value) self.text = value or "" end
function widgetMethods:GetText() return self.text end
function widgetMethods:GetStringHeight() return self.text == "" and 0 or 14 end
function widgetMethods:SetEnabled(value) self.enabled = value and true or false end
function widgetMethods:Enable() self.enabled = true end
function widgetMethods:Disable() self.enabled = false end
function widgetMethods:IsShown() return self.shown end
function widgetMethods:Show() self.shown = true end
function widgetMethods:Hide() self.shown = false end
function widgetMethods:SetShown(value) self.shown = value and true or false end
function widgetMethods:SetScript(name, handler) self.scripts[name] = handler end
function widgetMethods:CreateFontString() return newWidget("FontString") end
function widgetMethods:CreateTexture() return newWidget("Texture") end
CreateFrame = function(kind) return newWidget(kind) end
UIParent = newWidget("UIParent")
UISpecialFrames = {}
ns.Skin = { Register = function() return true end }

-- Aura group names and overlap hints (WoWraVoxDB.auras, built-in rules included)
local _, defGroup, defMeta = Share.Parse(craft({ name = "Defense", spellIDs = { 48707 } }, "MAGE"))
check("collision block: group parses", defGroup ~= nil)

-- No database: name unchanged, no overlap note
WoWraVoxDB = nil
check("no DB: name unchanged", Share.ToRule(defGroup, defMeta).name == "Defense")
check("no DB: no overlap note", #Share.Describe(defGroup, defMeta).notes == 0)

-- Exact name taken: " (2)", then " (3)" for the next copy
WoWraVoxDB = { auras = { { name = "Defense", spellIDs = { 48707 } } } }
local firstCopy = Share.ToRule(defGroup, defMeta)
check("collision: first copy gets (2)", firstCopy.name == "Defense (2)", firstCopy.name)
WoWraVoxDB.auras[#WoWraVoxDB.auras + 1] = firstCopy
local secondCopy = Share.ToRule(defGroup, defMeta)
check("collision: second copy gets (3)", secondCopy.name == "Defense (3)", secondCopy.name)

-- Capitalisation and surrounding blanks do not make a name different
WoWraVoxDB = { auras = { { name = "defense" } } }
check("collision ignores capitalisation", Share.ToRule(defGroup, defMeta).name == "Defense (2)", Share.ToRule(defGroup, defMeta).name)
WoWraVoxDB = { auras = { { name = "  DEFENSE  " } } }
check("collision ignores blanks and capitalisation", Share.ToRule(defGroup, defMeta).name == "Defense (2)")
WoWraVoxDB = { auras = { { name = "Defense" }, { name = "defense (2) " }, { name = false }, "x" } }
check("collision: suffix names compare trimmed and lower-cased, bad entries skipped", Share.ToRule(defGroup, defMeta).name == "Defense (3)")
WoWraVoxDB = { auras = { { name = "Defensive" } } }
check("no collision for a different name", Share.ToRule(defGroup, defMeta).name == "Defense")

-- Length: the base is cut so the result stays within 200 characters
local _, longGroup, longMeta = Share.Parse(craft({ name = string.rep("a", 200) }, "MAGE"))
WoWraVoxDB = { auras = { { name = longGroup.name } } }
local longName = Share.ToRule(longGroup, longMeta).name
check("length: 200 characters kept with the suffix", longName == string.rep("a", 196) .. " (2)", #longName)

-- A cut never leaves a lone "|" in the base
local _, pipeGroup, pipeMeta = Share.Parse(craft({ name = string.rep("a", 195) .. "|" }, "MAGE"))
WoWraVoxDB = { auras = { { name = pipeGroup.name } } }
local pipeName = Share.ToRule(pipeGroup, pipeMeta).name
check("length: cut keeps escaped pipes whole", pipeName == string.rep("a", 195) .. " (2)" and not loosePipes(pipeName), pipeName)

-- Overlap hint: aura rules (built-in included) sharing a spell ID; a rule without spellIDs is skipped
WoWraVoxDB = { auras = {
    { name = "Bloodlust", builtin = true, spellIDs = { 2825 } },
    { name = "Shields", spellIDs = { 48707 } },
    { name = "Broken" },
    { name = "Other", spellIDs = { 999 } },
} }
check("overlap: one rule named", has(Share.Describe(defGroup, defMeta).notes,
    "You already track some of these effects in: Shields. Both groups would announce them."))
local _, wideGroup, wideMeta = Share.Parse(craft({ name = "Wide", spellIDs = { 2825, 48707, 999 } }, "MAGE"))
check("overlap: two names, then +1 for the rest", has(Share.Describe(wideGroup, wideMeta).notes,
    "You already track some of these effects in: Bloodlust, Shields +1. Both groups would announce them."))
-- A switched-off rule does not count (enabled == false); a rule without the flag does
WoWraVoxDB = { auras = {
    { name = "Off", enabled = false, spellIDs = { 48707 } },
    { name = "On", enabled = true, spellIDs = { 48707 } },
    { name = "Unflagged", builtin = true, spellIDs = { 48707 } },
} }
check("overlap: disabled rules are skipped", has(Share.Describe(defGroup, defMeta).notes,
    "You already track some of these effects in: On, Unflagged. Both groups would announce them."))
WoWraVoxDB = { auras = { { name = "Off", enabled = false, spellIDs = { 48707 } } } }
check("overlap: only a disabled rule gives no note", #Share.Describe(defGroup, defMeta).notes == 0)
WoWraVoxDB = { auras = { { name = "Other", spellIDs = { 999 } } } }
check("overlap: no note without shared spell IDs", #Share.Describe(defGroup, defMeta).notes == 0)

-- Three notes at once (class, unknown ID, overlap) all fit the import window
local _, threeGroup, threeMeta = Share.Parse(craft({ name = "Three", spellIDs = { 48707, 888888 } }, "WARRIOR"))
WoWraVoxDB = { auras = { { name = "Shields", spellIDs = { 48707 } } } }
local threeNotes = Share.Describe(threeGroup, threeMeta).notes
check("three notes: class, unknown and overlap", #threeNotes == 3 and has(threeNotes, "This group was made for another class.")
    and has(threeNotes, "1 spell IDs are unknown to this client.")
    and has(threeNotes, "You already track some of these effects in: Shields. Both groups would announce them."))
WoWraVoxDB = nil

-- Item groups: trinket rules and other item rules (kind = "item-group"), logic only. Mocked: item names and icons
-- (C_Item), the worn items (GetInventoryItemID / GetInventoryItemTexture). Slot 13 wears 242395, slot 14 is empty.
TestItemNames = { [193762] = "Blazebinder's Hoof", [242395] = "Astral Antenna" }
TestItemIcons = { [193762] = 111111 }
TestItemRequests = {}
TestWornItems = { [13] = 242395 }
GetInventoryItemID = function(_, slot) return TestWornItems[slot] end
GetInventoryItemTexture = function(_, slot)
    if TestWornItems[slot] then return 999000 + slot end
    return nil
end
C_Item = {
    GetItemNameByID = function(itemID) return TestItemNames[itemID] end,
    GetItemIconByID = function(itemID) return TestItemIcons[itemID] end,
    RequestLoadItemDataByID = function(itemID) TestItemRequests[#TestItemRequests + 1] = itemID end,
}
do
    local function itemRule(name, message, members)
        local rule = ns.newItemRule(nil, name, nil, nil)
        rule.members = members
        rule.message = message
        return rule
    end
    local function craftItems(items, class)
        return "WVX1:" .. encode({ v = 1, kind = "item-group", class = class or "MAGE", items = items })
    end
    local function parseItems(items, class)
        return Share.Parse(craftItems(items, class))
    end
    local function entry(members, extra)
        local out = { name = "E", message = "M", enabled = true, members = members }
        for key, value in pairs(extra or {}) do out[key] = value end
        return out
    end
    local function slots(count)
        local out = {}
        for i = 1, count do out[i] = { slotID = i } end
        return out
    end
    local function entries(count)
        local out = {}
        for i = 1, count do out[i] = { name = "E" .. i, members = { { slotID = 13 } } } end
        return out
    end

    -- The main chunk of this file is close to Lua's limit of 200 locals: the sections below are blocks of their own
    -- and share only these.
    local t1, t2, t3, itemText, igroup

    -- Round trip: export, parse, new rules
    do
    t1 = itemRule("Trinket 1", "{slot} ready", { { slotID = 13 } })
    t2 = itemRule("Trinket 2", "{slot} ready", { { slotID = 14, itemID = 193762 } })
    t3 = itemRule("Hoof", "{item} ready", { { itemID = 193762 } })
    t1.id, t1.icon, t1.presetID, t1.voiceID, t1.volume = 7, 12345, "trinket-1", 42, 15
    t3.enabled = false
    local okItems
    okItems, itemText = Share.ExportItems({ t1, t2, t3 })
    check("items: export gives a WVX1 text", okItems and itemText:sub(1, 5) == "WVX1:", itemText)
    local payload = store[itemText:sub(6)]
    check("items: payload kind, version, class, entries", payload.kind == "item-group" and payload.v == 1
        and payload.class == "MAGE" and #payload.items == 3 and payload.group == nil)
    local allowedEntry = { name = true, message = true, enabled = true, members = true }
    local allowedMember = { slotID = true, itemID = true }
    local onlyAllowed = true
    for _, sent in ipairs(payload.items) do
        for key in pairs(sent) do
            if not allowedEntry[key] then onlyAllowed = false end
        end
        for _, member in ipairs(sent.members) do
            for key in pairs(member) do
                if not allowedMember[key] then onlyAllowed = false end
            end
        end
    end
    check("items: only name, message, enabled and members leave the machine", onlyAllowed)
    check("items: entries carry the values of the rules", payload.items[1].name == "Trinket 1"
        and payload.items[1].message == "{slot} ready" and payload.items[1].enabled == true
        and sameTable(payload.items[1].members, { { slotID = 13 } })
        and sameTable(payload.items[2].members, { { slotID = 14, itemID = 193762 } })
        and payload.items[3].enabled == false and sameTable(payload.items[3].members, { { itemID = 193762 } }))
    local okP, imeta
    okP, igroup, imeta = Share.Parse(itemText)
    check("items: parse accepts an own export", okP and #igroup.items == 3 and imeta.kind == "item-group"
        and imeta.class == "MAGE" and imeta.version == 1, igroup)
    check("items: parsed entries equal the sent ones", igroup.items[1].name == "Trinket 1"
        and igroup.items[1].message == "{slot} ready" and sameTable(igroup.items[2].members, { { slotID = 14, itemID = 193762 } })
        and igroup.items[3].message == "{item} ready" and igroup.items[3].enabled == false)
    check("items: an aura export still carries no kind in its meta", select(3, Share.Parse(text)).kind == nil)

    WoWraVoxDB = nil
    local made = Share.ToItemRules(igroup)
    check("items: one new rule per entry, in order", #made == 3 and made[1].name == "Trinket 1"
        and made[2].name == "Trinket 2" and made[3].name == "Hoof")
    check("items: members and messages kept (placeholders stay text)", sameTable(made[1].members, { { slotID = 13 } })
        and sameTable(made[2].members, { { slotID = 14, itemID = 193762 } }) and sameTable(made[3].members, { { itemID = 193762 } })
        and made[1].message == "{slot} ready" and made[3].message == "{item} ready")
    check("items: new rules are enabled (also when the source was off), without id or flags", made[3].enabled == true
        and made[1].enabled == true and made[1].id == nil and made[1].builtin == nil and made[1].starter == nil
        and made[1].presetID == nil)
    local fresh = ns.newItemRule()
    check("items: voice, volume, speed, sounds and screen text are the local defaults", made[1].voiceID ~= 42
        and made[1].voiceID == fresh.voiceID and made[1].volume == 80 and made[1].speechSpeed == 100
        and made[1].readyEnabled == true and made[1].readySoundEnabled == false and made[1].alertCategory == "none"
        and made[1].screenProfiles.ready ~= nil and made[1].screenProfiles.ready.enabled == false)
    check("items: icon from the first member (slot: the item worn there; item: its icon)", made[1].icon == 999013
        and made[2].icon == 111111 and made[3].icon == 111111, tostring(made[1].icon) .. " " .. tostring(made[2].icon))
    check("items: new rules share no table with the parsed group", made[1].members ~= igroup.items[1].members
        and made[1].members[1] ~= igroup.items[1].members[1])
    TestWornItems[13] = nil
    check("items: no icon when nothing is known (slot empty, no item sent)", Share.ToItemRules(igroup)[1].icon == nil)
    TestWornItems[13] = 242395
    check("items: empty or bad group gives no rules and no error", #Share.ToItemRules(nil) == 0
        and #Share.ToItemRules({}) == 0 and #Share.ToItemRules({ items = "x" }) == 0 and #Share.ToItemRules("x") == 0)

    -- Names stay unique (existing item rules, and inside the group)
    WoWraVoxDB = { items = { { name = "Trinket 1" }, { name = "  trinket 2 " } } }
    local clash = Share.ToItemRules(igroup)
    check("items: names that exist already get (2), capitalisation and blanks ignored", clash[1].name == "Trinket 1 (2)"
        and clash[2].name == "Trinket 2 (2)" and clash[3].name == "Hoof", clash[1].name)
    WoWraVoxDB = nil
    local _, sameGroup = parseItems({ entry({ { slotID = 13 } }, { name = "Same" }), entry({ { slotID = 14 } }, { name = "same" }),
        entry({ { slotID = 15 } }, { name = "SAME" }) })
    local same = Share.ToItemRules(sameGroup)
    check("items: equal names inside one group are numbered too", same[1].name == "Same" and same[2].name == "same (2)"
        and same[3].name == "SAME (3)", same[2].name .. " / " .. same[3].name)
    WoWraVoxDB = { auras = { { name = "Trinket 1" } } }
    check("items: an aura group with the same name is no clash", Share.ToItemRules(igroup)[1].name == "Trinket 1")
    WoWraVoxDB = nil
    end

    -- Defaults: empty name, missing message
    do
    local _, defaultsGroup = parseItems({
        { name = "", members = { { slotID = 13 } } },
        { members = { { itemID = 193762 } } },
        { name = "", message = "", members = { { itemID = 777777 } } },
        { members = { { slotID = 13 }, { slotID = 14 } } },
    })
    local made2 = Share.ToItemRules(defaultsGroup)
    check("items: empty name becomes the slot's name or the item's name", made2[1].name == "Trinket 1"
        and made2[2].name == "Blazebinder's Hoof" and made2[3].name == "Item 777777", made2[1].name .. " / " .. made2[2].name .. " / " .. made2[3].name)
    check("items: a second rule for the same default name is numbered", made2[4].name == "Trinket 1 (2)", made2[4].name)
    check("items: missing message gets the generated default, an empty one stays empty",
        made2[1].message == "{slot} ready" and made2[2].message == "{item} ready" and made2[3].message == ""
        and made2[4].message == "{item} ready", tostring(made2[1].message) .. " / " .. tostring(made2[4].message))

    -- Typed pipes stay stable over several hops
    local function hop(rule)
        local okHop, hopText = Share.ExportItems({ rule })
        local _, hopGroup = Share.Parse(hopText)
        check("items: pipe hop exports and parses", okHop and hopGroup ~= nil)
        return Share.ToItemRules(hopGroup)[1], hopText
    end
    local pipeRule = itemRule("A|B", "x|cffff0000y|r", { { slotID = 13 } })
    local h1, h1Text = hop(pipeRule)
    check("items: export sends the typed pipes", store[h1Text:sub(6)].items[1].name == "A|B"
        and store[h1Text:sub(6)].items[1].message == "x|cffff0000y|r")
    local h2 = hop(h1)
    local h3 = hop(h2)
    check("items: pipes stable over two hops, none loose", h1.name == "A||B" and h2.name == h1.name and h3.name == h1.name
        and h2.message == h1.message and h3.message == h1.message and not loosePipes(h3.name) and not loosePipes(h3.message),
        h1.name .. " / " .. h3.name)

    -- Whitelist: a hostile sender cannot set anything else
    local okW, wGroup = parseItems({ { name = "W", message = "m", enabled = true, id = 5, icon = 99, builtin = true,
        starter = "trinket", voiceID = 9, volume = 1, presetID = "x", evil = "x",
        members = { { slotID = 13, itemID = 5, icon = 1, evil = "x", id = 3 } } } })
    check("items: foreign fields are dropped on import", okW and sameTable(wGroup.items[1], { name = "W", message = "m",
        enabled = true, members = { { slotID = 13, itemID = 5 } } }))
    local wRule = Share.ToItemRules(wGroup)[1]
    check("items: an imported rule never takes id, icon, flags, voice or volume from the text", wRule.id == nil
        and wRule.builtin == nil and wRule.starter == nil and wRule.presetID == nil and wRule.volume == 80
        and wRule.evil == nil and wRule.icon ~= 99)
    local _, dedupGroup = parseItems({ entry({ { slotID = 13 }, { slotID = 13, itemID = 5 }, { itemID = 7 }, { itemID = 7 } }) })
    check("items: a member seen twice is kept once (first wins)", sameTable(dedupGroup.items[1].members,
        { { slotID = 13 }, { itemID = 7 } }))
    end

    -- Limits and strict types
    do
    check("items: 8 entries accepted", (parseItems(entries(8))))
    check("items: 9 entries refused", parseItems(entries(9)) == false)
    check("items: 4 members accepted", (parseItems({ entry(slots(4)) })))
    local okFive, errFive = parseItems({ entry(slots(5)) })
    check("items: 5 members refused", okFive == false and errFive == "The export data is invalid.", errFive)
    check("items: slot 1 and slot 19, item 1 and 2^31-1 accepted", (parseItems({ entry({ { slotID = 1 }, { slotID = 19 },
        { itemID = 1 }, { itemID = 2147483647 } }) })))
    local badItems = {
        { "slotID 0", { entry({ { slotID = 0 } }) } },
        { "slotID 20", { entry({ { slotID = 20 } }) } },
        { "slotID negative", { entry({ { slotID = -1 } }) } },
        { "slotID fractional", { entry({ { slotID = 13.5 } }) } },
        { "slotID as text", { entry({ { slotID = "13" } }) } },
        { "slotID NaN", { entry({ { slotID = 0 / 0 } }) } },
        { "itemID 0", { entry({ { itemID = 0 } }) } },
        { "itemID negative", { entry({ { itemID = -5 } }) } },
        { "itemID fractional", { entry({ { itemID = 1.5 } }) } },
        { "itemID above 2^31-1", { entry({ { itemID = 2147483648 } }) } },
        { "itemID as text", { entry({ { itemID = "5" } }) } },
        { "slot fine but itemID bad", { entry({ { slotID = 13, itemID = 0 } }) } },
        { "member without ids", { entry({ {} }) } },
        { "member with an unknown field only", { entry({ { evil = 1 } }) } },
        { "member is not a table", { entry({ 5 }) } },
        { "empty member list", { entry({}) } },
        { "members missing", { { name = "x" } } },
        { "members as text", { entry("x") } },
        { "member list with a hole", { entry({ [1] = { slotID = 13 }, [3] = { slotID = 14 } }) } },
        { "member list with a key", { entry({ { slotID = 13 }, extra = { slotID = 14 } }) } },
        { "name is a number", { entry({ { slotID = 13 } }, { name = 5 }) } },
        { "message is a table", { entry({ { slotID = 13 } }, { message = {} }) } },
        { "enabled is text", { entry({ { slotID = 13 } }, { enabled = "yes" }) } },
        { "entry is not a table", { 5 } },
        { "no entries", {} },
        { "entries are text", "x" },
        { "entry list with a hole", { [1] = entry({ { slotID = 13 } }), [3] = entry({ { slotID = 14 } }) } },
    }
    for _, case in ipairs(badItems) do
        local okBad, errBad = parseItems(case[2])
        check("items refused: " .. case[1], okBad == false and errBad == "The export data is invalid.", errBad)
    end
    check("items refused: payload without items", select(2, Share.Parse("WVX1:" .. encode({ v = 1, kind = "item-group" })))
        == "The export data is invalid.")
    check("items refused: class in lower case", select(2, parseItems(entries(1), "mage")) == "The export data is invalid.")
    check("items refused: payload version 2", select(2, Share.Parse("WVX1:" .. encode({ v = 2, kind = "item-group",
        items = entries(1) }))) == "Unsupported export version.")
    local okLong, longGroup = parseItems({ entry({ { slotID = 13 } }, { name = string.rep("a", 300), message = string.rep("b", 300) }) })
    check("items: texts are cut to 200 characters", okLong and #longGroup.items[1].name == 200 and #longGroup.items[1].message == 200)
    local okEsc, escGroup = parseItems({ entry({ { slotID = 13 } }, { name = "|cffff0000x|r", message = "|Hitem:1|h[x]|h {slot}" }) })
    check("items: texts are escaped, placeholders survive", okEsc and escGroup.items[1].name == "||cffff0000x||r"
        and not loosePipes(escGroup.items[1].message) and escGroup.items[1].message:find("{slot}", 1, true) ~= nil)
    local okCtl, ctlGroup = parseItems({ entry({ { slotID = 13 } }, { name = "a\nb\0c", message = "  go \t" }) })
    check("items: control characters removed, texts trimmed", okCtl and ctlGroup.items[1].name == "abc"
        and ctlGroup.items[1].message == "go")

    end

    -- Export refusals
    do
    local builtinItem = itemRule("B", "m", { { slotID = 13 } })
    builtinItem.builtin = true
    local okB, errB = Share.ExportItems({ builtinItem })
    check("items: a built-in rule cannot be exported", okB == false and errB == "builtin", errB)
    check("items: one built-in rule refuses the whole group", select(2, Share.ExportItems({ t1, builtinItem })) == "builtin")
    local starterRule = itemRule("Add a trinket", "m", {})
    starterRule.starter = "trinket"
    check("items: an empty starter cannot be exported", select(2, Share.ExportItems({ starterRule }))
        == "This rule has no item to share yet.")
    check("items: a rule without a member list cannot be exported", select(2, Share.ExportItems({ { name = "x" } }))
        == "This rule has no item to share yet.")
    check("items: a rule with 5 members cannot be exported", select(2, Share.ExportItems({ itemRule("Many", "m", slots(5)) }))
        == "Only rules with up to 4 items can be shared.")
    check("items: a rule with 4 members can", (Share.ExportItems({ itemRule("Four", "m", slots(4)) })))
    local nine = {}
    for i = 1, 9 do nine[i] = itemRule("R" .. i, "m", { { slotID = 13 } }) end
    check("items: 9 rules cannot be exported", select(2, Share.ExportItems(nine)) == "The export is too large.")
    nine[9] = nil
    check("items: 8 rules can", (Share.ExportItems(nine)))
    local invalidKey = "The export data is invalid."
    check("items: nothing, text or junk in the list is refused", select(2, Share.ExportItems({})) == invalidKey
        and select(2, Share.ExportItems(nil)) == invalidKey and select(2, Share.ExportItems("x")) == invalidKey
        and select(2, Share.ExportItems({ 5 })) == invalidKey and select(2, Share.ExportItems({ [1] = t1, [3] = t2 })) == invalidKey)
    check("items: a bad member or a bad name is refused", select(2, Share.ExportItems({ itemRule("Bad", "m", { { itemID = 0 } }) }))
        == invalidKey and select(2, Share.ExportItems({ itemRule(5, "m", { { slotID = 13 } }) })) == invalidKey
        and select(2, Share.ExportItems({ itemRule("Bad", "m", { 5 }) })) == invalidKey)
    local okThrow, throwOk = pcall(Share.ExportItems, { setmetatable({}, { __index = function() error("boom") end }) })
    check("items: a rule that raises an error gives a friendly refusal", okThrow and throwOk == false)
    local savedBase64 = realEncoding.EncodeBase64
    realEncoding.EncodeBase64 = function() return string.rep("A", 9000) end
    check("items: an export over 8 KB is refused", select(2, Share.ExportItems({ t1 })) == "The export is too large.")
    realEncoding.EncodeBase64 = savedBase64
    local savedCompress = realEncoding.CompressString
    realEncoding.CompressString = function() return nil end
    check("items: a failing encoder gives a friendly refusal", select(2, Share.ExportItems({ t1 })) == invalidKey)
    realEncoding.CompressString = savedCompress
    C_EncodingUtil = nil
    check("items: no C_EncodingUtil gives the client error", select(2, Share.ExportItems({ t1 })) == "This client cannot read exports.")
    C_EncodingUtil = realEncoding

    -- Largest allowed group: 8 rules x 4 members x two 200-byte texts. By arithmetic (about 4.2 KB of CBOR, 5.6 KB as
    -- Base64 even without any compression) it stays under MAX_INPUT; the mock cannot measure real sizes, so this
    -- only proves that the largest group passes every limit in both directions.
    local biggest = {}
    for i = 1, 8 do
        biggest[i] = itemRule(string.rep(string.char(96 + i), 200), string.rep(string.char(104 + i), 200),
            { { slotID = 1, itemID = 2000000000 + i }, { slotID = 2, itemID = 2000000100 + i },
              { slotID = 3, itemID = 2000000200 + i }, { slotID = 4, itemID = 2000000300 + i } })
    end
    local okBiggest, biggestText = Share.ExportItems(biggest)
    local okBiggestParse, biggestGroup = Share.Parse(biggestText or "")
    check("items: the largest allowed group exports and parses back", okBiggest and okBiggestParse
        and #biggestGroup.items == 8 and #biggestGroup.items[8].members == 4 and #biggestGroup.items[8].name == 200
        and #biggestGroup.items[8].message == 200, biggestText)

    end

    -- Preview: both trinkets visible
    do
    WoWraVoxDB = nil
    local preview = Share.Check(itemText)
    check("items: preview has the kind, one entry per rule and the checked text", preview ~= nil
        and preview.kind == "item-group" and #preview.entries == 3 and preview.text == itemText
        and preview.group ~= nil and preview.meta.kind == "item-group")
    local e1, e2, e3 = preview.entries[1], preview.entries[2], preview.entries[3]
    check("items: preview shows both trinket slots", e1.name == "Trinket 1" and #e1.members == 1
        and e1.members[1].slotName == "Trinket 1" and e1.members[1].itemName == nil and e1.members[1].known == true
        and e2.name == "Trinket 2" and e2.members[1].slotName == "Trinket 2"
        and e2.members[1].itemName == "Blazebinder's Hoof" and e2.members[1].known == true)
    check("items: preview of an exact item and the messages", e3.members[1].slotName == nil
        and e3.members[1].itemName == "Blazebinder's Hoof" and e3.message == "{item} ready" and e1.message == "{slot} ready")
    check("items: preview icons", e1.members[1].icon == 999013 and e3.members[1].icon == 111111)
    local _, unknownGroup, unknownMeta = parseItems({ entry({ { itemID = 4040404 }, { slotID = 14, itemID = 4040405 } }) })
    local unknownPreview = Share.Describe(unknownGroup, unknownMeta)
    local um = unknownPreview.entries[1].members
    check("items: an item the client has no name for is Item <id>, not known", um[1].itemName == "Item 4040404"
        and um[1].known == false and um[2].itemName == "Item 4040405" and um[2].known == false and um[2].slotName == "Trinket 2")
    local asked = false
    for _, id in ipairs(TestItemRequests) do
        if id == 4040404 then asked = true end
    end
    check("items: the client is asked to load an unknown item", asked)
    check("items: no notes without a database", #preview.notes == 0)
    check("items: CanImport gates on the checked text", Share.CanImport(preview, itemText)
        and not Share.CanImport(preview, itemText .. " ") and not Share.CanImport(nil, itemText))
    check("items: an aura preview has no kind", Share.Check(text).kind == nil)
    local emptyDefault = Share.Describe(select(2, parseItems({ { members = { { slotID = 13 } } } })),
        { class = "MAGE", version = 1, kind = "item-group" })
    check("items: preview shows the default name and message of an unnamed entry", emptyDefault.entries[1].name == "Trinket 1"
        and emptyDefault.entries[1].message == "{slot} ready")

    end

    -- Overlap with the own item rules (enabled ones, by slot)
    do
    local OVERLAP1 = "Trinket 1 is already tracked in: Trinket 1. Both rules would announce it."
    local OVERLAP2 = "Trinket 2 is already tracked in: Trinket 2. Both rules would announce it."
    local pair = { entry({ { slotID = 13 } }, { name = "T1" }), entry({ { slotID = 14 } }, { name = "T2" }) }
    local function notesFor(database, items)
        WoWraVoxDB = database
        local _, noteGroup, noteMeta = parseItems(items)
        local notes = Share.Describe(noteGroup, noteMeta).notes
        WoWraVoxDB = nil
        return notes
    end
    local n1 = notesFor({ items = { { name = "Trinket 1", members = { { slotID = 13 } } },
        { name = "Other", members = { { slotID = 1 } } } } }, pair)
    check("items: a slot already tracked gives one note naming the rule", #n1 == 1 and n1[1] == OVERLAP1, n1[1])
    local n2 = notesFor({ items = { { name = "Trinket 1", members = { { slotID = 13 } } },
        { name = "Trinket 2", members = { { slotID = 14, itemID = 5 } } } } }, pair)
    check("items: both slots tracked give two notes", #n2 == 2 and n2[1] == OVERLAP1 and n2[2] == OVERLAP2)
    check("items: a switched-off rule gives no note", #notesFor({ items = { { name = "Off", enabled = false,
        members = { { slotID = 13 } } } } }, pair) == 0)
    check("items: a rule without the enabled flag counts", #notesFor({ items = { { name = "Trinket 1",
        members = { { slotID = 13 } } } } }, pair) == 1)
    local n3 = notesFor({ items = { { name = "A", members = { { slotID = 13 } } }, { name = "B", members = { { slotID = 1 }, { slotID = 13 } } },
        { name = "C", members = { { slotID = 13 } } }, { name = "D", members = { { slotID = 13 } } } } }, { pair[1] })
    check("items: two names, then +N for the rest", #n3 == 1
        and n3[1] == "Trinket 1 is already tracked in: A, B +2. Both rules would announce it.", n3[1])
    check("items: exact items are not compared (only slots)", #notesFor({ items = { { name = "Hoof",
        members = { { itemID = 193762 } } } } }, { entry({ { itemID = 193762 } }), entry({ { slotID = 13 } }) }) == 0)
    local n4 = notesFor({ items = { "x", { name = "Broken" }, { name = "Bad", members = "x" }, { members = {} },
        { name = 7, members = { 5, { slotID = 13 } } } } }, { pair[1] })
    check("items: junk rules in the database are skipped, a bad name shows as ?", #n4 == 1
        and n4[1] == "Trinket 1 is already tracked in: ?. Both rules would announce it.", n4[1])
    check("items: no database items list, no note", #notesFor({ auras = {} }, pair) == 0)
    local tracked = { items = { { name = "Trinket 1", members = { { slotID = 13 } } } } }
    local n5 = notesFor(tracked, entries(8))
    check("items: 8 notes fold into three lines", #n5 == 3 and n5[1] == OVERLAP1 and n5[2] == OVERLAP1 and n5[3] == "+ 6 more",
        #n5 .. " " .. tostring(n5[3]))
    local n6 = notesFor(tracked, entries(4))
    check("items: 4 notes fold into 2 + one 'more' line", #n6 == 3 and n6[2] == OVERLAP1 and n6[3] == "+ 2 more", tostring(n6[3]))
    local n7 = notesFor(tracked, entries(3))
    check("items: 3 notes stay as they are", #n7 == 3 and n7[3] == OVERLAP1)

    end

    -- Junk never raises an error
    do
    local itemJunk = {
        "WVX1:" .. encode({ v = 1, kind = "item-group", items = "x" }),
        "WVX1:" .. encode({ v = 1, kind = "item-group", items = { { members = "x" } } }),
        "WVX1:" .. encode({ v = 1, kind = "item-group", items = { { members = { { slotID = {} } } } } }),
        "WVX1:" .. encode({ v = 1, kind = "item-group", items = { true } }),
        "WVX1:" .. encode({ v = 1, kind = {}, items = entries(1) }),
        "WVX1:" .. encode({ v = 1, kind = "item-group", class = 5, items = entries(1) }),
    }
    for index, value in ipairs(itemJunk) do
        local okCall, okJunk = pcall(Share.Parse, value)
        local okCheck, preview2 = pcall(Share.Check, value)
        check("items: junk " .. index .. " raises no error and is refused", okCall and okJunk == false and okCheck and preview2 == nil)
    end
    WoWraVoxDB = nil
    end
end

-- Export window
WoWraVoxDB = ns.CreateStarterDatabase()
-- A loaded database has ids on every rule (initializeDatabase); the bare starter database does not.
for listName, list in pairs({ auras = WoWraVoxDB.auras, items = WoWraVoxDB.items, skills = WoWraVoxDB.skills }) do
    for index, rule in ipairs(list or {}) do rule.id = rule.id or (listName .. "-" .. index) end
end
local existing = #WoWraVoxDB.auras
local source = ns.newAuraRule()
source.name = "UI group"
source.spellIDs = { 48707 }
source.applyEnabled = true
source.applyMessage = "Up"
ns.ShareUI.openExport(source)
local exportFrame = ns.ShareUI.exportFrame
local uiText = exportFrame.edit.text
check("export window opens with a WVX1 text", exportFrame.shown and uiText:sub(1, 5) == "WVX1:", uiText)
local _, windowGroup = Share.Parse(uiText)
check("export window text imports back to the source name", windowGroup and windowGroup.name == "UI group")
ns.ShareUI.openExport({ builtin = true, name = "Bloodlust", spellIDs = { 2825 } })
check("export of a built-in group raises no error and keeps the window text", exportFrame.edit.text == uiText)

-- Import window: gating and creation
ns.ShareUI.openImport()
local importFrame = ns.ShareUI.importFrame
local function typeText(value)
    importFrame.edit:SetText(value)
    importFrame.edit.scripts.OnTextChanged(importFrame.edit)
end
local function press(button)
    button.scripts.OnClick(button)
end
check("import window opens with the import button disabled", importFrame.shown and importFrame.importButton.enabled == false)
typeText(uiText)
check("import stays disabled before a check", importFrame.importButton.enabled == false)
press(importFrame.importButton)
check("import without a check adds nothing", #WoWraVoxDB.auras == existing)
press(importFrame.checkButton)
check("check enables import and shows the name", importFrame.importButton.enabled == true
    and importFrame.summary.text == "Name: UI group" and importFrame.error.text == "Check passed. Click Import to add the group.",
    importFrame.summary.text)
check("preview row shows the spell name and ID", importFrame.rows[1].shown and importFrame.rows[1].text.text == "Anti-Magic Shell · 48707")
typeText(uiText .. " ")
check("editing after a check disables import", importFrame.importButton.enabled == false
    and importFrame.error.text == "Text changed. Check it again before importing.")
press(importFrame.importButton)
check("import after an edit adds nothing", #WoWraVoxDB.auras == existing)
typeText(uiText)
press(importFrame.checkButton)
press(importFrame.importButton)
check("import adds exactly one new group", #WoWraVoxDB.auras == existing + 1)
local created = WoWraVoxDB.auras[#WoWraVoxDB.auras]
check("new group: name, enabled, own id, not the source table", created.name == "UI group" and created.enabled == true
    and created.id ~= nil and created ~= source)
check("import window closes after the import", importFrame.shown == false)
local seenIDs, uniqueIDs = {}, true
for _, rule in ipairs(WoWraVoxDB.auras) do
    if rule.id ~= nil then
        if seenIDs[rule.id] then uniqueIDs = false end
        seenIDs[rule.id] = true
    end
end
check("rule ids stay unique after import", uniqueIDs)

ns.ShareUI.openImport()
typeText("hello")
press(importFrame.checkButton)
check("bad text: error shown, import stays off", importFrame.error.text == "Not a WoWraVox export."
    and importFrame.importButton.enabled == false)

-- Import window: texts under the effect rows, grey label and white text, pipes shown as stored
local textRule = ns.newAuraRule()
textRule.name = "Texted"
textRule.spellIDs = { 100 }
textRule.applyEnabled = true
textRule.applyMessage = "Charge |cffff0000ready|r"
textRule.screenProfiles.apply.enabled = true
textRule.screenProfiles.apply.text = "Shield"
ns.ShareUI.openExport(textRule)
local textExport = exportFrame.edit.text
ns.ShareUI.openImport()
check("import window: no texts before a check", importFrame.textLines[1].text == "")
typeText(textExport)
press(importFrame.checkButton)
check("import window: spoken text line", importFrame.textLines[1].text
    == "|cff9a9a9aSpoken on application:|r |cffffffffCharge ||cffff0000ready||r|r", importFrame.textLines[1].text)
check("import window: screen text line", importFrame.textLines[2].text
    == "|cff9a9a9aScreen text on application:|r |cffffffffShield|r", importFrame.textLines[2].text)
check("import window: unused text lines stay empty", importFrame.textLines[3].text == "" and importFrame.textLines[4].text == "")
check("import window: effect rows still shown above the texts", importFrame.rows[1].shown == true
    and importFrame.summary.text == "Name: Texted")
typeText(uiText)
press(importFrame.checkButton)
check("import window: texts replaced by the next checked group", importFrame.textLines[1].text
    == "|cff9a9a9aSpoken on application:|r |cffffffffUp|r" and importFrame.textLines[2].text == "")
ns.ShareUI.openImport()
check("import window: texts cleared when the window reopens", importFrame.textLines[1].text == "")
check("import window: eight text lines", #importFrame.textLines == 8, #importFrame.textLines)

-- Import window: a received text (chat link) never overwrites text the user already has
local focusCalls = 0
importFrame.edit.SetFocus = function() focusCalls = focusCalls + 1 end
local WARNING = "Import window already has text. Clear it first."
-- closed window with old text: replaced and checked, focus taken
typeText("old draft")
importFrame:Hide()
focusCalls = 0
ns.ShareUI.openImport(uiText)
check("received text: closed window is replaced and shown", importFrame.shown and importFrame.edit.text == uiText)
check("received text: closed window takes focus once", focusCalls == 1, focusCalls)
check("received text: checked at once, import stays manual", importFrame.preview ~= nil and importFrame.summary.text == "Name: UI group")
-- visible window, own text: kept, warning, no focus
importFrame:Hide()
ns.ShareUI.openImport()
typeText("my own text")
focusCalls = 0
ns.ShareUI.openImport(textExport)
check("received text: own text in a visible window is kept", importFrame.edit.text == "my own text" and importFrame.shown)
check("received text: warning shown, nothing checked", importFrame.error.text == WARNING and importFrame.preview == nil
    and importFrame.summary.text == "")
check("received text: visible window keeps its focus", focusCalls == 0, focusCalls)
-- visible window, own text with a passed check: the check result stays
typeText(uiText)
press(importFrame.checkButton)
ns.ShareUI.openImport(textExport)
check("received text: checked own text is kept with its preview", importFrame.edit.text == uiText
    and importFrame.preview ~= nil and importFrame.error.text == "Check passed. Click Import to add the group.")
-- visible window, empty field: replaced without taking focus
typeText("")
focusCalls = 0
ns.ShareUI.openImport(textExport)
check("received text: empty field in a visible window is filled", importFrame.edit.text == textExport and importFrame.preview ~= nil)
check("received text: visible window is not refocused", focusCalls == 0, focusCalls)
-- same text again: not a conflict
ns.ShareUI.openImport(textExport)
check("received text: same text is accepted again", importFrame.edit.text == textExport and importFrame.preview ~= nil)
-- plain open keeps resetting the window
ns.ShareUI.openImport()
check("plain open still resets the window", importFrame.edit.text == "" and importFrame.preview == nil)
importFrame.edit.SetFocus = nil

-- Item groups in the windows. Frames and the chat are mocks. Ctrl-click itself (the row handler) cannot run here:
-- only what it calls (postToChat) is tested.
do
    local OVERLAP1 = "Trinket 1 is already tracked in: Trinket 1. Both rules would announce it."
    local OVERLAP2 = "Trinket 2 is already tracked in: Trinket 2. Both rules would announce it."
    local sent = {}
    ns.ShareChat = { SendToChat = function(shared, name) sent[#sent + 1] = { text = shared, name = name } return true end }
    local trinket1, trinket2 = WoWraVoxDB.items[1], WoWraVoxDB.items[2]
    check("starter database has the two trinket rules", trinket1.members[1].slotID == 13 and trinket2.members[1].slotID == 14)

    -- postToChat: one trinket rule posts both
    ns.ShareUI.postToChat(trinket1)
    check("post: a trinket rule posts the marker for both trinket rules, named Trinkets", #sent == 1 and sent[1].name == "Trinkets", #sent)
    local _, postedGroup, postedMeta = Share.Parse(sent[1].text)
    check("post: the text holds both trinket slots, as an item group", postedGroup and #postedGroup.items == 2
        and postedGroup.items[1].members[1].slotID == 13 and postedGroup.items[2].members[1].slotID == 14
        and postedMeta.kind == "item-group")
    sent = {}
    ns.ShareUI.postToChat(trinket2)
    check("post: the second trinket rule posts the same two rules", #sent == 1 and sent[1].name == "Trinkets"
        and #select(2, Share.Parse(sent[1].text)).items == 2)

    -- other item rules: only themselves
    sent = {}
    local hoof = ns.newItemRule(193762, "Blazebinder's Hoof", nil, nil)
    hoof.id = "items-hoof" -- every rule of a loaded database has an id (registerNewRule reads them all)
    table.insert(WoWraVoxDB.items, hoof)
    ns.ShareUI.postToChat(hoof)
    local _, hoofGroup = Share.Parse(sent[1] and sent[1].text or "")
    check("post: an exact-item rule posts only itself, under its own name", #sent == 1 and sent[1].name == "Blazebinder's Hoof"
        and hoofGroup and #hoofGroup.items == 1 and sameTable(hoofGroup.items[1].members, { { itemID = 193762 } }))
    sent = {}
    local lateSlot = ns.newItemRule(nil, "Late", nil, nil)
    lateSlot.members = { { itemID = 1 }, { slotID = 13 } }
    ns.ShareUI.postToChat(lateSlot)
    check("post: a rule whose trinket slot is not its first member counts as an ordinary rule", #sent == 1
        and sent[1].name == "Late" and #select(2, Share.Parse(sent[1].text)).items == 1)

    -- refused: nothing is posted
    sent = {}
    ns.ShareUI.postToChat({ starter = "trinket", name = "Add a trinket", members = {} })
    ns.ShareUI.postToChat({ builtin = true, name = "B", members = { { slotID = 5 } } })
    ns.ShareUI.postToChat({ builtin = true, name = "BT", members = { { slotID = 13 } } })
    check("post: an empty starter and built-in rules post nothing", #sent == 0, #sent)
    ns.ShareChat = nil
    check("post: without the chat module nothing happens and nothing fails", pcall(ns.ShareUI.postToChat, trinket1))

    -- aura groups: unchanged
    ns.ShareChat = { SendToChat = function(shared, name) sent[#sent + 1] = { text = shared, name = name } return true end }
    sent = {}
    ns.ShareUI.postToChat(source)
    local _, auraPosted, auraPostedMeta = Share.Parse(sent[1] and sent[1].text or "")
    check("post: an aura group still posts its own export under its name", #sent == 1 and sent[1].name == "UI group"
        and auraPosted and auraPosted.name == "UI group" and auraPostedMeta.kind == nil)
    ns.ShareChat = nil

    -- the import window: preview and import
    local ra = ns.newItemRule(nil, "Trinket 1", nil, nil)
    ra.members, ra.message = { { slotID = 13 } }, "{slot} ready"
    local rb = ns.newItemRule(nil, "Trinket 2", nil, nil)
    rb.members, rb.message = { { slotID = 14, itemID = 193762 } }, "{slot} ready"
    local okShare, shareText = Share.ExportItems({ ra, rb })
    check("item import: the sample text exports", okShare, shareText)
    for index = 1, 3 do
        importFrame.rows[index].icon.SetTexture = function(self, value) self.tex = value end
    end
    ns.ShareUI.openImport()
    typeText(uiText)
    press(importFrame.checkButton)
    check("item import: an aura check shows one row", importFrame.rows[1].shown and importFrame.rows[2].shown == false
        and importFrame.summary.text == "Name: UI group")
    typeText(shareText)
    check("item import: import stays off until the item text is checked", importFrame.importButton.enabled == false)
    press(importFrame.checkButton)
    check("item import: the check passes and shows the rule and item count", importFrame.error.text
        == "Check passed. Click Import to add the group." and importFrame.summary.text == "Item rules: 2"
        and importFrame.effects.text == "2 items", importFrame.summary.text .. " / " .. importFrame.effects.text)
    check("item import: both trinkets are listed, one row each", importFrame.rows[1].shown and importFrame.rows[2].shown
        and importFrame.rows[3].shown == false and importFrame.rows[1].text.text == "Trinket 1"
        and importFrame.rows[2].text.text == "Trinket 2 · Blazebinder's Hoof", importFrame.rows[2].text.text)
    check("item import: row icons from the worn item and from the item, plain colour", importFrame.rows[1].icon.tex == 999013
        and importFrame.rows[2].icon.tex == 111111, tostring(importFrame.rows[1].icon.tex))
    check("item import: what each rule says is listed under the rows", importFrame.textLines[1].text
        == "|cff9a9a9aTrinket 1:|r |cffffffff{slot} ready|r" and importFrame.textLines[2].text
        == "|cff9a9a9aTrinket 2:|r |cffffffff{slot} ready|r" and importFrame.textLines[3].text == "")
    check("item import: the own trinket rules are named in the notes", importFrame.notes[1].text == OVERLAP1
        and importFrame.notes[2].text == OVERLAP2 and importFrame.notes[3].text == "", importFrame.notes[1].text)
    check("item import: import is enabled after the check, more is empty", importFrame.importButton.enabled == true
        and importFrame.more.text == "")
    typeText(uiText)
    press(importFrame.checkButton)
    check("item import: the next aura check replaces the item preview", importFrame.rows[2].shown == false
        and importFrame.summary.text == "Name: UI group" and importFrame.textLines[2].text == "")
    typeText(shareText)
    press(importFrame.checkButton)

    local itemsBefore, aurasBefore = #WoWraVoxDB.items, #WoWraVoxDB.auras
    local scans = {}
    local realQueue = ns.queueItemScan
    ns.queueItemScan = function(delay) scans[#scans + 1] = delay end
    press(importFrame.importButton)
    check("item import: two new item rules, no aura rule", #WoWraVoxDB.items == itemsBefore + 2
        and #WoWraVoxDB.auras == aurasBefore)
    local new1, new2 = WoWraVoxDB.items[itemsBefore + 1], WoWraVoxDB.items[itemsBefore + 2]
    check("item import: names made unique against the own rules, members and message kept", new1.name == "Trinket 1 (2)"
        and new2.name == "Trinket 2 (2)" and sameTable(new1.members, { { slotID = 13 } })
        and sameTable(new2.members, { { slotID = 14, itemID = 193762 } }) and new1.message == "{slot} ready", new1.name)
    local itemIDs, uniqueItemIDs = {}, true
    for _, list in ipairs({ WoWraVoxDB.auras, WoWraVoxDB.items }) do
        for _, rule in ipairs(list) do
            if rule.id ~= nil then
                if itemIDs[rule.id] then uniqueItemIDs = false end
                itemIDs[rule.id] = true
            end
        end
    end
    check("item import: the new rules got their own ids, all ids stay unique", new1.id ~= nil and new2.id ~= nil
        and new1.id ~= new2.id and uniqueItemIDs)
    check("item import: enabled, own rules untouched", new1.enabled == true and new2.enabled == true
        and WoWraVoxDB.items[1].name == "Trinket 1" and WoWraVoxDB.items[1] ~= new1 and #WoWraVoxDB.items[1].members == 1)
    check("item import: one item scan queued at 0.1", #scans == 1 and scans[1] == 0.1, #scans)
    check("item import: the window closes", importFrame.shown == false)
    ns.ShareUI.openImport()
    typeText(shareText)
    press(importFrame.checkButton)
    press(importFrame.importButton)
    check("item import: importing again numbers the names again", WoWraVoxDB.items[itemsBefore + 3].name == "Trinket 1 (3)"
        and WoWraVoxDB.items[itemsBefore + 4].name == "Trinket 2 (3)", WoWraVoxDB.items[itemsBefore + 3].name)

    -- a text that is edited after the check cannot be imported; a broken text shows the error
    ns.ShareUI.openImport()
    typeText(shareText)
    press(importFrame.checkButton)
    typeText(shareText .. " ")
    local itemsNow = #WoWraVoxDB.items
    press(importFrame.importButton)
    check("item import: an edit after the check disables the import", importFrame.importButton.enabled == false
        and #WoWraVoxDB.items == itemsNow)
    typeText("WVX1:" .. encode({ v = 1, kind = "item-group", class = "MAGE", items = { { name = "x",
        members = { { slotID = 1 }, { slotID = 2 }, { slotID = 3 }, { slotID = 4 }, { slotID = 5 } } } } }))
    press(importFrame.checkButton)
    check("item import: a text with 5 members shows the error, no preview, import off", importFrame.error.text
        == "The export data is invalid." and importFrame.importButton.enabled == false and importFrame.summary.text == ""
        and importFrame.rows[1].shown == false)

    -- the largest group: 12 rows, the rest as "+ N more", eight texts
    local bigItems = {}
    for i = 1, 8 do
        bigItems[i] = { name = "R" .. i, message = "m" .. i, members = { { slotID = 1 }, { slotID = 2 }, { slotID = 3 }, { slotID = 4 } } }
    end
    typeText("WVX1:" .. encode({ v = 1, kind = "item-group", class = "MAGE", items = bigItems }))
    press(importFrame.checkButton)
    check("item import: 32 members show 12 rows and '+ 20 more'", importFrame.rows[12].shown and importFrame.more.text == "+ 20 more"
        and importFrame.effects.text == "32 items" and importFrame.summary.text == "Item rules: 8", importFrame.more.text)
    check("item import: eight rules, eight text lines", importFrame.textLines[8].text
        == "|cff9a9a9aR8:|r |cffffffffm8|r" and importFrame.textLines[1].text == "|cff9a9a9aR1:|r |cffffffffm1|r")
    check("item import: rows name the rule when the row does not", importFrame.rows[1].text.text == "R1 · Slot 1"
        and importFrame.rows[5].text.text == "R2 · Slot 1", importFrame.rows[1].text.text)
    -- one member: "1 item"; an unnamed item is shown as Item <id>
    typeText("WVX1:" .. encode({ v = 1, kind = "item-group", class = "MAGE", items = { { name = "Mystery",
        members = { { itemID = 4040404 } } } } }))
    press(importFrame.checkButton)
    check("item import: one unknown item reads '1 item' and Item <id>", importFrame.effects.text == "1 item"
        and importFrame.rows[1].text.text == "Mystery · Item 4040404" and importFrame.rows[1].icon.tex == "Interface\\Icons\\INV_Misc_QuestionMark"
        and importFrame.more.text == "", importFrame.rows[1].text.text)

    -- a text received by chat link opens the same preview
    importFrame:Hide()
    ns.ShareUI.openImport(shareText)
    check("item import: a received text is checked at once, import stays manual", importFrame.shown
        and importFrame.summary.text == "Item rules: 2" and importFrame.importButton.enabled == true)
    ns.ShareUI.openImport()
    importFrame:Hide()
    ns.queueItemScan = realQueue
end

print("ALL PASS")
