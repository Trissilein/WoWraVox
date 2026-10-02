const fs = require("fs");
const path = require("path");
const fengariPath = process.env.WOWRAVOX_FENGARI
  || "fengari"; // set WOWRAVOX_FENGARI to .../node_modules/fengari when it is not installed locally
const {
  lua,
  lauxlib,
  lualib,
  to_luastring,
  to_jsstring,
} = require(fengariPath);

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "WoWraVox.lua"), "utf8").replace(
  /^local addonName, ns = \.\.\.$/m,
  "local addonName, ns = addonName, addonNamespace",
);
const harness = fs.readFileSync(path.join(__dirname, "Test-TargetNotifications.lua"), "utf8");
const prelude = [
  "function wipe(value) for key in pairs(value) do value[key] = nil end end",
  "function GetLocale() return 'enUS' end",
  "CreateFrame = function() local frame = {} function frame:RegisterEvent() end function frame:SetScript() end return frame end",
  "addonNamespace.Locales = { enUS = {} }",
  "addonNamespace.Profiles = { RuleMatchesCurrentSpecialization = function() return true end }",
  "addonNamespace.SkillTracking = { Configure = function() end, Scan = function() end, ResetAll = function() end }",
].join("\n");
const program = [
  "local addonName = 'WoWraVox'",
  "local addonNamespace = {}",
  prelude,
  "do",
  source,
  "end",
  harness,
].join("\n");

const state = lauxlib.luaL_newstate();
lualib.luaL_openlibs(state);
const status = lauxlib.luaL_dostring(state, to_luastring(program));
if (status !== lua.LUA_OK) {
  console.error(to_jsstring(lua.lua_tostring(state, -1)));
  process.exit(1);
}
