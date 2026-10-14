const fs = require("fs");
const path = require("path");
const fengariPath = process.env.WOWRAVOX_FENGARI || "fengari";
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require(fengariPath);

const root = path.resolve(__dirname, "..");
const readModule = (name, pattern, replacement) => fs.readFileSync(path.join(root, name), "utf8")
  .replace(pattern, replacement);
const defaults = readModule("Defaults.lua", /^local _, ns = \.\.\.$/m,
  "local _, ns = addonName, addonNamespace");
const presets = readModule("AuraPresets.lua", /^local _, ns = \.\.\.$/m,
  "local _, ns = addonName, addonNamespace");
const profiles = readModule("Profiles.lua", /^local _, ns = \.\.\.$/m,
  "local _, ns = addonName, addonNamespace");
const skills = readModule("SkillTracking.lua", /^local _, ns = \.\.\.$/m,
  "local _, ns = addonName, addonNamespace");
const source = readModule("WoWraVox.lua", /^local addonName, ns = \.\.\.$/m,
  "local addonName, ns = addonName, addonNamespace");
const harness = fs.readFileSync(path.join(__dirname, "Test-AuraPresetImport.lua"), "utf8");

const prelude = `
function wipe(value) for key in pairs(value) do value[key] = nil end end
function GetLocale() return "enUS" end
function GetTime() return 0 end
function date() return "00:00:00" end
function debugprofilestop() return 0 end
function issecretvalue() return false end
function issecrettable() return false end
function InCombatLockdown() return false end
function IsPlayerSpell(spellID) return knownSpells and knownSpells[spellID] == true end
function IsSpellKnown(spellID) return knownSpells and knownSpells[spellID] == true end
function IsSpellKnownOrOverridesKnown(spellID) return knownSpells and knownSpells[spellID] == true end
function UnitClass() return "Paladin", "PALADIN", 2 end
function UnitName() return "Harness" end
function UnitFullName() return "Harness", "Realm" end
function GetSpecialization() return 1 end
function GetSpecializationInfo() return 66, "Protection" end
function ReloadUI() end
knownSpells = {}
SOUNDKIT = { RAID_WARNING = 8959 }
Enum = { TtsVoiceType = { Standard = 1 }, SpellBookSpellBank = { Player = 1 } }
C_TTSSettings = { GetVoiceOptionID = function() return 7 end }
C_VoiceChat = {
    GetTtsVoices = function() return { { voiceID = 7, name = "Harness" } } end,
    SpeakText = function() end,
}
C_Timer = { After = function(_, callback) end }
C_Spell = {
    GetSpellName = function(spellID) return "Spell " .. tostring(spellID) end,
    GetSpellInfo = function(spellID) return { name = "Spell " .. tostring(spellID), iconID = 1 } end,
    IsSelfBuff = function() return false end,
}
C_UnitAuras = { GetPlayerAuraBySpellID = function() return nil end }
C_Secrets = { ShouldAurasBeSecret = function() return false end }
UIParent = {
    GetWidth = function() return 1600 end,
    GetHeight = function() return 1000 end,
    GetEffectiveScale = function() return 1 end,
}
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
SlashCmdList = {}
GameTooltip = {
    HookScript = function() end, SetOwner = function() end, SetText = function() end,
    AddLine = function() end, Show = function() end, Hide = function() end,
}
GameTooltipText = {}
LibStub = nil
function CreateFrame()
    local frame = {}
    function frame:RegisterEvent() end
    function frame:RegisterUnitEvent() end
    function frame:UnregisterEvent() end
    function frame:UnregisterAllEvents() end
    function frame:SetScript() end
    return frame
end
`;

const program = [
  "local addonName = 'WoWraVox'",
  "local addonNamespace = {}",
  "local ns = addonNamespace",
  prelude,
  "do", defaults, "end",
  "do", presets, "end",
  "do", profiles, "end",
  "do", skills, "end",
  "do",
  "ns.Skin = { Data = function() return nil end, Register = function() end, SetState = function() end, SetArtShown = function() end, DropdownTextZone = function(width) return 0, width end, IsValid = function() return true end, Active = function() return 'current' end, Names = function() return { 'current' } end, Set = function() end }",
  "ns.AuraSoundFallback = { Refresh = function() end, Log = function() end, LogAura = function() end, SetStatusCallback = function() end, SetDebugEnabled = function() end, ClearLog = function() end, GetStatus = function() return {} end, GetLogLines = function() return {} end }",
  "ns.DebugReport = { NoteNotify = function() end, NoteAura = function() end, NoteCast = function() end, Build = function() return {} end, Run = function() end }",
  "ns.Simulation = { Start = function() end, Stop = function() end }",
  source,
  "local function runPresetImportHarness()",
  harness,
  "end",
  "runPresetImportHarness()",
  "end",
].join("\n");

const state = lauxlib.luaL_newstate();
lualib.luaL_openlibs(state);
const status = lauxlib.luaL_dostring(state, to_luastring(program));
if (status !== lua.LUA_OK) {
  console.error(to_jsstring(lua.lua_tostring(state, -1)));
  process.exit(1);
}
