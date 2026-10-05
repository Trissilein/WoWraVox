-- Fengari harness for Profiles.lua: which data a character gets on its first login.
local playerName, playerRealm = "Paladin", "Blackrock"

local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. detail) or "")) end
    print("PASS " .. name)
end

function UnitFullName() return playerName, playerRealm end

-- ==== MODULE ====

local Profiles = ns.Profiles
ns.CreateStarterDatabase = function()
    return { auras = { { name = "Starter rule" } }, items = {}, skills = {}, starter = true }
end

-- A Default profile that holds the first character's own, customised rules.
WoWraVoxProfilesDB = {
    version = 1, nextProfileID = 1, defaultProfileID = "profile-1",
    characters = { ["paladin-blackrock"] = { profileID = "profile-1", specializations = {} } },
    profiles = { ["profile-1"] = { name = "Default", data = { auras = { { name = "Paladin rule" } }, items = {}, skills = {} } } },
}

check("known character keeps its profile", Profiles.Prepare() and WoWraVoxDB.auras[1].name == "Paladin rule")

playerName = "Hunter"
check("first login of a new character works", Profiles.Prepare())
check("new character starts with the starter data, not a copy of Default",
    WoWraVoxDB.starter == true and WoWraVoxDB.auras[1].name == "Starter rule")
local root = WoWraVoxProfilesDB
local binding = root.characters["hunter-blackrock"]
check("new character gets its own, separate profile",
    binding and binding.profileID ~= "profile-1" and root.profiles[binding.profileID].name == "Hunter - Blackrock")
check("Default stays untouched", root.profiles["profile-1"].data.auras[1].name == "Paladin rule"
    and #root.profiles["profile-1"].data.auras == 1 and root.defaultProfileID == "profile-1")
check("Paladin binding is unchanged", root.characters["paladin-blackrock"].profileID == "profile-1")

WoWraVoxDB.auras[1].name = "Edited on the hunter"
playerName = "Paladin"
Profiles.Prepare()
check("Paladin still sees Default", WoWraVoxDB.auras[1].name == "Paladin rule")
playerName = "Hunter"
Profiles.Prepare()
check("hunter keeps its own edits on the next login", WoWraVoxDB.auras[1].name == "Edited on the hunter")

-- Without the starter data a new character falls back to a copy of Default instead of failing.
ns.CreateStarterDatabase = nil
playerName = "Mage"
check("fallback creates a profile", Profiles.Prepare())
check("fallback copy comes from Default", WoWraVoxDB.auras[1].name == "Paladin rule")
