local _, ns = ...
ns.ShareGroups = ns.ShareGroups or {}
local Share = ns.ShareGroups

-- Export and import of aura groups and item rule groups as text. Pure functions: no frames, no saved variables written here.
-- Format: "WVX1:" .. Base64(Deflate(CBOR({ v = 1, kind = "aura-group", class = <token>, group = {...} })))
-- Item rules: the same wrapper with kind = "item-group" and items = { { name, message, enabled, members }, ... }.
-- Text from another player is data only. Every field is checked against its type and range, unknown fields
-- are dropped, "|" is escaped so no chat link or texture code survives, and nothing is loaded or executed.

local TOKEN = "WVX1:"
local VERSION = 1
-- 8 KB: a full group (100 IDs, 100 cast pairs, 100 cues, seven 200-byte texts) stays near 5 KB. A lower limit keeps
-- the cost of a hostile paste (decode, decompress) and the 200-byte chat chunks small. Read by ShareChat.
local MAX_INPUT = 8192
Share.MAX_INPUT = MAX_INPUT
local MAX_DECODED = 64 * 1024
local MAX_SPELLS = 100
local MAX_PAIRS = 100
local MAX_SPECS = 8
local MAX_TEXT = 200
local MAX_ID = 2147483647
local MAX_ITEMS = 8   -- item rules in one shared group (both trinkets = 2)
local MAX_MEMBERS = 4 -- slots or items inside one shared item rule

local ERR_NOT_EXPORT = "Not a WoWraVox export."
local ERR_VERSION = "Unsupported export version."
local ERR_TOO_LARGE = "The export is too large."
local ERR_INVALID = "The export data is invalid."
local ERR_CLIENT = "This client cannot read exports."
local ERR_EMPTY = "This rule has no item to share yet."
local ERR_MEMBERS = "Only rules with up to 4 items can be shared."

local TEXT_FIELDS = { "name", "applyMessage", "expireMessage", "applySoundMediaName", "expireSoundMediaName" }
local BOOL_FIELDS = { "applyEnabled", "expireEnabled", "oneEffect", "applySoundEnabled", "expireSoundEnabled" }
local ID_FIELDS = { "applySoundKitID", "expireSoundKitID" }
local CUE_FIELDS = { "alertCategory", "expireCategory" }
local CHANNEL_FIELDS = { "applySoundChannel", "expireSoundChannel" }
local EVENT_KEYS = { "apply", "expire" }

local function joined(...)
    local out = {}
    for _, list in ipairs({ ... }) do
        for _, key in ipairs(list) do out[#out + 1] = key end
    end
    return out
end

local SCALAR_FIELDS = joined(TEXT_FIELDS, BOOL_FIELDS, ID_FIELDS, CUE_FIELDS, CHANNEL_FIELDS)
local EXPORT_FIELDS = joined(SCALAR_FIELDS, { "spellIDs", "castByAuraID", "categoryByAuraID", "specializationIDs" })
local COPY_FIELDS = joined(SCALAR_FIELDS, { "spellIDs", "castByAuraID", "categoryByAuraID" })

-- Text in English; the window translates it with ns.L. Formatted text is translated before formatting.
local function L(key, ...)
    local text = ns.L and ns.L(key) or key
    if select("#", ...) > 0 then return string.format(text, ...) end
    return text
end

local function playerClassToken()
    if type(UnitClass) ~= "function" then return nil end
    local ok, _, token = pcall(UnitClass, "player")
    if ok and type(token) == "string" and token ~= "" then return token end
    return nil
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function shallowCopy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function isID(v)
    return type(v) == "number" and v >= 1 and v <= MAX_ID and v == math.floor(v)
end

local function isCue(v, allowNone)
    if v == "none" then return allowNone == true end
    local labels = ns.NOTIFICATION_CUE_LABELS
    return type(v) == "string" and type(labels) == "table" and labels[v] ~= nil
end

local function isChannel(v)
    local channels = ns.NOTIFICATION_SOUND_CHANNEL_SET
    return type(v) == "string" and type(channels) == "table" and channels[v] == true
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Cuts to at most max bytes without splitting a UTF-8 character (continuation bytes are 0x80-0xBF).
local function utf8Cut(s, max)
    if #s <= max then return s end
    local cut = max
    while cut > 0 do
        local nextByte = s:byte(cut + 1)
        if nextByte < 0x80 or nextByte >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut)
end

-- Drops control characters, trims, escapes "|" (so |c, |T and |H codes cannot survive), cuts to MAX_TEXT.
-- A cut that would leave a lone "|" inside an escaped pair is trimmed by one more character.
local function cleanText(value)
    local s = trim((value:gsub("%c", "")))
    s = (s:gsub("|", "||"))
    s = utf8Cut(s, MAX_TEXT)
    local trailing = s:match("|*$") or ""
    if #trailing % 2 == 1 then s = s:sub(1, -2) end
    return trim(s)
end

-- Counterpart of cleanText for export: "||" (stored form) goes back to the typed "|", so a text that is
-- exported and imported again does not double its pipes each time.
local function unescapeText(value)
    return (value:gsub("||", "|"))
end

-- A sequence of positive integers: 1-based, no holes, no extra keys, duplicates removed.
local function idList(value, max)
    if type(value) ~= "table" or countKeys(value) ~= #value or #value > max then return nil end
    local out, seen = {}, {}
    for i = 1, #value do
        local id = value[i]
        if not isID(id) then return nil end
        if not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    return out
end

-- A map from positive integer keys to values that pass validValue.
local function idMap(value, validValue)
    if type(value) ~= "table" or countKeys(value) > MAX_PAIRS then return nil end
    local out = {}
    for key, item in pairs(value) do
        if not isID(key) or not validValue(item) then return nil end
        out[key] = item
    end
    return out
end

-- Type and range check of one group. Returns a new table with only whitelisted fields, or nil.
-- raw = true (export): texts get "||" turned back into "|" (unescapeText); false (import): texts are cleaned with cleanText.
local function sanitizeGroup(source, raw)
    if type(source) ~= "table" then return nil end
    local out = {}
    for _, key in ipairs(TEXT_FIELDS) do
        local v = source[key]
        if v ~= nil then
            if type(v) ~= "string" then return nil end
            out[key] = raw and unescapeText(v) or cleanText(v)
        end
    end
    for _, key in ipairs(BOOL_FIELDS) do
        local v = source[key]
        if v ~= nil then
            if type(v) ~= "boolean" then return nil end
            out[key] = v
        end
    end
    for _, key in ipairs(ID_FIELDS) do
        local v = source[key]
        if v ~= nil then
            if not isID(v) then return nil end
            out[key] = v
        end
    end
    for _, key in ipairs(CUE_FIELDS) do
        local v = source[key]
        if v ~= nil then
            if not isCue(v, true) then return nil end
            out[key] = v
        end
    end
    for _, key in ipairs(CHANNEL_FIELDS) do
        local v = source[key]
        if v ~= nil then
            if not isChannel(v) then return nil end
            out[key] = v
        end
    end
    if source.spellIDs ~= nil then
        out.spellIDs = idList(source.spellIDs, MAX_SPELLS)
        if not out.spellIDs then return nil end
    end
    if source.specializationIDs ~= nil then
        out.specializationIDs = idList(source.specializationIDs, MAX_SPECS)
        if not out.specializationIDs then return nil end
    end
    if source.castByAuraID ~= nil then
        out.castByAuraID = idMap(source.castByAuraID, isID)
        if not out.castByAuraID then return nil end
    end
    if source.categoryByAuraID ~= nil then
        out.categoryByAuraID = idMap(source.categoryByAuraID, function(cue) return isCue(cue, false) end)
        if not out.categoryByAuraID then return nil end
    end
    if source.screenProfiles ~= nil then
        local profiles = source.screenProfiles
        if type(profiles) ~= "table" then return nil end
        out.screenProfiles = {}
        for _, key in ipairs(EVENT_KEYS) do
            local p = profiles[key]
            if p ~= nil then
                if type(p) ~= "table" or type(p.enabled) ~= "boolean" or type(p.text) ~= "string" then return nil end
                out.screenProfiles[key] = { enabled = p.enabled, text = raw and unescapeText(p.text) or cleanText(p.text) }
            end
        end
    end
    return out
end

-- Members of one item rule: 1..MAX_MEMBERS tables, each { slotID } (whatever sits in that slot), { itemID } (one
-- exact item) or both; only the fields that are present are kept. A member seen twice (same slot, or same exact
-- item) is kept once. Returns a new list or nil. A text slot ("13") is refused: only numbers count.
local function sanitizeMembers(value)
    if type(value) ~= "table" or countKeys(value) ~= #value or #value < 1 or #value > MAX_MEMBERS then return nil end
    local out, seen = {}, {}
    for i = 1, #value do
        local source = value[i]
        if type(source) ~= "table" then return nil end
        local member = {}
        if source.slotID ~= nil then
            if type(source.slotID) ~= "number" then return nil end
            member.slotID = ns.normalizeSlotID(source.slotID)
            if not member.slotID then return nil end
        end
        if source.itemID ~= nil then
            if not isID(source.itemID) then return nil end
            member.itemID = source.itemID
        end
        if member.slotID == nil and member.itemID == nil then return nil end
        local key = member.slotID and ("s" .. member.slotID) or ("i" .. member.itemID)
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = member
        end
    end
    return out
end

-- One item rule: name and message (texts), enabled (boolean, read but never applied on import), members.
-- raw = true (export) / false (import): same text handling as sanitizeGroup.
local function sanitizeEntry(source, raw)
    if type(source) ~= "table" then return nil end
    local out = {}
    for _, key in ipairs({ "name", "message" }) do
        local v = source[key]
        if v ~= nil then
            if type(v) ~= "string" then return nil end
            out[key] = raw and unescapeText(v) or cleanText(v)
        end
    end
    if source.enabled ~= nil then
        if type(source.enabled) ~= "boolean" then return nil end
        out.enabled = source.enabled
    end
    out.members = sanitizeMembers(source.members)
    if not out.members then return nil end
    return out
end

-- The items of a group: 1..MAX_ITEMS entries. Returns { items = {...} } or nil.
local function sanitizeItems(source, raw)
    if type(source) ~= "table" or countKeys(source) ~= #source or #source < 1 or #source > MAX_ITEMS then return nil end
    local items = {}
    for i = 1, #source do
        items[i] = sanitizeEntry(source[i], raw)
        if not items[i] then return nil end
    end
    return { items = items }
end

-- Whitelisted copy of a local rule. Personal values (voice, volume, speed, font, colour, position, id,
-- enabled, builtin, presetID) are never read here.
local function pickGroup(rule)
    local group = {}
    for _, key in ipairs(EXPORT_FIELDS) do
        if rule[key] ~= nil then group[key] = rule[key] end
    end
    if type(rule.screenProfiles) == "table" then
        group.screenProfiles = {}
        for _, key in ipairs(EVENT_KEYS) do
            local p = rule.screenProfiles[key]
            if type(p) == "table" then
                group.screenProfiles[key] = {
                    enabled = p.enabled == true,
                    text = type(p.text) == "string" and p.text or "",
                }
            end
        end
    end
    return group
end

-- "WVX1:" .. Base64(Deflate(CBOR(payload))), or nil when one of the three steps gives nothing.
local function encodePayload(api, payload)
    local cbor = api.SerializeCBOR(payload)
    local packed = type(cbor) == "string" and api.CompressString(cbor) or nil
    local encoded = type(packed) == "string" and api.EncodeBase64(packed) or nil
    if type(encoded) ~= "string" or encoded == "" then return nil end
    return TOKEN .. encoded
end

local function exportRule(rule)
    if type(rule) ~= "table" then return false, ERR_INVALID end
    if rule.builtin then return false, "builtin" end
    local api = C_EncodingUtil
    if type(api) ~= "table" then return false, ERR_CLIENT end
    local group = sanitizeGroup(pickGroup(rule), true)
    if not group then return false, ERR_INVALID end
    local text = encodePayload(api, { v = VERSION, kind = "aura-group", class = playerClassToken(), group = group })
    if not text then return false, ERR_INVALID end
    return true, text
end

-- Item rules (the list is one group): only name, message, enabled and the members { slotID, itemID } leave the
-- machine. Built-in rules and rules without a member cannot be exported; neither can a rule with more members than
-- an import accepts (cutting them silently would share something else than the rule).
local function exportItems(rules)
    if type(rules) ~= "table" or #rules < 1 or countKeys(rules) ~= #rules then return false, ERR_INVALID end
    if #rules > MAX_ITEMS then return false, ERR_TOO_LARGE end
    local api = C_EncodingUtil
    if type(api) ~= "table" then return false, ERR_CLIENT end
    local items = {}
    for index, rule in ipairs(rules) do
        if type(rule) ~= "table" then return false, ERR_INVALID end
        if rule.builtin then return false, "builtin" end
        local members = rule.members
        if type(members) ~= "table" or #members == 0 then return false, ERR_EMPTY end
        if #members > MAX_MEMBERS then return false, ERR_MEMBERS end
        local picked = {}
        for i, member in ipairs(members) do
            if type(member) ~= "table" then return false, ERR_INVALID end
            picked[i] = { slotID = member.slotID, itemID = member.itemID }
        end
        items[index] = sanitizeEntry({ name = rule.name, message = rule.message, enabled = rule.enabled ~= false,
            members = picked }, true)
        if not items[index] then return false, ERR_INVALID end
    end
    local text = encodePayload(api, { v = VERSION, kind = "item-group", class = playerClassToken(), items = items })
    if not text then return false, ERR_INVALID end
    if #text > MAX_INPUT then return false, ERR_TOO_LARGE end
    return true, text
end

local function parseText(text)
    if type(text) ~= "string" then return nil, ERR_NOT_EXPORT end
    if #text > MAX_INPUT then return nil, ERR_TOO_LARGE end
    local body = (text:gsub("^%s+", ""))
    body = (body:gsub("%s+$", ""))
    local version = body:match("^WVX(%d+):")
    if not version then return nil, ERR_NOT_EXPORT end
    if version ~= "1" then return nil, ERR_VERSION end
    local api = C_EncodingUtil
    if type(api) ~= "table" then return nil, ERR_CLIENT end
    local data = body:sub(#TOKEN + 1)
    data = (data:gsub("%s", ""))
    local raw = api.DecodeBase64(data)
    if type(raw) ~= "string" or raw == "" then return nil, ERR_INVALID end
    local packed = api.DecompressString(raw)
    if type(packed) ~= "string" or packed == "" then return nil, ERR_INVALID end
    if #packed > MAX_DECODED then return nil, ERR_TOO_LARGE end
    local payload = api.DeserializeCBOR(packed)
    if type(payload) ~= "table" then return nil, ERR_INVALID end
    if payload.v ~= VERSION then return nil, ERR_VERSION end
    local kind = payload.kind
    if kind ~= "aura-group" and kind ~= "item-group" then return nil, ERR_INVALID end
    local class = payload.class
    if class ~= nil and (type(class) ~= "string" or #class > 16 or not class:match("^%u+$")) then
        return nil, ERR_INVALID
    end
    if kind == "item-group" then
        local items = sanitizeItems(payload.items, false)
        if not items then return nil, ERR_INVALID end
        return items, { class = class, version = VERSION, kind = kind }
    end
    local group = sanitizeGroup(payload.group, false)
    if not group then return nil, ERR_INVALID end
    return group, { class = class, version = VERSION }
end

local function lookupSpell(spellID)
    if type(C_Spell) ~= "table" or type(C_Spell.GetSpellInfo) ~= "function" then return nil end
    local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
    if not ok or type(info) ~= "table" then return nil end
    local okName, name = pcall(function() return info.name end)
    if not okName or type(name) ~= "string" or name == "" then return nil end
    local okIcon, icon = pcall(function() return info.iconID end)
    return name, okIcon and icon or nil
end

-- ok, text ("WVX1:...") or ok=false, error text. Built-in rules return false, "builtin".
function Share.Export(rule)
    local ok, result, text = pcall(exportRule, rule)
    if not ok then return false, ERR_INVALID end
    return result, text
end

-- Item rules (list of rules, 1..8, each with 1..4 members): ok, text ("WVX1:...") or ok=false, error text.
-- A built-in rule gives false, "builtin"; the other refusals give a translatable English text.
function Share.ExportItems(rules)
    local ok, result, text = pcall(exportItems, rules)
    if not ok then return false, ERR_INVALID end
    return result, text
end

-- ok, group, meta on success; ok=false, error text otherwise. Never runs or loads the text.
-- Aura group: group = the fields of the rule. Item group: group = { items = { entry, ... } } and meta.kind = "item-group".
function Share.Parse(text)
    local ok, group, meta = pcall(parseText, text)
    if not ok then return false, ERR_INVALID end
    if group == nil then return false, meta end
    return true, group, meta
end

-- true when every specialisation ID belongs to the player's class, false when one does not (or is unknown to the
-- client), nil when the client cannot tell (no GetSpecializationInfoByID, no class, or the call fails).
local function specsBelongToPlayer(specIDs)
    local own = playerClassToken()
    if type(GetSpecializationInfoByID) ~= "function" or not own then return nil end
    for _, specID in ipairs(specIDs) do
        local ok, _, _, _, _, _, classFile = pcall(GetSpecializationInfoByID, specID)
        if not ok then return nil end
        if classFile ~= own then return false end
    end
    return true
end

-- Existing aura rules (built-in included), or nil when no database is loaded (tests, first start).
local function auraList()
    local db = WoWraVoxDB
    if type(db) ~= "table" or type(db.auras) ~= "table" then return nil end
    return db.auras
end

local function nameKey(name)
    return trim(name):lower()
end

-- Name match against a list of rules (nil = no list), ignoring capitalisation and surrounding spaces.
local function listHasName(list, name)
    if not list then return false end
    local wanted = nameKey(name)
    for _, rule in ipairs(list) do
        if type(rule) == "table" and type(rule.name) == "string" and nameKey(rule.name) == wanted then return true end
    end
    return false
end

local function auraNameExists(name)
    return listHasName(auraList(), name)
end

-- Name as it would be stored: " (2)", " (3)" ... appended while the name is taken (exists(name), default: an aura
-- rule has it). The base is cut so the result stays within MAX_TEXT; a cut never splits a UTF-8 character or
-- leaves a lone "|" (same rules as cleanText).
local function uniqueName(name, exists)
    exists = exists or auraNameExists
    if not exists(name) then return name end
    local n = 2
    while true do
        local suffix = " (" .. n .. ")"
        local base = utf8Cut(name, MAX_TEXT - #suffix)
        local trailing = base:match("|*$") or ""
        if #trailing % 2 == 1 then base = base:sub(1, -2) end
        local candidate = trim(base) .. suffix
        if not exists(candidate) then return candidate end
        n = n + 1
    end
end

-- New aura rule from a checked group. The caller registers it (ns.registerNewRule) and adds it to the DB.
function Share.ToRule(group, meta)
    local rule = ns.newAuraRule()
    for _, key in ipairs(COPY_FIELDS) do
        local v = group[key]
        if v ~= nil and not (key == "name" and v == "") then
            rule[key] = type(v) == "table" and shallowCopy(v) or v
        end
    end
    if group.screenProfiles then
        for _, key in ipairs(EVENT_KEYS) do
            local p = group.screenProfiles[key]
            if p and rule.screenProfiles and rule.screenProfiles[key] then
                rule.screenProfiles[key].enabled = p.enabled
                rule.screenProfiles[key].text = p.text
            end
        end
    end
    rule.name = uniqueName(rule.name)
    rule.enabled = true
    local sameClass = meta and meta.class ~= nil and meta.class == playerClassToken()
    local keepSpecs = sameClass and group.specializationIDs and specsBelongToPlayer(group.specializationIDs) ~= false
    rule.specializationIDs = keepSpecs and shallowCopy(group.specializationIDs) or nil
    return rule
end

-- Name of an item as the client knows it now, nil while it is not loaded. Asks the client to load it, so the next
-- Check shows the name.
local function lookupItemName(itemID)
    local name
    if type(GetItemInfo) == "function" then
        local ok, value = pcall(GetItemInfo, itemID)
        if ok and type(value) == "string" and value ~= "" then name = value end
    end
    if type(C_Item) == "table" then
        if not name and type(C_Item.GetItemNameByID) == "function" then
            local ok, value = pcall(C_Item.GetItemNameByID, itemID)
            if ok and type(value) == "string" and value ~= "" then name = value end
        end
        if not name and type(C_Item.RequestLoadItemDataByID) == "function" then pcall(C_Item.RequestLoadItemDataByID, itemID) end
    end
    return name
end

-- Icon of a member as the addon shows it (a slot member: the item worn there now), nil when there is none.
local function memberIcon(member)
    if type(ns.itemMemberInfo) ~= "function" then return nil end
    local ok, _, icon = pcall(ns.itemMemberInfo, member)
    if ok then return icon end
    return nil
end

-- Name of an imported item rule: the sent name; empty = what a rule made by hand gets (first slot's name, or the item's).
local function entryName(entry)
    if entry.name ~= nil and entry.name ~= "" then return entry.name end
    local first = entry.members[1]
    if first.slotID then return ns.slotName(first.slotID) end
    return lookupItemName(first.itemID) or ("Item " .. first.itemID)
end

-- Message of an imported item rule: the sent text (placeholders {slot} and {item} stay as text); only a missing
-- message gets the generated default ("{slot} ready" for one slot, "{item} ready" otherwise).
local function entryMessage(entry)
    if entry.message ~= nil then return entry.message end
    local first = entry.members[1]
    if #entry.members == 1 and first.slotID then return ns.slotDefaultMessage(first.slotID) end
    return "{item} " .. L("ready")
end

-- New item rules from a checked item group: one per entry, in order, with the personal values of a new rule (voice,
-- volume, sounds, screen look). The caller registers each (ns.registerNewRule(rule, "items")) and adds it to
-- WoWraVoxDB.items. Names stay unique against the existing item rules and the rules made here.
function Share.ToItemRules(group)
    local rules = {}
    if type(group) ~= "table" or type(group.items) ~= "table" then return rules end
    local existing = type(WoWraVoxDB) == "table" and type(WoWraVoxDB.items) == "table" and WoWraVoxDB.items or nil
    local function taken(name) return listHasName(existing, name) or listHasName(rules, name) end
    for _, entry in ipairs(group.items) do
        local rule = ns.newItemRule()
        rule.members = {}
        for i, member in ipairs(entry.members) do rule.members[i] = { slotID = member.slotID, itemID = member.itemID } end
        rule.name = uniqueName(entryName(entry), taken)
        rule.message = entryMessage(entry)
        rule.icon = memberIcon(entry.members[1])
        rule.enabled = true
        rules[#rules + 1] = rule
    end
    return rules
end

-- Adds { label, text } when the output is enabled and the text is not empty. Labels are translated here.
local function addText(list, label, enabled, text)
    if enabled == true and type(text) == "string" and text ~= "" then
        list[#list + 1] = { label = L(label), text = text }
    end
end

-- Names of existing, enabled aura rules (built-in included) that track at least one of the spell IDs, first two
-- names only, and the total count. Returns nil when no database is loaded.
local function overlappingAuraNames(spellIDs)
    local auras = auraList()
    if not auras or type(spellIDs) ~= "table" or #spellIDs == 0 then return nil end
    local wanted = {}
    for _, spellID in ipairs(spellIDs) do wanted[spellID] = true end
    local names, count = {}, 0
    for _, rule in ipairs(auras) do
        local hit = false
        if type(rule) == "table" and rule.enabled ~= false and type(rule.spellIDs) == "table" then
            for _, spellID in ipairs(rule.spellIDs) do
                if wanted[spellID] then hit = true break end
            end
        end
        if hit then
            count = count + 1
            if count <= 2 then names[#names + 1] = type(rule.name) == "string" and rule.name or "?" end
        end
    end
    return names, count
end

-- Sound the group plays for one event, as preview text: media name first (as ns.playNotificationSound
-- does), else the sound kit ID, else the default kit of a new rule. Channel falls back to "Master".
local function soundText(group, prefix)
    if group[prefix .. "SoundEnabled"] ~= true then return nil end
    local channel = group[prefix .. "SoundChannel"] or "Master"
    local media = group[prefix .. "SoundMediaName"]
    if type(media) == "string" and media ~= "" then return L("Plays sound %s on %s", media, channel) end
    local kit = group[prefix .. "SoundKitID"]
    if kit == nil and type(ns.newAuraRule) == "function" then
        local okRule, fresh = pcall(ns.newAuraRule)
        kit = okRule and type(fresh) == "table" and fresh[prefix .. "SoundKitID"] or nil
    end
    if type(kit) ~= "number" then return nil end
    return L("Plays sound ID %d on %s", kit, channel)
end

local function cueText(cue)
    if type(cue) ~= "string" or cue == "none" then return nil end
    local labels = ns.NOTIFICATION_CUE_LABELS
    local label = type(labels) == "table" and labels[cue] or cue
    return L("Category cue: %s", L(label))
end

-- Names of the enabled item rules that already have this slot as a member (first two names only) and the total count.
-- Returns nil when no database is loaded. Exact-item members are not compared: a slot is what rules overlap on.
local function overlappingItemNames(slotID)
    local db = WoWraVoxDB
    if type(db) ~= "table" or type(db.items) ~= "table" then return nil end
    local names, count = {}, 0
    for _, rule in ipairs(db.items) do
        local hit = false
        if type(rule) == "table" and rule.enabled ~= false and type(rule.members) == "table" then
            for _, member in ipairs(rule.members) do
                if type(member) == "table" and member.slotID == slotID then hit = true break end
            end
        end
        if hit then
            count = count + 1
            if count <= 2 then names[#names + 1] = type(rule.name) == "string" and rule.name or "?" end
        end
    end
    return names, count
end

local MAX_NOTES = 3 -- lines the import window has for notes; more are folded into a last "+ N more" line

-- Preview of an item group: kind = "item-group", entries { name, message, members { slotName, slotID, itemID,
-- itemName, known, icon } }, notes (translated). A slot member has slotName (and itemName when the sender's item
-- travels with it); an exact item has only itemName ("Item <id>" with known = false while the client has no name).
local function describeItems(group)
    local preview = { kind = "item-group", entries = {}, notes = {} }
    local notes = {}
    for _, entry in ipairs(group.items or {}) do
        local row = { name = entryName(entry), message = entryMessage(entry), members = {} }
        for _, member in ipairs(entry.members) do
            local info = { slotID = member.slotID, itemID = member.itemID, known = true, icon = memberIcon(member) }
            if member.slotID then info.slotName = ns.slotName(member.slotID) end
            if member.itemID then
                local name = lookupItemName(member.itemID)
                info.itemName = name or ("Item " .. member.itemID)
                info.known = name ~= nil
            end
            row.members[#row.members + 1] = info
            local names, count = nil, 0
            if member.slotID then names, count = overlappingItemNames(member.slotID) end
            if names and count > 0 then
                local shown = table.concat(names, ", ")
                if count > #names then shown = shown .. " +" .. (count - #names) end
                notes[#notes + 1] = L("%s is already tracked in: %s. Both rules would announce it.", info.slotName, shown)
            end
        end
        preview.entries[#preview.entries + 1] = row
    end
    if #notes > MAX_NOTES then
        local more = #notes - (MAX_NOTES - 1)
        for i = #notes, MAX_NOTES, -1 do notes[i] = nil end
        notes[MAX_NOTES] = L("+ %d more", more)
    end
    preview.notes = notes
    return preview
end

-- Preview data: name, effect count, rows { spellID, name, icon, known }, unknown count, notes (translated),
-- texts { label, text } for every enabled, non-empty text the group would speak or show (stored form, "||" kept),
-- then the sound and the category cue of each event. An item group (meta.kind) gets describeItems instead.
function Share.Describe(group, meta)
    if meta and meta.kind == "item-group" then return describeItems(group) end
    local preview = { name = group.name or "", effects = 0, rows = {}, unknown = 0, notes = {}, texts = {} }
    local profiles = group.screenProfiles or {}
    addText(preview.texts, "Spoken on application", group.applyEnabled, group.applyMessage)
    addText(preview.texts, "Spoken on expiration", group.expireEnabled, group.expireMessage)
    addText(preview.texts, "Screen text on application", profiles.apply and profiles.apply.enabled,
        profiles.apply and profiles.apply.text)
    addText(preview.texts, "Screen text on expiration", profiles.expire and profiles.expire.enabled,
        profiles.expire and profiles.expire.text)
    addText(preview.texts, "On application", true, soundText(group, "apply"))
    addText(preview.texts, "On expiration", true, soundText(group, "expire"))
    addText(preview.texts, "On application", true, cueText(group.alertCategory))
    addText(preview.texts, "On expiration", true, cueText(group.expireCategory))
    local ownClass = playerClassToken()
    if meta and meta.class ~= nil and meta.class ~= ownClass then
        table.insert(preview.notes, L("This group was made for another class."))
    elseif meta and meta.class ~= nil and group.specializationIDs and specsBelongToPlayer(group.specializationIDs) == false then
        table.insert(preview.notes, L("Its specializations do not fit your class and are not imported."))
    end
    for _, spellID in ipairs(group.spellIDs or {}) do
        local name, icon = lookupSpell(spellID)
        local row = { spellID = spellID, known = name ~= nil, name = name, icon = icon }
        if not row.known then preview.unknown = preview.unknown + 1 end
        table.insert(preview.rows, row)
    end
    preview.effects = #preview.rows
    if preview.unknown > 0 then
        table.insert(preview.notes, L("%d spell IDs are unknown to this client.", preview.unknown))
    end
    local names, count = overlappingAuraNames(group.spellIDs)
    if names and count > 0 then
        local shown = table.concat(names, ", ")
        if count > #names then shown = shown .. " +" .. (count - #names) end
        table.insert(preview.notes, L("You already track some of these effects in: %s. Both groups would announce them.", shown))
    end
    return preview
end

-- Check button: preview (with .text, .group, .meta) or nil, error text.
function Share.Check(text)
    local ok, group, meta = Share.Parse(text)
    if not ok then return nil, group end
    local okPreview, preview = pcall(Share.Describe, group, meta)
    if not okPreview or type(preview) ~= "table" then return nil, ERR_INVALID end
    preview.text = text
    preview.group = group
    preview.meta = meta
    return preview
end

-- Import is enabled only for a passed check of exactly the text that is in the box now.
function Share.CanImport(preview, currentText)
    return type(preview) == "table" and preview.group ~= nil and preview.text == currentText
end
