-- Harness for Skin.lua (concatenated by Test-Skin.js: SkinData.lua, then Skin.lua, then this file).
local function check(name, condition, detail)
    if not condition then error("FAIL " .. name .. (detail and (" " .. tostring(detail)) or "")) end
    print("PASS " .. name)
end

local function near(a, b) return math.abs(a - b) < 1e-9 end

-- ---------------------------------------------------------------------------------------------
-- Fixture: the generated SkinData.lua itself (loaded by Test-Skin.js as ns.SkinData), so the tests run
-- on the real, trimmed asset sizes. Geometry expectations below derive from asset.w/h/texW/texH/slice.
-- ---------------------------------------------------------------------------------------------
assert(type(ns.SkinData) == "table" and ns.SkinData.skins and ns.SkinData.skins.clean, "ns.SkinData missing (SkinData.lua not loaded)")
print("INFO fixture source: SkinData.lua")

-- ---------------------------------------------------------------------------------------------
-- Mocks (recording). Only known method prefixes are recorded, so template keys such as Left/Button
-- stay nil unless a test installs them.
-- ---------------------------------------------------------------------------------------------
local RECORDED = { "^Set", "^Get", "^Is", "^Clear", "^Create", "^Hook", "^Enable", "^Disable" }

local function log(self, key, ...)
    self.count[key] = (self.count[key] or 0) + 1
    self.last[key] = { ... }
    self.all[key] = self.all[key] or {}
    table.insert(self.all[key], { ... })
end

local function recorder(obj)
    obj.count, obj.last, obj.all = {}, {}, {}
    obj.Show = function(self) log(self, "Show"); self.shown = true end
    obj.Hide = function(self) log(self, "Hide"); self.shown = false end
    return setmetatable(obj, { __index = function(_, key)
        if type(key) ~= "string" then return nil end
        for _, pattern in ipairs(RECORDED) do
            if key:find(pattern) then
                return function(self, ...) log(self, key, ...) end
            end
        end
    end })
end

local function totalCalls(obj)
    local sum = 0
    for _, n in pairs(obj.count) do sum = sum + n end
    return sum
end

local function newTexture() return recorder({ shown = true, CreateTexture = false }) end -- real Textures have no CreateTexture

local function newFrame(fields)
    local frame = recorder(fields or {})
    frame.textures, frame.hooks = {}, {}
    frame.CreateTexture = function(self, ...)
        log(self, "CreateTexture", ...)
        local tex = newTexture()
        tex.createArgs = { ... }
        table.insert(self.textures, tex)
        return tex
    end
    frame.HookScript = function(self, script, fn)
        log(self, "HookScript", script)
        self.hooks[script] = self.hooks[script] or {}
        table.insert(self.hooks[script], fn)
    end
    frame.GetWidth = function(self) return self.w or 0 end
    frame.GetHeight = function(self) return self.h or 0 end
    frame.fire = function(self, script, ...)
        for _, fn in ipairs(self.hooks[script] or {}) do fn(self, ...) end
    end
    return frame
end

local function allCalls(frame, key)
    local sum = 0
    for _, tex in ipairs(frame.textures) do sum = sum + (tex.count[key] or 0) end
    return sum
end

local function resetSkin(name)
    Skin.active = nil
    Skin.errors = {}
    Skin.state = setmetatable({}, { __mode = "k" })
    Skin.registry = setmetatable({}, { __mode = "k" })
    Skin.missingReported = nil
    WoWraVoxDB = { settings = { skin = name } }
end

local function lastTexturePath(frame)
    return frame.textures[1].last.SetTexture[1]
end

-- ---------------------------------------------------------------------------------------------
-- Names / Active / Set
-- ---------------------------------------------------------------------------------------------
do
    local names = Skin.Names()
    check("names: current, clean (blizzard and fantasy are gone)",
        #names == 2 and names[1] == "current" and names[2] == "clean" and not Skin.IsValid("fantasy") and not Skin.IsValid("blizzard"))
    names[1] = "x"
    check("names returns a copy", Skin.Names()[1] == "current")

    Skin.active, WoWraVoxDB = nil, nil
    check("active defaults to current without DB", Skin.Active() == "current")
    check("active is not cached while the DB is missing", Skin.active == nil)
    WoWraVoxDB = { settings = {} }
    check("active defaults to current without setting", Skin.Active() == "current")
    check("set rejects invalid names", Skin.Set("bogus") == "current" and WoWraVoxDB.settings.skin == "current")
    check("set stores a valid name", Skin.Set("clean") == "clean" and WoWraVoxDB.settings.skin == "clean")
    check("set turns the removed skins into current", Skin.Set("fantasy") == "current" and Skin.Set("blizzard") == "current" and WoWraVoxDB.settings.skin == "current")
    Skin.Set("clean")
    check("set does not switch the live skin (needs /reload)", Skin.Active() == "current")
    Skin.active = nil
    check("active reads the stored skin after reload", Skin.Active() == "clean")
    WoWraVoxDB = { settings = { skin = "nonsense" } }
    Skin.active = nil
    check("active validates the stored value", Skin.Active() == "current")
    for _, removed in ipairs({ "fantasy", "blizzard", "", 42 }) do
        WoWraVoxDB = { settings = { skin = removed } }
        Skin.active, Skin.errors, Skin.missingReported = nil, {}, nil
        local widget = newFrame({ w = 10, h = 10 })
        check("stored skin " .. tostring(removed) .. " (removed/unknown) falls back to current silently",
            Skin.Active() == "current" and Skin.Data() == nil and #Skin.errors == 0
            and Skin.Register(widget, "button") == false and totalCalls(widget) == 0 and next(Skin.registry) == nil)
    end
end

-- ---------------------------------------------------------------------------------------------
-- ComputeRegions (pure)
-- ---------------------------------------------------------------------------------------------
local function regionByKey(regions, key)
    for _, r in ipairs(regions) do
        if r.key == key then return r end
    end
end

local function sumRow(regions, row, field)
    local sum = 0
    for _, r in ipairs(regions) do
        if r.row == row then sum = sum + (field == "u" and (r.u1 - r.u0) or r.w) end
    end
    return sum
end

local function sumCol(regions, col, field)
    local sum = 0
    for _, r in ipairs(regions) do
        if r.col == col then sum = sum + (field == "v" and (r.v1 - r.v0) or r.h) end
    end
    return sum
end

local A = ns.SkinData.skins.clean.assets
do
    local r = Skin.ComputeRegions(A.button, 112, 30, 1)
    check("button 112x30: 3 regions (T=B=0)", #r == 3, #r)
    check("button: left corner is 12 px, UV 0..12/128", r[1].key == "L" and r[1].w == 12 and r[1].h == 30 and r[1].u0 == 0 and near(r[1].u1, 12 / 128))
    check("button: centre stretches to 88 px, UV 12/128..116/128", r[2].key == "C" and r[2].x == 12 and r[2].w == 88 and near(r[2].u0, 12 / 128) and near(r[2].u1, 116 / 128))
    check("button: right corner is 12 px at x=100, UV ends at 1", r[3].key == "R" and r[3].x == 100 and r[3].w == 12 and near(r[3].u1, 1))
    check("button: UV sum = 1 and widths sum = 112", near(sumRow(r, 2, "u"), 1) and sumRow(r, 2, "w") == 112)
    check("button: full height UV 0..1", near(r[1].v0, 0) and near(r[1].v1, 1))

    local r2 = Skin.ComputeRegions(A.button, 112, 30, 2)
    check("scale 2: corners are 24 px", r2[1].w == 24 and r2[3].w == 24 and r2[2].w == 64)
    local r3 = Skin.ComputeRegions(A.button, 112, 30, 1.5)
    check("scale 1.5: corners rounded to whole pixels (18)", r3[1].w == 18 and r3[1].w == math.floor(r3[1].w))
    local r4 = Skin.ComputeRegions(A.button, 20, 30, 1)
    check("frame narrower than both corners: clamped, no negative/overlap", sumRow(r4, 2, "w") == 20 and r4[1].w == 10 and #r4 == 2)

    local w = Skin.ComputeRegions(A.window, 1408, 943, 1)
    check("window 1408x943: 9 regions", #w == 9, #w)
    local tl, br, mid, top = regionByKey(w, "TL"), regionByKey(w, "BR"), regionByKey(w, "C"), regionByKey(w, "TC")
    check("window: TL corner 40x72 at 0,0", tl.w == 40 and tl.h == 72 and tl.x == 0 and tl.y == 0)
    check("window: BR corner 40x40 flush bottom-right", br.w == 40 and br.h == 40 and br.x + br.w == 1408 and br.y + br.h == 943)
    check("window: header strip stays 72 px high", top.h == 72 and top.w == 1328)
    check("window: centre 1328x831", mid.w == 1328 and mid.h == 831)
    check("window: UV rows 72/256 and 216/256", near(mid.v0, 72 / 256) and near(mid.v1, 216 / 256) and near(tl.v1, 72 / 256))
    check("window: columns/rows sum to frame size", sumRow(w, 1, "w") == 1408 and sumCol(w, 2, "h") == 943)
    check("window: UV sums = 1", near(sumRow(w, 2, "u"), 1) and near(sumCol(w, 2, "v"), 1))

    local d = Skin.ComputeRegions(A.dropdown, 200, 30, 1)
    check("dropdown: 3 regions, arrow zone fixed 34 px", #d == 3 and d[3].w == 34 and d[1].w == 10 and d[2].w == 156)
    check("dropdown: arrow UV starts at 94/128", near(d[3].u0, 94 / 128) and near(d[3].u1, 1))
    local dn = Skin.ComputeRegions(A.dropdown, 80, 30, 1)
    check("dropdown stays 34 px on the right when narrow", dn[3].w == 34 and dn[3].x == 46)

    local sc = Skin.ComputeRegions(A["scroll-track"], 16, 300, 1)
    check("scroll track: 3 vertical regions (L=R=0)", #sc == 3 and sc[1].key == "TC" and sc[1].h == 8 and sc[3].h == 8 and sc[2].h == 284)

    local dg = Skin.ComputeRegions(A["checkbox-on"], 30, 30, 1, true)
    check("fixed on 30x30: one uniformly scaled region", #dg == 1 and dg[1].w == 30 and dg[1].h == 30 and near(dg[1].u1, 1))
    local dg2 = Skin.ComputeRegions(A["checkbox-on"], 60, 30, 1, true)
    check("fixed is never stretched, only centred", #dg2 == 1 and dg2[1].w == 30 and dg2[1].x == 15)
    local dg3 = Skin.ComputeRegions(A["checkbox-on"], 32, 32, 1, true)
    check("fixed on 32x32 keeps 32x32", dg3[1].w == 32 and dg3[1].h == 32)
    check("null slice renders as fixed image", #Skin.ComputeRegions(A["checkbox-on"], 25, 25, 1) == 1)
    check("IsFixed: slice-less or forced, nine-sliced otherwise", Skin.IsFixed(A["checkbox-on"]) and Skin.IsFixed(A.button, true) and not Skin.IsFixed(A.button))
    check("no danger button art in the data (the x is a plain cross)", A["button-danger"] == nil)

    -- NPOT: 40 px high content (never stretched vertically, so not trimmed) on a 64 px canvas, top-left
    local ph = A["panel-header"]
    check("fixture: panel-header content is " .. ph.w .. "x40 on a pow2 canvas, height not trimmed",
        ph.h == 40 and ph.texH == 64 and ph.texW == ph.w and ph.w < 256)
    local p = Skin.ComputeRegions(ph, 300, 40, 1)
    check("NPOT header: 3 regions, V span = 40/64", #p == 3 and near(p[1].v0, 0) and near(p[1].v1, 40 / 64))
    check("NPOT header: UV u sum = w/texW = 1", near(sumRow(p, 2, "u"), 1))
    local odd = { file = "x.tga", w = 100, h = 40, texW = 128, texH = 64, slice = { 10, 0, 10, 0 } }
    local o = Skin.ComputeRegions(odd, 300, 40, 1)
    check("NPOT 100x40 on 128x64: u sum = 100/128, last u = 100/128", near(sumRow(o, 2, "u"), 100 / 128) and near(o[3].u1, 100 / 128) and near(o[1].v1, 40 / 64))
    local oddNine = { file = "x.tga", w = 100, h = 60, texW = 128, texH = 64, slice = { 10, 10, 10, 10 } }
    local n9 = Skin.ComputeRegions(oddNine, 300, 200, 1)
    check("NPOT nine: u sum = 100/128 and v sum = 60/64", near(sumRow(n9, 1, "u"), 100 / 128) and near(sumCol(n9, 1, "v"), 60 / 64))
end

-- every real asset, several frame sizes: contiguous, exact sizes, UV sums = content / canvas
do
    local count, bad = 0, nil
    for style, skin in pairs(ns.SkinData.skins) do
        for name, asset in pairs(skin.assets) do
            for _, size in ipairs({ { 300, 100 }, { 112, 30 }, { 40, 40 } }) do
                for _, scale in ipairs({ 1, 2 }) do
                    local fixed = Skin.IsFixed(asset, name)
                    local fw, fh = size[1], size[2]
                    local regions = Skin.ComputeRegions(asset, fw, fh, scale, fixed)
                    count = count + 1
                    if fixed then
                        if #regions ~= 1 then bad = style .. "/" .. name .. " fixed regions" end
                    elseif fw >= asset.w * scale and fh >= asset.h * scale then
                        -- big enough: all corners honoured, full coverage, UV complete
                        local sl = asset.slice
                        local rowSum = sumRow(regions, #regions > 0 and regions[1].row or 2, "w")
                        local ucover, vcover = 0, 0
                        local firstRow, firstCol = regions[1].row, regions[1].col
                        for _, r in ipairs(regions) do
                            if r.row == firstRow then ucover = ucover + (r.u1 - r.u0) end
                            if r.col == firstCol then vcover = vcover + (r.v1 - r.v0) end
                        end
                        if not near(ucover, asset.w / asset.texW) or not near(vcover, asset.h / asset.texH) then bad = style .. "/" .. name .. " uv cover" end
                        if rowSum ~= fw or sumCol(regions, firstCol, "h") ~= fh then bad = style .. "/" .. name .. " size cover " .. rowSum end
                        local cl = Skin.Round((sl[1] or 0) * scale)
                        local corner = regions[1]
                        if cl > 0 and corner.w ~= cl then bad = style .. "/" .. name .. " corner px" end
                    end
                end
            end
        end
    end
    check("all " .. count .. " asset/size/scale combos tile exactly with exact UV coverage", bad == nil, bad)
end

-- trimmed-centre contract (tools/Build-SkinAssets.py): pow2 canvases, a real stretch strip left on every
-- stretched axis, and identical geometry across the states of one widget (no jumping on hover/press)
do
    local bad
    local function isPow2(n)
        local p = 1
        while p < n do p = p * 2 end
        return p == n
    end
    for name, a in pairs(A) do
        if not (isPow2(a.texW) and isPow2(a.texH)) then bad = name .. " canvas not pow2" end
        if a.w > a.texW or a.h > a.texH then bad = name .. " content larger than canvas" end
        if a.slice then
            local l, t, r, b = a.slice[1], a.slice[2], a.slice[3], a.slice[4]
            if l + r > 0 and a.w - l - r < 8 then bad = name .. " horizontal centre < 8 px" end
            if t + b > 0 and a.h - t - b < 8 then bad = name .. " vertical centre < 8 px" end
        end
    end
    check("all assets: pow2 canvas, content fits, stretched centre >= 8 px", bad == nil, bad)

    local groups = { "button", "editbox", "dropdown", "panel-header", "list-row", "member-row", "tag" }
    local suffix = { "", "-hover", "-pressed", "-disabled", "-focus", "-selected" }
    local mismatch, compared = nil, 0
    for _, base in ipairs(groups) do
        local ref = A[base]
        for _, sfx in ipairs(suffix) do
            local o = A[base .. sfx]
            if o and o ~= ref then
                compared = compared + 1
                local same = o.w == ref.w and o.h == ref.h and o.texW == ref.texW and o.texH == ref.texH and o.arrowW == ref.arrowW
                for i = 1, 4 do same = same and o.slice[i] == ref.slice[i] end
                if not same then mismatch = base .. sfx end
            end
        end
    end
    check("state groups share identical geometry (" .. compared .. " states compared)", mismatch == nil and compared > 0, mismatch)
end

-- ---------------------------------------------------------------------------------------------
-- NineSlice with mock frames
-- ---------------------------------------------------------------------------------------------
resetSkin("clean")
do
    local frame = newFrame({ w = 112, h = 30 })
    local nine = Skin.NineSlice(frame, "button")
    check("NineSlice button: 3 textures", nine and #nine.textures == 3 and #frame.textures == 3)
    check("NineSlice: textures created in BACKGROUND/-8", frame.textures[1].createArgs[2] == "BACKGROUND" and frame.textures[1].createArgs[4] == -8)
    local file = "Interface\\AddOns\\WoWraVox\\Assets\\skin\\clean\\button.tga"
    check("NineSlice: files set", lastTexturePath(frame) == file and frame.textures[3].last.SetTexture[1] == file)
    check("NineSlice: UV for left corner", near(frame.textures[1].last.SetTexCoord[2], 12 / 128) and frame.textures[1].last.SetTexCoord[1] == 0)
    local p = frame.textures[2].all.SetPoint
    check("NineSlice: centre anchored left+12 / right-12 to the frame edges",
        p[1][1] == "TOPLEFT" and p[1][2] == frame and p[1][3] == "TOPLEFT" and p[1][4] == 12 and p[1][5] == 0
        and p[2][1] == "BOTTOMRIGHT" and p[2][3] == "BOTTOMRIGHT" and p[2][4] == -12 and p[2][5] == 0)

    local pointsBefore, createdBefore = allCalls(frame, "SetPoint"), frame.count.CreateTexture
    check("NineSlice: SetAsset hover ok", nine.SetAsset("button-hover") == true)
    check("state swap: only files change (no new textures, no re-anchoring)",
        frame.count.CreateTexture == createdBefore and allCalls(frame, "SetPoint") == pointsBefore and allCalls(frame, "ClearAllPoints") == 3)
    check("state swap: all 3 textures use the hover file", frame.textures[1].last.SetTexture[1]:find("button%-hover%.tga$") and frame.textures[3].last.SetTexture[1]:find("button%-hover%.tga$"))
    check("SetAsset unknown name fails softly", nine.SetAsset("nope") == false and #Skin.errors == 1)
    Skin.errors = {}

    nine.SetVertexColor(0.5, 0.6, 0.7, 1)
    check("SetVertexColor reaches all textures", frame.textures[2].last.SetVertexColor[3] == 0.7 and frame.textures[3].last.SetVertexColor[1] == 0.5)
    nine.SetShown(false)
    check("SetShown(false) hides all", not frame.textures[1].shown and not frame.textures[2].shown and not frame.textures[3].shown)
    nine.SetShown(true)
    check("SetShown(true) shows all", frame.textures[1].shown and frame.textures[3].shown)

    local win = newFrame({ w = 1408, h = 943 })
    local wn = Skin.NineSlice(win, "window", { layer = "ARTWORK" })
    check("NineSlice window: 9 textures", #wn.textures == 9)
    local tl = win.textures[1].all.SetPoint
    check("window TL cell: fixed 40x72 corner from the top-left", tl[1][4] == 0 and tl[1][5] == 0 and tl[2][1] == "BOTTOMRIGHT" and tl[2][3] == "TOPLEFT" and tl[2][4] == 40 and tl[2][5] == -72)
    local br = win.textures[9].all.SetPoint
    check("window BR cell: anchored to the bottom-right corner", br[1][3] == "BOTTOMRIGHT" and br[1][4] == -40 and br[1][5] == 40 and br[2][3] == "BOTTOMRIGHT" and br[2][4] == 0 and br[2][5] == 0)
    local scaled = newFrame({ w = 300, h = 200 })
    Skin.NineSlice(scaled, "window", { scale = 0.5 })
    check("scale 0.5: TL corner 20x36", scaled.textures[1].all.SetPoint[2][4] == 20 and scaled.textures[1].all.SetPoint[2][5] == -36)

    local dd = newFrame({ w = 200, h = 32 })
    Skin.NineSlice(dd, "dropdown", { inset = { l = 15, r = 17 } })
    local ddp = dd.textures[3].all.SetPoint
    check("inset: right arrow zone starts 34+17 from the right edge", ddp[1][3] == "TOPRIGHT" and ddp[1][4] == -34 - 17 and ddp[2][4] == -17)

    local danger = newFrame({ w = 30, h = 30 })
    local dn = Skin.NineSlice(danger, "checkbox-on")
    check("slice-less NineSlice: 1 centred fixed texture of 30x30", #dn.textures == 1 and danger.textures[1].last.SetSize[1] == 30 and danger.textures[1].all.SetPoint[1][1] == "CENTER")
    check("shape change (nine -> fixed) relays out and hides spare textures", (function()
        local f = newFrame({ w = 40, h = 40 })
        local n = Skin.NineSlice(f, "window")
        n.SetAsset("checkbox-on")
        return #n.textures == 9 and f.textures[1].shown and not f.textures[2].shown and not f.textures[9].shown
    end)())
    check("NineSlice without data/asset fails softly", Skin.NineSlice(frame, "does-not-exist") == nil)
    Skin.errors = {}
end

-- ---------------------------------------------------------------------------------------------
-- State priority
-- ---------------------------------------------------------------------------------------------
do
    local names = { normal = "n", hover = "h", pressed = "p", disabled = "d", selected = "s", focus = "f" }
    check("state priority: disabled > pressed > selected > focus > hover > normal",
        Skin.StateAsset(names, { hover = true }) == "h" and Skin.StateAsset(names, { hover = true, focus = true }) == "f"
        and Skin.StateAsset(names, { hover = true, selected = true }) == "s" and Skin.StateAsset(names, { selected = true, pressed = true }) == "p"
        and Skin.StateAsset(names, { pressed = true, disabled = true }) == "d" and Skin.StateAsset(names, {}) == "n")
    check("state falls back to normal when a state asset is missing", Skin.StateAsset({ normal = "n" }, { hover = true, pressed = true }) == "n")
end

-- ---------------------------------------------------------------------------------------------
-- Register
-- ---------------------------------------------------------------------------------------------
resetSkin("current")
do
    local all = {}
    for _, kind in ipairs(Skin.KindNames()) do
        local widget = newFrame({ w = 100, h = 24 })
        widget.Left, widget.Middle, widget.Right = newTexture(), newTexture(), newTexture()
        widget.Button = newFrame()
        widget.bg = newTexture()
        all[#all + 1] = widget
        check("current: Register(" .. kind .. ") returns false", Skin.Register(widget, kind) == false)
    end
    local touched = 0
    for _, widget in ipairs(all) do
        touched = touched + totalCalls(widget) + totalCalls(widget.Left) + totalCalls(widget.bg) + totalCalls(widget.Button)
            + (widget.count.Show or 0)
    end
    check("current: Register is a strict no-op (0 widget/region calls, empty registry)", touched == 0 and next(Skin.registry) == nil and #Skin.errors == 0, touched)
    check("kinds: all 20 spec kinds exist", #Skin.KindNames() == 20, #Skin.KindNames())
end

resetSkin("clean")
do
    -- button with Blizzard template regions
    local button = newFrame({ w = 112, h = 30 })
    button.Left, button.Middle, button.Right = newTexture(), newTexture(), newTexture()
    local highlight = newTexture()
    button.GetHighlightTexture = function() return highlight end
    check("clean: Register(button) ok", Skin.Register(button, "button") == true and #Skin.errors == 0)
    check("button: template Left/Middle/Right hidden", not button.Left.shown and not button.Middle.shown and not button.Right.shown)
    check("button: native highlight faded, still present", highlight.last.SetAlpha[1] == 0)
    check("button: 3 skin textures, normal file", #button.textures == 3 and lastTexturePath(button):find("button%.tga$") ~= nil)
    check("button: hooks (never SetScript)", button.hooks.OnEnter and button.hooks.OnLeave and button.hooks.OnMouseDown
        and button.hooks.OnMouseUp and button.hooks.OnEnable and button.hooks.OnDisable and (button.count.SetScript or 0) == 0)
    local created, points = button.count.CreateTexture, allCalls(button, "SetPoint")
    button:fire("OnEnter")
    check("button: hover swaps to button-hover", lastTexturePath(button):find("button%-hover%.tga$") ~= nil)
    button:fire("OnMouseDown")
    check("button: press swaps to button-pressed", lastTexturePath(button):find("button%-pressed%.tga$") ~= nil)
    button:fire("OnMouseUp")
    check("button: release returns to hover", lastTexturePath(button):find("button%-hover%.tga$") ~= nil)
    button:fire("OnDisable")
    check("button: disable swaps to button-disabled", lastTexturePath(button):find("button%-disabled%.tga$") ~= nil)
    button:fire("OnEnable")
    button:fire("OnLeave")
    check("button: enable+leave returns to normal", lastTexturePath(button):find("button%.tga$") ~= nil)
    check("button: state changes built nothing new", button.count.CreateTexture == created and allCalls(button, "SetPoint") == points)
    button:fire("OnEnter"); button:fire("OnMouseDown"); button:fire("OnHide")
    check("button: OnHide clears hover/pressed", lastTexturePath(button):find("button%.tga$") ~= nil)
    check("button: registered twice does not double-hook", (function()
        local before = #button.hooks.OnEnter
        Skin.Register(button, "button")
        return #button.hooks.OnEnter == before and #button.textures == 3
    end)())

    local disabled = newFrame({ w = 100, h = 24 })
    disabled.IsEnabled = function() return false end
    disabled.Left = newTexture()
    Skin.Register(disabled, "button")
    check("button created disabled starts as button-disabled", lastTexturePath(disabled):find("button%-disabled%.tga$") ~= nil)

    -- editbox
    local box = newFrame({ w = 200, h = 24 })
    box.Left, box.Middle, box.Right = newTexture(), newTexture(), newTexture()
    ns.Layout = { EDITBOX_INSET = 5, DD_INSET_L = 15, DD_INSET_R = 17 }
    Skin.Register(box, "editbox")
    check("editbox: template border hidden, focus hooks", not box.Left.shown and box.hooks.OnEditFocusGained and box.hooks.OnEditFocusLost)
    check("editbox: art extends 5 px left like the Blizzard border (layout inset kept)", box.textures[1].all.SetPoint[1][4] == -5)
    box:fire("OnEditFocusGained")
    check("editbox: focus swaps to editbox-focus", lastTexturePath(box):find("editbox%-focus%.tga$") ~= nil)
    box:fire("OnEditFocusLost")
    check("editbox: focus lost returns to editbox", lastTexturePath(box):find("editbox%.tga$") ~= nil)

    -- dropdown
    local dd = newFrame({ w = 200, h = 32 })
    dd.Left, dd.Middle, dd.Right = newTexture(), newTexture(), newTexture()
    dd.Button = newFrame()
    local arrows = { newTexture(), newTexture(), newTexture(), newTexture() }
    dd.Button.GetNormalTexture = function() return arrows[1] end
    dd.Button.GetPushedTexture = function() return arrows[2] end
    dd.Button.GetDisabledTexture = function() return arrows[3] end
    dd.Button.GetHighlightTexture = function() return arrows[4] end
    Skin.Register(dd, "dropdown")
    check("dropdown: frame art hidden", not dd.Left.shown and not dd.Middle.shown and not dd.Right.shown)
    check("dropdown: native arrow button transparent but not hidden/disabled",
        arrows[1].last.SetAlpha[1] == 0 and arrows[4].last.SetAlpha[1] == 0 and dd.Button.count.Hide == nil and dd.Button.count.Disable == nil)
    check("dropdown: skin arrow zone fixed 34 px (3 slices, inset from layout)", #dd.textures == 3 and dd.textures[1].all.SetPoint[1][4] == 15)
    dd.Button:fire("OnEnter")
    check("dropdown: hover (on the arrow button) swaps to dropdown-hover", lastTexturePath(dd):find("dropdown%-hover%.tga$") ~= nil)

    -- checkbox
    local cb = newFrame({ w = 25, h = 25 })
    local cbTex = {}
    for _, part in ipairs({ "Normal", "Pushed", "Highlight", "Checked", "DisabledChecked" }) do
        cbTex[part] = newTexture()
        cb["Get" .. part .. "Texture"] = function() return cbTex[part] end
    end
    cb.GetChecked = function() return true end
    Skin.Register(cb, "checkbox")
    check("checkbox: Normal/Checked/Highlight set via Set*Texture",
        cb.last.SetNormalTexture[1]:find("checkbox%-off%.tga$") and cb.last.SetCheckedTexture[1]:find("checkbox%-on%.tga$")
        and cb.last.SetHighlightTexture[1]:find("checkbox%-hover%.tga$") and cb.last.SetHighlightTexture[2] == "BLEND")
    check("checkbox: no extra textures, no SetScript", #cb.textures == 0 and (cb.count.SetScript or 0) == 0)
    cb:fire("OnEnter")
    check("checkbox: hover highlight hidden while checked (checkbox-on stays visible)", cbTex.Highlight.last.SetAlpha[1] == 0)

    -- chevron + SetState
    local chev = newFrame({ w = 16, h = 16 })
    Skin.Register(chev, "chevron")
    check("chevron starts collapsed", lastTexturePath(chev):find("chevron%-collapsed%.tga$") ~= nil)
    check("SetState expanded -> chevron-expanded", Skin.SetState(chev, "expanded") and lastTexturePath(chev):find("chevron%-expanded%.tga$") ~= nil)
    Skin.SetState(chev, "collapsed")
    check("SetState collapsed -> chevron-collapsed", lastTexturePath(chev):find("chevron%-collapsed%.tga$") ~= nil)
    check("SetState on unregistered widget is false", Skin.SetState(newFrame(), "selected") == false)

    -- list row: selected state
    local row = newFrame({ w = 300, h = 64 })
    row.SetBackdrop = function(self, ...) log(self, "SetBackdrop", ...) end
    row.bg, row.bottomEdge = newTexture(), newTexture()
    Skin.Register(row, "listRow")
    check("listRow: backdrop cleared, addon fills hidden", row.last.SetBackdrop[1] == nil and row.count.SetBackdrop == 1 and not row.bg.shown and not row.bottomEdge.shown)
    row:fire("OnEnter")
    Skin.SetState(row, "selected", true)
    row:fire("OnLeave")
    check("listRow: selected state sticks after leave", lastTexturePath(row):find("list%-row%-selected%.tga$") ~= nil)
    Skin.SetState(row, "selected", false)
    check("listRow: deselect returns to list-row", lastTexturePath(row):find("list%-row%.tga$") ~= nil)

    -- window: backdrop only when present, ARTWORK layer
    local window = newFrame({ w = 1408, h = 943 })
    window.SetBackdrop = function(self, ...) log(self, "SetBackdrop", ...) end
    window.corners = { newTexture(), newTexture() }
    window.bg = newTexture()
    Skin.Register(window, "window")
    check("window: 9 ARTWORK textures, backdrop nil, gold corners + opaque bg hidden",
        #window.textures == 9 and window.textures[1].createArgs[2] == "ARTWORK" and window.last.SetBackdrop[1] == nil
        and not window.corners[1].shown and not window.bg.shown)
    local plain = newFrame({ w = 10, h = 10 })
    check("window without SetBackdrop is fine", Skin.Register(plain, "window") == true and #Skin.errors == 0)

    -- sliders / scroll
    local slider = newFrame({ w = 150, h = 18 })
    slider.NineSlice = newFrame()
    local thumb = newTexture()
    slider.GetThumbTexture = function() return thumb end
    Skin.Register(slider, "sliderTrack")
    Skin.Register(slider, "sliderThumb")
    check("slider: template NineSlice frame hidden, track 3 slices", slider.NineSlice.shown == false and #slider.textures == 3)
    check("slider thumb: SetThumbTexture + fixed 16x32", slider.last.SetThumbTexture[1]:find("slider%-thumb%.tga$") and thumb.last.SetSize[1] == 16 and thumb.last.SetSize[2] == 32)
    local scroll = newFrame({ w = 200, h = 300 })
    scroll.ScrollBar = newFrame({ w = 16, h = 280 })
    local sthumb = newTexture()
    scroll.ScrollBar.GetThumbTexture = function() return sthumb end
    Skin.Register(scroll, "scrollTrack")
    Skin.Register(scroll, "scrollThumb")
    check("scroll: track drawn on the ScrollBar (vertical 3 slices), thumb replaced",
        #scroll.ScrollBar.textures == 3 and #scroll.textures == 0 and scroll.ScrollBar.last.SetThumbTexture[1]:find("scroll%-thumb%.tga$"))

    -- divider as a bare Texture
    local parent = newFrame({ w = 200, h = 8 })
    local line = newTexture()
    line.GetParent = function() return parent end
    Skin.Register(line, "divider")
    check("texture widget (divider): hidden, nine drawn on its parent anchored to it",
        not line.shown and #parent.textures == 3 and parent.textures[1].all.SetPoint[1][2] == line)
end

-- ---------------------------------------------------------------------------------------------
-- Accent tint (meta) - only accent kinds
-- ---------------------------------------------------------------------------------------------
resetSkin("clean")
do
    local r, g, b = Skin.Accent()
    check("accent from meta.accent (#39B8B0)", near(r, 0x39 / 255) and near(g, 0xB8 / 255) and near(b, 0xB0 / 255))
    local meta = ns.SkinData.skins.clean.meta
    ns.SkinData.skins.clean.meta = { palette = { accent = "#6E2028" } }
    local pr, pg, pb = Skin.Accent()
    check("accent falls back to meta.palette.accent (#6E2028)", near(pr, 0x6E / 255) and near(pg, 0x20 / 255) and near(pb, 0x28 / 255))
    ns.SkinData.skins.clean.meta = meta
    local tag = newFrame({ w = 64, h = 16 })
    Skin.Register(tag, "tag")
    local plainTint = tag.textures[1].last.SetVertexColor
    tag:fire("OnEnter")
    local tint = tag.textures[1].last.SetVertexColor
    check("accent kind: hover tints (not white)", tint[1] < 1 and tint[1] > r)
    tag:fire("OnLeave")
    local back = tag.textures[1].last.SetVertexColor
    check("accent kind: leave resets to white", back[1] == 1 and back[2] == 1 and back[3] == 1)
    local button = newFrame({ w = 100, h = 24 })
    Skin.Register(button, "button")
    button:fire("OnEnter")
    check("non-accent kind (button): never tinted", button.textures[1].count.SetVertexColor == nil)
    check("ParseColor handles #hex, 0-1 and 0-255 tables", select(1, Skin.ParseColor("#FF0000")) == 1 and select(1, Skin.ParseColor({ 0.5, 0, 0 })) == 0.5 and select(2, Skin.ParseColor({ 255, 51, 0 })) == 0.2 and Skin.ParseColor("zzz") == nil)
end

-- ---------------------------------------------------------------------------------------------
-- Robustness: missing template regions, throwing templates, unknown kinds, missing SkinData
-- ---------------------------------------------------------------------------------------------
resetSkin("clean")
do
    local failures = 0
    for _, kind in ipairs(Skin.KindNames()) do
        local minimal = { CreateTexture = function() return newTexture() end, HookScript = function() end }
        local ok = Skin.Register(minimal, kind)
        if not ok then failures = failures + 1 end
    end
    check("minimal frames (no template regions, no Backdrop) for all kinds: no failure", failures == 0 and #Skin.errors == 0, #Skin.errors > 0 and Skin.errors[1] or failures)

    local bare = {}
    check("frame without CreateTexture/HookScript/GetParent: error collected, not thrown", (function()
        local ok = pcall(Skin.Register, bare, "button")
        return ok
    end)())
    Skin.errors = {}

    local throwing = newFrame({ w = 10, h = 10 })
    throwing.Left = { Hide = function() error("boom") end }
    throwing.Middle = newTexture()
    check("throwing template region: Register survives, error recorded, rest still hidden",
        Skin.Register(throwing, "button") == true and #Skin.errors == 1 and Skin.errors[1]:find("boom") and not throwing.Middle.shown)
    Skin.errors = {}

    check("unknown kind: false + error", Skin.Register(newFrame(), "nonsense") == false and #Skin.errors == 1)
    Skin.errors = {}
    check("nil widget: false", Skin.Register(nil, "button") == false)

    local saved = ns.SkinData
    ns.SkinData = nil
    resetSkin("clean")
    local w = newFrame({ w = 10, h = 10 })
    check("missing SkinData: Register is a no-op with one error", Skin.Register(w, "button") == true and totalCalls(w) == 0 and #Skin.errors == 1)
    ns.SkinData = saved

    resetSkin("clean")
    for i = 1, 80 do Skin.Fail("x", i) end
    check("error log is capped", #Skin.errors == Skin.ERROR_LIMIT)
end

-- ---------------------------------------------------------------------------------------------
-- Skin.SetArtShown (expanded panel hides its header art) and Skin.DropdownTextZone (text ends before the divider)
-- ---------------------------------------------------------------------------------------------
for _, name in ipairs({ "clean" }) do
    resetSkin(name)
    local header = newFrame({ w = 300, h = 34 })
    Skin.Register(header, "panelHeader")
    local all = true
    for _, tex in ipairs(header.textures) do all = all and tex.shown end
    check(name .. ": header art starts visible (3 slices)", #header.textures == 3 and all)
    check(name .. ": SetArtShown(false) hides every slice", Skin.SetArtShown(header, false) == true
        and not header.textures[1].shown and not header.textures[2].shown and not header.textures[3].shown)
    Skin.Refresh(header)
    header:fire("OnEnter")
    check(name .. ": hover while hidden keeps the art hidden", not header.textures[2].shown)
    Skin.SetArtShown(header, true)
    check(name .. ": SetArtShown(true) shows it again", header.textures[1].shown and header.textures[3].shown)
    check(name .. ": SetArtShown on an unregistered widget is a no-op", Skin.SetArtShown(newFrame(), false) == false and #Skin.errors == 0)

    local asset = ns.SkinData.skins[name].assets.dropdown
    local right, width = Skin.DropdownTextZone(195)
    local divider = ns.Layout.DD_INSET_R + (asset.arrowW or asset.slice[3])
    check(name .. ": dropdown text ends " .. Skin.DD_TEXT_GRACE .. " px before the divider (right " .. tostring(right) .. ")",
        right == divider + Skin.DD_TEXT_GRACE and right > divider)
    check(name .. ": dropdown text width = frame - left pad - right zone", width == 195 - ns.Layout.DD_INSET_L - Skin.DD_TEXT_LEFT_PAD - right and width > 0)
    check(name .. ": tiny dropdown keeps a positive text width", select(2, Skin.DropdownTextZone(10)) == 1)
end
resetSkin("current")
check("current: native dropdown zone is left to Blizzard (nil)", Skin.DropdownTextZone(195) == nil)

-- ---------------------------------------------------------------------------------------------
-- Remove / close "x" without a button (dangerButton), and addon-fill hiding with nil holes
-- ---------------------------------------------------------------------------------------------
for _, name in ipairs({ "clean" }) do
    resetSkin(name)
    local function color(hex) local r, g, b = Skin.ParseColor(hex); return r, g, b end
    local nr, ng, nb = color("#C85A4F")
    local hr, hg, hb = color("#FF7A6B")
    local function lastColor(mark) return mark.last.SetTextColor end
    local function sameColor(c, r, g, b) return c and near(c[1], r) and near(c[2], g) and near(c[3], b) and c[4] == 1 end

    -- an existing FontString mark (member / trigger rows)
    local button = newFrame({ w = 22, h = 22 })
    local normal, pushed, disabledTex, highlight = newTexture(), newTexture(), newTexture(), newTexture()
    button.GetNormalTexture = function() return normal end
    button.GetPushedTexture = function() return pushed end
    button.GetDisabledTexture = function() return disabledTex end
    button.GetHighlightTexture = function() return highlight end
    button.mark = newTexture()
    check(name .. ": Register(dangerButton) ok", Skin.Register(button, "dangerButton") == true and #Skin.errors == 0, Skin.errors[1])
    check(name .. ": dangerButton draws no button art (no textures, no NineSlice state)", #button.textures == 0 and Skin.state[button] == nil and Skin.dangers[button] ~= nil)
    check(name .. ": template button textures faded, backdrop dropped",
        normal.last.SetAlpha[1] == 0 and pushed.last.SetAlpha[1] == 0 and disabledTex.last.SetAlpha[1] == 0 and highlight.last.SetAlpha[1] == 0
        and button.last.SetBackdrop ~= nil and button.last.SetBackdrop[1] == nil)
    check(name .. ": the mark stays and is shown, muted red #C85A4F", button.mark.shown and sameColor(lastColor(button.mark), nr, ng, nb))
    button:fire("OnEnter")
    check(name .. ": hover is brighter (#FF7A6B)", sameColor(lastColor(button.mark), hr, hg, hb))
    button:fire("OnLeave")
    check(name .. ": leave returns to #C85A4F", sameColor(lastColor(button.mark), nr, ng, nb))
    button:fire("OnDisable")
    check(name .. ": disabled is grey", sameColor(lastColor(button.mark), 0.5, 0.5, 0.5))
    button:fire("OnEnter")
    check(name .. ": hover while disabled stays grey", sameColor(lastColor(button.mark), 0.5, 0.5, 0.5))
    button:fire("OnEnable"); button:fire("OnLeave")
    check(name .. ": enable returns to #C85A4F", sameColor(lastColor(button.mark), nr, ng, nb))
    button:fire("OnEnter"); button:fire("OnHide")
    check(name .. ": hiding resets the hover colour", sameColor(lastColor(button.mark), nr, ng, nb))
    check(name .. ": click area untouched (no SetSize/SetPoint/SetWidth on the button), hooks only", (button.count.SetSize or 0) == 0
        and (button.count.SetWidth or 0) == 0 and (button.count.SetHeight or 0) == 0 and (button.count.SetPoint or 0) == 0 and (button.count.SetScript or 0) == 0)
    check(name .. ": registered twice does not double-hook", (function()
        local before = #button.hooks.OnEnter
        Skin.Register(button, "dangerButton")
        return #button.hooks.OnEnter == before
    end)())

    -- no mark of its own (list row UIPanelCloseButton): a centred "x" FontString is created
    local bare = newFrame({ w = 24, h = 24 })
    local made
    bare.CreateFontString = function(self, ...)
        made = newTexture()
        made.createArgs = { ... }
        return made
    end
    Skin.Register(bare, "dangerButton")
    check(name .. ": without a mark a centred x FontString is created",
        made ~= nil and made.last.SetText[1] == "\195\151" and made.last.SetPoint[1] == "CENTER" and bare.mark == made and made.shown and sameColor(lastColor(made), nr, ng, nb))

    -- texture strokes (window close): extra.marks, coloured with SetColorTexture
    local close = newFrame({ w = 36, h = 36 })
    local strokeA, strokeB = newTexture(), newTexture()
    strokeA.SetTextColor, strokeB.SetTextColor = false, false -- real Textures have no SetTextColor
    Skin.Register(close, "dangerButton", { marks = { strokeA, strokeB } })
    check(name .. ": window close keeps both strokes, shown and coloured, no box",
        #close.textures == 0 and strokeA.shown and strokeB.shown and sameColor(strokeA.last.SetColorTexture, nr, ng, nb) and sameColor(strokeB.last.SetColorTexture, nr, ng, nb))
    close:fire("OnEnter")
    check(name .. ": strokes brighten on hover", sameColor(strokeA.last.SetColorTexture, hr, hg, hb) and sameColor(strokeB.last.SetColorTexture, hr, hg, hb))
    -- HideAddonFills: extra.hide works although corners / lines are nil (ipairs stopped at the first hole)
    local help = newFrame({ w = 18, h = 18 })
    help.bg, help.mark = newTexture(), newTexture()
    Skin.Register(help, "helpButton", { hide = { help.bg, help.mark } })
    check(name .. ": hide list is applied without corners/lines (help button bg + ? mark hidden)", not help.bg.shown and not help.mark.shown and #Skin.errors == 0)
end
resetSkin("current")
do
    local button = newFrame({ w = 22, h = 22 })
    button.mark = newTexture()
    Skin.Register(button, "dangerButton")
    check("current: dangerButton leaves the native look alone (no hooks, mark untouched)", next(button.hooks) == nil and totalCalls(button.mark) == 0 and Skin.dangers[button] == nil)
end

print("ALL PASS")
