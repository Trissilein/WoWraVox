const fs = require("fs");
const path = require("path");
const fengariPath = process.env.WOWRAVOX_FENGARI || "fengari";
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require(fengariPath);

const root = path.resolve(__dirname, "..");
const modulePath = process.argv[2] || path.join(root, "AuraTrackerView.lua");
const harnessPath = process.argv[3] || path.join(__dirname, "Test-AuraTrackerView.lua");
const moduleSource = fs.readFileSync(modulePath, "utf8").replace(
  /^local _, ns = \.\.\.$/m,
  "local addonName, ns = 'WoWraVox', addonNamespace",
);
const harness = fs.readFileSync(harnessPath, "utf8");
const source = ["local addonNamespace = {}", moduleSource, harness].join("\n");

const state = lauxlib.luaL_newstate();
lualib.luaL_openlibs(state);
const status = lauxlib.luaL_dostring(state, to_luastring(source));
if (status !== lua.LUA_OK) {
  console.error(to_jsstring(lua.lua_tostring(state, -1)));
  process.exit(1);
}
