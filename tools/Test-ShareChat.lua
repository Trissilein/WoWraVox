-- Tests for ShareChat.lua (chat link: marker, filter, click, addon whisper, chunking) and its hooks in WoWraVox.lua.
-- Runs in the Fengari harness of tools/Test-ShareChat.js. Everything the client provides is MOCKED: the chat filter,
-- the link click (EventRegistry), C_ChatInfo.SendAddonMessage and its result codes, the restriction states, timers,
-- GetTime and the widget frames. Nothing here proves the real client behaviour; only two characters in the game do.

local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. tostring(detail)) or "")) end
    print("PASS " .. name)
end

local Chat = ns.ShareChat
local SECRET = "SECRET-VALUE"

-- Mocks ---------------------------------------------------------------------------------------------------

local clock = 1000
GetTime = function() return clock end
issecretvalue = function(value) return value == SECRET end
UnitName = function() return "Hero" end

local sent, sendResult = {}, 0
local lockdown = false
local restriction = {}
local registered = {}
Enum = {
    SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, AddOnMessageLockdown = 11 },
    AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5 },
}
C_ChatInfo = {
    SendAddonMessage = function(prefix, message, chatType, target)
        sent[#sent + 1] = { prefix = prefix, message = message, chatType = chatType, target = target }
        if type(sendResult) == "function" then return sendResult(#sent) end
        return sendResult
    end,
    RegisterAddonMessagePrefix = function(prefix) registered[#registered + 1] = prefix return 0 end,
    InChatMessagingLockdown = function() return lockdown end,
}
C_RestrictedActions = {
    GetAddOnRestrictionState = function(kind) return restriction[kind] or 0 end,
}

local timers = {}
local realAfter = Chat.After
Chat.After = function(seconds, fn) timers[#timers + 1] = { seconds = seconds, fn = fn } end
-- Runs the short timers (send steps); the 15 second request timeouts stay queued unless all = true.
local function runTimers(all)
    local batch, keep = timers, {}
    timers = {}
    for _, timer in ipairs(batch) do
        if all or timer.seconds < 5 then timer.fn() else keep[#keep + 1] = timer end
    end
    for _, timer in ipairs(keep) do timers[#timers + 1] = timer end
    return #batch > #keep
end
local function drain()
    for _ = 1, 400 do
        if not runTimers() then break end
    end
end
local notes = {}
Chat.notify = function(text, isError) notes[#notes + 1] = { text = text, isError = isError == true } end
local function lastNote() return notes[#notes] and notes[#notes].text end

local function reset()
    sent, sendResult, lockdown, restriction, notes, timers = {}, 0, false, {}, {}, {}
    Chat.offers, Chat.offerOrder, Chat.queue, Chat.lastReply, Chat.pending, Chat.pumping = {}, {}, {}, {}, nil, false
    Chat.replyCount, Chat.replyPruned, Chat.lastClick = 0, -math.huge, nil
    clock = clock + 100
end
local function messages()
    local out = {}
    for _, entry in ipairs(sent) do out[#out + 1] = entry.message end
    return out
end

local realOpenImport = ns.ShareUI.openImport
local opened = {}
ns.ShareUI.openImport = function(text) opened[#opened + 1] = text end

local TEXT = "WVX1:" .. string.rep("AbC+/=", 100)

-- Marker --------------------------------------------------------------------------------------------------
do
    reset()
    local marker = Chat.BuildMarker("Shield group", "0123abcd")
    check("marker format", marker == "[WoWraVox: Shield group #0123abcd]", marker)
    local dirty = Chat.BuildMarker("A|cffff0000B[x]\ny|r", "0123ABCD")
    check("marker name: no pipe, bracket or control character; code lower case", dirty == "[WoWraVox: Acffff0000Bxyr #0123abcd]", dirty)
    local long = Chat.BuildMarker(string.rep("x", 80), "0123abcd")
    check("marker name: at most 30 characters", long == "[WoWraVox: " .. string.rep("x", 30) .. " #0123abcd]", long)
    local even = Chat.BuildMarker(string.rep("\195\164", 40), "0123abcd"):match("^%[WoWraVox: (.-) #")
    check("marker name: multi-byte text cut on a character boundary keeps 30 bytes", #even == 30 and even == string.rep("\195\164", 15), #even)
    local split = Chat.BuildMarker("x" .. string.rep("\195\164", 40), "0123abcd"):match("^%[WoWraVox: (.-) #")
    check("marker name: a cut inside a multi-byte character drops that character", #split == 29 and split == "x" .. string.rep("\195\164", 14), #split)
    check("marker name: empty name gets the default", Chat.BuildMarker("|[]", "0123abcd") == "[WoWraVox: New aura group #0123abcd]")
    check("marker: bad code gives nil", Chat.BuildMarker("x", "zzzz") == nil and Chat.BuildMarker("x", nil) == nil)
    check("marker: matches the filter pattern", marker:match("%[WoWraVox: ([^%[%]|]+) #(%x%x%x%x%x%x%x%x)%]") == "Shield group")
end

-- Offers --------------------------------------------------------------------------------------------------
do
    reset()
    local code, marker = Chat.MakeOffer(TEXT, "Shield group")
    check("offer: code is 8 hex characters and the marker holds it", code and code:match("^%x%x%x%x%x%x%x%x$")
        and marker == "[WoWraVox: Shield group #" .. code .. "]", marker)
    check("offer: kept in memory with a 10 minute expiry", Chat.offers[code].text == TEXT and Chat.offers[code].expires == clock + 600)
    local again = Chat.MakeOffer(TEXT, "Shield group")
    check("offer: same text reuses the code", again == code and #Chat.offerOrder == 1)
    check("offer: wrong prefix refused", Chat.MakeOffer("hello", "x") == nil)
    check("offer: odd characters refused", Chat.MakeOffer("WVX1:abc def", "x") == nil and Chat.MakeOffer("WVX1:abc\0", "x") == nil)
    check("offer: non-string refused", Chat.MakeOffer(nil, "x") == nil and Chat.MakeOffer({}, "x") == nil and Chat.MakeOffer(SECRET, "x") == nil)
    local limit = Chat.MAX_TOTAL
    check("limit: follows ShareGroups.MAX_INPUT, 8192 when that is missing", limit == (ns.ShareGroups.MAX_INPUT or 8192), limit)
    check("offer: too large refused", Chat.MakeOffer("WVX1:" .. string.rep("A", limit), "x") == nil)
    check("offer: exactly at the limit accepted", Chat.MakeOffer("WVX1:" .. string.rep("A", limit - 5), "x") ~= nil)
    reset()
    local first
    for i = 1, 6 do
        local c = Chat.MakeOffer("WVX1:text" .. i, "g" .. i)
        if i == 1 then first = c end
    end
    check("offer: at most 5, the oldest falls out", #Chat.offerOrder == 5 and Chat.offers[first] == nil)
    reset()
    local c = Chat.MakeOffer(TEXT, "x")
    clock = clock + 599
    check("offer: still served after 599 s", Chat.HandleRequest("Bob", c) == "ok")
    drain()
    reset()
    c = Chat.MakeOffer(TEXT, "x")
    clock = clock + 601
    check("offer: expired after 10 minutes, answered with ERR expired", Chat.HandleRequest("Bob", c) == "err:expired"
        and messages()[1] == "ERR:" .. c .. ":expired", messages()[1])
    check("offer: expired offer is removed on access", Chat.offers[c] == nil and #Chat.offerOrder == 0)
    reset()
    local oldCode = Chat.MakeOffer("WVX1:old", "old")
    clock = clock + 601
    Chat.MakeOffer("WVX1:new", "new")
    check("offer: expired offers are dropped when a new one is made", Chat.offers[oldCode] == nil and #Chat.offerOrder == 1)
end

-- Chunking ------------------------------------------------------------------------------------------------
do
    for _, size in ipairs({ 1, 200, 201, 400, Chat.MAX_TOTAL }) do
        local text = string.rep("Q", size)
        local parts = Chat.ChunkText(text)
        local ok = #parts == math.ceil(size / 200)
        for _, part in ipairs(parts) do if #part > 200 or #part == 0 then ok = false end end
        check("chunk roundtrip " .. size .. " bytes", ok and table.concat(parts) == text, #parts)
    end
    check("chunk: empty and non-string give no parts", #Chat.ChunkText("") == 0 and #Chat.ChunkText(nil) == 0 and #Chat.ChunkText(5) == 0)
    check("chunk: the size limit is exactly the part limit", #Chat.ChunkText(string.rep("Q", Chat.MAX_TOTAL)) == math.ceil(Chat.MAX_TOTAL / 200))
end

-- Restricted ----------------------------------------------------------------------------------------------
do
    reset()
    check("not restricted by default", Chat.Restricted() == false)
    lockdown = true
    check("chat lockdown restricts", Chat.Restricted() == true)
    lockdown = false
    for key, value in pairs({ Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Chat = 5 }) do
        restriction = { [value] = 2 }
        check("active " .. key .. " restriction restricts", Chat.Restricted() == true)
    end
    restriction = { [Enum.AddOnRestrictionType.Encounter] = 1 }
    check("activating restriction restricts", Chat.Restricted() == true)
    restriction = { [Enum.AddOnRestrictionType.Combat] = 2, [Enum.AddOnRestrictionType.Map] = 2 }
    check("combat and map alone do not restrict", Chat.Restricted() == false)
    restriction = {}
    local realLockdown, realState = C_ChatInfo.InChatMessagingLockdown, C_RestrictedActions.GetAddOnRestrictionState
    C_ChatInfo.InChatMessagingLockdown = function() error("boom") end
    C_RestrictedActions.GetAddOnRestrictionState = function() error("boom") end
    check("failing restriction APIs count as not restricted", Chat.Restricted() == false)
    C_ChatInfo.InChatMessagingLockdown, C_RestrictedActions.GetAddOnRestrictionState = realLockdown, realState
    local realTypes = Enum.AddOnRestrictionType
    Enum.AddOnRestrictionType = nil
    C_RestrictedActions.GetAddOnRestrictionState = function() return 2 end
    check("missing restriction enum degrades to not restricted", Chat.Restricted() == false)
    Enum.AddOnRestrictionType = realTypes
    C_RestrictedActions.GetAddOnRestrictionState = realState
    local realRestricted = C_RestrictedActions
    C_RestrictedActions, C_ChatInfo.InChatMessagingLockdown = nil, nil
    check("missing APIs degrade to not restricted", Chat.Restricted() == false)
    C_RestrictedActions, C_ChatInfo.InChatMessagingLockdown = realRestricted, realLockdown
end

-- Filter: marker to link ----------------------------------------------------------------------------------
do
    reset()
    local link = "|cff00ccff|Haddon:WoWraVox:import:0123abcd:Bob-Realm|h[WoWraVox: Shield group]|h|r"
    local out, changed = Chat.RewriteMessage("look [WoWraVox: Shield group #0123abcd] here", "Bob-Realm")
    check("filter: marker becomes a local link", changed and out == "look " .. link .. " here", out)
    local two = Chat.RewriteMessage("[WoWraVox: A #00000001][WoWraVox: B #00000002]", "Bob")
    check("filter: two markers in one message", select(2, two:gsub("|Haddon:", "")) == 2, two)
    local upper = Chat.RewriteMessage("[WoWraVox: A #ABCDEF01]", "Bob")
    check("filter: code is lower-cased in the link", upper:find("import:abcdef01:Bob", 1, true) ~= nil, upper)
    local cleanSender = Chat.RewriteMessage("[WoWraVox: A #00000001]", "Bo|c:b[x]")
    check("filter: no colon, pipe or bracket from the author in the link", cleanSender:find("import:00000001:Bocbx|h", 1, true) ~= nil, cleanSender)
    for index, text in ipairs({
        "just chat", "[WoWraVox: x #123]", "[WoWraVox: #12345678]", "[WoWraVox: x #1234567g]",
        "[WoWraVox: a|cffff0000b #12345678]", "[WoWraVox: a[b #12345678]", "WoWraVox: x #12345678",
        "[WoWraVox: x #12345678", "[wowravox: x #12345678]",
    }) do
        local result, did = Chat.RewriteMessage(text, "Bob")
        check("filter: foreign text or broken marker untouched " .. index, did == false and result == text, result)
    end
    local result, did = Chat.RewriteMessage(nil, "Bob")
    check("filter: nil message untouched", result == nil and did == false)
    result, did = Chat.RewriteMessage(42, "Bob")
    check("filter: number untouched", result == 42 and did == false)
    result, did = Chat.RewriteMessage(SECRET, "Bob")
    check("filter: secret message untouched", result == SECRET and did == false)
    result, did = Chat.RewriteMessage("[WoWraVox: x #12345678]", SECRET)
    check("filter: secret author untouched", did == false and result == "[WoWraVox: x #12345678]")
    result, did = Chat.RewriteMessage("[WoWraVox: x #12345678]", nil)
    check("filter: missing author untouched", did == false)
    result, did = Chat.RewriteMessage("[WoWraVox: x #12345678]", "|:")
    check("filter: author empty after cleaning untouched", did == false)
    lockdown = true
    result, did = Chat.RewriteMessage("[WoWraVox: x #12345678]", "Bob")
    check("filter: restricted state leaves the message alone", did == false and result == "[WoWraVox: x #12345678]")
    lockdown = false
    local filterResult = { Chat.Filter({}, "CHAT_MSG_PARTY", "[WoWraVox: x #12345678]", "Bob", "lang", "chan", "extra") }
    check("filter function: returns false and all arguments, message replaced", filterResult[1] == false
        and filterResult[2]:find("|Haddon:WoWraVox:import:12345678:Bob|h", 1, true) ~= nil and filterResult[3] == "Bob"
        and filterResult[4] == "lang" and filterResult[5] == "chan" and filterResult[6] == "extra")
    local unchanged = { Chat.Filter({}, "CHAT_MSG_PARTY", "hello", "Bob") }
    check("filter function: nothing returned beyond false when untouched", #unchanged == 1 and unchanged[1] == false)
    local secretResult = { Chat.Filter({}, "CHAT_MSG_PARTY", SECRET, "Bob") }
    check("filter function: secret message passes unchanged", #secretResult == 1 and secretResult[1] == false)
    check("filter function: junk raises no error", pcall(Chat.Filter, nil, nil, {}, {}))
end

-- Debug log (/wvdebug on): lines through a mocked AuraSoundFallback.Log; filter results never change -------------
do
    reset()
    local realFallback = ns.AuraSoundFallback
    local log = {}
    local function clearLog() for index = #log, 1, -1 do log[index] = nil end end
    local fallback = { debugEnabled = true, Log = function(category, line) log[#log + 1] = category .. " " .. line end }
    ns.AuraSoundFallback = fallback
    local function same(a, b)
        if #a ~= #b then return false end
        for index = 1, #a do if a[index] ~= b[index] then return false end end
        return true
    end
    local function filter(event, msg, author, ...)
        return { Chat.Filter({}, event, msg, author, ...) }
    end
    local MARK = "[WoWraVox: x #12345678]"

    clearLog(); Chat.filterLogLines = 0
    local on = filter("CHAT_MSG_WHISPER", MARK, "Bob-Realm", "lang")
    check("debug: marker whisper writes one CHAT-FILTER line", #log == 1 and log[1] == "CHAT-FILTER CHAT_MSG_WHISPER msgSecret=false msgType=string authorSecret=false restricted=false marker=true rewritten=true", log[1])
    check("debug: filter result is the link with the event's arguments", on[1] == false and on[2]:find("|Haddon:WoWraVox:import:12345678:Bob-Realm|h", 1, true) ~= nil
        and on[3] == "Bob-Realm" and on[4] == "lang", on[2])
    fallback.debugEnabled = false
    local off = filter("CHAT_MSG_WHISPER", MARK, "Bob-Realm", "lang")
    fallback.debugEnabled = true
    check("debug off: same filter result as with debug, no line", same(on, off) and #log == 1, #log)

    clearLog(); Chat.filterLogLines = 0
    local secret = filter("CHAT_MSG_WHISPER", SECRET, "Bob-Realm")
    check("debug: secret whisper writes a line with marker=?", #log == 1 and log[1] == "CHAT-FILTER CHAT_MSG_WHISPER msgSecret=true msgType=string authorSecret=false restricted=false marker=? rewritten=false"
        and #secret == 1 and secret[1] == false, log[1])

    clearLog()
    local secretAuthor = filter("CHAT_MSG_WHISPER", MARK, SECRET)
    check("debug: secret author with marker logs authorSecret=true rewritten=false, result unchanged", #log == 1
        and log[1] == "CHAT-FILTER CHAT_MSG_WHISPER msgSecret=false msgType=string authorSecret=true restricted=false marker=true rewritten=false"
        and #secretAuthor == 1 and secretAuthor[1] == false, log[1])

    clearLog()
    local nilMsg = filter("CHAT_MSG_SAY", nil, "Bob")
    check("debug: nil message logs msgType=nil", #log == 1 and log[1] == "CHAT-FILTER CHAT_MSG_SAY msgSecret=false msgType=nil authorSecret=false restricted=false marker=? rewritten=false"
        and #nilMsg == 1, log[1])

    clearLog()
    local plain = filter("CHAT_MSG_SAY", "hello", "Bob")
    check("debug: plain message without marker writes nothing", #log == 0 and #plain == 1 and plain[1] == false)

    clearLog(); Chat.filterLogLines = 0
    lockdown = true
    local locked = filter("CHAT_MSG_WHISPER", MARK, "Bob-Realm")
    lockdown = false
    check("debug: restricted state logged, message left alone", #log == 1
        and log[1] == "CHAT-FILTER CHAT_MSG_WHISPER msgSecret=false msgType=string authorSecret=false restricted=true marker=true rewritten=false"
        and #locked == 1 and locked[1] == false, log[1])

    clearLog(); Chat.filterLogLines = 0
    local allRewritten = true
    for _ = 1, 35 do
        local res = filter("CHAT_MSG_WHISPER", MARK, "Bob-Realm")
        if res[1] ~= false or type(res[2]) ~= "string" or res[2]:find("|Haddon:", 1, true) == nil then allRewritten = false end
    end
    check("debug: at most 30 filter lines per session", #log == 30 and Chat.filterLogLines == 30, #log)
    check("debug: the line cap does not change the filter results", allRewritten)

    ns.AuraSoundFallback = nil
    local missing = filter("CHAT_MSG_WHISPER", MARK, "Bob-Realm")
    check("debug: no logger, filter still rewrites and raises nothing", #missing == 3 and missing[2]:find("|Haddon:", 1, true) ~= nil)
    ns.AuraSoundFallback = { debugEnabled = true, Log = function() error("logger broke") end }
    local broken = filter("CHAT_MSG_WHISPER", MARK, "Bob-Realm")
    check("debug: failing logger raises nothing and the result stays", #broken == 3 and broken[1] == false and broken[2]:find("|Haddon:", 1, true) ~= nil)
    ns.AuraSoundFallback = fallback

    clearLog(); reset()
    Chat.OnLink("addon:WoWraVox:import:0123abcd:Bob-Realm")
    check("debug: click logs CHAT-LINK, REQ logs the SendAddonMessage result", #log == 2
        and log[1] == "CHAT-LINK code=0123abcd own=false restricted=false"
        and log[2] == "CHAT-REQ code=0123abcd to=Bob-Realm result=ok raw=0", table.concat(log, " | "))

    clearLog(); reset(); sendResult = 3
    Chat.OnLink("addon:WoWraVox:import:0123abcd:Bob-Realm")
    check("debug: throttled REQ logs result=throttle and the raw code", log[#log] == "CHAT-REQ code=0123abcd to=Bob-Realm result=throttle raw=3"
        and #sent == 1, table.concat(log, " | "))

    clearLog(); reset()
    local own = Chat.MakeOffer(TEXT, "Hero")
    Chat.OnLink("addon:WoWraVox:import:" .. own .. ":Hero")
    check("debug: own offer click logs own=true and no REQ", #log == 1 and log[1] == "CHAT-LINK code=" .. own .. " own=true"
        and #sent == 0, table.concat(log, " | "))

    clearLog(); reset(); lockdown = true
    Chat.OnLink("addon:WoWraVox:import:0123abcd:Bob-Realm")
    lockdown = false
    check("debug: blocked click logs restricted=true and sends no REQ", #log == 1
        and log[1] == "CHAT-LINK code=0123abcd own=false restricted=true" and #sent == 0, table.concat(log, " | "))

    fallback.debugEnabled = false; clearLog(); reset()
    Chat.OnLink("addon:WoWraVox:import:0123abcd:Bob-Realm")
    check("debug off: click still sends the REQ, no lines", #log == 0 and #sent == 1 and sent[1].message == "REQ:0123abcd", #log)

    ns.AuraSoundFallback = realFallback
    Chat.filterLogLines = 0
    reset()
end

-- Serving requests (sender) -------------------------------------------------------------------------------
do
    reset()
    local code = Chat.MakeOffer(TEXT, "Shield group")
    local result, count = Chat.HandleRequest("Bob-Realm", code)
    check("REQ: known code is answered", result == "ok" and count == #Chat.ChunkText(TEXT), result)
    check("REQ: the first part goes out at once, the rest waits for timers", #sent == 1 and #Chat.queue == #Chat.ChunkText(TEXT) - 1)
    check("REQ: the next part waits 0.15 s", timers[1] and timers[1].seconds == 0.15)
    drain()
    check("REQ: all parts sent", #sent == count and #Chat.queue == 0 and Chat.pumping == false, #sent)
    local allOk = true
    for index, entry in ipairs(sent) do
        if entry.prefix ~= "WVX" or entry.chatType ~= "WHISPER" or entry.target ~= "Bob-Realm" or #entry.message > 255 then allOk = false end
        if entry.message:sub(1, 5 + 8 + 1) ~= "DATA:" .. code .. ":" then allOk = false end
        if not entry.message:find(":" .. index .. "/" .. count .. ":", 1, true) then allOk = false end
    end
    check("REQ: prefix, whisper, target, header and 255 byte limit hold for every part", allOk)
    local joined = {}
    for _, entry in ipairs(sent) do joined[#joined + 1] = entry.message:match("^DATA:%x+:%d+/%d+:(.*)$") end
    check("REQ: parts add up to the offer text", table.concat(joined) == TEXT)

    reset()
    code = Chat.MakeOffer(TEXT, "x")
    Chat.HandleRequest("Bob-Realm", code)
    drain()
    local before = #sent
    check("REQ: same player and code within 5 s is ignored", Chat.HandleRequest("bob-realm", code) == "ignored")
    clock = clock + 4
    check("REQ: still ignored after 4 s", Chat.HandleRequest("Bob-Realm", code) == "ignored")
    check("REQ: another player may ask at once", Chat.HandleRequest("Carl", code) == "ok")
    clock = clock + 2
    check("REQ: the same player may ask again after 5 s", Chat.HandleRequest("Bob-Realm", code) == "ok")
    drain()
    check("REQ: ignored requests send nothing", #sent > before)

    reset()
    check("REQ: unknown code answered with ERR unknown", Chat.HandleRequest("Bob", "deadbeef") == "err:unknown"
        and messages()[1] == "ERR:deadbeef:unknown", messages()[1])
    check("REQ: ERR goes by whisper to the asker", sent[1].target == "Bob" and sent[1].chatType == "WHISPER")
    reset()
    code = Chat.MakeOffer(TEXT, "x")
    lockdown = true
    check("REQ: restricted state answers nothing", Chat.HandleRequest("Bob", code) == "blocked" and #sent == 0)
    lockdown = false
    reset()
    check("REQ: junk arguments are ignored", Chat.HandleRequest(nil, "deadbeef") == "ignored"
        and Chat.HandleRequest("Bob", nil) == "ignored" and Chat.HandleRequest("Bob", "zz") == "ignored"
        and Chat.HandleRequest("", "deadbeef") == "ignored" and Chat.HandleRequest(SECRET, "deadbeef") == "ignored"
        and Chat.HandleRequest({}, {}) == "ignored" and #sent == 0)

    -- sending failures
    reset()
    code = Chat.MakeOffer(TEXT, "x")
    sendResult = function(n) if n == 1 then return 0 end return 3 end
    Chat.HandleRequest("Bob", code)
    drain()
    check("send: throttle result retries after 1 s, then gives up after 5 retries", #sent == 1 + 6 and #Chat.queue == 0
        and Chat.pumping == false, #sent)
    reset()
    code = Chat.MakeOffer(TEXT, "x")
    local calls = 0
    sendResult = function() calls = calls + 1 if calls == 2 then return 3 end return 0 end
    Chat.HandleRequest("Bob", code)
    drain()
    check("send: one throttle retry still delivers every part", #Chat.queue == 0 and #sent == #Chat.ChunkText(TEXT) + 1)
    reset()
    code = Chat.MakeOffer(TEXT, "x")
    sendResult = function(n) if n == 3 then return 11 end return 0 end
    Chat.HandleRequest("Bob", code)
    drain()
    check("send: lockdown result empties the queue", #sent == 3 and #Chat.queue == 0 and Chat.pumping == false, #sent)
    reset()
    code = Chat.MakeOffer(TEXT, "x")
    sendResult = 9
    Chat.HandleRequest("Bob", code)
    drain()
    check("send: any other failure empties the queue", #sent == 1 and #Chat.queue == 0 and Chat.pumping == false)
    sendResult = 0
    Chat.HandleRequest("Dora", code)
    drain()
    check("send: a new request works after an aborted queue", #sent > 1 and #Chat.queue == 0)
end

-- Click (receiver) ----------------------------------------------------------------------------------------
do
    reset()
    check("link: parsed", select(1, Chat.ParseLink("addon:WoWraVox:import:0123ABCD:Bob-Realm")) == "0123abcd"
        and select(2, Chat.ParseLink("addon:WoWraVox:import:0123abcd:Bob-Realm")) == "Bob-Realm")
    for index, link in ipairs({ "addon:Other:import:0123abcd:Bob", "addon:WoWraVox:import:012:Bob", "addon:WoWraVox:import:0123abcd:",
        "addon:WoWraVox:import:0123abcd:Bob:x", "item:1", "", SECRET }) do
        check("link: refused " .. index, Chat.ParseLink(link) == nil)
    end
    check("click: non-WoWraVox link is not handled", Chat.OnLink("item:123") == false and Chat.OnLink(nil) == false
        and Chat.OnLink({}) == false and #sent == 0)

    check("click: handled", Chat.OnLink("addon:WoWraVox:import:0123abcd:Bob-Realm") == true)
    check("click: REQ whispered to the sender", #sent == 1 and sent[1].message == "REQ:0123abcd" and sent[1].target == "Bob-Realm"
        and sent[1].prefix == "WVX" and sent[1].chatType == "WHISPER")
    check("click: status message names the sender", lastNote() == "Requesting group from Bob-Realm ...", lastNote())
    check("click: 15 second timeout armed, one open request", timers[1] and timers[1].seconds == 15 and Chat.pending.code == "0123abcd")
    clock = clock + 15
    runTimers(true)
    check("click: timeout message after 15 s", lastNote() == "No answer from Bob-Realm. They may be offline or in combat content."
        and notes[#notes].isError and Chat.pending == nil, lastNote())

    reset()
    Chat.OnLink("addon:WoWraVox:import:00000001:Bob")
    Chat.OnLink("addon:WoWraVox:import:00000002:Carl")
    check("click: a second click replaces the open request", Chat.pending.code == "00000002" and Chat.pending.sender == "Carl")
    check("click: the replaced request is announced as cancelled", notes[#notes - 1].text == "Request to Bob cancelled."
        and notes[#notes - 1].isError == false, notes[#notes - 1].text)
    local noteCount = #notes
    clock = clock + 15
    runTimers(true)
    check("click: only the current request times out", #notes == noteCount + 1 and notes[#notes].text:find("Carl", 1, true) ~= nil)

    reset()
    lockdown = true
    Chat.OnLink("addon:WoWraVox:import:0123abcd:Bob")
    check("click while restricted: message, no REQ, no request", #sent == 0 and Chat.pending == nil
        and lastNote() == "Sharing is blocked during encounters, Mythic+ and PvP." and notes[#notes].isError)
    lockdown = false

    reset()
    sendResult = 11
    Chat.OnLink("addon:WoWraVox:import:0123abcd:Bob")
    check("click: lockdown result shows the blocked message and drops the request", Chat.pending == nil
        and lastNote() == "Sharing is blocked during encounters, Mythic+ and PvP.")
    reset()
    sendResult = 12
    Chat.OnLink("addon:WoWraVox:import:0123abcd:Bob")
    check("click: failed send shows an error and drops the request", Chat.pending == nil
        and lastNote() == "Could not send the request to Bob.")
    reset()
    local realSend = C_ChatInfo.SendAddonMessage
    C_ChatInfo.SendAddonMessage = nil
    check("click: no SendAddonMessage degrades without error", Chat.OnLink("addon:WoWraVox:import:0123abcd:Bob") == true
        and Chat.pending == nil)
    C_ChatInfo.SendAddonMessage = realSend

    reset()
    opened = {}
    local own = Chat.MakeOffer(TEXT, "Mine")
    Chat.OnLink("addon:WoWraVox:import:" .. own .. ":Hero")
    check("click on own link: opens the import with the own text, no whisper", #sent == 0 and opened[1] == TEXT and Chat.pending == nil)
    Chat.OnLink("addon:WoWraVox:import:" .. own .. ":Villain")
    check("click on a link with this code from someone else still asks that player", #sent == 1 and sent[1].target == "Villain")
    Chat.OnLink("addon:WoWraVox:import:deadbeef:Hero")
    check("click on own name but unknown code asks nobody useful: request goes out", #sent == 2)
end

-- Assembling (receiver) -----------------------------------------------------------------------------------
do
    local function startRequest(sender, code)
        reset()
        opened = {}
        Chat.OnLink("addon:WoWraVox:import:" .. code .. ":" .. sender)
        sent = {}
    end
    startRequest("Bob-Realm", "0123abcd")
    check("data without a matching request is ignored", Chat.HandleData("Bob-Realm", 1, 1, "00000000", "WVX1:a") == "ignored")
    check("data from another sender is ignored", Chat.HandleData("Carl-Realm", 1, 1, "0123abcd", "WVX1:a") == "ignored"
        and Chat.pending ~= nil)
    check("data from the same name on another realm is ignored", Chat.HandleData("Bob-Other", 1, 1, "0123abcd", "WVX1:a") == "ignored")
    check("data from a longer name is ignored", Chat.HandleData("Bobby-Realm", 1, 1, "0123abcd", "WVX1:a") == "ignored")
    check("data with an empty sender is ignored", Chat.HandleData("", 1, 1, "0123abcd", "WVX1:a") == "ignored"
        and Chat.HandleData(nil, 1, 1, "0123abcd", "WVX1:a") == "ignored")
    check("data: i = 0, i > n, n = 0, n > limit, fractions and strings are ignored",
        Chat.HandleData("Bob-Realm", 0, 2, "0123abcd", "WVX1:a") == "ignored"
        and Chat.HandleData("Bob-Realm", 3, 2, "0123abcd", "WVX1:a") == "ignored"
        and Chat.HandleData("Bob-Realm", 1, 0, "0123abcd", "WVX1:a") == "ignored"
        and Chat.HandleData("Bob-Realm", 1, math.ceil(Chat.MAX_TOTAL / 200) + 1, "0123abcd", "WVX1:a") == "ignored"
        and Chat.HandleData("Bob-Realm", 1.5, 2, "0123abcd", "WVX1:a") == "ignored"
        and Chat.HandleData("Bob-Realm", "1", 2, "0123abcd", "WVX1:a") == "ignored")
    check("data: empty, oversize or odd parts are ignored", Chat.HandleData("Bob-Realm", 1, 2, "0123abcd", "") == "ignored"
        and Chat.HandleData("Bob-Realm", 1, 2, "0123abcd", string.rep("A", 201)) == "ignored"
        and Chat.HandleData("Bob-Realm", 1, 2, "0123abcd", "bad part") == "ignored"
        and Chat.HandleData("Bob-Realm", 1, 2, "0123abcd", SECRET) == "ignored")
    check("data: nothing of the above changed the request", Chat.pending.count == 0 and #opened == 0)

    check("data: first part accepted (arrives second in order)", Chat.HandleData("Bob-Realm", 2, 3, "0123abcd", "BBBB") == "ok")
    check("data: duplicate ignored", Chat.HandleData("Bob-Realm", 2, 3, "0123abcd", "XXXX") == "dup" and Chat.pending.count == 1)
    check("data: a different n mid-way is ignored", Chat.HandleData("Bob-Realm", 1, 4, "0123abcd", "AAAA") == "ignored")
    check("data: sender without realm is refused, case of name, realm and code does not matter", Chat.HandleData("bob", 3, 3, "0123abcd", "CCCC") == "ignored"
        and Chat.HandleData("bob-REALM", 3, 3, "0123ABCD", "CCCC") == "ok")
    check("data: gap keeps the request open and opens nothing", #opened == 0 and Chat.pending ~= nil)
    local result, text = Chat.HandleData("Bob-Realm", 1, 3, "0123abcd", "WVX1:AAAA")
    check("data: last missing part completes in the right order", result == "complete" and text == "WVX1:AAAABBBBCCCC", text)
    check("data: import opened once with the text, request closed", #opened == 1 and opened[1] == "WVX1:AAAABBBBCCCC" and Chat.pending == nil)
    check("data: completion is announced", lastNote() == "Group received from Bob-Realm. Check it, then import.")
    check("data after completion is ignored", Chat.HandleData("Bob-Realm", 1, 3, "0123abcd", "WVX1:AAAA") == "ignored")

    startRequest("Bob-Realm", "0123abcd")
    Chat.HandleData("Bob-Realm", 1, 2, "0123abcd", "WVX1:AAAA")
    clock = clock + 15
    runTimers(true)
    check("gap: the request times out with the no-answer message", Chat.pending == nil and lastNote():find("No answer from Bob-Realm", 1, true) == 1)
    check("gap: late data after the timeout is ignored", Chat.HandleData("Bob-Realm", 2, 2, "0123abcd", "BBBB") == "ignored" and #opened == 0)

    startRequest("Bob-Realm", "0123abcd")
    clock = clock + 16
    check("data after 15 s is ignored even before the timer ran", Chat.HandleData("Bob-Realm", 1, 1, "0123abcd", "WVX1:A") == "ignored")

    startRequest("Bob-Realm", "0123abcd")
    local full = string.rep("Z", 200)
    local verdict
    local fullParts = math.ceil(Chat.MAX_TOTAL / 200)
    for index = 1, fullParts do
        verdict = Chat.HandleData("Bob-Realm", index, fullParts, "0123abcd", full)
        if verdict ~= "ok" then break end
    end
    check("too large: more than the size limit in total is dropped with a message", verdict == "abort" and Chat.pending == nil and #opened == 0
        and lastNote() == "The export is too large." and notes[#notes].isError, verdict)

    startRequest("Bob-Realm", "0123abcd")
    local one = Chat.HandleData("Bob-Realm", 1, 1, "0123abcd", "WVX1:A")
    check("single part export completes", one == "complete" and opened[1] == "WVX1:A")

    startRequest("Bob-Realm", "0123abcd")
    Chat.HandleError("Carl", "0123abcd", "unknown")
    check("ERR from someone else is ignored", Chat.pending ~= nil)
    Chat.HandleError("Bob-Realm", "0123abcd", "expired")
    check("ERR from the sender ends the request with a message", Chat.pending == nil
        and lastNote() == "Bob-Realm no longer offers this group. Ask them to share it again." and notes[#notes].isError)
    startRequest("Bob-Realm", "0123abcd")
    Chat.HandleError("Bob-Realm", "0123abcd", "toolarge")
    check("ERR toolarge shows the too-large message", Chat.pending == nil and lastNote() == "The export is too large.")
    check("timeout after an ERR does nothing more", (function() local n = #notes runTimers(true) return #notes == n end)())
end

-- Wire loopback: serve a request and feed the answer back into a requester --------------------------------
do
    reset()
    opened = {}
    local code = Chat.MakeOffer(TEXT, "Shield group")
    check("wire: REQ message served through OnAddonMessage", Chat.OnAddonMessage("WVX", "REQ:" .. code, "WHISPER", "Bob-Realm") == "ok")
    drain()
    local wire = messages()
    reset()
    opened = {}
    Chat.OnLink("addon:WoWraVox:import:" .. code .. ":Bob-Realm")
    sent = {}
    local last
    for _, message in ipairs(wire) do last = Chat.OnAddonMessage("WVX", message, "WHISPER", "Bob-Realm") end
    check("wire: the received parts open the import with the original text", last == "complete" and opened[1] == TEXT)

    clock = clock + 1; Chat.OnLink("addon:WoWraVox:import:" .. code .. ":Bob-Realm")
    check("wire: ERR through OnAddonMessage ends the request", Chat.OnAddonMessage("WVX", "ERR:" .. code .. ":unknown", "WHISPER", "Bob-Realm") == "failed"
        and Chat.pending == nil)

    clock = clock + 1; Chat.OnLink("addon:WoWraVox:import:" .. code .. ":Bob-Realm")
    check("wire: other prefix ignored", Chat.OnAddonMessage("OTHER", wire[1], "WHISPER", "Bob-Realm") == nil)
    check("wire: other channel ignored", Chat.OnAddonMessage("WVX", wire[1], "PARTY", "Bob-Realm") == nil
        and Chat.OnAddonMessage("WVX", wire[1], "GUILD", "Bob-Realm") == nil)
    check("wire: secret values ignored", Chat.OnAddonMessage("WVX", SECRET, "WHISPER", "Bob-Realm") == nil
        and Chat.OnAddonMessage("WVX", wire[1], "WHISPER", SECRET) == nil and Chat.OnAddonMessage(SECRET, wire[1], "WHISPER", "Bob") == nil)
    check("wire: over 255 bytes ignored", Chat.OnAddonMessage("WVX", "DATA:" .. string.rep("x", 260), "WHISPER", "Bob-Realm") == nil)
    check("wire: unknown verb ignored", Chat.OnAddonMessage("WVX", "HELLO:" .. code, "WHISPER", "Bob-Realm") == nil)
    check("wire: unsolicited DATA from a stranger ignored", Chat.OnAddonMessage("WVX", wire[1], "WHISPER", "Mallory") == "ignored"
        and Chat.pending.count == 0)
    Chat.pending = nil
    check("wire: unsolicited DATA without any request ignored", Chat.OnAddonMessage("WVX", wire[1], "WHISPER", "Bob-Realm") == "ignored")
end

-- Review findings M1: send queue, reply table, per-asker cooldown, failure scope ---------------------------
do
    reset()
    for i = 1, 2000 do Chat.HandleRequest("Mallory-Realm", string.format("%08x", i)) end
    check("M1b flood: one asker with 2000 changing codes gets one answer in total", #sent + #Chat.queue == 1 and Chat.replyCount == 1,
        #sent + #Chat.queue)

    reset()
    for i = 1, 2000 do Chat.HandleRequest("Player" .. i .. "-Realm", string.format("%08x", i)) end
    local entries = 0
    for _ in pairs(Chat.lastReply) do entries = entries + 1 end
    check("M1c flood: 2000 different askers leave at most 100 remembered and 100 answers", entries <= Chat.MAX_REPLIES
        and entries == Chat.replyCount and #sent + #Chat.queue <= Chat.MAX_REPLIES, entries)
    clock = clock + 6
    check("M1c: expired askers are dropped when the table is full, the next asker is served", Chat.HandleRequest("Fresh-Realm", "deadbeef") == "err:unknown"
        and Chat.replyCount == 1, Chat.replyCount)
    local another = 0
    for _ in pairs(Chat.lastReply) do another = another + 1 end
    check("M1c: the table really shrank", another == 1, another)

    reset()
    local big = Chat.MakeOffer("WVX1:" .. string.rep("A", Chat.MAX_TOTAL - 5), "big")
    local served = 0
    for i = 1, 60 do
        if Chat.HandleRequest("Asker" .. i .. "-Realm", big) == "ok" then served = served + 1 end
    end
    check("M1a flood: full-size answers stop at the queue cap", #Chat.queue <= Chat.MAX_QUEUE and served >= 1 and served < 60,
        #Chat.queue .. "/" .. served)
    local before = #Chat.queue
    check("M1a: a request that no longer fits is ignored without a trace", Chat.HandleRequest("Late-Realm", big) == "ignored"
        and #Chat.queue == before and Chat.lastReply["late-realm"] == nil)
    check("M1a: Chat.After without C_Timer reports false and runs nothing", (function()
        local savedTimer, ran = C_Timer, false
        C_Timer = nil
        local result = realAfter(1, function() ran = true end)
        C_Timer = savedTimer
        return result == false and ran == false
    end)())

    -- one target failing does not empty the others
    reset()
    local offerCode = Chat.MakeOffer(TEXT, "x")
    local parts = #Chat.ChunkText(TEXT)
    sendResult = function(n) if sent[n].target == "Alice-Realm" then return 9 end return 0 end
    Chat.HandleRequest("Bob-Realm", offerCode)
    Chat.HandleRequest("Alice-Realm", offerCode)
    Chat.HandleRequest("Carol-Realm", "deadbeef")
    drain()
    local toBob, toAlice, toCarol = {}, 0, {}
    for _, entry in ipairs(sent) do
        if entry.target == "Bob-Realm" then toBob[#toBob + 1] = entry.message end
        if entry.target == "Alice-Realm" then toAlice = toAlice + 1 end
        if entry.target == "Carol-Realm" then toCarol[#toCarol + 1] = entry.message end
    end
    check("M1d: a failing send to A drops A's parts only (one try)", toAlice == 1 and #Chat.queue == 0 and Chat.pumping == false, toAlice)
    check("M1d: B still gets every part, in order", #toBob == parts and toBob[1]:find(":1/" .. parts .. ":", 1, true) ~= nil
        and toBob[parts]:find(":" .. parts .. "/" .. parts .. ":", 1, true) ~= nil, #toBob)
    check("M1d: C still gets the ERR", #toCarol == 1 and toCarol[1] == "ERR:deadbeef:unknown")
    sendResult = 0

    -- throttle out of retries is also one target's failure
    reset()
    offerCode = Chat.MakeOffer(TEXT, "x")
    sendResult = function(n) if sent[n].target == "Alice-Realm" then return 3 end return 0 end
    Chat.HandleRequest("Bob-Realm", offerCode)
    Chat.HandleRequest("Alice-Realm", offerCode)
    drain()
    local bobCount, aliceCount = 0, 0
    for _, entry in ipairs(sent) do
        if entry.target == "Bob-Realm" then bobCount = bobCount + 1 end
        if entry.target == "Alice-Realm" then aliceCount = aliceCount + 1 end
    end
    check("M1d: endless throttle for A (1 try + 5 retries) does not stop B", bobCount == parts and aliceCount == 6 and #Chat.queue == 0, bobCount .. "/" .. aliceCount)
    sendResult = 0

    -- a lockdown result is not about one target: the rest would fail the same way
    reset()
    offerCode = Chat.MakeOffer(TEXT, "x")
    sendResult = function(n) if n == 1 then return 0 end return 11 end
    Chat.HandleRequest("Bob-Realm", offerCode)
    Chat.HandleRequest("Carl-Realm", offerCode)
    drain()
    check("M1d: a lockdown result empties the whole queue", #sent == 2 and #Chat.queue == 0 and Chat.pumping == false, #sent)
    sendResult = 0
end

-- Review findings M2: double click and a click on another link --------------------------------------------
do
    reset()
    opened = {}
    local link = "addon:WoWraVox:import:0123abcd:Bob-Realm"
    Chat.OnLink(link)
    clock = clock + 1
    local pending = Chat.pending
    check("M2: second click on the same link while waiting does nothing but say so", Chat.OnLink(link) == true and #sent == 1
        and Chat.pending == pending and lastNote() == "Already requesting this group." and notes[#notes].isError == false, lastNote())
    clock = clock + 1
    Chat.OnLink("addon:WoWraVox:import:0123ABCD:bob-realm")
    check("M2: the same group with another spelling of the sender counts as the same", #sent == 1 and Chat.pending == pending)
    local result, text = Chat.HandleData("Bob-Realm", 1, 1, "0123abcd", "WVX1:A")
    check("M2: the transfer still arrives after the double click", result == "complete" and opened[1] == "WVX1:A" and text == "WVX1:A", result)

    reset()
    Chat.OnLink("addon:WoWraVox:import:00000001:Bob-Realm")
    clock = clock + 1
    Chat.OnLink("addon:WoWraVox:import:00000002:Carl-Realm")
    check("M2: a click on another link cancels the first request with a message and starts the new one", #sent == 2
        and sent[2].message == "REQ:00000002" and sent[2].target == "Carl-Realm" and Chat.pending.sender == "Carl-Realm"
        and notes[#notes - 1].text == "Request to Bob-Realm cancelled." and lastNote() == "Requesting group from Carl-Realm ...", lastNote())
    check("M2: data for the cancelled request is dropped", Chat.HandleData("Bob-Realm", 1, 1, "00000001", "WVX1:A") == "ignored")
    clock = clock + 1
    Chat.OnLink("addon:WoWraVox:import:00000003:Carl-Realm")
    check("M2: a click on another group from the same player also cancels", #sent == 3 and Chat.pending.code == "00000003"
        and notes[#notes - 1].text == "Request to Carl-Realm cancelled.")

    reset()
    Chat.OnLink(link)
    clock = clock + 16
    local before = #notes
    Chat.OnLink(link)
    check("M2: a request that ran out of time is simply replaced, no cancel message", #sent == 2 and #notes == before + 1
        and lastNote() == "Requesting group from Bob-Realm ...", lastNote())

    reset()
    local noteCount = #notes
    Chat.OnLink(link)
    Chat.OnLink(link)
    check("M2/hooks: the same link twice within a moment is one click (no REQ, no message)", #sent == 1 and #notes == noteCount + 1, #sent)
    clock = clock + 0.1
    Chat.OnLink(link)
    check("M2/hooks: still one click 0.1 s later", #sent == 1 and #notes == noteCount + 1)
end

-- Review findings M3: sender match is exact on Name-Realm ---------------------------------------------------
do
    GetNormalizedRealmName = function() return "RealmB" end
    reset()
    opened = {}
    Chat.OnLink("addon:WoWraVox:import:0123abcd:Bob-RealmA")
    check("M3: data from Bob without realm (= own realm B) is refused for a request to Bob-RealmA", Chat.HandleData("Bob", 1, 1, "0123abcd", "WVX1:A") == "ignored"
        and Chat.HandleData("bob-realmb", 1, 1, "0123abcd", "WVX1:A") == "ignored" and #opened == 0)
    check("M3: Bob-RealmA is accepted", Chat.HandleData("bob-RealmA", 1, 1, "0123abcd", "WVX1:A") == "complete")

    reset()
    Chat.OnLink("addon:WoWraVox:import:0123abcd:Bob")
    check("M3: a request to Bob without realm is a request to Bob-RealmB: Bob-RealmA is refused", Chat.HandleData("Bob-RealmA", 1, 1, "0123abcd", "WVX1:A") == "ignored")
    check("M3: Bob and Bob-RealmB match", Chat.HandleData("Bob", 1, 1, "0123abcd", "WVX1:A") == "complete")

    reset()
    Chat.OnLink("addon:WoWraVox:import:0123abcd:Bob-RealmA")
    check("M3: names that only share a prefix never match", Chat.HandleData("Bob-RealmAB", 1, 1, "0123abcd", "WVX1:A") == "ignored"
        and Chat.HandleData("Bobby-RealmA", 1, 1, "0123abcd", "WVX1:A") == "ignored" and Chat.HandleData("Bob-Real", 1, 1, "0123abcd", "WVX1:A") == "ignored")
    check("M3: ERR from Bob without realm is refused too", Chat.HandleError("Bob", "0123abcd", "unknown") == "ignored" and Chat.pending ~= nil)

    local out = Chat.RewriteMessage("[WoWraVox: x #12345678]", "Bob")
    check("M3 filter: an author without realm gets the own realm in the link", out:find("import:12345678:Bob-RealmB|h", 1, true) ~= nil, out)
    out = Chat.RewriteMessage("[WoWraVox: x #12345678]", "Bob-RealmA")
    check("M3 filter: an author with a realm is left as it is", out:find("import:12345678:Bob-RealmA|h", 1, true) ~= nil, out)
    GetNormalizedRealmName = nil
    GetRealmName = function() return "Twisting Nether" end
    out = Chat.RewriteMessage("[WoWraVox: x #12345678]", "Bob")
    check("M3 filter: GetRealmName is the fallback, spaces are removed", out:find("import:12345678:Bob-TwistingNether|h", 1, true) ~= nil, out)
    GetRealmName = nil
    out = Chat.RewriteMessage("[WoWraVox: x #12345678]", "Bob")
    check("M3 filter: no realm API, the author stays as it is", out:find("import:12345678:Bob|h", 1, true) ~= nil, out)

    GetNormalizedRealmName = function() return "RealmB" end
    reset()
    opened = {}
    local own = Chat.MakeOffer(TEXT, "Mine")
    Chat.OnLink("addon:WoWraVox:import:" .. own .. ":Hero-RealmB")
    check("M3: own link (Hero on the own realm) opens the own text", #sent == 0 and opened[1] == TEXT)
    clock = clock + 1
    Chat.OnLink("addon:WoWraVox:import:" .. own .. ":Hero-RealmA")
    check("M3: a Hero from another realm is not me: the request goes out", #sent == 1 and sent[1].target == "Hero-RealmA")
    GetNormalizedRealmName = nil
end

-- Review findings M4: the timeout moves on with every part, hard limit 60 s ------------------------------------
do
    local savedTotal = Chat.MAX_TOTAL
    Chat.MAX_TOTAL = 24 * 1024
    reset()
    opened = {}
    Chat.OnLink("addon:WoWraVox:import:0123abcd:Bob-Realm")
    local start = clock
    local count, verdict = 100, nil
    local midway
    for index = 1, count do
        clock = start + 0.15 * index
        verdict = Chat.HandleData("Bob-Realm", index, count, "0123abcd", string.rep("A", 200))
        if index == 50 then
            runTimers(true) -- the 15 s timer fires at 7.5 s here (mocked early): it must not time the request out
            midway = Chat.pending ~= nil
        end
    end
    check("M4: 100 parts at 0.15 s (15 s in all) arrive", verdict == "complete" and opened[1] and #opened[1] == 100 * 200, verdict)
    check("M4: an early timer does not end a request that still gets parts", midway == true)
    Chat.MAX_TOTAL = savedTotal

    reset()
    Chat.OnLink("addon:WoWraVox:import:0123abcd:Bob-Realm")
    start = clock
    clock = start + 10
    Chat.HandleData("Bob-Realm", 1, 2, "0123abcd", "AAAA")
    check("M4: an accepted part moves the end to now + 15", Chat.pending.expires == start + 25)
    clock = start + 15
    local noteCount = #notes
    runTimers(true)
    check("M4: the first timer finds time left and sets itself again for the rest", Chat.pending ~= nil and #notes == noteCount
        and timers[1] and timers[1].seconds == 10, timers[1] and timers[1].seconds)
    clock = start + 25
    runTimers(true)
    check("M4: without further parts the request times out 15 s after the last part", Chat.pending == nil
        and lastNote():find("No answer from Bob-Realm", 1, true) == 1)

    reset()
    Chat.OnLink("addon:WoWraVox:import:0123abcd:Bob-Realm")
    start = clock
    clock = start + 5
    Chat.HandleData("Bob-Realm", 1, 2, "0123abcd", "AAAA")
    Chat.HandleData("Bob-Realm", 1, 2, "0123abcd", "AAAA")
    check("M4: a duplicate does not move the end", Chat.pending.expires == start + 20)
    Chat.HandleData("Bob-Realm", 1, 2, "0123abcd", "bad part")
    check("M4: a refused part does not move the end", Chat.pending.expires == start + 20)

    reset()
    opened = {}
    Chat.OnLink("addon:WoWraVox:import:0123abcd:Bob-Realm")
    start = clock
    local accepted = {}
    for index = 1, 7 do
        clock = start + 10 * index
        accepted[index] = Chat.HandleData("Bob-Realm", index, 30, "0123abcd", "AAAA")
    end
    check("M4: parts keep it alive up to 60 s, not beyond", accepted[5] == "ok" and accepted[6] == "ignored" and accepted[7] == "ignored"
        and Chat.pending.expires == start + 60, tostring(accepted[5]) .. "/" .. tostring(accepted[6]))
    runTimers(true)
    check("M4: the request ends with the no-answer message at the hard limit", Chat.pending == nil
        and lastNote():find("No answer from Bob-Realm", 1, true) == 1 and #opened == 0)
end

-- Junk in every handler -----------------------------------------------------------------------------------
do
    reset()
    local junk = { nil, false, true, 0, -1, 1e308, 0 / 0, "", "\0", string.rep("x", 100000), {}, { 1, 2 }, function() end, SECRET,
        "REQ:", "DATA:::", "DATA:00000000:1/1:", "DATA:00000000:99999/1:x", "ERR:zz:", "|Haddon:x|h" }
    local functions = { "BuildMarker", "MakeOffer", "ChunkText", "RewriteMessage", "HandleRequest", "HandleData", "HandleError",
        "OnAddonMessage", "OnLink", "ParseLink", "Filter", "SendToChat", "OpenChat" }
    local failures = 0
    Chat.OnLink("addon:WoWraVox:import:00000000:Bob")
    for _, name in ipairs(functions) do
        for index = 1, 21 do
            local a, b, c, d, e = junk[index], junk[(index % 21) + 1], junk[((index + 3) % 21) + 1], junk[((index + 5) % 21) + 1], "x"
            if not pcall(Chat[name], a, b, c, d, e) then
                failures = failures + 1
                print("INFO junk failed in " .. name .. " at " .. index)
            end
        end
    end
    check("junk: no handler raises a Lua error", failures == 0, failures)
end

-- Send to chat --------------------------------------------------------------------------------------------
do
    reset()
    local opens = {}
    ChatFrame_OpenChat = function(text) opens[#opens + 1] = text end
    local ok, marker = Chat.SendToChat(TEXT, "Shield group")
    check("send to chat: marker goes into the chat box (ChatFrame_OpenChat fallback)", ok and #opens == 1
        and opens[1] == marker and marker:match("^%[WoWraVox: Shield group #%x%x%x%x%x%x%x%x%]$") ~= nil, marker)
    local code = marker:match("#(%x+)%]")
    check("send to chat: the offer is kept for the code", Chat.offers[code] and Chat.offers[code].text == TEXT)
    check("send to chat: the marker is not sent by the addon", #sent == 0)
    check("send to chat: the player is told what to do", lastNote() == "Link placed in the chat box. Press Enter to send it.")
    ChatFrameUtil = { OpenChat = function(text) opens[#opens + 1] = "util:" .. text end }
    Chat.SendToChat(TEXT, "Shield group")
    check("send to chat: ChatFrameUtil.OpenChat is preferred when present", opens[#opens] == "util:" .. marker, opens[#opens])
    ChatFrameUtil, ChatFrame_OpenChat = nil, nil
    reset()
    ok = Chat.SendToChat(TEXT, "x")
    check("send to chat: no chat function gives a friendly error", ok == false and lastNote() == "The chat box is unavailable." and notes[#notes].isError)
    ChatFrame_OpenChat = function() error("boom") end
    check("send to chat: a failing chat function raises nothing", Chat.SendToChat(TEXT, "x") == false)
    ChatFrame_OpenChat = function(text) opens[#opens + 1] = text end
    reset()
    lockdown = true
    local before = #opens
    ok = Chat.SendToChat(TEXT, "x")
    check("send to chat: blocked when restricted, with message and no offer", ok == false and #opens == before
        and lastNote() == "Sharing is blocked during encounters, Mythic+ and PvP." and #Chat.offerOrder == 0)
    lockdown = false
    ok = Chat.SendToChat("not an export", "x")
    check("send to chat: invalid text gives an error and no chat input", ok == false and #opens == before)
    ChatFrame_OpenChat = nil
end

-- Install: client wiring ----------------------------------------------------------------------------------
do
    reset()
    local filters, callbacks, frames, hooks = {}, {}, {}, {}
    registered = {}
    ChatFrame_AddMessageEventFilter = function(event, fn) filters[#filters + 1] = { event = event, fn = fn } end
    EventRegistry = { RegisterCallback = function(self, event, fn, owner) callbacks[#callbacks + 1] = { event = event, fn = fn, owner = owner } end }
    CreateFrame = function()
        local frame = { events = {}, scripts = {} }
        function frame:RegisterEvent(event) self.events[event] = true end
        function frame:SetScript(name, fn) self.scripts[name] = fn end
        frames[#frames + 1] = frame
        return frame
    end
    Chat.installed = nil
    local done = Chat.Install()
    check("install: prefix WVX registered", registered[1] == "WVX" and done.prefix)
    check("install: CHAT_MSG_ADDON frame created", frames[1] and frames[1].events.CHAT_MSG_ADDON and done.frame)
    local wanted = { "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_INSTANCE_CHAT",
        "CHAT_MSG_INSTANCE_CHAT_LEADER", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_WHISPER", "CHAT_MSG_SAY", "CHAT_MSG_YELL" }
    local seen = {}
    for _, entry in ipairs(filters) do seen[entry.event] = entry.fn == Chat.Filter end
    local complete = #filters == #wanted
    for _, event in ipairs(wanted) do if seen[event] ~= true then complete = false end end
    check("install: filter on the 11 channels, none on Battle.net whispers", complete and seen.CHAT_MSG_BN_WHISPER == nil, #filters)
    check("install: SetItemRef callback registered", callbacks[1] and callbacks[1].event == "SetItemRef" and done.click)
    Chat.Install()
    check("install: running again adds nothing", #filters == 11 and #callbacks == 1 and #frames == 1 and #registered == 1)

    frames[1].scripts.OnEvent(frames[1], "CHAT_MSG_ADDON", "WVX", "REQ:deadbeef", "WHISPER", "Bob")
    check("event frame: CHAT_MSG_ADDON reaches the handler", #sent == 1 and sent[1].message == "ERR:deadbeef:unknown")
    sent = {}
    callbacks[1].fn(callbacks[1].owner, "addon:WoWraVox:import:0123abcd:Bob", "text", "LeftButton")
    check("click callback: owner first, link second", #sent == 1 and sent[1].message == "REQ:0123abcd")
    sent = {}
    callbacks[1].fn("addon:WoWraVox:import:0123abcd:Carl", "text", "LeftButton")
    check("click callback: link first also works", #sent == 1 and sent[1].target == "Carl")
    sent = {}
    callbacks[1].fn(callbacks[1].owner, "item:123", "[Sword]", "LeftButton")
    callbacks[1].fn(callbacks[1].owner, nil, nil, nil)
    callbacks[1].fn()
    check("click callback: other links and junk do nothing", #sent == 0)

    -- fallbacks and missing APIs
    EventRegistry = nil
    SetItemRef = function() end
    hooksecurefunc = function(name, fn) hooks[#hooks + 1] = { name = name, fn = fn } end
    Chat.installed = nil
    Chat.Install()
    check("install: hooksecurefunc fallback on SetItemRef without EventRegistry", hooks[1] and hooks[1].name == "SetItemRef")
    sent = {}
    hooks[1].fn("addon:WoWraVox:import:0123abcd:Dora", "text", "LeftButton")
    check("install: the fallback hook handles the link", #sent == 1 and sent[1].target == "Dora")

    -- both click paths installed at once: one click must stay one request, whichever fires first
    local callbacks2, hooks2 = {}, {}
    EventRegistry = { RegisterCallback = function(self, event, fn, owner) callbacks2[#callbacks2 + 1] = { event = event, fn = fn, owner = owner } end }
    hooksecurefunc = function(name, fn) hooks2[#hooks2 + 1] = { name = name, fn = fn } end
    Chat.installed = nil
    local both = Chat.Install()
    check("install: EventRegistry and the SetItemRef hook are both wired", both.click == true and both.hook == true
        and #callbacks2 == 1 and #hooks2 == 1 and hooks2[1].name == "SetItemRef")
    Chat.Install()
    check("install: running again wires neither twice", #callbacks2 == 1 and #hooks2 == 1)
    reset()
    local doubleLink = "addon:WoWraVox:import:0123abcd:Erin-Realm"
    callbacks2[1].fn(callbacks2[1].owner, doubleLink, "text", "LeftButton")
    hooks2[1].fn(doubleLink, "text", "LeftButton")
    check("double fire (EventRegistry, then hook): one REQ and no extra message", #sent == 1 and sent[1].target == "Erin-Realm"
        and #notes == 1 and lastNote() == "Requesting group from Erin-Realm ...", #sent)
    reset()
    hooks2[1].fn(doubleLink, "text", "LeftButton")
    callbacks2[1].fn(callbacks2[1].owner, doubleLink, "text", "LeftButton")
    check("double fire (hook, then EventRegistry): one REQ and no extra message", #sent == 1 and #notes == 1, #sent)
    clock = clock + 1
    hooks2[1].fn(doubleLink, "text", "LeftButton")
    check("a later click on the same link is a new click (answered with the hint)", #sent == 1 and lastNote() == "Already requesting this group.")
    EventRegistry, hooksecurefunc, Chat.installed = nil, function(name, fn) hooks[#hooks + 1] = { name = name, fn = fn } end, nil

    ChatFrame_AddMessageEventFilter, ChatFrameUtil = nil, { AddMessageEventFilter = function(event, fn) filters[#filters + 1] = { event = event, fn = fn } end }
    filters = {}
    Chat.installed = nil
    Chat.Install()
    check("install: ChatFrameUtil.AddMessageEventFilter used when the global is missing", #filters == 11)

    ChatFrameUtil, hooksecurefunc, SetItemRef, CreateFrame, C_ChatInfo = nil, nil, nil, nil, nil
    Chat.installed = nil
    check("install: no APIs at all raises no error", pcall(Chat.Install))
    C_ChatInfo = {
        SendAddonMessage = function(prefix, message, chatType, target)
            sent[#sent + 1] = { prefix = prefix, message = message, chatType = chatType, target = target }
            return sendResult
        end,
        RegisterAddonMessagePrefix = function() return 0 end,
        InChatMessagingLockdown = function() return lockdown end,
    }
    Chat.installed = nil
end

-- Hooks in WoWraVox.lua: widget mocks, export button, import with text ------------------------------------
do
    reset()
    ns.ShareUI.openImport = realOpenImport
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

    C_EncodingUtil = {
        SerializeCBOR = (function()
            local store, n = {}, 0
            ns.testCBORStore = store
            return function(value)
                n = n + 1
                store["CBOR" .. n] = value
                return "CBOR" .. n
            end
        end)(),
        DeserializeCBOR = function(source) return ns.testCBORStore[source] end,
        CompressString = function(source) return source end,
        DecompressString = function(source) return source end,
        EncodeBase64 = function(source) return source end,
        DecodeBase64 = function(source) return source end,
    }
    UnitClass = function() return "Mage", "MAGE", 8 end
    C_Spell = { GetSpellInfo = function(id) if id == 100 then return { name = "Charge", iconID = 132337 } end end }

    local rule = ns.newAuraRule()
    rule.name = "UI group"
    rule.spellIDs = { 100 }
    rule.applyEnabled = true
    rule.applyMessage = "Up"
    ns.ShareUI.openExport(rule)
    local exportFrame = ns.ShareUI.exportFrame
    local exportText = exportFrame.edit.text
    check("export window: no Send to chat button any more", exportFrame.sendToChat == nil and exportFrame.sendText == nil
        and exportFrame.sendName == nil)

    -- Ctrl-click path: ns.ShareUI.postToChat(rule) passes the export text and the group name to ShareChat
    local captured = {}
    local realSendToChat = Chat.SendToChat
    Chat.SendToChat = function(text, name) captured[#captured + 1] = { text = text, name = name } return true end
    ns.ShareUI.postToChat(rule)
    -- The CBOR mock gives a new token per call, so the text is checked by its format and by Parse, not by equality.
    local parsedOk, parsedGroup = ns.ShareGroups.Parse(captured[1] and captured[1].text or "")
    check("post to chat: export text and group name go to ShareChat", #captured == 1 and captured[1].text:sub(1, 5) == "WVX1:"
        and captured[1].name == "UI group" and parsedOk == true and parsedGroup.name == "UI group", #captured)
    local calls = #captured
    ns.ShareUI.postToChat({ builtin = true, name = "Bloodlust", spellIDs = { 2825 } })
    check("post to chat: a built-in rule is not sent (export refuses it)", #captured == calls)
    Chat.SendToChat = function() return false end
    local ran = pcall(ns.ShareUI.postToChat, rule)
    check("post to chat: a failing ShareChat call raises nothing", ran == true)
    Chat.SendToChat = realSendToChat

    -- real path: Ctrl-click -> offer -> request -> parts -> import window with a passed check
    local opens = {}
    ChatFrame_OpenChat = function(text) opens[#opens + 1] = text end
    ns.ShareUI.postToChat(rule)
    local code = opens[1] and opens[1]:match("#(%x+)%]")
    check("post to chat: marker in the chat box", code ~= nil, opens[1])
    local linked = Chat.RewriteMessage(opens[1], "Hero-Realm")
    local linkData = linked:match("|H(.-)|h")
    check("post to chat: marker rewrites into a link with this code", linkData == "addon:WoWraVox:import:" .. code .. ":Hero-Realm", linkData)
    local shareText = Chat.offers[code] and Chat.offers[code].text
    Chat.HandleRequest("Bob-Realm", code)
    drain()
    local wire = messages()
    reset()
    Chat.OnLink("addon:WoWraVox:import:" .. code .. ":Bob-Realm")
    sent = {}
    -- the offer was cleared by reset(); build the same answer from the captured wire messages
    for _, message in ipairs(wire) do Chat.OnAddonMessage("WVX", message, "WHISPER", "Bob-Realm") end
    local importFrame = ns.ShareUI.importFrame
    check("received group: import window open with the text in the box", importFrame and importFrame.shown and importFrame.edit.text == shareText)
    check("received group: check ran by itself and passed", importFrame.summary.text == "Name: UI group"
        and importFrame.error.text == "Check passed. Click Import to add the group.", importFrame.error.text)
    check("received group: Import is enabled but nothing was imported yet", importFrame.importButton.enabled == true)

    ns.ShareUI.openImport()
    check("openImport without text: empty box, no check, Import disabled", importFrame.edit.text == "" and importFrame.importButton.enabled == false
        and importFrame.error.text == "Paste a group text, then click Check.")
    ns.ShareUI.openImport("not an export")
    check("openImport with bad text: error shown, Import disabled", importFrame.error.text == "Not a WoWraVox export." and importFrame.importButton.enabled == false)
    ChatFrame_OpenChat = nil
end

print("ALL PASS")
