-- Fengari harness for AuraSoundFallback.lua: which native aura sounds get registered with WoW.
-- Policy: category word on Added (not for own self-buffs), selected media tones on Added/Removed,
-- nothing else. No generic tone, no addon-side cue.

local timers = {}
local added = {}
local removed = {}
local selfBuff = {}
local mediaPaths = { Foo = "media\\foo.ogg", Bar = "media\\bar.ogg" }

local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. detail) or "")) end
    print("PASS " .. name)
end

function wipe(value)
    for key in pairs(value) do value[key] = nil end
end
function date() return "00:00:00" end
function GetTime() return 0 end
function InCombatLockdown() return false end
function CreateFrame()
    local frame = {}
    function frame:RegisterEvent() end
    function frame:SetScript() end
    return frame
end
C_Timer = { After = function(_, callback) table.insert(timers, callback) end }
Enum = { UnitAuraSoundTrigger = { Added = 1, Removed = 2 } }
local nextSoundID = 0
C_UnitAuras = {
    AddAuraSound = function(trigger, info)
        nextSoundID = nextSoundID + 1
        table.insert(added, { id = nextSoundID, trigger = trigger, spellID = info.spellID,
            file = info.soundFileName, channel = info.outputChannel })
        return nextSoundID
    end,
    RemoveAuraSound = function(id) table.insert(removed, id) end,
}
-- LibStub is a function here on purpose: AuraSoundFallback only resolves media when type(LibStub) == "function".
LibStub = function()
    return { Fetch = function(_, _, name) return mediaPaths[name] end }
end

-- ==== MODULE ====

ns._Aura = {
    getSelfBuffStatus = function(spellID) return selfBuff[spellID] and "true" or "false" end,
}
local fallback = ns.AuraSoundFallback

local function refresh(rules)
    added, removed, timers = {}, {}, {}
    fallback.Refresh(rules, true)
    while #timers > 0 do
        local pending = timers
        timers = {}
        for _, callback in ipairs(pending) do callback() end
    end
end

local function registered(spellID, trigger)
    for _, entry in ipairs(added) do
        if entry.spellID == spellID and entry.trigger == trigger then return entry end
    end
end

local function rule(fields)
    local result = { enabled = true, alertCategory = "none", spellIDs = { 100 }, applyEnabled = false,
        expireEnabled = false, applySoundEnabled = false, expireSoundEnabled = false,
        applySoundChannel = "Master", expireSoundChannel = "Master", screenProfiles = {} }
    for key, value in pairs(fields) do result[key] = value end
    return result
end

local ADDED, REMOVED = Enum.UnitAuraSoundTrigger.Added, Enum.UnitAuraSoundTrigger.Removed
local DEFENSIVE = fallback.categorySoundFiles.defensive

check("generic tone and addon-side cue are gone", fallback.soundFile == nil and fallback.enabled == nil
    and fallback.SetEnabled == nil and fallback.TestSound == nil and fallback.PlayApplicationCue == nil)

selfBuff = { [200] = true }
refresh({ rule({ alertCategory = "defensive", applyEnabled = true, spellIDs = { 100, 200 } }) })
check("category word registered for a non-self-buff aura",
    registered(100, ADDED) and registered(100, ADDED).file == DEFENSIVE)
check("category word suppressed for a self-buff aura", registered(200, ADDED) == nil)
check("category word is never registered for expiration", registered(100, REMOVED) == nil)

selfBuff = {}
refresh({ rule({ applyEnabled = true, expireEnabled = true }) })
check("TTS-only rule registers no generic tone", #added == 0)

refresh({ rule({ applyEnabled = true, expireEnabled = true, applySoundEnabled = true, expireSoundEnabled = true }) })
check("sound-kit rule registers nothing natively", #added == 0)

refresh({ rule({ expireSoundEnabled = true, expireSoundMediaName = "Foo", expireSoundChannel = "SFX" }) })
check("selected expire media tone is registered on Removed",
    #added == 1 and registered(100, REMOVED) and registered(100, REMOVED).file == mediaPaths.Foo
    and registered(100, REMOVED).channel == "SFX")

refresh({ rule({ applySoundEnabled = true, applySoundMediaName = "Bar" }) })
check("selected apply media tone is registered on Added",
    #added == 1 and registered(100, ADDED) and registered(100, ADDED).file == mediaPaths.Bar)

refresh({ rule({ alertCategory = "defensive", applySoundEnabled = true, applySoundMediaName = "Bar" }) })
check("category word wins over an apply media tone", #added == 1 and registered(100, ADDED).file == DEFENSIVE)

refresh({ rule({ expireEnabled = true, expireSoundEnabled = true, expireSoundMediaName = "Missing" }) })
check("unknown media name registers nothing", #added == 0)

refresh({ rule({ alertCategory = "defensive", applyEnabled = true, enabled = false }) })
check("disabled rule registers nothing", #added == 0)

refresh({ rule({ alertCategory = "defensive", applyEnabled = true }) })
check("status counts the wanted sound", fallback.GetStatus().wanted == 1 and fallback.GetStatus().registered == 1)
