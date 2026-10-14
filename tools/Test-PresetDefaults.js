const fs = require("fs");
const path = require("path");
const fengariPath = process.env.WOWRAVOX_FENGARI || "fengari";
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require(fengariPath);

const root = path.resolve(__dirname, "..");
const defaults = fs.readFileSync(path.join(root, "Defaults.lua"), "utf8").replace(
  /^local _, ns = \.\.\.$/m,
  "local _, ns = addonName, addonNamespace",
);
const harness = fs.readFileSync(path.join(__dirname, "Test-PresetDefaults.lua"), "utf8");
const program = [
  "local addonName = 'WoWraVox'",
  "local addonNamespace = {}",
  defaults,
  harness,
].join("\n");

const state = lauxlib.luaL_newstate();
lualib.luaL_openlibs(state);
const status = lauxlib.luaL_dostring(state, to_luastring(program));
if (status !== lua.LUA_OK) {
  console.error(to_jsstring(lua.lua_tostring(state, -1)));
  process.exit(1);
}
