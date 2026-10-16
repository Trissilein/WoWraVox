local _, ns = ...
ns.ShareChat = ns.ShareChat or {}
local Chat = ns.ShareChat

-- Chat link for sharing aura groups. The export text never goes into chat (255 character limit, no addon links
-- across players). The sender puts a short marker "[WoWraVox: <Name> #<8 hex>]" into the chat box and keeps the
-- export text as an offer in memory. Every client with this addon rewrites the marker into a local link
-- (chat filter). A click asks the sender by addon whisper (prefix WVX) for the text, which comes back in small parts.
-- The finished text opens the same import window as the pasted text (ShareGroups.Parse checks it again).
-- Nothing is accepted that this client did not ask for, nothing is executed, and everything stays quiet during
-- encounters, Mythic+ and PvP, where Blizzard blocks addon messages and chat reading.
-- Logic and event wiring are separate: the Chat.* functions are plain and testable, Chat.Install() wires the client.

local PREFIX = "WVX"
local LINK_PREFIX = "addon:WoWraVox:import:"
local MAX_PART = 200           -- bytes of export text per message; the header adds about 22, the limit is 255
local FALLBACK_TOTAL = 8192    -- used when ShareGroups.MAX_INPUT is missing
local OFFER_TTL = 600
local MAX_OFFERS = 5
local REQUEST_TIMEOUT = 15     -- moves on with every accepted part
local REQUEST_LIMIT = 60       -- hard limit for one request, however many parts keep coming
local CLICK_DEDUPE = 0.25      -- the same link firing twice within this many seconds counts as one click
local SEND_INTERVAL = 0.15
local THROTTLE_RETRY = 1
local MAX_RETRIES = 5
local REPLY_COOLDOWN = 5       -- per asker, whatever the code
local MAX_QUEUE = 200          -- outgoing messages waiting; new requests are ignored beyond this
local MAX_REPLIES = 100        -- askers remembered for the cooldown
local FILTER_LOG_MAX = 30      -- /wvdebug lines from the chat filter per session, so chat cannot flood the log
local NAME_MAX = 30
local SENDER_MAX = 64
local MARKER_PATTERN = "%[WoWraVox: ([^%[%]|]+) #(%x%x%x%x%x%x%x%x)%]"
local TEXT_CHARS = "^[%w%+/=:_%-]+$" -- "WVX1:" and Base64: nothing else may travel
local BLOCKED = "Sharing is blocked during encounters, Mythic+ and PvP."
local RESTRICTION_KEYS = { "Encounter", "ChallengeMode", "PvPMatch", "Chat" }
local FILTER_EVENTS = {
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
    "CHAT_MSG_WHISPER", "CHAT_MSG_SAY", "CHAT_MSG_YELL",
}

-- Same limit as the pasted text in ShareGroups.lua. Read once at load (ShareGroups.lua loads first); tests may override it.
local shareGroups = ns.ShareGroups
Chat.PREFIX = PREFIX
Chat.MAX_PART = MAX_PART
Chat.MAX_TOTAL = type(shareGroups) == "table" and type(shareGroups.MAX_INPUT) == "number" and shareGroups.MAX_INPUT or FALLBACK_TOTAL
Chat.MAX_QUEUE = MAX_QUEUE
Chat.MAX_REPLIES = MAX_REPLIES
Chat.offers = {}
Chat.offerOrder = {}
Chat.queue = {}
Chat.lastReply = {}
Chat.replyCount = 0
Chat.replyPruned = -math.huge
Chat.pending = nil
Chat.lastClick = nil
Chat.filterLogLines = 0

local function L(key, ...)
    local text = ns.L and ns.L(key) or key
    if select("#", ...) > 0 then return string.format(text, ...) end
    return text
end

local function now()
    if type(GetTime) == "function" then return GetTime() end
    return 0
end

local function isSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value) == true
end

local function plainString(value)
    return not isSecret(value) and type(value) == "string"
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Cuts to max bytes without leaving half of a multi-byte character.
local function utf8Cut(s, max)
    if #s <= max then return s end
    local nextByte = s:byte(max + 1)
    if nextByte and nextByte >= 0x80 and nextByte < 0xC0 then
        local i = max
        while i > 0 do
            local b = s:byte(i)
            if b < 0x80 or b >= 0xC0 then break end
            i = i - 1
        end
        return s:sub(1, i - 1)
    end
    return s:sub(1, max)
end

local function normCode(code)
    if type(code) == "string" and code:match("^%x%x%x%x%x%x%x%x$") then return code:lower() end
    return nil
end

local function maxParts()
    return math.ceil(Chat.MAX_TOTAL / MAX_PART)
end

-- Realm of this player ("" when the client does not say). A name without a realm belongs to this realm.
local function selfRealm()
    for _, getter in ipairs({ "GetNormalizedRealmName", "GetRealmName" }) do
        local fn = _G[getter]
        if type(fn) == "function" then
            local ok, realm = pcall(fn)
            if ok and type(realm) == "string" and realm ~= "" then return realm end
        end
    end
    return nil
end

-- "name-realm", lower case, spaces and hyphens gone from the realm; nil for anything that is not a plain name.
-- A missing realm becomes the own realm, so "Bob" and "Bob-OtherRealm" never match each other.
local function normalizeSender(full)
    if not plainString(full) or full == "" then return nil end
    local name, realm = full:match("^([^%-]+)%-(.+)$")
    if not name then name = full end
    realm = realm or selfRealm()
    return name:lower() .. "-" .. (realm and realm:lower():gsub("[%s%-]", "") or "")
end

local function sameSender(a, b)
    local keyA, keyB = normalizeSender(a), normalizeSender(b)
    return keyA ~= nil and keyA == keyB
end

local function selfName()
    if type(UnitName) ~= "function" then return nil end
    local ok, name = pcall(UnitName, "player")
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

function Chat.notify(text, isError)
    if not DEFAULT_CHAT_FRAME then return end
    DEFAULT_CHAT_FRAME:AddMessage("|cffd8b65aWoWraVox:|r " .. (isError and "|cffff6040" .. text .. "|r" or text))
end

-- Timer indirection so tests can run delayed work by hand. Returns false when there is no timer (the work does not run).
function Chat.After(seconds, fn)
    if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
        C_Timer.After(seconds, fn)
        return true
    end
    return false
end

-- true while the client blocks addon messages and chat reading (encounter, Mythic+, PvP match, chat lockdown).
-- Combat and Map restrictions are not checked: they do not block addon whispers. Missing APIs count as not restricted.
function Chat.Restricted()
    if type(C_ChatInfo) == "table" and type(C_ChatInfo.InChatMessagingLockdown) == "function" then
        local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
        if ok and locked == true then return true, "chat" end
    end
    if type(C_RestrictedActions) == "table" and type(C_RestrictedActions.GetAddOnRestrictionState) == "function"
        and type(Enum) == "table" and type(Enum.AddOnRestrictionType) == "table" then
        for _, key in ipairs(RESTRICTION_KEYS) do
            local kind = Enum.AddOnRestrictionType[key]
            if kind ~= nil then
                local ok, state = pcall(C_RestrictedActions.GetAddOnRestrictionState, kind)
                if ok and type(state) == "number" and state > 0 then return true, key end
            end
        end
    end
    return false
end

-- Debug log (/wvdebug on). Lines go to the same buffer as the other debug lines (AuraSoundFallback.Log). Silent when
-- debug is off or the logger is missing. Nothing here raises or changes what the client sees.
local function debugOn()
    local fallback = ns.AuraSoundFallback
    return type(fallback) == "table" and fallback.debugEnabled == true and type(fallback.Log) == "function"
end

-- Format arguments must already be strings (Lua 5.1 %s rejects booleans and nil).
local function debugLine(category, format, ...)
    if not debugOn() then return end
    pcall(function(...)
        ns.AuraSoundFallback.Log(category, string.format(format, ...))
    end, ...)
end

-- Only for messages that are secret (or not a string) or that contain a marker. marker=? when msg is not plain.
local function logFilter(event, msg, author, rewritten)
    local plain = plainString(msg)
    local marker
    if plain then marker = msg:match(MARKER_PATTERN) ~= nil end
    if plain and not marker then return end
    if Chat.filterLogLines >= FILTER_LOG_MAX then return end
    Chat.filterLogLines = Chat.filterLogLines + 1
    debugLine("CHAT-FILTER", "%s msgSecret=%s msgType=%s authorSecret=%s restricted=%s marker=%s rewritten=%s",
        type(event) == "string" and event or "?", tostring(isSecret(msg)), type(msg), tostring(isSecret(author)),
        tostring((Chat.Restricted())), marker == nil and "?" or tostring(marker), tostring(rewritten == true))
end

-- Marker and offers (sender side)

local function cleanMarkerName(name)
    local s = type(name) == "string" and name or ""
    s = trim((s:gsub("[%c|%[%]]", "")))
    s = trim(utf8Cut(s, NAME_MAX))
    if s == "" then s = L("New aura group") end
    return s
end

function Chat.BuildMarker(name, code)
    code = normCode(code)
    if not code then return nil end
    return string.format("[WoWraVox: %s #%s]", cleanMarkerName(name), code)
end

local function newCode()
    for _ = 1, 20 do
        local code = string.format("%04x%04x", math.random(0, 65535), math.random(0, 65535))
        if not Chat.offers[code] then return code end
    end
    return nil
end

local function dropOffer(code)
    Chat.offers[code] = nil
    for index, value in ipairs(Chat.offerOrder) do
        if value == code then
            table.remove(Chat.offerOrder, index)
            break
        end
    end
end

-- Offers expire when they are read; no timer. Returns the offer, or nil and "expired" / "unknown".
local function lookupOffer(code)
    local offer = Chat.offers[code]
    if not offer then return nil, "unknown" end
    if now() >= offer.expires then
        dropOffer(code)
        return nil, "expired"
    end
    return offer
end

-- code, marker; or nil, error text. Offering the same text again refreshes the old offer.
function Chat.MakeOffer(text, name)
    if not plainString(text) or text == "" or text:sub(1, 5) ~= "WVX1:" or not text:match(TEXT_CHARS) then
        return nil, "The export data is invalid."
    end
    if #text > Chat.MAX_TOTAL then return nil, "The export is too large." end
    for index = #Chat.offerOrder, 1, -1 do
        lookupOffer(Chat.offerOrder[index]) -- drops the offer when it has expired
    end
    local code
    for _, existing in ipairs(Chat.offerOrder) do
        if Chat.offers[existing].text == text then code = existing end
    end
    if not code then
        code = newCode()
        if not code then return nil, "The export data is invalid." end
        while #Chat.offerOrder >= MAX_OFFERS do dropOffer(Chat.offerOrder[1]) end
        Chat.offerOrder[#Chat.offerOrder + 1] = code
    end
    Chat.offers[code] = { text = text, expires = now() + OFFER_TTL }
    return code, Chat.BuildMarker(name, code)
end

function Chat.ChunkText(text)
    local parts = {}
    if type(text) ~= "string" or text == "" then return parts end
    for first = 1, #text, MAX_PART do parts[#parts + 1] = text:sub(first, first + MAX_PART - 1) end
    return parts
end

-- Opens the chat box with the text in it. The player picks the channel and presses Enter.
function Chat.OpenChat(text)
    local fn = type(ChatFrameUtil) == "table" and ChatFrameUtil.OpenChat or nil
    if type(fn) ~= "function" then fn = ChatFrame_OpenChat end
    if type(fn) ~= "function" then return false end
    return (pcall(fn, text))
end

local function sendToChat(text, name)
    if Chat.Restricted() then
        Chat.notify(L(BLOCKED), true)
        return false, "blocked"
    end
    local code, marker = Chat.MakeOffer(text, name)
    if not code then
        Chat.notify(L(marker), true)
        return false, "invalid"
    end
    if not Chat.OpenChat(marker) then
        Chat.notify(L("The chat box is unavailable."), true)
        return false, "nochat"
    end
    Chat.notify(L("Link placed in the chat box. Press Enter to send it."))
    return true, marker
end

function Chat.SendToChat(text, name)
    local ok, result, detail = pcall(sendToChat, text, name)
    if not ok then return false, "error" end
    return result, detail
end

-- Receiving a marker (chat filter)

-- Returns the message with every valid marker turned into a local link, and true when something changed.
-- Secret values, other types and messages without a marker come back untouched.
function Chat.RewriteMessage(msg, author)
    if not plainString(msg) or not plainString(author) then return msg, false end
    if not msg:find("[WoWraVox: ", 1, true) then return msg, false end
    local sender = trim((author:gsub("[%c|:%[%]]", "")))
    if sender == "" then return msg, false end
    if not sender:find("-", 1, true) then
        local realm = selfRealm() -- the filter only sees "Name" for players of this realm; the click needs "Name-Realm"
        realm = realm and realm:gsub("[%c|:%[%]%s%-]", "")
        if realm and realm ~= "" then sender = sender .. "-" .. realm end
    end
    sender = utf8Cut(sender, SENDER_MAX)
    if Chat.Restricted() then return msg, false end
    local changed = false
    local result = msg:gsub(MARKER_PATTERN, function(name, code)
        local shown = trim(utf8Cut((name:gsub("%c", "")), NAME_MAX))
        if shown == "" then return nil end
        changed = true
        return string.format("|cff00ccff|Haddon:WoWraVox:import:%s:%s|h[WoWraVox: %s]|h|r", code:lower(), sender, shown)
    end)
    if not changed then return msg, false end
    return result, true
end

function Chat.Filter(_, event, msg, author, ...)
    local ok, result, changed = pcall(Chat.RewriteMessage, msg, author)
    local rewritten = ok and changed == true
    if debugOn() then pcall(logFilter, event, msg, author, rewritten) end
    if rewritten then return false, result, author, ... end
    return false
end

-- Link click (receiver side)

function Chat.ParseLink(link)
    if not plainString(link) then return nil end
    local code, sender = link:match("^" .. LINK_PREFIX .. "(%x%x%x%x%x%x%x%x):([^:|]+)$")
    if not code then return nil end
    return code:lower(), sender
end

local function endRequest(pending)
    if Chat.pending == pending then Chat.pending = nil end
end

-- The timeout moves on with every accepted part (pending.expires), so the timer checks again when it fires early.
local function expireRequest(pending)
    if Chat.pending ~= pending then return end
    local remaining = pending.expires - now()
    if remaining > 0.05 then
        Chat.After(remaining, function() expireRequest(pending) end)
        return
    end
    Chat.pending = nil
    Chat.notify(L("No answer from %s. They may be offline or in combat content.", pending.sender), true)
end

local function startRequest(code, sender)
    local started = now()
    local pending = { code = code, sender = sender, expires = started + REQUEST_TIMEOUT, limit = started + REQUEST_LIMIT,
        parts = {}, count = 0, total = 0 }
    Chat.pending = pending
    local result, raw = Chat.SendAddon("REQ:" .. code, sender)
    debugLine("CHAT-REQ", "code=%s to=%s result=%s raw=%s", code, tostring(sender), tostring(result), tostring(raw))
    if result ~= "ok" then
        endRequest(pending)
        if result == "lockdown" then
            Chat.notify(L(BLOCKED), true)
        else
            Chat.notify(L("Could not send the request to %s.", sender), true)
        end
        return false
    end
    Chat.notify(L("Requesting group from %s ...", sender))
    Chat.After(REQUEST_TIMEOUT, function() expireRequest(pending) end)
    return true
end

local function openImport(text)
    if ns.ShareUI and type(ns.ShareUI.openImport) == "function" then ns.ShareUI.openImport(text) end
end

local function handleLink(link)
    local code, sender = Chat.ParseLink(link)
    if not code then return false end
    -- EventRegistry and the SetItemRef hook may both fire for one click: the same link twice in a moment is one click.
    local t = now()
    local last = Chat.lastClick
    if last and last.link == link and t >= last.at and t - last.at < CLICK_DEDUPE then return true end
    Chat.lastClick = { link = link, at = t }
    local own = lookupOffer(code)
    if own and sameSender(sender, selfName()) then
        debugLine("CHAT-LINK", "code=%s own=true", code)
        openImport(own.text)
        return true
    end
    local blocked = Chat.Restricted()
    debugLine("CHAT-LINK", "code=%s own=false restricted=%s", code, tostring(blocked == true))
    if blocked then
        Chat.notify(L(BLOCKED), true)
        return true
    end
    local open = Chat.pending
    if open and t < open.expires then
        if open.code == code and sameSender(open.sender, sender) then
            Chat.notify(L("Already requesting this group."))
            return true
        end
        Chat.notify(L("Request to %s cancelled.", open.sender))
    end
    endRequest(open)
    startRequest(code, sender)
    return true
end

function Chat.OnLink(link)
    local ok, handled = pcall(handleLink, link)
    return ok and handled == true
end

-- Wire messages

-- "ok", "throttle", "lockdown", "unavailable" or "failed" (+ the raw result). Success only means queued by the client.
function Chat.SendAddon(message, target)
    if type(C_ChatInfo) ~= "table" or type(C_ChatInfo.SendAddonMessage) ~= "function" then return "unavailable", "missing" end
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, message, "WHISPER", target)
    if not ok then return "failed", "error" end
    local results = type(Enum) == "table" and Enum.SendAddonMessageResult or nil
    local success = results and results.Success or 0
    local throttle = results and results.AddonMessageThrottle or 3
    local lockdown = results and results.AddOnMessageLockdown or 11
    if result == true or result == success then return "ok", result end
    if result == throttle then return "throttle", result end
    if result == lockdown then return "lockdown", result end
    return "failed", result
end

-- Drops every waiting message for one target (a failed send to them says nothing about the others).
local function dropTarget(target)
    local keep = {}
    for _, entry in ipairs(Chat.queue) do
        if entry.target ~= target then keep[#keep + 1] = entry end
    end
    Chat.queue = keep
end

local function step()
    local entry = Chat.queue[1]
    if not entry then
        Chat.pumping = false
        return
    end
    local result = Chat.SendAddon(entry.message, entry.target)
    local delay = SEND_INTERVAL
    if result == "ok" then
        table.remove(Chat.queue, 1)
    elseif result == "throttle" and entry.tries < MAX_RETRIES then
        entry.tries = entry.tries + 1
        delay = THROTTLE_RETRY
    elseif result == "lockdown" or result == "unavailable" then
        Chat.queue = {} -- not about one target: every other send would fail the same way
    else
        dropTarget(entry.target)
    end
    if Chat.After(delay, step) == false then
        Chat.queue = {}
        Chat.pumping = false
    end
end

-- One message per SEND_INTERVAL; the first goes out at once. A failed send drops the rest for that target only.
function Chat.Pump()
    if Chat.pumping then return end
    Chat.pumping = true
    step()
end

local function enqueue(target, message)
    Chat.queue[#Chat.queue + 1] = { target = target, message = message, tries = 0 }
end

-- One answer per asker every REPLY_COOLDOWN seconds, whatever code they ask for. At most MAX_REPLIES askers are
-- remembered; when the table is full, expired ones are dropped (at most once a second) and a new asker has to wait.
local function claimReply(key, t)
    local last = Chat.lastReply[key]
    if last and t - last < REPLY_COOLDOWN then return false end
    if last == nil then
        if Chat.replyCount >= MAX_REPLIES then
            if t - Chat.replyPruned < 1 then return false end
            Chat.replyPruned = t
            for known, stamp in pairs(Chat.lastReply) do
                if t - stamp >= REPLY_COOLDOWN then
                    Chat.lastReply[known] = nil
                    Chat.replyCount = Chat.replyCount - 1
                end
            end
            if Chat.replyCount >= MAX_REPLIES then return false end
        end
        Chat.replyCount = Chat.replyCount + 1
    end
    Chat.lastReply[key] = t
    return true
end

local function handleRequest(sender, code)
    code = normCode(code)
    if not plainString(sender) or sender == "" or #sender > SENDER_MAX or not code then return "ignored" end
    if Chat.Restricted() then return "blocked" end
    local key = normalizeSender(sender)
    if not key or #Chat.queue >= MAX_QUEUE then return "ignored" end
    local offer, why = lookupOffer(code)
    local count = offer and math.ceil(#offer.text / MAX_PART) or 0
    if offer and (count == 0 or count > maxParts()) then offer, why = nil, "toolarge" end
    if #Chat.queue + (offer and count or 1) > MAX_QUEUE then return "ignored" end
    if not claimReply(key, now()) then return "ignored" end
    local parts = offer and Chat.ChunkText(offer.text) or {}
    if not offer then
        enqueue(sender, string.format("ERR:%s:%s", code, why))
        Chat.Pump()
        return "err:" .. why
    end
    for index, part in ipairs(parts) do
        enqueue(sender, string.format("DATA:%s:%d/%d:%s", code, index, #parts, part))
    end
    Chat.Pump()
    return "ok", #parts
end

function Chat.HandleRequest(sender, code)
    local ok, result, count = pcall(handleRequest, sender, code)
    if not ok then return "error" end
    return result, count
end

-- Returns "ok", "dup", "ignored", "complete" (+ text) or "abort". Only for the one open request of this client.
local function handleData(sender, index, total, code, part)
    local pending = Chat.pending
    code = normCode(code)
    if not pending or not code or pending.code ~= code or not sameSender(pending.sender, sender) then return "ignored" end
    local t = now()
    if t >= pending.expires then return "ignored" end
    if type(index) ~= "number" or type(total) ~= "number" or index ~= math.floor(index) or total ~= math.floor(total)
        or total < 1 or total > maxParts() or index < 1 or index > total then
        return "ignored"
    end
    if not plainString(part) or part == "" or #part > MAX_PART or not part:match(TEXT_CHARS) then return "ignored" end
    if pending.declared ~= nil and pending.declared ~= total then return "ignored" end
    pending.declared = total
    if pending.parts[index] then return "dup" end
    if pending.total + #part > Chat.MAX_TOTAL then
        endRequest(pending)
        Chat.notify(L("The export is too large."), true)
        return "abort"
    end
    pending.parts[index] = part
    pending.count = pending.count + 1
    pending.total = pending.total + #part
    pending.expires = math.min(t + REQUEST_TIMEOUT, pending.limit) -- every accepted part moves the timeout on
    if pending.count < total then return "ok" end
    endRequest(pending)
    local text = table.concat(pending.parts, "", 1, total)
    Chat.notify(L("Group received from %s. Check it, then import.", pending.sender))
    openImport(text)
    return "complete", text
end

function Chat.HandleData(sender, index, total, code, part)
    local ok, result, text = pcall(handleData, sender, index, total, code, part)
    if not ok then return "error" end
    return result, text
end

local function handleError(sender, code, reason)
    local pending = Chat.pending
    code = normCode(code)
    if not pending or not code or pending.code ~= code or not sameSender(pending.sender, sender) then return "ignored" end
    endRequest(pending)
    if reason == "toolarge" then
        Chat.notify(L("The export is too large."), true)
    else
        Chat.notify(L("%s no longer offers this group. Ask them to share it again.", pending.sender), true)
    end
    return "failed"
end

function Chat.HandleError(sender, code, reason)
    local ok, result = pcall(handleError, sender, code, reason)
    if not ok then return "error" end
    return result
end

-- CHAT_MSG_ADDON: whispers with our prefix only. Secret values are ignored.
function Chat.OnAddonMessage(prefix, text, channel, sender)
    local ok, result = pcall(function()
        if not plainString(prefix) or prefix ~= PREFIX or not plainString(channel) or channel ~= "WHISPER" then return nil end
        if not plainString(text) or not plainString(sender) or sender == "" or #text > 255 then return nil end
        local code = text:match("^REQ:(%x%x%x%x%x%x%x%x)$")
        if code then return Chat.HandleRequest(sender, code) end
        local dataCode, index, total, part = text:match("^DATA:(%x%x%x%x%x%x%x%x):(%d%d?%d?%d?)/(%d%d?%d?%d?):(.+)$")
        if dataCode then return Chat.HandleData(sender, tonumber(index), tonumber(total), dataCode, part) end
        local errCode, reason = text:match("^ERR:(%x%x%x%x%x%x%x%x):(%a+)$")
        if errCode then return Chat.HandleError(sender, errCode, reason) end
        return nil
    end)
    if not ok then return "error" end
    return result
end

-- Client wiring. Safe to call again; each step runs once and is skipped when its API is missing.
function Chat.Install()
    local done = Chat.installed or {}
    Chat.installed = done
    if not done.prefix and type(C_ChatInfo) == "table" and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function" then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
        done.prefix = true
    end
    if not done.frame and type(CreateFrame) == "function" then
        local ok, frame = pcall(CreateFrame, "Frame")
        if ok and type(frame) == "table" and type(frame.RegisterEvent) == "function" and type(frame.SetScript) == "function" then
            frame:RegisterEvent("CHAT_MSG_ADDON")
            frame:SetScript("OnEvent", function(_, event, ...)
                if event == "CHAT_MSG_ADDON" then Chat.OnAddonMessage(...) end
            end)
            Chat.eventFrame = frame
            done.frame = true
        end
    end
    if not done.filters then
        local add = ChatFrame_AddMessageEventFilter
        if type(add) ~= "function" and type(ChatFrameUtil) == "table" then add = ChatFrameUtil.AddMessageEventFilter end
        if type(add) == "function" then
            for _, event in ipairs(FILTER_EVENTS) do pcall(add, event, Chat.Filter) end
            done.filters = true
        end
    end
    -- Both click paths are wired; if the client fires both for one click, OnLink treats the second as the same click.
    if not done.click and type(EventRegistry) == "table" and type(EventRegistry.RegisterCallback) == "function" then
        local ok = pcall(EventRegistry.RegisterCallback, EventRegistry, "SetItemRef", function(...)
            -- The owner may or may not come first; the link is the first string that starts with "addon:".
            for index = 1, select("#", ...) do
                local value = select(index, ...)
                if plainString(value) and value:sub(1, 6) == "addon:" then
                    Chat.OnLink(value)
                    return
                end
            end
        end, Chat)
        done.click = ok
    end
    if not done.hook and type(hooksecurefunc) == "function" and type(SetItemRef) == "function" then
        local ok = pcall(hooksecurefunc, "SetItemRef", function(link) Chat.OnLink(link) end)
        done.hook = ok
    end
    return done
end

Chat.Install()
