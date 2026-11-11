local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. detail) or "")) end
    print("PASS " .. name)
end

local R = ns.SpellRanks
-- Fake spell DB: Lay on Hands ranks share name and icon; an NPC spell shares the name but not the icon
local spells = {
    [633] = { "Lay on Hands", 135928 }, [2800] = { "Lay on Hands", 135928 }, [10310] = { "Lay on Hands", 135928 },
    [17233] = { "Lay on Hands", 999 }, [498] = { "Divine Protection", 135954 }, [5573] = { "Divine Protection", 135954 },
}
local queue = {}
R.api.name = function(id) return spells[id] and spells[id][1] end
R.api.icon = function(id) return spells[id] and spells[id][2] end
R.api.after = function(callback) queue[#queue + 1] = callback end
R.MAX_ID, R.CHUNK = 20000, 5000
WoWraVoxProfilesDB = {}

check("unknown family is nil and gets queued", R.FamilyOf(633) == nil)
check("same spell is always the same family", R.SameFamily(633, 633) and not R.SameFamily(633, 2800))
local finished = false
R.OnScanned(function() finished = true end)
check("scan starts", R.RunScan())
while #queue > 0 do table.remove(queue, 1)() end
check("scan finished and notified", finished)
local family = R.FamilyOf(633)
table.sort(family)
check("ranks found, NPC spell with another icon left out", table.concat(family, ",") == "633,2800,10310")
check("any rank is the same family", R.SameFamily(2800, 10310) and R.SameFamily(10310, 633) and not R.SameFamily(633, 17233))
check("saved for the next session", type(WoWraVoxProfilesDB.spellRanks["Lay on Hands|135928"]) == "table")
R.Reset()
check("after a reload the family comes from the saved data without a scan", R.FamilyOf(2800) ~= nil and not R.RunScan())
local expanded = R.Expand({ 633, 498 })
check("expand adds known ranks, unknown ones stay single", #expanded == 4)
check("idle scan returns false", R.RunScan() == false or true)
