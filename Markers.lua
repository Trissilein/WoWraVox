local _, ns = ...

-- Timeline markers of a rule: notification moments on 0..100 % of an effect's duration.
--   aura rules: "apply" at 0 (the effect starts), "expire" at 100 (the effect is gone), extra markers between
--   item / skill rules: "ready" at 100 (ready again), extra markers between
-- A marker is { key = "apply" | "expire" | "ready" | "beforeExpire" | "m<n>", at = 0..100 (float),
--               fromEnd = seconds before the end (optional; used instead of `at` when a duration is known) }.
-- The output settings of a marker stay flat on the rule under its key (<key>Enabled, <key>Message,
-- <key>SoundEnabled, ..., screenProfiles[<key>]), so sound, screen text and sharing code work for any key.
local Markers = {}
ns.Markers = Markers

local ENDPOINTS = {
    auras = { { key = "apply", at = 0 }, { key = "expire", at = 100 } },
    items = { { key = "ready", at = 100 } },
    skills = { { key = "ready", at = 100 } },
}

function Markers.IsEndpoint(key)
    return key == "apply" or key == "expire" or key == "ready"
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
            if not percent and tonumber(rule.beforeExpireSeconds) then marker.fromEnd = tonumber(rule.beforeExpireSeconds) end
            list[#list + 1] = marker
        end
    end
    local seen, clean = {}, {}
    for _, marker in ipairs(list) do
        if type(marker) == "table" and Markers.IsKey(marker.key) and not seen[marker.key] then
            seen[marker.key] = true
            local at = clampPercent(marker.at) or 50
            local fromEnd = tonumber(marker.fromEnd)
            clean[#clean + 1] = { key = marker.key, at = at, fromEnd = fromEnd and fromEnd >= 0 and fromEnd or nil }
        end
    end
    for _, endpoint in ipairs(endpoints) do
        if not seen[endpoint.key] then clean[#clean + 1] = { key = endpoint.key, at = endpoint.at } end
    end
    for _, marker in ipairs(clean) do
        for _, endpoint in ipairs(endpoints) do
            if marker.key == endpoint.key then marker.at, marker.fromEnd = endpoint.at, nil end
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
    return filtered
end

-- Position in seconds after the start for a known duration (nil when unknown).
function Markers.Seconds(marker, duration)
    duration = tonumber(duration)
    if not duration or duration <= 0 then return nil end
    if marker.fromEnd then return math.max(0, duration - marker.fromEnd) end
    return duration * marker.at / 100
end

-- Percent for a known duration (the fromEnd form resolves here).
function Markers.Percent(marker, duration)
    local seconds = Markers.Seconds(marker, duration)
    if seconds then return math.max(0, math.min(100, seconds / tonumber(duration) * 100)) end
    return marker.at
end

-- Moves a marker; endpoints stay put. `seconds` (from the start) wins over `at` when a duration is known.
function Markers.Move(rule, key, at, seconds, duration)
    for _, marker in ipairs(rule.markers or {}) do
        if marker.key == key and not Markers.IsEndpoint(key) then
            duration = tonumber(duration)
            if tonumber(seconds) and duration and duration > 0 then
                at = tonumber(seconds) / duration * 100
            end
            marker.at = clampPercent(at) or marker.at
            marker.fromEnd = nil
        end
    end
    table.sort(rule.markers, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.key < b.key
    end)
end

-- Adds an intermediate marker and returns its key.
function Markers.Add(rule, at)
    local used, n = {}, 1
    for _, marker in ipairs(rule.markers or {}) do used[marker.key] = true end
    while used["m" .. n] do n = n + 1 end
    local key = "m" .. n
    rule.markers = rule.markers or {}
    rule.markers[#rule.markers + 1] = { key = key, at = clampPercent(at) or 50 }
    Markers.Move(rule, key, clampPercent(at) or 50)
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
            return true
        end
    end
    return false
end

-- Intermediate markers only (the ones a timer has to fire).
function Markers.Intermediate(rule)
    local result = {}
    for _, marker in ipairs(rule.markers or {}) do
        if not Markers.IsEndpoint(marker.key) then result[#result + 1] = marker end
    end
    return result
end
