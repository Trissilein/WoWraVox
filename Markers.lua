local _, ns = ...

-- Timeline markers of a rule: notification moments on 0..100 % of an effect's duration.
--   aura rules: "apply" at 0 (the effect starts), "expire" at 100 (the effect is gone), extra markers between
--   item / skill rules: "ready" at 100 (ready again), extra markers between
-- A marker is { key = "apply" | "expire" | "ready" | "beforeExpire" | "m<n>", at = 0..100 (float),
--               anchor = "percent" | "start" | "end", offset = seconds (for anchor start/end) }.
--   percent: `at` is the position; start: `offset` seconds after the start (needs no duration);
--   end: `offset` seconds before the end (needs a duration). `at` is kept as the drawn position for every anchor.
-- The output settings of a marker stay flat on the rule under its key (<key>Enabled, <key>Message,
-- <key>SoundEnabled, ..., screenProfiles[<key>]), so sound, screen text and sharing code work for any key.
local Markers = {}
ns.Markers = Markers

local ENDPOINTS = {
    auras = { { key = "apply", at = 0 }, { key = "expire", at = 100 } },
    items = { { key = "used", at = 0 }, { key = "ready", at = 100 } },
    skills = { { key = "used", at = 0 }, { key = "ready", at = 100 } },
}

function Markers.IsEndpoint(key)
    return key == "apply" or key == "expire" or key == "ready" or key == "used"
end

-- Any key whose output fields live on the rule.
function Markers.IsKey(key)
    return type(key) == "string" and (Markers.IsEndpoint(key) or key == "beforeExpire" or key:match("^m%d+$") ~= nil)
end

local function clampPercent(value)
    value = tonumber(value)
    if not value or value ~= value then return nil end
    return math.max(0, math.min(100, value))
end

-- Inner nodes stay strictly between the ends: 0 % is the start and 100 % the end, so an inner node there would only
-- duplicate them (and sit on top of their handle).
Markers.INNER_MIN, Markers.INNER_MAX = 0.5, 99.5
local function clampInner(value)
    value = clampPercent(value)
    if not value then return nil end
    return math.max(Markers.INNER_MIN, math.min(Markers.INNER_MAX, value))
end
Markers.ClampInner = clampInner

-- Builds rule.markers from the older fixed fields once, then keeps the list valid: endpoints present and
-- pinned, positions clamped, keys unique, sorted by position. Idempotent.
function Markers.Normalize(rule, category)
    local endpoints = ENDPOINTS[category] or ENDPOINTS.auras
    local list = type(rule.markers) == "table" and rule.markers or nil
    if not list then
        list = {}
        for _, endpoint in ipairs(endpoints) do list[#list + 1] = { key = endpoint.key, at = endpoint.at } end
        -- Codex' fixed "before expiry" warning becomes an ordinary marker (only when it was switched on).
        if category == "auras" and rule.beforeExpireEnabled == true then
            local percent = tonumber(rule.beforeExpirePercent)
            local marker = { key = "beforeExpire", at = percent and (100 - percent) or 95 }
            if not percent and tonumber(rule.beforeExpireSeconds) then
                marker.anchor, marker.offset = "end", tonumber(rule.beforeExpireSeconds)
            end
            list[#list + 1] = marker
        end
    end
    local seen, clean = {}, {}
    for _, marker in ipairs(list) do
        if type(marker) == "table" and Markers.IsKey(marker.key) and not seen[marker.key] then
            seen[marker.key] = true
            local at = clampInner(marker.at) or 50
            local anchor, offset = marker.anchor, tonumber(marker.offset)
            if tonumber(marker.fromEnd) then anchor, offset = "end", tonumber(marker.fromEnd) end -- older saves
            if anchor ~= "start" and anchor ~= "end" then anchor, offset = "percent", nil end
            if anchor ~= "percent" and not (offset and offset >= 0) then anchor, offset = "percent", nil end
            clean[#clean + 1] = { key = marker.key, at = at, anchor = anchor, offset = offset }
        end
    end
    for _, endpoint in ipairs(endpoints) do
        if not seen[endpoint.key] then clean[#clean + 1] = { key = endpoint.key, at = endpoint.at } end
    end
    for _, marker in ipairs(clean) do
        for _, endpoint in ipairs(endpoints) do
            if marker.key == endpoint.key then marker.at, marker.anchor, marker.offset = endpoint.at, nil, nil end
        end
    end
    -- Endpoints of the other category do not belong here (an aura rule has no "ready").
    local filtered = {}
    for _, marker in ipairs(clean) do
        local foreign = Markers.IsEndpoint(marker.key)
        for _, endpoint in ipairs(endpoints) do if endpoint.key == marker.key then foreign = false end end
        if not foreign then filtered[#filtered + 1] = marker end
    end
    table.sort(filtered, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.key < b.key
    end)
    rule.markers = filtered
    Markers.PruneOverrides(rule)
    return filtered
end

local function sortMarkers(list)
    table.sort(list, function(x, y)
        if x.at ~= y.at then return x.at < y.at end
        return x.key < y.key
    end)
end

-- Position in seconds after the start, or nil when it needs a duration that is unknown.
-- Anchor "start" needs no duration.
function Markers.Seconds(marker, duration)
    duration = tonumber(duration)
    local known = duration and duration > 0
    if marker.anchor == "start" and marker.offset then return marker.offset end
    if not known then return nil end
    if marker.anchor == "end" and marker.offset then return math.max(0, duration - marker.offset) end
    return duration * marker.at / 100
end

-- Percent on the line: computed from the seconds when a duration is known, else the stored position.
function Markers.Percent(marker, duration)
    duration = tonumber(duration)
    if marker.anchor and marker.anchor ~= "percent" and duration and duration > 0 then
        local seconds = Markers.Seconds(marker, duration)
        if seconds then return clampInner(seconds / duration * 100) end
    end
    return marker.at
end

-- Brings the drawn positions of second-based nodes in line with a known duration, then re-sorts.
function Markers.Resolve(rule, duration)
    for _, marker in ipairs(rule.markers or {}) do
        if not Markers.IsEndpoint(marker.key) then marker.at = Markers.Percent(marker, duration) end
    end
    sortMarkers(rule.markers or {})
end

-- Moves a marker on the line (drag); endpoints stay put. A second-based node keeps its anchor and gets the
-- matching seconds when the duration is known. `seconds` (after the start) wins over `at` for percent nodes.
function Markers.Move(rule, key, at, seconds, duration)
    duration = tonumber(duration)
    for _, marker in ipairs(rule.markers or {}) do
        if marker.key == key and not Markers.IsEndpoint(key) then
            if tonumber(seconds) and duration and duration > 0 then at = tonumber(seconds) / duration * 100 end
            marker.at = clampInner(at) or marker.at
            if marker.anchor == "start" and duration and duration > 0 then
                marker.offset = duration * marker.at / 100
            elseif marker.anchor == "end" and duration and duration > 0 then
                marker.offset = duration * (100 - marker.at) / 100
            end
        end
    end
    sortMarkers(rule.markers)
end

-- Sets the timing of a node: anchor "percent" (value = %), "start" (value = s after start), "end" (s before end).
function Markers.SetTiming(rule, key, anchor, value, duration)
    value = tonumber(value)
    for _, marker in ipairs(rule.markers or {}) do
        if marker.key == key and not Markers.IsEndpoint(key) then
            if anchor == "start" or anchor == "end" then
                marker.anchor = anchor
                if value then marker.offset = math.max(0, value) end
                if not marker.offset then
                    local d = tonumber(duration)
                    if d and d > 0 then
                        marker.offset = anchor == "start" and d * marker.at / 100 or d * (100 - marker.at) / 100
                    else
                        marker.offset = 1
                    end
                end
                marker.at = Markers.Percent(marker, duration)
            else
                marker.anchor, marker.offset = "percent", nil
                if value then marker.at = clampInner(value) or marker.at end
            end
        end
    end
    sortMarkers(rule.markers)
end

-- Short timing text of a node: "90 %", "+2 s" (after start), "-2 s" (before end).
function Markers.TimingText(marker, format)
    format = format or function(v) return tostring(v) end
    if marker.anchor == "start" and marker.offset then return "+" .. format(marker.offset) .. " s" end
    if marker.anchor == "end" and marker.offset then return "-" .. format(marker.offset) .. " s" end
    return format(marker.at) .. " %"
end

-- Adds an intermediate marker and returns its key.
function Markers.Add(rule, at)
    local used, n = {}, 1
    for _, marker in ipairs(rule.markers or {}) do used[marker.key] = true end
    while used["m" .. n] do n = n + 1 end
    local key = "m" .. n
    rule.markers = rule.markers or {}
    rule.markers[#rule.markers + 1] = { key = key, at = clampInner(at) or 50, anchor = "percent" }
    Markers.Move(rule, key, clampInner(at) or 50)
    return key
end

-- Removes an intermediate marker and its output fields. Endpoints cannot be removed (only switched off).
function Markers.Remove(rule, key)
    if Markers.IsEndpoint(key) then return false end
    for index, marker in ipairs(rule.markers or {}) do
        if marker.key == key then
            table.remove(rule.markers, index)
            for _, suffix in ipairs({ "Enabled", "Message", "SoundEnabled", "SoundMediaName", "SoundKitID", "SoundChannel",
                "Category", "Percent", "Seconds", "ScreenEnabled", "ScreenText" }) do
                rule[key .. suffix] = nil
            end
            if type(rule.screenProfiles) == "table" then rule.screenProfiles[key] = nil end
            for _, bySpell in pairs(type(rule.markerOverrides) == "table" and rule.markerOverrides or {}) do bySpell[key] = nil end
            Markers.PruneOverrides(rule)
            return true
        end
    end
    return false
end

-- Per-spell overrides of a group rule: rule.markerOverrides[spellID][key] = { at, anchor, offset }. A spell without
-- an override follows the group marker; an override keeps the anchor (a "5 s before end" node stays seconds-based).
local function findMarker(rule, key)
    for _, marker in ipairs(rule.markers or {}) do
        if marker.key == key then return marker end
    end
end

function Markers.GetOverride(rule, spellID, key)
    local bySpell = type(rule.markerOverrides) == "table" and rule.markerOverrides[spellID]
    return type(bySpell) == "table" and bySpell[key] or nil
end

-- Marker as seen by one spell: the override when set, else the group marker itself.
function Markers.Effective(rule, spellID, key)
    local base = findMarker(rule, key)
    if not base then return nil end
    local override = Markers.GetOverride(rule, spellID, key)
    if not override then return base, false end
    -- off: this spell does not use the node at all (third result true).
    if override.off then return nil, true, true end
    return { key = key, at = override.at, anchor = override.anchor, offset = override.offset }, true
end

function Markers.IsOff(rule, spellID, key)
    local override = Markers.GetOverride(rule, spellID, key)
    return override ~= nil and override.off == true
end

-- Removes a node for one spell only (the group node and the other spells keep it). ClearOverride brings it back.
function Markers.DisableOverride(rule, spellID, key)
    if spellID == nil or Markers.IsEndpoint(key) or not findMarker(rule, key) then return false end
    rule.markerOverrides = type(rule.markerOverrides) == "table" and rule.markerOverrides or {}
    rule.markerOverrides[spellID] = type(rule.markerOverrides[spellID]) == "table" and rule.markerOverrides[spellID] or {}
    rule.markerOverrides[spellID][key] = { off = true }
    return true
end

-- A new node that exists for one spell only: off for every other spell of the rule.
function Markers.AddOnlyFor(rule, spellID, at)
    local key = Markers.Add(rule, at)
    for _, id in ipairs(rule.spellIDs or {}) do
        if id ~= spellID then Markers.DisableOverride(rule, id, key) end
    end
    return key
end

-- The group's marker list resolved for one spell (a fresh list; the rule is not changed).
function Markers.ForSpell(rule, spellID)
    local list = {}
    for _, marker in ipairs(rule.markers or {}) do
        local effective = Markers.Effective(rule, spellID, marker.key)
        if effective then list[#list + 1] = effective end
    end
    return list
end

-- Sets/moves the override of one spell. `apply(temp, key)` edits a temporary one-marker rule with the existing
-- SetTiming/Move logic, so the anchor rules stay in one place.
local function editOverride(rule, spellID, key, apply)
    local base = findMarker(rule, key)
    if not base or Markers.IsEndpoint(key) or spellID == nil then return false end
    local current = Markers.Effective(rule, spellID, key) or base
    local temp = { markers = { { key = key, at = current.at, anchor = current.anchor, offset = current.offset } } }
    apply(temp, key)
    local marker = temp.markers[1]
    rule.markerOverrides = type(rule.markerOverrides) == "table" and rule.markerOverrides or {}
    rule.markerOverrides[spellID] = type(rule.markerOverrides[spellID]) == "table" and rule.markerOverrides[spellID] or {}
    rule.markerOverrides[spellID][key] = { at = marker.at, anchor = marker.anchor, offset = marker.offset }
    return true
end

function Markers.SetOverrideTiming(rule, spellID, key, anchor, value, duration)
    return editOverride(rule, spellID, key, function(temp, k)
        local marker = temp.markers[1]
        Markers.SetTiming(temp, k, anchor or marker.anchor or "percent", value, duration)
    end)
end

function Markers.MoveOverride(rule, spellID, key, at, duration)
    return editOverride(rule, spellID, key, function(temp, k) Markers.Move(temp, k, at, nil, duration) end)
end

function Markers.ClearOverride(rule, spellID, key)
    local bySpell = type(rule.markerOverrides) == "table" and rule.markerOverrides[spellID]
    if type(bySpell) ~= "table" or bySpell[key] == nil then return false end
    bySpell[key] = nil
    if next(bySpell) == nil then rule.markerOverrides[spellID] = nil end
    if next(rule.markerOverrides) == nil then rule.markerOverrides = nil end
    return true
end

function Markers.OverrideCount(rule)
    local count = 0
    for _, bySpell in pairs(type(rule.markerOverrides) == "table" and rule.markerOverrides or {}) do
        for _ in pairs(bySpell) do count = count + 1 end
    end
    return count
end

-- Drops overrides whose marker or spell is gone (call after Normalize / when triggers change).
function Markers.PruneOverrides(rule)
    if type(rule.markerOverrides) ~= "table" then return end
    local spells = {}
    for _, id in ipairs(rule.spellIDs or {}) do spells[id] = true end
    for spellID, bySpell in pairs(rule.markerOverrides) do
        if type(bySpell) ~= "table" or (next(spells) and not spells[spellID]) then
            rule.markerOverrides[spellID] = nil
        else
            for key in pairs(bySpell) do
                local marker = findMarker(rule, key)
                if not marker or Markers.IsEndpoint(key) then bySpell[key] = nil end
            end
            if next(bySpell) == nil then rule.markerOverrides[spellID] = nil end
        end
    end
    if next(rule.markerOverrides) == nil then rule.markerOverrides = nil end
end

-- Intermediate markers only (the ones a timer has to fire).
function Markers.Intermediate(rule)
    local result = {}
    for _, marker in ipairs(rule.markers or {}) do
        if not Markers.IsEndpoint(marker.key) then result[#result + 1] = marker end
    end
    return result
end
