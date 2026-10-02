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
const module_ = fs.readFileSync(path.join(root, "AuraSoundFallback.lua"), "utf8").replace(
  /^local _, ns = \.\.\.$/m,
  "local _, ns = addonName, addonNamespace",
);
// The harness is split at the marker: mocks must exist before the module runs, the checks after.
const [mocks, checks] = fs.readFileSync(path.join(__dirname, "Test-AuraSoundFallback.lua"), "utf8")
  .split("-- ==== MODULE ====");
const program = [
  "local addonName = 'WoWraVox'",
  "local addonNamespace = {}",
  "local ns = addonNamespace",
  mocks,
  module_,
  checks,
].join("\n");

const state = lauxlib.luaL_newstate();
lualib.luaL_openlibs(state);
const status = lauxlib.luaL_dostring(state, to_luastring(program));
if (status !== lua.LUA_OK) {
  console.error(to_jsstring(lua.lua_tostring(state, -1)));
  process.exit(1);
}
