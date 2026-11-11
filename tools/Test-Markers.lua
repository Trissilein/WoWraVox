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
check("seconds warning keeps fromEnd", secs.markers[2].key == "beforeExpire" and secs.markers[2].fromEnd == 5)
local item = {}
M.Normalize(item, "items")
check("item rule gets ready at 100", keys(item) == "ready@100")

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
check("fromEnd resolves against the duration", M.Seconds({ at = 50, fromEnd = 5 }, 20) == 15 and M.Percent({ at = 50, fromEnd = 5 }, 20) == 75)
check("IsKey", M.IsKey("m12") and M.IsKey("beforeExpire") and not M.IsKey("mx") and not M.IsKey(nil))

local edge = {}
M.Normalize(edge, "auras")
local e1 = M.Add(edge, 100)
local e2 = M.Add(edge, 0)
check("inner nodes never sit on the ends", keys(edge) == "apply@0," .. e2 .. "@0.5," .. e1 .. "@99.5,expire@100", keys(edge))
M.Move(edge, e1, 120)
check("moving past the end stops at 99.5", edge.markers[3].at == 99.5)
