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
const skinPath = process.argv[2] || path.join(root, "Skin.lua");
const harnessPath = process.argv[3] || path.join(__dirname, "Test-Skin.lua");

const skin = fs.readFileSync(skinPath, "utf8").replace(
  /^local _, ns = \.\.\.$/m,
  "local _, ns = addonName, addonNamespace",
);
const harness = fs.readFileSync(harnessPath, "utf8");

// The generated SkinData.lua is the fixture (trimmed asset sizes), loaded into the same namespace.
const skinData = fs.readFileSync(path.join(root, "SkinData.lua"), "utf8").replace(
  /^local _, ns = \.\.\.$/m,
  "local _, ns = addonName, addonNamespace",
);

const source = [
  "local addonName = 'WoWraVox'",
  "local addonNamespace = {}",
  "do " + skinData + " end",
  skin,
  harness,
].join("\n");

const state = lauxlib.luaL_newstate();
lualib.luaL_openlibs(state);
const status = lauxlib.luaL_dostring(state, to_luastring(source));
if (status !== lua.LUA_OK) {
  console.error(to_jsstring(lua.lua_tostring(state, -1)));
  process.exit(1);
}
