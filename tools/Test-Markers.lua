local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. detail) or "")) end
    print("PASS " .. name)
end

local M = ns.Markers
local function keys(rule)
    local out = {}
    for _, m in ipairs(rule.markers) do out[#out + 1] = m.key .. "@" .. string.format("%g", m.at) end
    return table.concat(out, ",")
end

-- Migration
local plain = {}
M.Normalize(plain, "auras")
check("aura rule gets apply and expire", keys(plain) == "apply@0,expire@100")
local before = { beforeExpireEnabled = true, beforeExpirePercent = 10 }
M.Normalize(before, "auras")
check("before-expiry warning becomes a marker at 90", keys(before) == "apply@0,beforeExpire@90,expire@100")
local off = { beforeExpireEnabled = false, beforeExpirePercent = 10 }
M.Normalize(off, "auras")
check("switched-off warning is not migrated", keys(off) == "apply@0,expire@100")
local secs = { beforeExpireEnabled = true, beforeExpireSeconds = 5 }
M.Normalize(secs, "auras")
check("seconds warning becomes 5 s before the end", secs.markers[2].key == "beforeExpire" and secs.markers[2].anchor == "end" and secs.markers[2].offset == 5)
local item = {}
M.Normalize(item, "items")
check("item rule gets Start at 0 and Ready at 100", keys(item) == "used@0,ready@100", keys(item))

-- Idempotent and repairing
local again = keys(before)
M.Normalize(before, "auras")
check("normalize is idempotent", keys(before) == again)
local broken = { markers = { { key = "expire", at = 3 }, { key = "m2", at = 140 }, { key = "m2", at = 20 }, { key = "bad" }, { key = "ready", at = 100 } } }
M.Normalize(broken, "auras")
check("endpoints pinned, inner clamped below 100, duplicates and foreign keys dropped", keys(broken) == "apply@0,m2@99.5,expire@100", keys(broken))

-- Add / Move / Remove
local r = {}
M.Normalize(r, "auras")
local k1 = M.Add(r, 90)
local k2 = M.Add(r, 25.5)
check("add gives unique keys, sorted", k1 == "m1" and k2 == "m2" and keys(r) == "apply@0,m2@25.5,m1@90,expire@100", keys(r))
M.Move(r, "m1", 50)
check("move re-sorts", keys(r) == "apply@0,m2@25.5,m1@50,expire@100")
M.Move(r, "m2", nil, 3, 12)
check("move by seconds uses the duration", r.markers[2].key == "m2" and math.abs(r.markers[2].at - 25) < 1e-9)
M.Move(r, "apply", 40)
check("endpoints cannot move", r.markers[1].key == "apply" and r.markers[1].at == 0)
r.m1Message = "x"; r.screenProfiles = { m1 = {} }
check("remove deletes marker and its fields", M.Remove(r, "m1") and r.m1Message == nil and r.screenProfiles.m1 == nil
    and keys(r) == "apply@0,m2@25,expire@100")
check("endpoints cannot be removed", not M.Remove(r, "expire"))
check("intermediate lists only m2", #M.Intermediate(r) == 1 and M.Intermediate(r)[1].key == "m2")

-- Seconds / Percent
check("seconds from percent", M.Seconds({ at = 90 }, 20) == 18 and M.Seconds({ at = 90 }, nil) == nil)
check("end anchor resolves against the duration", M.Seconds({ at = 50, anchor = "end", offset = 5 }, 20) == 15 and M.Percent({ at = 50, anchor = "end", offset = 5 }, 20) == 75)
check("IsKey", M.IsKey("m12") and M.IsKey("beforeExpire") and not M.IsKey("mx") and not M.IsKey(nil))

local edge = {}
M.Normalize(edge, "auras")
local e1 = M.Add(edge, 100)
local e2 = M.Add(edge, 0)
check("inner nodes never sit on the ends", keys(edge) == "apply@0," .. e2 .. "@0.5," .. e1 .. "@99.5,expire@100", keys(edge))
M.Move(edge, e1, 120)
check("moving past the end stops at 99.5", edge.markers[3].at == 99.5)

-- Anchors
local t = {}
M.Normalize(t, "auras")
local a = M.Add(t, 50)
M.SetTiming(t, a, "start", 2, nil)
check("2 s after start needs no duration", M.Seconds(t.markers[2], nil) == 2 and M.TimingText(t.markers[2]) == "+2 s")
M.SetTiming(t, a, "end", 2, 20)
check("2 s before end with a duration", M.Seconds(t.markers[2], 20) == 18 and t.markers[2].at == 90 and M.TimingText(t.markers[2]) == "-2 s")
check("2 s before end without a duration has no time", M.Seconds(t.markers[2], nil) == nil)
M.Move(t, a, 75, nil, 20)
check("dragging an end-anchored node keeps the anchor and updates the seconds", t.markers[2].anchor == "end" and t.markers[2].offset == 5)
M.SetTiming(t, a, "percent", 33.3)
check("back to percent", t.markers[2].anchor == "percent" and t.markers[2].offset == nil and t.markers[2].at == 33.3)
local legacy = { markers = { { key = "apply", at = 0 }, { key = "m1", at = 80, fromEnd = 4 }, { key = "expire", at = 100 } } }
M.Normalize(legacy, "auras")
check("older fromEnd becomes an end anchor", legacy.markers[2].anchor == "end" and legacy.markers[2].offset == 4)
M.SetTiming(t, a, "start", 3, 10)
M.Resolve(t, 10)
check("resolve draws second-based nodes at their spot", t.markers[2].at == 30)

-- Per-spell overrides of a group rule
local g = { spellIDs = { 11, 22 } }
M.Normalize(g, "auras")
local pk = M.Add(g, 50)
local ek = M.Add(g, 90)
M.SetTiming(g, ek, "end", 5, 30)
check("spell without override follows the group", select(2, M.Effective(g, 11, pk)) == false and M.Effective(g, 11, pk).at == 50)
M.MoveOverride(g, 22, pk, 70, 15)
check("moving on one spell overrides only that spell", M.Effective(g, 22, pk).at == 70 and M.Effective(g, 11, pk).at == 50 and M.OverrideCount(g) == 1)
M.MoveOverride(g, 22, ek, 60, 15)
local e22 = M.Effective(g, 22, ek)
check("override keeps the end anchor and moves its seconds", e22.anchor == "end" and e22.offset == 6, tostring(e22.anchor) .. "/" .. tostring(e22.offset))
check("group node itself is untouched", g.markers[3].offset == 5 or g.markers[2].offset == 5)
local list22 = M.ForSpell(g, 22)
local found
for _, marker in ipairs(list22) do if marker.key == pk then found = marker end end
check("ForSpell resolves overrides", found and found.at == 70)
M.SetOverrideTiming(g, 11, pk, "percent", 33)
check("typed value sets the override", M.Effective(g, 11, pk).at == 33 and M.OverrideCount(g) == 3)
M.ClearOverride(g, 11, pk)
check("clear re-links to the group", select(2, M.Effective(g, 11, pk)) == false and M.OverrideCount(g) == 2)
M.Remove(g, pk)
check("removing a node drops its overrides", M.OverrideCount(g) == 1)
g.spellIDs = { 11 }
M.PruneOverrides(g)
check("overrides of removed spells are pruned", g.markerOverrides == nil)

-- Node removed for one spell / created for one spell only
local h = { spellIDs = { 1, 2, 3 } }
M.Normalize(h, "auras")
local hk = M.Add(h, 60)
M.DisableOverride(h, 2, hk)
check("off node is not in that spell's list", #M.ForSpell(h, 2) == 2 and #M.ForSpell(h, 1) == 3 and M.IsOff(h, 2, hk))
check("Effective reports off", select(3, M.Effective(h, 2, hk)) == true and M.Effective(h, 2, hk) == nil)
M.SetOverrideTiming(h, 2, hk, "percent", 40)
check("editing an off node switches it on again", not M.IsOff(h, 2, hk) and M.Effective(h, 2, hk).at == 40)
M.DisableOverride(h, 2, hk)
M.ClearOverride(h, 2, hk)
check("re-link restores a removed node", #M.ForSpell(h, 2) == 3)
local only = M.AddOnlyFor(h, 3, 80)
check("node for one spell only", #M.ForSpell(h, 3) == 4 and #M.ForSpell(h, 1) == 3 and #M.ForSpell(h, 2) == 3)
M.Remove(h, only)
check("removing the group node drops the off entries", M.OverrideCount(h) == 0)
