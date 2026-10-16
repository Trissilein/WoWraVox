local _, ns = ...
ns.ShareGroups = ns.ShareGroups or {}
local Share = ns.ShareGroups

-- Export and import of aura groups as text. Pure functions: no frames, no saved variables written here.
-- Format: "WVX1:" .. Base64(Deflate(CBOR({ v = 1, kind = "aura-group", class = <token>, group = {...} })))
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

local ERR_NOT_EXPORT = "Not a WoWraVox export."
local ERR_VERSION = "Unsupported export version."
local ERR_TOO_LARGE = "The export is too large."
local ERR_INVALID = "The export data is invalid."
local ERR_CLIENT = "This client cannot read exports."

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

local function exportRule(rule)
    if type(rule) ~= "table" then return false, ERR_INVALID end
    if rule.builtin then return false, "builtin" end
    local api = C_EncodingUtil
    if type(api) ~= "table" then return false, ERR_CLIENT end
    local group = sanitizeGroup(pickGroup(rule), true)
    if not group then return false, ERR_INVALID end
    local cbor = api.SerializeCBOR({ v = VERSION, kind = "aura-group", class = playerClassToken(), group = group })
    local packed = type(cbor) == "string" and api.CompressString(cbor) or nil
    local encoded = type(packed) == "string" and api.EncodeBase64(packed) or nil
    if type(encoded) ~= "string" or encoded == "" then return false, ERR_INVALID end
    return true, TOKEN .. encoded
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
    if payload.kind ~= "aura-group" then return nil, ERR_INVALID end
    local class = payload.class
    if class ~= nil and (type(class) ~= "string" or #class > 16 or not class:match("^%u+$")) then
        return nil, ERR_INVALID
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

-- ok, group, meta on success; ok=false, error text otherwise. Never runs or loads the text.
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

-- Name match against the existing aura rules, ignoring capitalisation and surrounding spaces.
local function auraNameExists(name)
    local auras = auraList()
    if not auras then return false end
    local wanted = nameKey(name)
    for _, rule in ipairs(auras) do
        if type(rule) == "table" and type(rule.name) == "string" and nameKey(rule.name) == wanted then return true end
    end
    return false
end

-- Name as it would be stored: " (2)", " (3)" ... appended while the name is taken. The base is cut so the result
-- stays within MAX_TEXT; a cut never splits a UTF-8 character or leaves a lone "|" (same rules as cleanText).
local function uniqueName(name)
    if not auraNameExists(name) then return name end
    local n = 2
    while true do
        local suffix = " (" .. n .. ")"
        local base = utf8Cut(name, MAX_TEXT - #suffix)
        local trailing = base:match("|*$") or ""
        if #trailing % 2 == 1 then base = base:sub(1, -2) end
        local candidate = trim(base) .. suffix
        if not auraNameExists(candidate) then return candidate end
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

-- Preview data: name, effect count, rows { spellID, name, icon, known }, unknown count, notes (translated),
-- texts { label, text } for every enabled, non-empty text the group would speak or show (stored form, "||" kept),
-- then the sound and the category cue of each event.
function Share.Describe(group, meta)
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
