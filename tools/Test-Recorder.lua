local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. tostring(detail)) or "")) end
    print("PASS " .. name)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Fakes. The frame stub is strict: only the methods Recorder.lua uses exist, so a typo fails here, but the stub says
-- nothing about layout or about whether the real client has the method (see the report).
local clock = 1000
function GetTime() return clock end
local timers = {}
C_Timer = { After = function(delay, fn) timers[#timers + 1] = { at = clock + delay, fn = fn } end }
local function advance(seconds)
    clock = clock + seconds
    local due, rest = {}, {}
    for _, timer in ipairs(timers) do
        if timer.at <= clock then due[#due + 1] = timer else rest[#rest + 1] = timer end
    end
    timers = rest
    for _, timer in ipairs(due) do timer.fn() end
end

-- A "secret" value: any index / arithmetic / compare / concat / call on it raises, like in the client.
local function secretMeta(label)
    local function trap() error("secret " .. label .. " was used") end
    return { __index = trap, __newindex = trap, __lt = trap, __le = trap, __concat = trap, __call = trap, __len = trap,
        __add = trap, __sub = trap, __unm = trap, __tostring = trap }
end
local SECRET = setmetatable({}, secretMeta("value"))
local SECRET_TABLE = setmetatable({}, secretMeta("table"))
function issecretvalue(value) return rawequal(value, SECRET) or rawequal(value, SECRET_TABLE) end
function issecrettable(value) return rawequal(value, SECRET_TABLE) end

function wipe(t) for k in pairs(t) do t[k] = nil end return t end
local chat = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) chat[#chat + 1] = message end }
local function lastChat() return chat[#chat] or "" end
UISpecialFrames = {}
UIParent = {}
local locale = "enUS"
function GetLocale() return locale end

local allFrames = {}
local noop = function() end
local frameMethods = {}
for _, name in ipairs({ "SetSize", "SetPoint", "SetFrameStrata", "SetToplevel", "SetFrameLevel", "SetBackdrop",
    "SetBackdropColor", "SetBackdropBorderColor", "SetColorTexture", "SetTexCoord", "SetJustifyH", "SetWidth",
    "SetHighlightTexture", "SetAllPoints", "SetScrollChild", "SetAutoFocus", "SetMaxLetters", "ClearFocus",
    "SetFromAlpha", "SetToAlpha", "SetDuration", "SetLooping", "Play", "Stop", "SetMovable" }) do
    frameMethods[name] = noop
end
local function newStub(kind, parent, template)
    local f = { kind = kind, parent = parent, template = template, shown = false, enabled = true, scripts = {},
        events = {}, text = "", alpha = 1, mouse = false }
    allFrames[#allFrames + 1] = f
    return setmetatable(f, { __index = frameMethods })
end
function frameMethods.Show(self) self.shown = true end
function frameMethods.Hide(self)
    local was = self.shown
    self.shown = false
    if was and self.scripts.OnHide then self.scripts.OnHide(self) end
end
function frameMethods.IsShown(self) return self.shown end
function frameMethods.SetEnabled(self, value) self.enabled = value and true or false end
function frameMethods.EnableMouse(self, value) self.mouse = value and true or false end
function frameMethods.SetAlpha(self, value) self.alpha = value end
function frameMethods.SetHeight(self, value) self.height = value end
function frameMethods.SetText(self, value) self.text = value end
function frameMethods.GetText(self) return self.text end
function frameMethods.SetTexture(self, value) self.texture = value end
function frameMethods.SetScript(self, name, fn) self.scripts[name] = fn end
function frameMethods.RegisterEvent(self, name) self.events[name] = true end
function frameMethods.RegisterUnitEvent(self, name) self.events[name] = true end
function frameMethods.UnregisterAllEvents(self) wipe(self.events) end
function frameMethods.CreateTexture(self) return newStub("Texture", self) end
function frameMethods.CreateFontString(self) return newStub("FontString", self) end
function frameMethods.CreateAnimationGroup(self) return newStub("AnimationGroup", self) end
function frameMethods.CreateAnimation(self) return newStub("Animation", self) end
function frameMethods.Click(self) self.scripts.OnClick(self) end
function CreateFrame(kind, name, parent, template)
    local f = newStub(kind, parent, template)
    if name then _G[name] = f end
    return f
end

local spells = {
    [1459] = { name = "Arcane Intellect", icon = 135932 },
    [2825] = { name = "Bloodlust", icon = 136012 },
    [20473] = { name = "Holy Shock", icon = 135972 },
    [100] = { name = "Charge", icon = 132337 },
    [200] = { name = "Old Cooldown", icon = 1 },
    [300] = { name = "Secret Cooldown", icon = 2 },
    [777] = { name = "Lit Buff", icon = 3 },
}
C_Spell = {
    GetSpellInfo = function(id) local s = spells[id]; if s then return { name = s.name, iconID = s.icon } end end,
    GetSpellTexture = function(id) return spells[id] and spells[id].icon end,
    GetSpellCooldown = function(id) local s = spells[id]; return s and s.cd end,
}

local Recorder = ns.Recorder
local x = Recorder.x
local function cast(spellID, guid) Recorder.frame.scripts.OnEvent(Recorder.frame, "UNIT_SPELLCAST_SUCCEEDED", "player", guid, spellID) end
local function auraEvent(updateInfo, unit) Recorder.frame.scripts.OnEvent(Recorder.frame, "UNIT_AURA", unit or "player", updateInfo) end
local function cooldownEvent(spellID) Recorder.frame.scripts.OnEvent(Recorder.frame, "SPELL_UPDATE_COOLDOWN", spellID) end
local function entry(kind, id) return Recorder.current.byKey[kind .. ":" .. id] end
local guidCounter = 0
local function nextGUID() guidCounter = guidCounter + 1; return "Cast-" .. guidCounter end
local function shownRows(win)
    local n = 0
    for _, row in ipairs(win.rows) do if row.shown then n = n + 1 end end
    return n
end

-- ---------------------------------------------------------------------------------------------------------------
-- Before anything was recorded
check("module is exposed", type(Recorder.Start) == "function" and type(Recorder.Stop) == "function" and Recorder.x ~= nil)
check("/wvrec is registered", SLASH_WOWRAVOXREC1 == "/wvrec" and type(SlashCmdList.WOWRAVOXREC) == "function")
SlashCmdList.WOWRAVOXREC("show")
check("show with nothing recorded says so", lastChat():find("Nothing recorded yet", 1, true) and not x.win)
SlashCmdList.WOWRAVOXREC("bogus")
check("unknown argument prints the usage", lastChat():find("/wvrec show", 1, true))
check("stop without a recording is harmless", Recorder.Stop() == false)

-- ---------------------------------------------------------------------------------------------------------------
-- Start
local cdmCalls = {}
local originalCDM = function(ids, active, info) cdmCalls[#cdmCalls + 1] = { ids = ids, active = active, info = info }; return "orig" end
ns._Aura = { cdmSignal = originalCDM }
SlashCmdList.WOWRAVOXREC("")
local rec = Recorder.current
check("/wvrec starts a recording", Recorder.IsRecording() and rec ~= nil and Recorder.last == nil)
check("events registered while recording", Recorder.frame.events.UNIT_SPELLCAST_SUCCEEDED and Recorder.frame.events.UNIT_AURA
    and Recorder.frame.events.SPELL_UPDATE_COOLDOWN)
check("small window is shown and click-through", x.mini.shown and x.mini.mouse == false)
check("starting twice is refused", Recorder.Start() == false and Recorder.current == rec)
check("CDM signal is wrapped", ns._Aura.cdmSignal ~= originalCDM)

-- Casts
local startedAt = clock
cast(1459, nextGUID())
local intellect = entry("cast", 1459)
check("cast is recorded with name and icon", intellect and intellect.name == "Arcane Intellect" and intellect.icon == 135932)
local guid = nextGUID()
cast(5001, guid); cast(5001, guid)
check("same cast GUID counts once", entry("cast", 5001).seen == 1)
check("unknown spell falls back to ID name and question mark", entry("cast", 5001).name == "Spell ID 5001"
    and entry("cast", 5001).icon == x.unknownIcon)
cast(1459, nextGUID())
check("repeat cast bumps the seen counter, not the list", entry("cast", 1459).seen == 2 and rec.counts.cast == 3)
Recorder.frame.scripts.OnEvent(Recorder.frame, "UNIT_SPELLCAST_SUCCEEDED", "target", nextGUID(), 6000)
Recorder.frame.scripts.OnEvent(Recorder.frame, "UNIT_SPELLCAST_SUCCEEDED", "party1", nextGUID(), 6001)
check("only the player's own casts", not entry("cast", 6000) and not entry("cast", 6001))
local before = #rec.entries
Recorder.frame.scripts.OnEvent(Recorder.frame, "UNIT_SPELLCAST_SUCCEEDED", "player", nextGUID(), SECRET)
local hiddenCast = rec.entries[#rec.entries]
check("secret cast ID: hidden placeholder, no error", #rec.entries == before + 1 and hiddenCast.hidden
    and hiddenCast.spellID == nil and rec.errors == 0)

-- Auras
advance(5)
auraEvent({ addedAuras = { { spellId = 2825, name = "Bloodlust", icon = 136012, applications = 0, duration = 40 } } })
local lust = entry("aura", 2825)
check("aura: name, icon, readable duration", lust and lust.name == "Bloodlust" and lust.icon == 136012 and lust.duration == 40)
auraEvent({ addedAuras = { { spellId = 9001, name = "Stacky", icon = 9, applications = 3, duration = SECRET } } })
check("aura: stack count kept, secret duration dropped", entry("aura", 9001).count == 3 and entry("aura", 9001).duration == nil)
auraEvent({ addedAuras = { { spellId = 9002, name = SECRET, icon = SECRET, applications = SECRET, duration = SECRET } } })
check("aura: secret name/icon fall back to spell info", entry("aura", 9002) and entry("aura", 9002).name == "Spell ID 9002"
    and entry("aura", 9002).count == nil and rec.errors == 0)
cast(20473, nextGUID())
before = #rec.entries
auraEvent({ addedAuras = { { spellId = SECRET, name = SECRET, icon = SECRET, applications = 1, duration = 5 } } })
local hiddenAura = rec.entries[#rec.entries]
check("secret aura ID: hidden placeholder remembering the cast", #rec.entries == before + 1 and hiddenAura.hidden
    and hiddenAura.spellID == nil and hiddenAura.relatedCast == 20473 and hiddenAura.name == "Hidden aura" and rec.errors == 0)
before = #rec.entries
auraEvent({ isFullUpdate = true, addedAuras = { { spellId = 9100, name = "x", icon = 1 } } })
auraEvent({ addedAuras = { { spellId = 9101, name = "x", icon = 1 } } }, "target")
auraEvent(SECRET_TABLE)
auraEvent({ addedAuras = SECRET_TABLE })
auraEvent(nil)
check("full update, other units, secret tables: nothing recorded, no error", #rec.entries == before and rec.errors == 0)
auraEvent({ addedAuras = { SECRET_TABLE } })
check("a secret aura table inside the list is a hidden aura", #rec.entries == before + 1 and rec.entries[#rec.entries].hidden and rec.errors == 0)

-- Cooldown Manager signal
local ids777 = { 777 }
local result = ns._Aura.cdmSignal(ids777, true, { instanceID = 4 })
check("CDM wrapper passes through to the original", result == "orig" and #cdmCalls == 1 and cdmCalls[1].ids == ids777)
local lit = entry("aura", 777)
check("CDM signal records a hidden aura with its ID", lit and lit.hidden and lit.source == "cdm" and lit.name == "Lit Buff")
ns._Aura.cdmSignal({ 888 }, false)
check("CDM going dark records nothing", not entry("aura", 888))
before = #rec.entries
ns._Aura.cdmSignal(ids777, true)
check("CDM repeat inside 1.5 s is not a new entry", lit.seen == 1 and #rec.entries == before)
ns._Aura.cdmSignal({ 2825 }, true)
check("CDM signal for an aura already read is ignored", lust.seen == 1)
advance(0.2)
auraEvent({ addedAuras = { { spellId = SECRET, name = SECRET } } })
local pending = rec.entries[#rec.entries]
before = #rec.entries
ns._Aura.cdmSignal({ 4242 }, true)
check("CDM signal resolves the fresh hidden placeholder", #rec.entries == before and pending.spellID == 4242
    and pending.source == "cdm" and entry("aura", 4242) == pending)

-- Cooldown starts
spells[20473].cd = { startTime = clock, duration = 12, isEnabled = true, isOnGCD = false }
cast(20473, nextGUID())
check("cooldown is not read before the delay", not entry("cooldown", 20473))
advance(0.2)
check("cooldown start is recorded with its duration", entry("cooldown", 20473) and entry("cooldown", 20473).duration == 12)
cooldownEvent(20473)
check("same cooldown seen again is not a second start", entry("cooldown", 20473).seen == 1)
advance(20)
spells[20473].cd = { startTime = clock, duration = 12, isEnabled = true, isOnGCD = false }
cooldownEvent(20473)
check("a new start of the same cooldown counts again", entry("cooldown", 20473).seen == 2)
spells[100].cd = { startTime = clock, duration = 1.5, isEnabled = true, isOnGCD = true }
cast(100, nextGUID()); advance(0.2)
check("global cooldown is ignored, the cast is kept", entry("cast", 100) and not entry("cooldown", 100))
spells[200].cd = { startTime = rec.startedAt - 30, duration = 120, isEnabled = true, isOnGCD = false }
cooldownEvent(200)
check("a cooldown that started before the recording is only a baseline", not entry("cooldown", 200))
spells[300].cd = { startTime = SECRET, duration = SECRET, isEnabled = true, isOnGCD = SECRET }
cast(300, nextGUID()); advance(0.2)
check("secret cooldown: cast kept, no cooldown, no error", entry("cast", 300) and not entry("cooldown", 300) and rec.errors == 0)
spells[300].cd = SECRET_TABLE
cooldownEvent(300)
check("secret cooldown table: no error", rec.errors == 0)
cooldownEvent(nil); cooldownEvent(SECRET)
check("cooldown event without a public spell ID is ignored", rec.errors == 0)

-- Ring buffer
for id = 5101, 5108 do cast(id, nextGUID()) end
check("ring shows newest first", x.ringEntry(rec, 1).spellID == 5108 and x.ringEntry(rec, 6).spellID == 5103)
check("ring is capped at its size", x.ringEntry(rec, 7) == nil and rec.ringCount == Recorder.ringSize)
local shownIcons = 0
for _, icon in ipairs(x.mini.icons) do if icon.shown then shownIcons = shownIcons + 1 end end
check("small window shows ringSize icons", shownIcons == Recorder.ringSize and x.mini.icons[1].texture == x.unknownIcon
    and x.mini.label.text == "Recording · " .. #rec.entries)

-- Entry cap
Recorder.Stop()
Recorder.maxEntries = 20
Recorder.Start()
local small = Recorder.current
for id = 1, 30 do cast(7000 + id, nextGUID()) end
check("entry list is capped, oldest dropped", #small.entries == 20 and small.dropped == 10 and small.entries[1].spellID == 7011
    and small.byKey["cast:7001"] == nil and small.byKey["cast:7030"] == small.entries[20])
check("occurrences still count after the cap", small.counts.cast == 30)
Recorder.Stop()
Recorder.maxEntries = 500
check("summary mentions dropped entries", x.win.summary.text:find("10 older entries", 1, true))
Recorder.Start()
local big = Recorder.current
for id = 1, 600 do cast(20000 + id, nextGUID()) end
check("default cap is 500 entries", #big.entries == 500 and big.dropped == 100)
Recorder.Stop()

-- ---------------------------------------------------------------------------------------------------------------
-- Stop and the large window
Recorder.Start()
rec = Recorder.current
check("a new recording drops the old result and hides its window", Recorder.last == nil and not x.win.shown)
cast(1459, nextGUID()); cast(20473, nextGUID())
spells[20473].cd = { startTime = clock, duration = 12, isEnabled = true, isOnGCD = false }
advance(0.2)
auraEvent({ addedAuras = { { spellId = 2825, name = "Bloodlust", icon = 136012, applications = 0, duration = 40 } } })
auraEvent({ addedAuras = { { spellId = 9001, name = "Stacky", icon = 9, applications = 3 } } })
auraEvent({ addedAuras = { { spellId = SECRET } } })
check("show while recording is refused", Recorder.Show() == false and lastChat():find("Still recording", 1, true))
local originalAfterStop = ns._Aura.cdmSignal
SlashCmdList.WOWRAVOXREC("")
local win = x.win
check("stop ends the recording and keeps the result", not Recorder.IsRecording() and Recorder.last == rec and rec.stoppedAt)
check("events and CDM wrapper are gone", next(Recorder.frame.events) == nil and ns._Aura.cdmSignal == originalCDM
    and originalAfterStop ~= originalCDM)
check("small window hidden, large window shown", not x.mini.shown and win.shown)
check("large window is clickable and closes with Escape", win.mouse == true and UISpecialFrames[1] == "WoWraVoxRecorderWindow")
check("one row per entry", shownRows(win) == #rec.entries and #rec.entries == 6, #rec.entries)
check("summary line carries the counts", win.summary.text:find("6 entries", 1, true) and win.summary.text:find("2 casts", 1, true))

local function rowFor(kind, id)
    for _, row in ipairs(win.rows) do
        if row.shown and row.entry and row.entry.kind == kind and row.entry.spellID == id then return row end
    end
end
local function placeholderRow()
    for _, row in ipairs(win.rows) do if row.shown and row.entry and not row.entry.spellID then return row end end
end
local stacky = rowFor("aura", 9001)
check("row shows name, ID, type, count", stacky.name.text == "Stacky" and stacky.id.text == "9001"
    and stacky.kind.text == "Aura" and stacky.count.text == "3" and stacky.duration.text == "")
check("row shows readable duration", rowFor("aura", 2825).duration.text == "40 s")
check("cooldown row shows its duration", rowFor("cooldown", 20473).duration.text == "12 s" and rowFor("cooldown", 20473).kind.text == "Cooldown")
check("hidden placeholder row has no ID and is dimmed", placeholderRow().id.text == "-" and placeholderRow().alpha < 1)

win.filters.cast:Click()
check("cast filter lists only casts", shownRows(win) == 2 and not win.filters.cast.enabled and win.filters.all.enabled)
win.filters.all:Click()
check("all filter lists everything again", shownRows(win) == 6)

-- Selection without a host
check("no host: both group buttons disabled", ns.RecorderHost == nil and not win.addButton.enabled and not win.newButton.enabled)
check("no host: status explains it", win.status.text:find("not available", 1, true))
rowFor("aura", 9001):Click()
check("click selects a row", win.selected[stacky.entry] and stacky.selection.shown)
check("no host: buttons stay disabled with a selection", not win.addButton.enabled and not win.newButton.enabled)
placeholderRow():Click()
check("hidden placeholder cannot be selected", #x.selectedIDs(win) == 1)
stacky:Click()
check("second click deselects", #x.selectedIDs(win) == 0 and not stacky.selection.shown)

-- With a host
local hostCalls = {}
local rules = { { name = "Defensives", spellIDs = { 1 } }, { name = "Procs", spellIDs = {} } }
ns.RecorderHost = {
    Rules = function() return rules end,
    AddToRule = function(rule, ids) hostCalls[#hostCalls + 1] = { "add", rule, ids } end,
    NewRule = function(name, ids) hostCalls[#hostCalls + 1] = { "new", name, ids } end,
}
Recorder.Show()
check("show reopens the last result", win.shown and win.rec == rec and #x.selectedIDs(win) == 0)
check("nothing selected: group buttons disabled", not win.addButton.enabled and not win.newButton.enabled)
win.addButton:Click()
rowFor("aura", 9001):Click(); rowFor("cast", 1459):Click(); rowFor("cooldown", 20473):Click(); rowFor("cast", 20473):Click()
check("selection enables both buttons", win.addButton.enabled and win.newButton.enabled and win.status.text:find("3 spell IDs", 1, true),
    win.status.text)
local ids = x.selectedIDs(win)
check("selected IDs are unique and in recorded order", table.concat(ids, ",") == "1459,20473,9001", table.concat(ids, ","))
win.addButton:Click()
local picker = win.picker
check("Add to group opens a picker with the rules", picker.shown and picker.rows[1].text.text == "Defensives"
    and picker.rows[2].text.text == "Procs" and not picker.rows[3])
picker.rows[2]:Click()
check("picking a rule calls AddToRule with the IDs", #hostCalls == 1 and hostCalls[1][1] == "add" and hostCalls[1][2] == rules[2]
    and table.concat(hostCalls[1][3], ",") == "1459,20473,9001" and not picker.shown)
check("selection is cleared and the result confirmed", #x.selectedIDs(win) == 0 and win.status.text:find("added to Procs", 1, true)
    and lastChat():find("added to Procs", 1, true))

rowFor("aura", 2825):Click(); rowFor("aura", 9001):Click()
win.nameBox:SetText("  Bloodlust set  ")
win.newButton:Click()
check("New group from selection passes name and IDs", hostCalls[2][1] == "new" and hostCalls[2][2] == "Bloodlust set"
    and table.concat(hostCalls[2][3], ",") == "2825,9001" and win.nameBox.text == "")
rowFor("aura", 2825):Click()
win.newButton:Click()
check("empty name gets a default", hostCalls[3][2] == "Recorded group " .. rec.serial, hostCalls[3][2])
win.selectAll:Click()
ids = x.selectedIDs(win)
check("Select all takes every entry with an ID (unique IDs) and no placeholder", #ids == 4 and not win.selected[placeholderRow().entry], #ids)
win.clear:Click()
check("Clear empties the selection", #x.selectedIDs(win) == 0)

ns.RecorderHost.AddToRule = function() error("boom") end
rowFor("aura", 2825):Click()
win.addButton:Click()
picker.rows[1]:Click()
check("a failing host call is reported and nothing breaks", win.status.text:find("Could not add", 1, true) and #x.selectedIDs(win) == 1)
ns.RecorderHost.Rules = function() return {} end
win.addButton:Click()
check("no rules yet: hint instead of an empty picker", win.status.text:find("No aura groups yet", 1, true))
ns.RecorderHost = { Rules = function() return rules end } -- host without AddToRule / NewRule
x.updateButtons(win)
check("partial host disables the missing buttons", not win.addButton.enabled and not win.newButton.enabled)

win:Hide()
check("closing the window keeps the result", Recorder.last == rec)
Recorder.Show()
check("it can be reopened after closing", win.shown)

-- ---------------------------------------------------------------------------------------------------------------
-- Cheap and contained
local onUpdate = 0
for _, frame in ipairs(allFrames) do if frame.scripts.OnUpdate then onUpdate = onUpdate + 1 end end
check("no OnUpdate handler anywhere", onUpdate == 0)
Recorder.Start()
local errors = Recorder.current
errors.entries = nil -- break the state on purpose
cast(1459, nextGUID())
check("a failing handler is contained and counted", errors.errors == 1 and errors.lastError ~= nil)
errors.entries = {}
Recorder.Stop()

-- ---------------------------------------------------------------------------------------------------------------
-- German: every string the recorder asks for has a translation
local de = ns.Locales.deDE
local misses = {}
setmetatable(de, { __index = function(_, key) misses[key] = true end })
locale = "deDE"
x.win, x.mini = nil, nil
ns.RecorderHost = { Rules = function() return rules end, AddToRule = function() end, NewRule = function() end }
SlashCmdList.WOWRAVOXREC("show")
Recorder.Start()
cast(1459, nextGUID()); cast(20473, nextGUID())
auraEvent({ addedAuras = { { spellId = SECRET } } })
auraEvent({ addedAuras = { { spellId = 2825, name = "Bloodlust", icon = 1, applications = 2, duration = 100 } } })
Recorder.frame.scripts.OnEvent(Recorder.frame, "UNIT_SPELLCAST_SUCCEEDED", "player", nextGUID(), SECRET)
ns._Aura.cdmSignal({ 777 }, true)
SlashCmdList.WOWRAVOXREC("bogus")
Recorder.Show()
Recorder.Stop()
win = x.win
win.addButton:Click() -- nothing selected
for _, row in ipairs(win.rows) do if row.shown and row.entry and row.entry.spellID then row:Click() end end
win.addButton:Click()
win.picker.rows[1]:Click()
win.nameBox:SetText("")
win.selectAll:Click()
win.newButton:Click()
x.setStatus(win, "")
x.updateButtons(win)
ns.RecorderHost = nil
x.updateButtons(win)
Recorder.Start(); Recorder.Stop()
local missing = {}
for key in pairs(misses) do missing[#missing + 1] = key end
table.sort(missing)
check("German has every recorder string", #missing == 0, table.concat(missing, " | "))
locale = "enUS"
