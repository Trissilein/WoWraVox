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
const skillPath = process.argv[2] || path.join(root, "SkillTracking.lua");
const harnessPath = process.argv[3] || path.join(__dirname, "Test-SkillCharges.lua");

const skill = fs.readFileSync(skillPath, "utf8").replace(
  /^local _, ns = \.\.\.$/m,
  "local _, ns = addonName, addonNamespace",
);
const harness = fs.readFileSync(harnessPath, "utf8");
const source = [
  "local addonName = 'WoWraVox'",
  "local addonNamespace = {}",
  skill,
  harness,
].join("\n");

const state = lauxlib.luaL_newstate();
lualib.luaL_openlibs(state);
const status = lauxlib.luaL_dostring(state, to_luastring(source));
if (status !== lua.LUA_OK) {
  console.error(to_jsstring(lua.lua_tostring(state, -1)));
  process.exit(1);
}
