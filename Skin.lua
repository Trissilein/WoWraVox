-- Skin layer: an optional texture skin ("clean") on top of the Blizzard templates. "current" (default) is a
-- strict no-op. Unknown stored values (e.g. removed skins) fall back to "current". Data comes from ns.SkinData (generated).
-- The skin is chosen when the UI is built; changing it needs /reload.
local _, ns = ...

ns.Skin = ns.Skin or {}
local Skin = ns.Skin

Skin.NAMES = { "current", "clean" }
Skin.errors = {}                                     -- pcall failures; never thrown at the caller
Skin.registry = setmetatable({}, { __mode = "k" })   -- widget -> { [kind] = true } (weak keys)
Skin.state = setmetatable({}, { __mode = "k" })      -- widget -> state machine (weak)
Skin.ACCENT_MIX = 0.35
Skin.ERROR_LIMIT = 50

-- ---------------------------------------------------------------------------------------------
-- Basics: names, active skin, error collection
-- ---------------------------------------------------------------------------------------------

function Skin.Names()
    local copy = {}
    for index, name in ipairs(Skin.NAMES) do copy[index] = name end
    return copy
end

function Skin.IsValid(name)
    for _, known in ipairs(Skin.NAMES) do
        if known == name then return true end
    end
    return false
end

-- Read once (after the DB exists) and cached: Set() only takes effect after /reload.
function Skin.Active()
    if Skin.active then return Skin.active end
    local db = WoWraVoxDB
    if type(db) ~= "table" or type(db.settings) ~= "table" then return "current" end
    local name = db.settings.skin
    if not Skin.IsValid(name) then name = "current" end
    Skin.active = name
    return name
end

function Skin.Set(name)
    if not Skin.IsValid(name) then name = "current" end
    local db = WoWraVoxDB
    if type(db) ~= "table" then
        Skin.Fail("Set", "WoWraVoxDB missing")
        return name
    end
    db.settings = type(db.settings) == "table" and db.settings or {}
    db.settings.skin = name
    return name
end

function Skin.Fail(where, err)
    if #Skin.errors < Skin.ERROR_LIMIT then
        Skin.errors[#Skin.errors + 1] = tostring(where) .. ": " .. tostring(err)
    end
end

function Skin.Try(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then Skin.Fail("pcall", result) end
    return ok, result
end

function Skin.Round(value)
    return math.floor(value + 0.5)
end

-- Skin data of the active texture skin, or nil (current / data missing).
function Skin.Data()
    local name = Skin.Active()
    if name == "current" then return nil end
    local all = ns.SkinData
    local data = all and all.skins and all.skins[name]
    if not data and not Skin.missingReported then
        Skin.missingReported = true
        Skin.Fail("Data", "no SkinData for skin " .. tostring(name))
    end
    return data
end

function Skin.ParseColor(value)
    if type(value) == "string" then
        local r, g, b = value:match("^#?(%x%x)(%x%x)(%x%x)$")
        if r then return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255 end
    elseif type(value) == "table" then
        local r, g, b = tonumber(value[1] or value.r), tonumber(value[2] or value.g), tonumber(value[3] or value.b)
        if r and g and b then
            if r > 1 or g > 1 or b > 1 then return r / 255, g / 255, b / 255 end
            return r, g, b
        end
    end
end

-- Accent colour of the active skin (meta.accent | meta.palette.accent | meta.colors.accent), or nil.
function Skin.Accent()
    local data = Skin.Data()
    local meta = data and data.meta
    if type(meta) ~= "table" then return nil end
    local value = meta.accent
    if value == nil and type(meta.palette) == "table" then value = meta.palette.accent end
    if value == nil and type(meta.colors) == "table" then value = meta.colors.accent end
    return Skin.ParseColor(value)
end

-- ---------------------------------------------------------------------------------------------
-- Geometry (pure, testable)
-- ---------------------------------------------------------------------------------------------

function Skin.IsFixed(asset, force)
    return force or not asset.slice
end

-- Fixed corner sizes in UI units: source pixels * scale, rounded to whole pixels.
function Skin.CornerSizes(asset, scale)
    local slice = asset.slice or {}
    scale = scale or 1
    return Skin.Round((slice[1] or 0) * scale), Skin.Round((slice[2] or 0) * scale),
        Skin.Round((slice[3] or 0) * scale), Skin.Round((slice[4] or 0) * scale)
end

Skin.ROW_KEYS = { "T", "", "B" }
Skin.COL_KEYS = { "L", "C", "R" }

-- Regions of `asset` drawn into a width x height frame. Each region: key, row, col, x, y (offset from the
-- frame's top-left, y downwards), w, h (UI units) and u0,u1,v0,v1 (content pixels / canvas size, so NPOT
-- canvases with the content in the top-left corner map correctly). Fixed assets give one uniformly
-- scaled, centred region (never stretched).
function Skin.ComputeRegions(asset, width, height, scale, fixed)
    scale = scale or 1
    local w, h = asset.w, asset.h
    local texW, texH = asset.texW or w, asset.texH or h
    if not width or not height then width, height = w * scale, h * scale end
    if fixed or not asset.slice then
        local fit = math.min(width / w, height / h)
        local rw, rh = Skin.Round(w * fit), Skin.Round(h * fit)
        return { { key = "C", row = 2, col = 2, x = Skin.Round((width - rw) / 2), y = Skin.Round((height - rh) / 2),
            w = rw, h = rh, u0 = 0, u1 = w / texW, v0 = 0, v1 = h / texH } }
    end
    local slice = asset.slice
    local srcL, srcT, srcR, srcB = slice[1] or 0, slice[2] or 0, slice[3] or 0, slice[4] or 0
    local cl, ct, cr, cb = Skin.CornerSizes(asset, scale)
    if cl + cr > width and cl + cr > 0 then cl = math.floor(width * cl / (cl + cr)); cr = width - cl end
    if ct + cb > height and ct + cb > 0 then ct = math.floor(height * ct / (ct + cb)); cb = height - ct end
    local xs, ys = { 0, cl, width - cr, width }, { 0, ct, height - cb, height }
    local us, vs = { 0, srcL / texW, (w - srcR) / texW, w / texW }, { 0, srcT / texH, (h - srcB) / texH, h / texH }
    local regions = {}
    for row = 1, 3 do
        for col = 1, 3 do
            local rw, rh = xs[col + 1] - xs[col], ys[row + 1] - ys[row]
            if rw > 0 and rh > 0 and us[col + 1] > us[col] and vs[row + 1] > vs[row] then
                regions[#regions + 1] = {
                    key = Skin.ROW_KEYS[row] .. Skin.COL_KEYS[col], row = row, col = col,
                    x = xs[col], y = ys[row], w = rw, h = rh,
                    u0 = us[col], u1 = us[col + 1], v0 = vs[row], v1 = vs[row + 1],
                }
            end
        end
    end
    return regions
end

-- ---------------------------------------------------------------------------------------------
-- NineSlice: up to 9 textures on `parent`, anchored to its edges (no SetTextureSliceMargins).
-- ---------------------------------------------------------------------------------------------

function Skin.SizeOf(frame)
    local width = frame and frame.GetWidth and frame:GetWidth() or 0
    local height = frame and frame.GetHeight and frame:GetHeight() or 0
    return width, height
end

-- asset: asset table or asset name (resolved in opts.data / the active skin).
-- opts: scale (1), layer ("BACKGROUND"), sublayer (-8), data, anchor (region to anchor to, default parent),
--       inset {l,t,r,b} (outer offsets, positive = inwards), fixed (force uniform fit, no stretching).
function Skin.NineSlice(parent, asset, opts)
    opts = opts or {}
    local data = opts.data or Skin.Data()
    local name = type(asset) == "string" and asset or nil
    if name then asset = data and data.assets and data.assets[name] end
    if not parent or type(asset) ~= "table" then
        Skin.Fail("NineSlice", "unknown asset " .. tostring(name))
        return nil
    end
    local host = opts.anchor or parent
    local scale = opts.scale or 1
    local layer, sublayer = opts.layer or "BACKGROUND", opts.sublayer or -8
    local inset = opts.inset or {}
    local insetL, insetT, insetR, insetB = inset.l or 0, inset.t or 0, inset.r or 0, inset.b or 0
    local self = { textures = {}, shown = true }
    local used, shape, color, uvs = 0, nil, nil, {}

    local function pathOf(a)
        return ((a.dir or (data and data.dir)) or "") .. a.file
    end

    local function shapeKey(a, fixed)
        local s = a.slice or {}
        return table.concat({ a.w, a.h, a.texW or a.w, a.texH or a.h, s[1] or "-", s[2] or "-", s[3] or "-", s[4] or "-",
            fixed and "F" or "N" }, ":")
    end

    local function layout(a)
        local fixed = Skin.IsFixed(a, opts.fixed)
        local hostW, hostH = Skin.SizeOf(host)
        if not (hostW > 0 and hostH > 0) then hostW, hostH = a.w * scale, a.h * scale end
        local regions = fixed and Skin.ComputeRegions(a, hostW, hostH, scale, true)
            or Skin.ComputeRegions(a, a.w * scale, a.h * scale, scale, false)
        local cl, ct, cr, cb = Skin.CornerSizes(a, scale)
        local path = pathOf(a)
        for index, region in ipairs(regions) do
            local tex = self.textures[index]
            if not tex then
                tex = parent:CreateTexture(nil, layer, nil, sublayer)
                self.textures[index] = tex
            end
            tex:ClearAllPoints()
            tex:SetTexture(path)
            tex:SetTexCoord(region.u0, region.u1, region.v0, region.v1)
            uvs[index] = region
            if fixed then
                tex:SetPoint("CENTER", host, "CENTER", 0, 0)
                tex:SetSize(region.w, region.h)
            else
                local row, col = region.row, region.col
                local tlX = (col == 1 and insetL) or (col == 2 and cl + insetL) or (-cr - insetR)
                local tlY = (row == 1 and -insetT) or (row == 2 and -ct - insetT) or (cb + insetB)
                local brX = (col == 1 and cl + insetL) or (col == 2 and -cr - insetR) or -insetR
                local brY = (row == 1 and -ct - insetT) or (row == 2 and cb + insetB) or insetB
                tex:SetPoint("TOPLEFT", host, (row == 3 and "BOTTOM" or "TOP") .. (col == 3 and "RIGHT" or "LEFT"), tlX, tlY)
                tex:SetPoint("BOTTOMRIGHT", host, (row == 1 and "TOP" or "BOTTOM") .. (col == 1 and "LEFT" or "RIGHT"), brX, brY)
            end
            if color then tex:SetVertexColor(color[1], color[2], color[3], color[4]) end
            if self.shown then tex:Show() end
        end
        for index = #regions + 1, used do self.textures[index]:Hide() end
        used = #regions
        shape = shapeKey(a, fixed)
    end

    -- Switch state without rebuilding: same geometry -> only the texture files change.
    function self.SetAsset(newName)
        local a = type(newName) == "table" and newName or (data and data.assets and data.assets[newName])
        if not a then
            Skin.Fail("NineSlice.SetAsset", "unknown asset " .. tostring(newName))
            return false
        end
        if shape == shapeKey(a, Skin.IsFixed(a, opts.fixed)) then
            local path = pathOf(a)
            for index = 1, used do
                local tex, uv = self.textures[index], uvs[index]
                tex:SetTexture(path)
                tex:SetTexCoord(uv.u0, uv.u1, uv.v0, uv.v1) -- do not rely on SetTexture keeping the coords
            end
        else
            layout(a)
        end
        self.assetName = type(newName) == "string" and newName or nil
        return true
    end

    function self.SetShown(shown)
        self.shown = shown and true or false
        for index = 1, used do
            if self.shown then self.textures[index]:Show() else self.textures[index]:Hide() end
        end
    end

    function self.SetVertexColor(r, g, b, a)
        color = { r, g, b, a or 1 }
        for index = 1, used do self.textures[index]:SetVertexColor(r, g, b, a or 1) end
    end

    layout(asset)
    self.assetName = name
    return self
end

-- Dropdown text zone of the active texture skin, from the dropdown FRAME: returns the right offset (positive =
-- inwards) and the text width. The text stops DD_TEXT_GRACE px before the divider that opens the arrow zone
-- (asset.arrowW source px from the visible right edge, which is DD_INSET_R inside the frame). nil for current /
-- current: the native layout already ends 43 px from the frame's right edge (Blizzard UIDropDownMenuTemplate
-- Text anchor "RIGHT" of Right x=-43, width = SetWidth - 25), 3 px before the 24 px arrow button.
Skin.DD_TEXT_GRACE = 6
Skin.DD_TEXT_LEFT_PAD = 10
function Skin.DropdownTextZone(frameWidth)
    local data = Skin.Data()
    local asset = data and data.assets and data.assets.dropdown
    if not asset then return nil end
    local layout = ns.Layout or {}
    local insetL, insetR = layout.DD_INSET_L or 15, layout.DD_INSET_R or 17
    local right = insetR + Skin.Round(asset.arrowW or (asset.slice and asset.slice[3]) or 0) + Skin.DD_TEXT_GRACE
    local left = insetL + Skin.DD_TEXT_LEFT_PAD
    return right, math.max(1, frameWidth - left - right)
end

-- ---------------------------------------------------------------------------------------------
-- States: pure priority function + small state machine per widget
-- ---------------------------------------------------------------------------------------------

function Skin.StateAsset(names, flags)
    if flags.disabled and names.disabled then return names.disabled end
    if flags.pressed and names.pressed then return names.pressed end
    if flags.selected and names.selected then return names.selected end
    if flags.focus and names.focus then return names.focus end
    if flags.hover and names.hover then return names.hover end
    return names.normal
end

function Skin.Refresh(widget)
    local st = Skin.state[widget]
    if not st then return end
    local name = Skin.StateAsset(st.names, st.flags)
    if name ~= st.current then
        st.current = name
        Skin.Try(st.nine.SetAsset, name)
    end
    if st.accent then
        local tint = st.flags.hover and st.accent or { 1, 1, 1 }
        Skin.Try(st.nine.SetVertexColor, tint[1], tint[2], tint[3], 1)
    end
end

-- key: hover | pressed | selected | focus | disabled | expanded | collapsed (chevron). No-op without a skin.
function Skin.SetState(widget, key, on)
    local st = Skin.state[widget]
    if not st then return false end
    if on == nil then on = true end
    if key == "expanded" then key = "selected" elseif key == "collapsed" then key = "selected"; on = not on end
    st.flags[key] = on and true or false
    Skin.Refresh(widget)
    return true
end

-- Show/hide the art of a registered widget (e.g. the header art of an expanded panel, which would otherwise
-- keep its own bottom border inside the panel). No-op without a skin state (current).
function Skin.SetArtShown(widget, shown)
    local st = Skin.state[widget]
    if not st then return false end
    Skin.Try(st.nine.SetShown, shown)
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Template access helpers (nil-safe, pcall-wrapped)
-- ---------------------------------------------------------------------------------------------

function Skin.Hide(region)
    if region and region.Hide then Skin.Try(region.Hide, region) end
end

function Skin.Fade(region)
    if region and region.SetAlpha then Skin.Try(region.SetAlpha, region, 0) end
end

function Skin.Hook(frame, script, fn)
    if frame and frame.HookScript then Skin.Try(frame.HookScript, frame, script, fn) end
end

-- Fade the native button textures (Normal/Pushed/Disabled/Highlight); the button stays clickable.
function Skin.FadeButtonTextures(button, which)
    if not button then return end
    for _, part in ipairs(which) do
        local getter = button["Get" .. part .. "Texture"]
        if getter then
            local ok, tex = Skin.Try(getter, button)
            if ok then Skin.Fade(tex) end
        end
    end
end

function Skin.AssetPath(data, name)
    local asset = data.assets and data.assets[name]
    if not asset then
        Skin.Fail("asset", "unknown " .. tostring(name))
        return nil
    end
    return asset, ((asset.dir or data.dir) or "") .. asset.file
end

-- SetXTexture(path) on a template button + exact UVs on the resulting texture region.
function Skin.SetButtonTexture(button, setter, getter, data, name, ...)
    local asset, path = Skin.AssetPath(data, name)
    if not asset or not button[setter] then return nil end
    Skin.Try(button[setter], button, path, ...)
    local ok, tex = Skin.Try(button[getter], button)
    if ok and tex and tex.SetTexCoord then
        Skin.Try(tex.SetTexCoord, tex, 0, asset.w / (asset.texW or asset.w), 0, asset.h / (asset.texH or asset.h))
    end
    return tex
end

-- ---------------------------------------------------------------------------------------------
-- Kinds. Generic fields: names (state -> asset), layer, sublayer, hideKeys (template regions to Hide()),
-- fadeButton (button texture parts to fade), dropBackdrop, autoHide (addon-made fills/borders),
-- hover / press / enable / focus (hook sets), hoverTarget, inset(), accent, custom(widget, data, extra).
-- ---------------------------------------------------------------------------------------------

Skin.TEMPLATE_TRIO = { "Left", "Middle", "Right" }

Skin.kinds = {
    window      = { names = { normal = "window" }, layer = "ARTWORK", dropBackdrop = true, autoHide = true },
    panel       = { names = { normal = "panel" }, layer = "ARTWORK", dropBackdrop = true, autoHide = true },
    panelHeader = { names = { normal = "panel-header", hover = "panel-header-hover" }, layer = "ARTWORK",
        dropBackdrop = true, autoHide = true, hover = true, accent = true },
    button      = { names = { normal = "button", hover = "button-hover", pressed = "button-pressed", disabled = "button-disabled" },
        hideKeys = Skin.TEMPLATE_TRIO, fadeButton = { "Highlight" }, hover = true, press = true, enable = true },
    dangerButton = { custom = "ApplyDangerButton" },
    editbox     = { names = { normal = "editbox", focus = "editbox-focus" }, hideKeys = Skin.TEMPLATE_TRIO, focus = true,
        inset = function() return { l = -((ns.Layout and ns.Layout.EDITBOX_INSET) or 5) } end },
    dropdown    = { names = { normal = "dropdown", hover = "dropdown-hover" }, hideKeys = Skin.TEMPLATE_TRIO,
        hover = true, enable = true,
        hoverTarget = function(widget) return widget.Button end,
        fadeTarget = function(widget) return widget.Button end,
        fadeButton = { "Normal", "Pushed", "Disabled", "Highlight" },
        inset = function()
            local layout = ns.Layout or {}
            return { l = layout.DD_INSET_L or 15, t = 0, r = layout.DD_INSET_R or 17, b = 2 }
        end },
    sliderTrack = { names = { normal = "slider-track" }, hideKeys = { "NineSlice", "Left", "Middle", "Right" } },
    scrollTrack = { names = { normal = "scroll-track" }, barTarget = true },
    iconFrame   = { names = { normal = "icon-frame" }, layer = "OVERLAY", keepBackdropFill = true },
    swatchFrame = { names = { normal = "swatch-frame" }, layer = "OVERLAY", keepBackdropFill = true },
    listRow     = { names = { normal = "list-row", hover = "list-row-hover", selected = "list-row-selected" }, layer = "ARTWORK",
        dropBackdrop = true, autoHide = true, hover = true },
    memberRow   = { names = { normal = "member-row", hover = "member-row-hover" }, layer = "ARTWORK",
        dropBackdrop = true, autoHide = true, hover = true },
    tag         = { names = { normal = "tag", hover = "tag-hover" }, hover = true, accent = true },
    helpButton  = { names = { normal = "help-button", hover = "help-button-hover" }, fixed = true, hover = true, accent = true,
        fadeButton = { "Highlight" } },
    chevron     = { names = { normal = "chevron-collapsed", selected = "chevron-expanded" }, fixed = true, layer = "ARTWORK" },
    divider     = { names = { normal = "divider" }, layer = "ARTWORK" },
    checkbox    = { custom = "ApplyCheckbox" },
    sliderThumb = { custom = "ApplySliderThumb" },
    scrollThumb = { custom = "ApplyScrollThumb" },
}

function Skin.KindNames()
    local list = {}
    for kind in pairs(Skin.kinds) do list[#list + 1] = kind end
    table.sort(list)
    return list
end

-- Checkbox: Set*Texture on the template button (keeps CheckButton behaviour and its label).
function Skin.ApplyCheckbox(widget, data)
    Skin.SetButtonTexture(widget, "SetNormalTexture", "GetNormalTexture", data, "checkbox-off")
    Skin.SetButtonTexture(widget, "SetPushedTexture", "GetPushedTexture", data, "checkbox-hover")
    Skin.SetButtonTexture(widget, "SetHighlightTexture", "GetHighlightTexture", data, "checkbox-hover", "BLEND")
    Skin.SetButtonTexture(widget, "SetCheckedTexture", "GetCheckedTexture", data, "checkbox-on")
    local disabledOn = Skin.SetButtonTexture(widget, "SetDisabledCheckedTexture", "GetDisabledCheckedTexture", data, "checkbox-on")
    if disabledOn and disabledOn.SetVertexColor then Skin.Try(disabledOn.SetVertexColor, disabledOn, 0.5, 0.5, 0.5, 1) end
    -- checkbox-hover is an unchecked highlight: hide it while the box is checked so checkbox-on stays visible
    local function syncHighlight()
        local tex = widget.GetHighlightTexture and widget:GetHighlightTexture()
        if tex and tex.SetAlpha then tex:SetAlpha((widget.GetChecked and widget:GetChecked()) and 0 or 1) end
    end
    Skin.Hook(widget, "OnEnter", syncHighlight)
    Skin.Hook(widget, "OnClick", syncHighlight)
end

-- Slider thumb: native thumb region gets the asset (fixed size, never stretched).
function Skin.ApplySliderThumb(widget, data, extra)
    local scale = extra.scale or 1
    local asset, path = Skin.AssetPath(data, "slider-thumb")
    if not asset or not widget.SetThumbTexture then return end
    Skin.Try(widget.SetThumbTexture, widget, path)
    local ok, tex = Skin.Try(widget.GetThumbTexture, widget)
    if ok and tex then
        Skin.Try(tex.SetTexCoord, tex, 0, asset.w / (asset.texW or asset.w), 0, asset.h / (asset.texH or asset.h))
        Skin.Try(tex.SetSize, tex, asset.w * scale, asset.h * scale)
    end
end

-- Scroll thumb: native Slider thumb of the scroll bar; asset is squeezed to extra.thumbHeight (default 32).
function Skin.ApplyScrollThumb(widget, data, extra)
    local bar = widget.ScrollBar or widget
    local scale = extra.scale or 1
    local asset, path = Skin.AssetPath(data, "scroll-thumb")
    if not asset or not bar.SetThumbTexture then return end
    Skin.Try(bar.SetThumbTexture, bar, path)
    local ok, tex = Skin.Try(bar.GetThumbTexture, bar)
    if ok and tex then
        Skin.Try(tex.SetTexCoord, tex, 0, asset.w / (asset.texW or asset.w), 0, asset.h / (asset.texH or asset.h))
        Skin.Try(tex.SetSize, tex, asset.w * scale, extra.thumbHeight or 32)
    end
end

-- Remove / close "x" without a button: no frame, backdrop or button art, only the cross itself in muted red
-- (brighter on hover, grey when disabled). The click area is untouched. The cross is widget.mark (FontString),
-- extra.marks (textures, e.g. the window close strokes) or a new "×" FontString.
Skin.DANGER_COLORS = { normal = "#C85A4F", hover = "#FF7A6B", disabled = { 0.5, 0.5, 0.5 } }
Skin.dangers = setmetatable({}, { __mode = "k" }) -- widget -> { marks, flags }

function Skin.PaintDanger(widget)
    local st = Skin.dangers[widget]
    if not st then return end
    local colors = Skin.DANGER_COLORS
    local r, g, b = Skin.ParseColor(st.flags.disabled and colors.disabled or st.flags.hover and colors.hover or colors.normal)
    for _, mark in ipairs(st.marks) do
        if mark.SetTextColor then Skin.Try(mark.SetTextColor, mark, r, g, b, 1)
        elseif mark.SetColorTexture then Skin.Try(mark.SetColorTexture, mark, r, g, b, 1) end
    end
end

function Skin.ApplyDangerButton(widget, data, extra)
    Skin.FadeButtonTextures(widget, { "Normal", "Pushed", "Disabled", "Highlight" })
    if widget.SetBackdrop then Skin.Try(widget.SetBackdrop, widget, nil) end
    local marks = extra.marks or (widget.mark and { widget.mark })
    if not marks and widget.CreateFontString then
        local mark = widget:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        mark:SetPoint("CENTER", widget, "CENTER", 0, 0)
        mark:SetText("×")
        widget.mark = mark
        marks = { mark }
    end
    if not marks then return end
    for _, mark in ipairs(marks) do Skin.Try(mark.Show, mark) end
    local st = { marks = marks, flags = {} }
    Skin.dangers[widget] = st
    if widget.IsEnabled then
        local ok, enabled = Skin.Try(widget.IsEnabled, widget)
        st.flags.disabled = ok and enabled == false
    end
    local function flag(key, value)
        return function()
            st.flags[key] = value
            Skin.PaintDanger(widget)
        end
    end
    Skin.Hook(widget, "OnEnter", flag("hover", true))
    Skin.Hook(widget, "OnLeave", flag("hover", false))
    Skin.Hook(widget, "OnEnable", flag("disabled", false))
    Skin.Hook(widget, "OnDisable", flag("disabled", true))
    Skin.Hook(widget, "OnHide", flag("hover", false))
    Skin.PaintDanger(widget)
end

-- Addon-made fills/borders (stylePanel: bg, texture, corners, lines; list rows: bg, bottomEdge) that would
-- show through the transparent corners of a texture skin.
function Skin.HideAddonFills(widget, extra)
    Skin.Hide(widget.bg)
    Skin.Hide(widget.texture)
    Skin.Hide(widget.bottomEdge)
    local groups = { widget.corners, widget.lines, extra.hide } -- holes are normal: index, never ipairs
    for index = 1, 3 do
        if type(groups[index]) == "table" then
            for _, region in pairs(groups[index]) do Skin.Hide(region) end
        end
    end
end

function Skin.ApplyTexture(widget, kind, spec, extra, data)
    if spec.custom then
        Skin[spec.custom](widget, data, extra)
        return
    end
    local host, anchor = widget, nil
    if not widget.CreateTexture then -- a Texture itself: hide it, draw into its parent
        host, anchor = widget:GetParent(), widget
        Skin.Hide(widget)
    end
    for _, key in ipairs(spec.hideKeys or {}) do Skin.Hide(widget[key]) end
    if spec.fadeButton then Skin.FadeButtonTextures(spec.fadeTarget and spec.fadeTarget(widget) or widget, spec.fadeButton) end
    if spec.dropBackdrop and widget.SetBackdrop then Skin.Try(widget.SetBackdrop, widget, nil) end
    if spec.keepBackdropFill and widget.SetBackdropBorderColor then Skin.Try(widget.SetBackdropBorderColor, widget, 0, 0, 0, 0) end
    if spec.autoHide or extra.hide then Skin.HideAddonFills(widget, extra) end
    if spec.barTarget and widget.ScrollBar then host = widget.ScrollBar end
    local nine = Skin.NineSlice(host, spec.names.normal, {
        data = data, layer = spec.layer, anchor = anchor, scale = extra.scale,
        inset = spec.inset and spec.inset() or extra.inset, fixed = spec.fixed,
    })
    if not nine then return end
    local st = { nine = nine, names = spec.names, flags = {}, current = spec.names.normal }
    Skin.state[widget] = st
    local target = spec.hoverTarget and spec.hoverTarget(widget) or widget
    if spec.accent then
        local r, g, b = Skin.Accent()
        if r then
            local mix = Skin.ACCENT_MIX
            st.accent = { 1 - mix * (1 - r), 1 - mix * (1 - g), 1 - mix * (1 - b) }
        end
    end
    if spec.enable and target and target.IsEnabled then
        local ok, enabled = Skin.Try(target.IsEnabled, target)
        st.flags.disabled = ok and enabled == false
        if st.flags.disabled then Skin.Refresh(widget) end
    end
    local function flag(key, value)
        return function()
            st.flags[key] = value
            Skin.Refresh(widget)
        end
    end
    if spec.hover then
        Skin.Hook(target, "OnEnter", flag("hover", true))
        Skin.Hook(target, "OnLeave", flag("hover", false))
    end
    if spec.press then
        Skin.Hook(widget, "OnMouseDown", flag("pressed", true))
        Skin.Hook(widget, "OnMouseUp", flag("pressed", false))
    end
    if spec.enable then
        Skin.Hook(target, "OnEnable", flag("disabled", false))
        Skin.Hook(target, "OnDisable", flag("disabled", true))
    end
    if spec.focus then
        Skin.Hook(widget, "OnEditFocusGained", flag("focus", true))
        Skin.Hook(widget, "OnEditFocusLost", flag("focus", false))
    end
    if spec.hover or spec.press then
        Skin.Hook(widget, "OnHide", function()
            st.flags.hover, st.flags.pressed = false, false
            Skin.Refresh(widget)
        end)
    end
    if spec.accent then Skin.Refresh(widget) end
end

function Skin.Apply(widget, kind, extra)
    local spec = Skin.kinds[kind]
    if not spec then error("unknown skin kind " .. tostring(kind), 0) end
    local kinds = Skin.registry[widget]
    if not kinds then kinds = {}; Skin.registry[widget] = kinds end
    if kinds[kind] then return end -- already applied (e.g. Register called twice)
    kinds[kind] = true
    local data = Skin.Data()
    if data then Skin.ApplyTexture(widget, kind, spec, extra, data) end
end

-- Register a widget for the active skin and apply it immediately. `current`: strict no-op.
-- extra (all optional): scale, hide = { regions to hide }, inset {l,t,r,b}, thumbHeight.
function Skin.Register(widget, kind, extra)
    if not widget then return false end
    if Skin.Active() == "current" then return false end
    return (Skin.Try(Skin.Apply, widget, kind, extra or {}))
end
