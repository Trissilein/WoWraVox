const fs = require("fs");
const path = require("path");
const fengariPath = process.env.WOWRAVOX_FENGARI || "fengari";
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require(fengariPath);

const root = path.resolve(__dirname, "..");
const load = (name) => fs.readFileSync(path.join(root, name), "utf8").replace(
  /^local _, ns = \.\.\.$/m, "local _, ns = addonName, addonNamespace");
const program = [
  "local addonName = 'WoWraVox'",
  "local addonNamespace = {}",
  "local ns = addonNamespace",
  "do", load("Markers.lua"), "end",
  "do", load("MarkerTimers.lua"), "end",
  fs.readFileSync(path.join(__dirname, "Test-MarkerTimers.lua"), "utf8"),
].join("\n");

const state = lauxlib.luaL_newstate();
lualib.luaL_openlibs(state);
if (lauxlib.luaL_dostring(state, to_luastring(program)) !== lua.LUA_OK) {
  console.error(to_jsstring(lua.lua_tostring(state, -1)));
  process.exit(1);
}
