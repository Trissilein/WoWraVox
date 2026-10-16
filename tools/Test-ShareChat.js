const fs = require("fs");
const path = require("path");
const fengariPath = process.env.WOWRAVOX_FENGARI || "fengari"; // set WOWRAVOX_FENGARI to .../node_modules/fengari when it is not installed locally
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require(fengariPath);

const root = path.resolve(__dirname, "..");
const readAddonFile = (name, pattern, replacement) =>
  fs.readFileSync(path.join(root, name), "utf8").replace(pattern, replacement);
const defaults = readAddonFile("Defaults.lua", /^local _, ns = \.\.\.$/m, "local _, ns = addonName, addonNamespace");
const ruleOutput = readAddonFile("RuleOutput.lua", /^local _, ns = \.\.\.$/m, "local _, ns = addonName, addonNamespace");
const debugReport = readAddonFile("DebugReport.lua", /^local _, ns = \.\.\.$/m, "local _, ns = addonName, addonNamespace");
const shareGroups = readAddonFile("ShareGroups.lua", /^local _, ns = \.\.\.$/m, "local _, ns = addonName, addonNamespace");
const shareChat = readAddonFile("ShareChat.lua", /^local _, ns = \.\.\.$/m, "local _, ns = addonName, addonNamespace");
const source = readAddonFile("WoWraVox.lua", /^local addonName, ns = \.\.\.$/m, "local addonName, ns = addonName, addonNamespace");
const simulation = readAddonFile("Simulation.lua", /^local _, ns = \.\.\.$/m, "local _, ns = addonName, addonNamespace");
const harness = fs.readFileSync(path.join(__dirname, "Test-ShareChat.lua"), "utf8");
// Same stubs as Test-ShareGroups.js: the window code needs only the modules it uses.
const prelude = [
  "function wipe(value) for key in pairs(value) do value[key] = nil end end",
  "function GetLocale() return 'enUS' end",
  "CreateFrame = function() local frame = {} function frame:RegisterEvent() end function frame:SetScript() end return frame end",
  "addonNamespace.Locales = { enUS = {} }",
  "addonNamespace.Profiles = { RuleMatchesCurrentSpecialization = function() return true end }",
  "addonNamespace.SkillTracking = { Configure = function() end, Scan = function() end, ResetAll = function() end }",
].join("\n");
// ShareGroups.lua and ShareChat.lua load before WoWraVox.lua, as in WoWraVox.toc.
const program = [
  "local addonName = 'WoWraVox'",
  "local addonNamespace = {}",
  prelude,
  "do", defaults, "end",
  "do", ruleOutput, "end",
  "do", debugReport, "end",
  "do", shareGroups, "end",
  "do", shareChat, "end",
  "do", source, "end",
  "do", simulation, "end",
  "local ns = addonNamespace", // each file above runs in its own do-block, so the harness binds ns itself
  harness,
].join("\n");

const state = lauxlib.luaL_newstate();
lualib.luaL_openlibs(state);
const status = lauxlib.luaL_dostring(state, to_luastring(program));
if (status !== lua.LUA_OK) {
  console.error(to_jsstring(lua.lua_tostring(state, -1)));
  process.exit(1);
}
