const fs = require("fs");
const path = require("path");
const fengariPath = process.env.WOWRAVOX_FENGARI || "fengari"; // set WOWRAVOX_FENGARI to .../node_modules/fengari when it is not installed locally
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require(fengariPath);

const root = path.resolve(__dirname, "..");
const load = (name) => fs.readFileSync(path.join(root, name), "utf8").replace(
  /^local _, ns = \.\.\.$/m, "local _, ns = addonName, addonNamespace");

// 200-locals limit of a main chunk: Recorder.lua keeps its helpers in a table
const topLevelLocals = (fs.readFileSync(path.join(root, "Recorder.lua"), "utf8").match(/^local /gm) || []).length;
if (topLevelLocals > 5) {
  console.error(`FAIL Recorder.lua has ${topLevelLocals} top-level locals; helpers belong in Recorder.x`);
  process.exit(1);
}
console.log(`PASS Recorder.lua top-level locals: ${topLevelLocals}`);

const program = [
  "local addonName = 'WoWraVox'",
  "local addonNamespace = {}",
  "local ns = addonNamespace",
  "SlashCmdList = {}", // exists before the addon files load, as in the client
  "do", load("Locales/enUS.lua"), "end",
  "do", load("Locales/deDE.lua"), "end",
  "do", load("Recorder.lua"), "end",
  fs.readFileSync(path.join(__dirname, "Test-Recorder.lua"), "utf8"),
].join("\n");

const state = lauxlib.luaL_newstate();
lualib.luaL_openlibs(state);
if (lauxlib.luaL_dostring(state, to_luastring(program)) !== lua.LUA_OK) {
  console.error(to_jsstring(lua.lua_tostring(state, -1)));
  process.exit(1);
}
