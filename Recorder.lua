local _, ns = ...

-- Session recorder (/wvrec). Independent of every rule: while it runs it notes the player's own casts, new auras and
-- cooldown starts. A tiny click-through window shows "Recording" plus the last few icons; after the stop one large
-- window lists everything, and a selection can go into an aura group (ns.RecorderHost, implemented by WoWraVox.lua).
-- Event driven only (no OnUpdate). Helpers live in Recorder.x because of the 200-locals limit of a main chunk.

local Recorder = ns.Recorder or {}
ns.Recorder = Recorder
Recorder.x = Recorder.x or {}
local x = Recorder.x

Recorder.maxEntries = 500 -- unique entries; the oldest drop out
Recorder.ringSize = 6     -- icons in the small window
Recorder.cooldownDelay = 0.15
Recorder.current = nil    -- the running recording
Recorder.last = nil       -- the finished one the large window shows (dropped when a new recording starts)
Recorder.serial = Recorder.serial or 0

x.unknownIcon = 134400    -- question mark
x.gcdSpellID = 61304
x.rowHeight = 24
x.kindOrder = { "cast", "aura", "cooldown" }
x.filterKeys = { "all", "cast", "aura", "cooldown" }

---------------------------------------------------------------------------------------------------------------------
-- Safe reads (nothing here compares or indexes a secret value)

function x.L(key)
    local locales = ns.Locales or {}
    local messages = locales[GetLocale and GetLocale() or "enUS"] or locales.enUS
    return (messages and messages[key]) or key
end

function x.isSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) == true
end

function x.safeNumber(value)
    return not x.isSecret(value) and type(value) == "number"
        and value == value and value ~= math.huge and value ~= -math.huge
end

function x.publicInteger(value)
    return x.safeNumber(value) and value > 0 and value == math.floor(value)
end

function x.field(object, key)
    if type(object) ~= "table" or (issecrettable and issecrettable(object)) then return nil, false end
    local ok, value = pcall(function() return object[key] end)
    if not ok or x.isSecret(value) then return nil, false end
    return value, true
end

function x.isIcon(value)
    if x.isSecret(value) then return false end
    return (type(value) == "number" and value > 0) or (type(value) == "string" and value ~= "")
end

function x.say(message)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffd8b65aWoWraVox:|r " .. message) end
end

function x.trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function x.spellInfo(spellID)
    local name, icon
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
        if ok then
            local infoName = x.field(info, "name")
            if type(infoName) == "string" and infoName ~= "" then name = infoName end
            local infoIcon = x.field(info, "iconID")
            if x.isIcon(infoIcon) then icon = infoIcon end
        end
    end
    if not icon and C_Spell and C_Spell.GetSpellTexture then
        local ok, texture = pcall(C_Spell.GetSpellTexture, spellID)
        if ok and x.isIcon(texture) then icon = texture end
    end
    return name or (x.L("Spell ID") .. " " .. tostring(spellID)), icon or x.unknownIcon
end

function x.formatDuration(seconds)
    if not x.safeNumber(seconds) or seconds <= 0 then return "" end
    if seconds < 60 then
        if seconds == math.floor(seconds) then return string.format("%d s", seconds) end
        return string.format("%.1f s", seconds)
    end
    return string.format("%d:%02d min", math.floor(seconds / 60), math.floor(seconds % 60))
end

function x.formatClock(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

function x.readCooldown(spellID)
    if not (C_Spell and C_Spell.GetSpellCooldown) then return nil, false end
    local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
    if not ok or type(info) ~= "table" or (issecrettable and issecrettable(info)) then return nil, false end
    local startTime, startOK = x.field(info, "startTime")
    local duration, durationOK = x.field(info, "duration")
    local isEnabled, enabledOK = x.field(info, "isEnabled")
    local isOnGCD, gcdOK = x.field(info, "isOnGCD")
    if not (startOK and durationOK and enabledOK and x.safeNumber(startTime) and x.safeNumber(duration)
        and type(isEnabled) == "boolean") then return nil, false end
    if not gcdOK then isOnGCD = nil end
    return { startTime = startTime, duration = duration, isEnabled = isEnabled, isOnGCD = isOnGCD }, true
end

function x.isGlobalCooldown(cooldown)
    if cooldown.isOnGCD == true then return true end
    if cooldown.isOnGCD == false then return false end
    local gcd, ok = x.readCooldown(x.gcdSpellID)
    return ok and gcd.duration > 0 and gcd.startTime > 0
        and math.abs(cooldown.startTime - gcd.startTime) <= 0.05
        and math.abs(cooldown.duration - gcd.duration) <= 0.05 or false
end

---------------------------------------------------------------------------------------------------------------------
-- Recording

function x.newRecording()
    Recorder.serial = Recorder.serial + 1
    return {
        serial = Recorder.serial,
        startedAt = GetTime(),
        entries = {},     -- unique entries in order of first sight
        byKey = {},       -- "kind:spellID" -> entry
        ring = {},        -- last ringSize occurrences (newest at ringPos - 1)
        ringPos = 1,
        ringCount = 0,
        cd = {},          -- spellID -> { active, startTime }
        counts = { cast = 0, aura = 0, cooldown = 0 }, -- occurrences, repeats included
        dropped = 0,
        errors = 0,
    }
end

function x.pushRing(rec, entry)
    local size = Recorder.ringSize
    rec.ring[rec.ringPos] = entry
    rec.ringPos = rec.ringPos % size + 1
    rec.ringCount = math.min(size, rec.ringCount + 1)
end

-- index 1 = newest
function x.ringEntry(rec, index)
    if index > rec.ringCount then return nil end
    local size = Recorder.ringSize
    return rec.ring[(rec.ringPos - 1 - index) % size + 1]
end

function x.removeEntry(rec, entry)
    for index, other in ipairs(rec.entries) do
        if other == entry then
            table.remove(rec.entries, index)
            break
        end
    end
    if entry.key and rec.byKey[entry.key] == entry then rec.byKey[entry.key] = nil end
end

-- info: name, icon, count, duration, hidden, source, relatedCast
function x.record(rec, kind, spellID, info)
    info = info or {}
    local now = GetTime()
    local key = spellID and (kind .. ":" .. spellID) or nil
    local entry = key and rec.byKey[key]
    if entry then
        entry.seen = entry.seen + 1
        entry.lastAt = now - rec.startedAt
        if info.count ~= nil then entry.count = info.count end
        if info.duration ~= nil then entry.duration = info.duration end
        if not info.hidden then entry.hidden = false end
    else
        local name, icon = info.name, info.icon
        if spellID and not (name and icon) then
            local spellName, spellIcon = x.spellInfo(spellID)
            name, icon = name or spellName, icon or spellIcon
        end
        entry = {
            kind = kind, key = key, spellID = spellID, name = name, icon = icon or x.unknownIcon,
            count = info.count, duration = info.duration, hidden = info.hidden == true,
            source = info.source, relatedCast = info.relatedCast, seen = 1,
            at = now - rec.startedAt, lastAt = now - rec.startedAt, wall = now,
        }
        table.insert(rec.entries, entry)
        if key then rec.byKey[key] = entry end
        if #rec.entries > Recorder.maxEntries then
            x.removeEntry(rec, rec.entries[1])
            rec.dropped = rec.dropped + 1
        end
    end
    rec.counts[kind] = (rec.counts[kind] or 0) + 1
    x.pushRing(rec, entry)
    x.refreshMini(rec)
    return entry
end

function x.onCast(rec, unit, castGUID, spellID)
    if x.isSecret(unit) or unit ~= "player" then return end
    if type(castGUID) == "string" and not x.isSecret(castGUID) then
        if castGUID == rec.lastCastGUID then return end
        rec.lastCastGUID = castGUID
    end
    local now = GetTime()
    if x.publicInteger(spellID) then
        x.record(rec, "cast", spellID)
        rec.lastCast = { spellID = spellID, at = now }
        if C_Timer and C_Timer.After then
            C_Timer.After(Recorder.cooldownDelay, function()
                if Recorder.current == rec then pcall(x.sampleCooldown, rec, spellID) end
            end)
        end
    else
        rec.lastCast = nil
        x.record(rec, "cast", nil, { hidden = true, name = x.L("Hidden cast"), source = "UNIT_SPELLCAST_SUCCEEDED" })
    end
end

function x.onCooldownEvent(rec, spellID)
    if x.publicInteger(spellID) then x.sampleCooldown(rec, spellID) end
end

-- A cooldown counts once per start: a new startTime after an inactive sample. One that began before the recording
-- (or reads secret / global) is only a baseline.
function x.sampleCooldown(rec, spellID)
    local cooldown, ok = x.readCooldown(spellID)
    if not ok then return end
    local now = GetTime()
    local active = cooldown.isEnabled ~= false and cooldown.startTime > 0 and cooldown.duration > 0
        and cooldown.startTime + cooldown.duration > now + 0.12 and not x.isGlobalCooldown(cooldown)
    local state = rec.cd[spellID]
    if not active then
        if state and state.active then rec.cd[spellID] = { active = false } end
        return
    end
    local startedBefore = cooldown.startTime < rec.startedAt - 0.5
    local isNew = not startedBefore and (not state or not state.active or math.abs(state.startTime - cooldown.startTime) > 0.25)
    rec.cd[spellID] = { active = true, startTime = cooldown.startTime }
    if isNew then x.record(rec, "cooldown", spellID, { duration = cooldown.duration }) end
end

function x.addAura(rec, aura)
    local now = GetTime()
    local spellID, idOK = x.field(aura, "spellId")
    if not (idOK and x.publicInteger(spellID)) then
        local relatedCast
        if rec.lastCast and now - rec.lastCast.at <= 1 then relatedCast = rec.lastCast.spellID end
        rec.pendingHidden = x.record(rec, "aura", nil, {
            hidden = true, name = x.L("Hidden aura"), source = "UNIT_AURA", relatedCast = relatedCast })
        return
    end
    local info = { source = "UNIT_AURA" }
    local name = x.field(aura, "name")
    if type(name) == "string" and name ~= "" then info.name = name end
    local icon = x.field(aura, "icon")
    if x.isIcon(icon) then info.icon = icon end
    local count = x.field(aura, "applications")
    if x.safeNumber(count) and count >= 0 then info.count = count end
    local duration = x.field(aura, "duration")
    if x.safeNumber(duration) and duration > 0 then info.duration = duration end
    x.record(rec, "aura", spellID, info)
end

function x.onAura(rec, unit, updateInfo)
    if x.isSecret(unit) or unit ~= "player" then return end
    local fullUpdate = x.field(updateInfo, "isFullUpdate")
    if fullUpdate == true then return end -- zone change / reload: nothing new happened
    local added, addedOK = x.field(updateInfo, "addedAuras")
    if not (addedOK and type(added) == "table") then return end
    for _, aura in ipairs(added) do pcall(x.addAura, rec, aura) end
end

-- The Cooldown Manager icon lights up even while the aura behind it is hidden: ns._Aura.cdmSignal (called from
-- WoWraVoxTooltip.lua) is wrapped for the length of a recording and always passes through.
function x.onCDM(rec, spellIDs, active)
    if active ~= true or type(spellIDs) ~= "table" then return end
    local spellID
    for _, id in ipairs(spellIDs) do
        if x.publicInteger(id) then spellID = id; break end
    end
    if not spellID then return end
    local now = GetTime()
    local key = "aura:" .. spellID
    local existing = rec.byKey[key]
    if existing and now - rec.startedAt - existing.lastAt < 1.5 then return end -- the readable path saw it already
    local pending = rec.pendingHidden
    if pending and not pending.spellID and now - pending.wall <= 2 then
        rec.pendingHidden = nil
        if existing then
            x.removeEntry(rec, pending)
            existing.seen = existing.seen + 1
            existing.lastAt = now - rec.startedAt
        else
            local name, icon = x.spellInfo(spellID)
            pending.spellID, pending.key, pending.name, pending.icon, pending.source = spellID, key, name, icon, "cdm"
            rec.byKey[key] = pending
            x.refreshMini(rec)
        end
        return
    end
    x.record(rec, "aura", spellID, { hidden = true, source = "cdm" })
end

function x.hookCDM(rec)
    local aura = ns._Aura
    if type(aura) ~= "table" or type(aura.cdmSignal) ~= "function" then return end
    local original = aura.cdmSignal
    rec.cdmOriginal = original
    rec.cdmWrapper = function(spellIDs, active, info)
        if Recorder.current == rec then pcall(x.onCDM, rec, spellIDs, active) end
        return original(spellIDs, active, info)
    end
    aura.cdmSignal = rec.cdmWrapper
end

function x.unhookCDM(rec)
    local aura = ns._Aura
    if rec.cdmWrapper and type(aura) == "table" and aura.cdmSignal == rec.cdmWrapper then
        aura.cdmSignal = rec.cdmOriginal
    end
    rec.cdmWrapper = nil -- a wrapper someone else stacked on top stays in place but is inert (Recorder.current ~= rec)
end

function x.dispatch(event, ...)
    local rec = Recorder.current
    if not rec then return end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then x.onCast(rec, ...)
    elseif event == "UNIT_AURA" then x.onAura(rec, ...)
    elseif event == "SPELL_UPDATE_COOLDOWN" then x.onCooldownEvent(rec, ...)
    end
end

function x.onEvent(_, event, ...)
    local ok, err = pcall(x.dispatch, event, ...)
    local rec = Recorder.current
    if not ok and rec then
        rec.errors = rec.errors + 1
        rec.lastError = tostring(err)
    end
end

function x.registerEvents()
    if not Recorder.frame then
        Recorder.frame = CreateFrame("Frame")
        Recorder.frame:SetScript("OnEvent", x.onEvent)
    end
    local frame = Recorder.frame
    if frame.RegisterUnitEvent then
        frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
        frame:RegisterUnitEvent("UNIT_AURA", "player")
    else
        frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        frame:RegisterEvent("UNIT_AURA")
    end
    frame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
end

---------------------------------------------------------------------------------------------------------------------
-- Small window (click-through)

function x.createMini()
    if x.mini then return x.mini end
    if not (CreateFrame and UIParent) then return nil end
    local size = Recorder.ringSize
    local frame = CreateFrame("Frame", "WoWraVoxRecorderMini", UIParent, "BackdropTemplate")
    frame:SetSize(12 + size * 22, 46)
    frame:SetPoint("LEFT", UIParent, "LEFT", 4, -120)
    frame:SetFrameStrata("MEDIUM")
    frame:EnableMouse(false)
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    frame:SetBackdropColor(0.025, 0.03, 0.04, 0.78)
    frame:SetBackdropBorderColor(0.75, 0.15, 0.15, 1)
    frame.dot = frame:CreateTexture(nil, "ARTWORK")
    frame.dot:SetSize(9, 9)
    frame.dot:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -6)
    frame.dot:SetColorTexture(0.95, 0.12, 0.12, 1)
    frame.label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.label:SetPoint("LEFT", frame.dot, "RIGHT", 5, 0)
    frame.icons = {}
    for index = 1, size do
        local icon = frame:CreateTexture(nil, "ARTWORK")
        icon:SetSize(20, 20)
        icon:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 6 + (index - 1) * 22, 5)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:Hide()
        frame.icons[index] = icon
    end
    -- a slow blink from the animation engine, no OnUpdate
    pcall(function()
        local group = frame.dot:CreateAnimationGroup()
        local fade = group:CreateAnimation("Alpha")
        fade:SetFromAlpha(1)
        fade:SetToAlpha(0.25)
        fade:SetDuration(0.8)
        group:SetLooping("BOUNCE")
        frame.dot.blink = group
    end)
    frame:Hide()
    x.mini = frame
    return frame
end

function x.refreshMini(rec)
    local mini = x.mini
    if not (mini and mini:IsShown()) then return end
    mini.label:SetText(x.L("Recording") .. " · " .. #rec.entries)
    for index, icon in ipairs(mini.icons) do
        local entry = x.ringEntry(rec, index)
        if entry then
            icon:SetTexture(entry.icon or x.unknownIcon)
            icon:SetAlpha(math.max(0.35, 1 - (index - 1) * 0.12))
            icon:Show()
        else
            icon:Hide()
        end
    end
end

function x.showMini(rec)
    local mini = x.createMini()
    if not mini then return end
    mini:Show()
    if mini.dot.blink then mini.dot.blink:Play() end
    x.refreshMini(rec)
end

function x.hideMini()
    local mini = x.mini
    if not mini then return end
    if mini.dot.blink then mini.dot.blink:Stop() end
    mini:Hide()
end

---------------------------------------------------------------------------------------------------------------------
-- Large window (after the stop)

function x.host()
    local host = ns.RecorderHost
    return type(host) == "table" and host or nil
end

function x.kindLabel(kind)
    if kind == "cast" then return x.L("Cast") end
    if kind == "aura" then return x.L("Aura") end
    return x.L("Cooldown")
end

function x.entryTexts(entry)
    local name = entry.name or ""
    -- a hidden entry without ID is already named "Hidden aura/cast"; one with an ID came from the Cooldown Manager
    if entry.hidden and entry.spellID then name = name .. " |cffff9040(" .. x.L("hidden aura") .. ")|r" end
    if entry.relatedCast then
        local castName = x.spellInfo(entry.relatedCast)
        name = name .. " |cff9a9a9a" .. string.format(x.L("after %s"), castName) .. "|r"
    end
    return {
        name = name,
        id = entry.spellID and tostring(entry.spellID) or "-",
        kind = x.kindLabel(entry.kind),
        count = (entry.count and entry.count > 0) and tostring(entry.count) or "",
        duration = x.formatDuration(entry.duration),
        seen = entry.seen > 1 and ("×" .. entry.seen) or "",
    }
end

function x.visibleEntries(rec, filter)
    local list = {}
    for _, entry in ipairs(rec.entries) do
        if filter == "all" or filter == entry.kind then list[#list + 1] = entry end
    end
    return list
end

function x.selectedIDs(win)
    local ids, seen = {}, {}
    local rec = win.rec
    for _, entry in ipairs(rec and rec.entries or {}) do
        if win.selected[entry] and entry.spellID and not seen[entry.spellID] then
            seen[entry.spellID] = true
            ids[#ids + 1] = entry.spellID
        end
    end
    return ids
end

function x.setStatus(win, message)
    win.status:SetText(message or "")
end

function x.updateButtons(win)
    local ids = x.selectedIDs(win)
    local host = x.host()
    local canAdd = host ~= nil and type(host.Rules) == "function" and type(host.AddToRule) == "function"
    local canNew = host ~= nil and type(host.NewRule) == "function"
    win.addButton:SetEnabled(#ids > 0 and canAdd)
    win.newButton:SetEnabled(#ids > 0 and canNew)
    if not (canAdd or canNew) then
        x.setStatus(win, x.L("Adding to groups is not available in this version."))
    else
        x.setStatus(win, #ids > 0 and string.format(x.L("%d spell IDs selected"), #ids)
            or x.L("Click rows to select them."))
    end
end

function x.fillRow(row, entry, selected)
    local texts = x.entryTexts(entry)
    row.icon:SetTexture(entry.icon or x.unknownIcon)
    row.name:SetText(texts.name)
    row.id:SetText(texts.id)
    row.kind:SetText(texts.kind)
    row.count:SetText(texts.count)
    row.duration:SetText(texts.duration)
    row.seen:SetText(texts.seen)
    if selected then row.selection:Show() else row.selection:Hide() end
    row:SetAlpha(entry.spellID and 1 or 0.5)
end

function x.createRow(win, index)
    local row = CreateFrame("Button", nil, win.child)
    row:SetHeight(x.rowHeight)
    row:SetPoint("TOPLEFT", win.child, "TOPLEFT", 0, -(index - 1) * x.rowHeight)
    row:SetPoint("TOPRIGHT", win.child, "TOPRIGHT", 0, -(index - 1) * x.rowHeight)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    row.selection = row:CreateTexture(nil, "BACKGROUND")
    row.selection:SetAllPoints()
    row.selection:SetColorTexture(0.72, 0.52, 0.12, 0.22)
    row.selection:Hide()
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    for _, column in ipairs(x.columns) do
        local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("LEFT", row, "LEFT", column.x, 0)
        text:SetWidth(column.width)
        text:SetJustifyH("LEFT")
        row[column.key] = text
    end
    row:SetScript("OnClick", function(self)
        local entry = self.entry
        if not (entry and entry.spellID) then return end -- a hidden aura has no ID to add
        win.selected[entry] = not win.selected[entry] or nil
        x.fillRow(self, entry, win.selected[entry])
        x.updateButtons(win)
    end)
    win.rows[index] = row
    return row
end

x.columns = {
    { key = "name", label = "Name", x = 30, width = 250 },
    { key = "id", label = "Spell ID", x = 286, width = 70 },
    { key = "kind", label = "Type", x = 360, width = 70 },
    { key = "count", label = "Count", x = 434, width = 40 },
    { key = "duration", label = "Duration", x = 478, width = 70 },
    { key = "seen", label = "Seen", x = 552, width = 44 },
}

function x.refreshList(win)
    local rec = win.rec
    local list = rec and x.visibleEntries(rec, win.filter) or {}
    for index, entry in ipairs(list) do
        local row = win.rows[index] or x.createRow(win, index)
        row.entry = entry
        x.fillRow(row, entry, win.selected[entry])
        row:Show()
    end
    for index = #list + 1, #win.rows do
        win.rows[index].entry = nil
        win.rows[index]:Hide()
    end
    win.child:SetHeight(math.max(1, #list * x.rowHeight))
    win.empty:SetText(#list == 0 and x.L("Nothing was recorded.") or "")
    for key, button in pairs(win.filters) do button:SetEnabled(key ~= win.filter) end
end

function x.summary(rec)
    local text = string.format(x.L("%d entries · %s · %d casts · %d auras · %d cooldowns"),
        #rec.entries, x.formatClock((rec.stoppedAt or GetTime()) - rec.startedAt),
        rec.counts.cast, rec.counts.aura, rec.counts.cooldown)
    if rec.dropped > 0 then
        text = text .. "\n" .. string.format(x.L("The list was full: %d older entries were dropped."), rec.dropped)
    end
    return text
end

function x.clearSelection(win)
    win.selected = {}
    x.refreshList(win)
    x.updateButtons(win)
end

function x.selectAllVisible(win)
    for _, entry in ipairs(x.visibleEntries(win.rec, win.filter)) do
        if entry.spellID then win.selected[entry] = true end
    end
    x.refreshList(win)
    x.updateButtons(win)
end

function x.afterGroupChange(win, message)
    win.selected = {}
    x.refreshList(win)
    x.updateButtons(win)
    x.setStatus(win, message)
    x.say(message)
end

function x.addToRule(win, rule)
    local host, ids = x.host(), x.selectedIDs(win)
    if not (host and type(host.AddToRule) == "function") or #ids == 0 then return end
    local ok, err = pcall(host.AddToRule, rule, ids)
    local name = type(rule) == "table" and rule.name or x.L("Unnamed group")
    if ok then
        x.afterGroupChange(win, string.format(x.L("Spell IDs added to %s."), tostring(name)))
    else
        x.setStatus(win, string.format(x.L("Could not add: %s"), tostring(err)))
    end
end

function x.newGroup(win)
    local host, ids = x.host(), x.selectedIDs(win)
    if not (host and type(host.NewRule) == "function") or #ids == 0 then return end
    local name = x.trim(win.nameBox:GetText())
    if name == "" then name = string.format(x.L("Recorded group %d"), win.rec.serial) end
    local ok, err = pcall(host.NewRule, name, ids)
    if ok then
        win.nameBox:SetText("")
        x.afterGroupChange(win, string.format(x.L("Group %s created."), name))
    else
        x.setStatus(win, string.format(x.L("Could not add: %s"), tostring(err)))
    end
end

function x.createPicker(win)
    if win.picker then return win.picker end
    local picker = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    picker:SetSize(320, 330)
    picker:SetPoint("CENTER", win, "CENTER", 0, 0)
    picker:SetFrameStrata("FULLSCREEN_DIALOG")
    picker:SetToplevel(true)
    picker:SetFrameLevel(200)
    picker:EnableMouse(true)
    picker:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
    picker:SetBackdropColor(0.025, 0.03, 0.04, 0.99)
    picker:SetBackdropBorderColor(0.7, 0.55, 0.2, 1)
    picker:Hide()
    picker.title = picker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    picker.title:SetPoint("TOPLEFT", picker, "TOPLEFT", 14, -12)
    picker.title:SetText(x.L("Add to which group?"))
    local close = CreateFrame("Button", nil, picker, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", picker, "TOPRIGHT", -4, -4)
    picker.scroll = CreateFrame("ScrollFrame", nil, picker, "UIPanelScrollFrameTemplate")
    picker.scroll:SetPoint("TOPLEFT", picker, "TOPLEFT", 12, -40)
    picker.scroll:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -30, 12)
    picker.child = CreateFrame("Frame", nil, picker.scroll)
    picker.child:SetSize(270, 1)
    picker.scroll:SetScrollChild(picker.child)
    picker.rows = {}
    win.picker = picker
    return picker
end

function x.openPicker(win)
    local host, ids = x.host(), x.selectedIDs(win)
    if not (host and type(host.Rules) == "function" and type(host.AddToRule) == "function") then return end
    if #ids == 0 then
        x.setStatus(win, x.L("Select at least one entry with a spell ID first."))
        return
    end
    local ok, rules = pcall(host.Rules)
    if not ok or type(rules) ~= "table" or #rules == 0 then
        x.setStatus(win, x.L("No aura groups yet. Use New group from selection."))
        return
    end
    local picker = x.createPicker(win)
    for index, rule in ipairs(rules) do
        local row = picker.rows[index]
        if not row then
            row = CreateFrame("Button", nil, picker.child)
            row:SetHeight(22)
            row:SetPoint("TOPLEFT", picker.child, "TOPLEFT", 0, -(index - 1) * 22)
            row:SetPoint("TOPRIGHT", picker.child, "TOPRIGHT", 0, -(index - 1) * 22)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.text:SetPoint("LEFT", row, "LEFT", 6, 0)
            row.text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            row.text:SetJustifyH("LEFT")
            row:SetScript("OnClick", function(self)
                picker:Hide()
                x.addToRule(win, self.rule)
            end)
            picker.rows[index] = row
        end
        row.rule = rule
        row.text:SetText(type(rule) == "table" and rule.name or x.L("Unnamed group"))
        row:Show()
    end
    for index = #rules + 1, #picker.rows do
        picker.rows[index].rule = nil
        picker.rows[index]:Hide()
    end
    picker.child:SetHeight(math.max(1, #rules * 22))
    picker:Show()
end

function x.createWindow()
    if x.win then return x.win end
    if not (CreateFrame and UIParent) then return nil end
    local win = CreateFrame("Frame", "WoWraVoxRecorderWindow", UIParent, "BackdropTemplate")
    win:SetSize(680, 540)
    win:SetPoint("CENTER")
    win:SetFrameStrata("FULLSCREEN_DIALOG")
    win:SetToplevel(true)
    win:SetFrameLevel(100)
    win:EnableMouse(true)
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "WoWraVoxRecorderWindow") end
    win:Hide()
    win:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
    win:SetBackdropColor(0.025, 0.03, 0.04, 0.98)
    win:SetBackdropBorderColor(0.7, 0.55, 0.2, 1)
    win.selected, win.rows, win.filters, win.filter = {}, {}, {}, "all"

    win.title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    win.title:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -14)
    win.title:SetText(x.L("Session recording"))
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", win, "TOPRIGHT", -4, -4)
    win.summary = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    win.summary:SetPoint("TOPLEFT", win.title, "BOTTOMLEFT", 0, -8)
    win.summary:SetWidth(640)
    win.summary:SetJustifyH("LEFT")

    local previous
    for _, key in ipairs(x.filterKeys) do
        local button = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        button:SetSize(90, 22)
        if previous then button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        else button:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -72) end
        button:SetText(x.L(key == "all" and "All" or key == "cast" and "Casts" or key == "aura" and "Auras" or "Cooldowns"))
        button:SetScript("OnClick", function()
            win.filter = key
            x.refreshList(win)
        end)
        win.filters[key] = button
        previous = button
    end
    win.selectAll = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    win.selectAll:SetSize(90, 22)
    win.selectAll:SetPoint("TOPRIGHT", win, "TOPRIGHT", -14, -72)
    win.selectAll:SetText(x.L("Select all"))
    win.selectAll:SetScript("OnClick", function() x.selectAllVisible(win) end)
    win.clear = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    win.clear:SetSize(70, 22)
    win.clear:SetPoint("RIGHT", win.selectAll, "LEFT", -4, 0)
    win.clear:SetText(x.L("Clear"))
    win.clear:SetScript("OnClick", function() x.clearSelection(win) end)

    win.scroll = CreateFrame("ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
    win.scroll:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -122)
    win.scroll:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -32, 84)
    win.child = CreateFrame("Frame", nil, win.scroll)
    win.child:SetSize(600, 1)
    win.scroll:SetScrollChild(win.child)
    for _, column in ipairs(x.columns) do
        local header = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        header:SetPoint("BOTTOMLEFT", win.scroll, "TOPLEFT", column.x, 2)
        header:SetText(x.L(column.label))
    end
    win.empty = win:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    win.empty:SetPoint("CENTER", win.scroll, "CENTER", 0, 0)

    win.status = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    win.status:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 16, 56)
    win.status:SetWidth(640)
    win.status:SetJustifyH("LEFT")

    win.addButton = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    win.addButton:SetSize(110, 26)
    win.addButton:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 14, 14)
    win.addButton:SetText(x.L("Add to group"))
    win.addButton:SetScript("OnClick", function() x.openPicker(win) end)
    win.nameBox = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
    win.nameBox:SetSize(140, 24)
    win.nameBox:SetPoint("LEFT", win.addButton, "RIGHT", 16, 0)
    win.nameBox:SetAutoFocus(false)
    win.nameBox:SetMaxLetters(60)
    win.nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    win.nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    win.newButton = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    win.newButton:SetSize(200, 26)
    win.newButton:SetPoint("LEFT", win.nameBox, "RIGHT", 6, 0)
    win.newButton:SetText(x.L("New group from selection"))
    win.newButton:SetScript("OnClick", function() x.newGroup(win) end)
    win.closeButton = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    win.closeButton:SetSize(80, 26)
    win.closeButton:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -14, 14)
    win.closeButton:SetText(x.L("Close"))
    win.closeButton:SetScript("OnClick", function() win:Hide() end)
    win:SetScript("OnHide", function()
        if win.picker then win.picker:Hide() end
    end)
    x.win = win
    return win
end

function x.showWindow(rec)
    local win = x.createWindow()
    if not win then return end
    win.rec = rec
    win.selected = {}
    win.filter = "all"
    win.summary:SetText(x.summary(rec))
    x.refreshList(win)
    x.updateButtons(win)
    win:Show()
end

---------------------------------------------------------------------------------------------------------------------
-- Public interface

function Recorder.IsRecording()
    return Recorder.current ~= nil
end

function Recorder.Start()
    if Recorder.current then return false end
    Recorder.last = nil -- the previous result is dropped only now
    if x.win then
        x.win.rec = nil
        x.win.selected = {}
        x.win:Hide()
    end
    local rec = x.newRecording()
    Recorder.current = rec
    x.registerEvents()
    x.hookCDM(rec)
    x.showMini(rec)
    x.say(x.L("Recording started. Play normally; /wvrec stops it."))
    return true
end

function Recorder.Stop()
    local rec = Recorder.current
    if not rec then return false end
    Recorder.current = nil
    rec.stoppedAt = GetTime()
    if Recorder.frame then Recorder.frame:UnregisterAllEvents() end
    x.unhookCDM(rec)
    x.hideMini()
    Recorder.last = rec
    x.say(string.format(x.L("Recording stopped: %d entries."), #rec.entries))
    x.showWindow(rec)
    return true
end

function Recorder.Toggle()
    if Recorder.current then return Recorder.Stop() end
    return Recorder.Start()
end

function Recorder.Show()
    if Recorder.current then
        x.say(x.L("Still recording. Stop it with /wvrec first."))
        return false
    end
    if not Recorder.last then
        x.say(x.L("Nothing recorded yet. Use /wvrec to start."))
        return false
    end
    x.showWindow(Recorder.last)
    return true
end

function Recorder.Command(message)
    local command = x.trim(message):lower()
    if command == "" then Recorder.Toggle()
    elseif command == "show" then Recorder.Show()
    else x.say(x.L("Use /wvrec to start or stop, /wvrec show to reopen the last recording.")) end
end

SLASH_WOWRAVOXREC1 = "/wvrec"
if type(SlashCmdList) == "table" then SlashCmdList.WOWRAVOXREC = Recorder.Command end
