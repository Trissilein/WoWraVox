#!/usr/bin/env python3
"""Build game-ready skin textures + SkinData.lua from the delivered PNG sets.

    python tools/Build-SkinAssets.py [--src .agents/ui-skin/out/assets]

Reads <src>/<skin>/manifest.json + the runtime PNGs (source stays untouched) and writes
  Assets/skin/<skin>/<name>.tga   32-bit uncompressed TGA (type 2, 32 bpp, 8 alpha bits)
  SkinData.lua                    ns.SkinData (file, content size, pow2 canvas size, slices)

TGA details (same layout as the shipped Assets/WoWraVoxIcon.tga):
  * 18-byte header, no ID, no colour map, image type 2, 32 bpp, descriptor 0x28
    (8 alpha bits + bit 5 = TOP-LEFT origin), pixel order B,G,R,A, no TGA 2.0 footer.
  * Straight (non-premultiplied) alpha. RGB under alpha==0 is replaced by the colour of the
    nearest visible pixel, so bilinear filtering cannot pull black/garbage into the edge.
  * Non-power-of-two images sit in the top-left of the next pow2 canvas; the rest is
    transparent. Sample the content region only: UV = (0..w/texW, 0..h/texH).
  * Pixel-identical images inside a skin are stored once; the Lua entries share the file.
  * Lossless trim of the stretched centre: the game stretches the nine-slice centre anyway, so when
    that centre is pixel-identical along the stretch axis it is cut to a pow2-sized strip
    (newSize = pow2(slice sum + MIN_CENTER)); w,h in SkinData.lua are the trimmed sizes, `slice`
    is unchanged. Assets whose centre is not uniform stay untouched (reported). verify() stretches
    every trimmed image back to the source size and requires a pixel-exact match.
"""
import argparse
import hashlib
import json
import re
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SKINS = ("clean",)
ADDON_DIR = "Interface\\AddOns\\WoWraVox\\Assets\\skin\\"
SKIN_NAMES = {"clean": "Clean"}
SKIP_PREFIX = "button-danger"  # delivered by the design set, unused: the remove/close "x" is a plain cross
BUDGET_BYTES = 1_000_000
MIN_CENTER = 8                 # px of stretched centre kept after the trim
NO_TRIM = {"scroll-thumb"}     # Skin.ApplyScrollThumb squeezes the whole image: never trim it
STATE_SUFFIX = re.compile(r"-(hover|pressed|disabled|focus|selected)$")


def pow2(n):
    p = 1
    while p < n:
        p *= 2
    return p


def hex_rgb(h):
    h = h.lstrip("#")
    return [round(int(h[i:i + 2], 16) / 255.0, 4) for i in (0, 2, 4)]


def clean_rgb(arr):
    """Fill RGB of alpha==0 pixels with the nearest visible pixel colour (grow outward)."""
    known = arr[..., 3] > 0
    if not known.any() or known.all():
        return arr
    rgb = arr[..., :3].copy()
    while not known.all():
        new = known.copy()
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)):
            sk = np.roll(known, (dy, dx), (0, 1))
            sr = np.roll(rgb, (dy, dx), (0, 1))
            # np.roll wraps; mask wrapped borders out
            if dy == 1:
                sk[0, :] = False
            if dy == -1:
                sk[-1, :] = False
            if dx == 1:
                sk[:, 0] = False
            if dx == -1:
                sk[:, -1] = False
            take = sk & ~new
            rgb[take] = sr[take]
            new |= take
        if new.sum() == known.sum():
            break
        known = new
    out = arr.copy()
    out[..., :3] = rgb
    return out


def tga_bytes(arr):
    """Uncompressed 32-bit top-left TGA, hand-assembled (no Pillow footer/quirks)."""
    h, w = arr.shape[:2]
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x28)
    bgra = arr[..., [2, 1, 0, 3]]
    return header + np.ascontiguousarray(bgra).tobytes()


def centre_uniform(arr, axis, lo, hi):
    """True if every column (axis 1) / row (axis 0) in [lo, hi) is identical (alpha==0 RGB ignored)."""
    norm = arr.copy()
    norm[norm[..., 3] == 0] = 0
    part = norm[:, lo:hi] if axis == 1 else norm[lo:hi]
    first = part[:, :1] if axis == 1 else part[:1]
    return bool((part == first).all())


def trim_axis(arr, axis, lo, hi, new_len):
    """Replace the centre [lo, hi) along `axis` by `new_len` copies of its middle line."""
    mid = (lo + hi) // 2
    if axis == 1:
        return np.concatenate([arr[:, :lo], np.repeat(arr[:, mid:mid + 1], new_len, axis=1), arr[:, hi:]], axis=1)
    return np.concatenate([arr[:lo], np.repeat(arr[mid:mid + 1], new_len, axis=0), arr[hi:]], axis=0)


def stretch_back(arr, slice_, width, height):
    """Nearest-neighbour nine-slice of `arr` to width x height (corners/edges fixed, centre stretched)."""
    L, T, R, B = slice_
    h, w = arr.shape[:2]

    def index(n, near, far, src):
        i = np.arange(n)
        mid = near + (i - near) * (src - near - far) // max(n - near - far, 1)
        return np.where(i < near, i, np.where(i >= n - far, src - (n - i), mid))

    return arr[index(height, T, B, h)][:, index(width, L, R, w)]


def plan_trims(loaded):
    """Per state group and axis: new size, or a note why not. Group = stem without -hover/-pressed/...,
    so all states of a widget get identical geometry; one non-uniform member keeps the whole group."""
    groups = {}
    for stem, a, arr in loaded:
        if a.get("slice") and stem not in NO_TRIM:
            groups.setdefault(STATE_SUFFIX.sub("", stem), []).append((stem, a, arr))
    plan, notes = {}, []
    for gname, members in groups.items():
        for axis in (1, 0):
            label = "horizontal" if axis == 1 else "vertical"
            a0 = members[0][1]
            size = a0["width"] if axis == 1 else a0["height"]
            near, far = (a0["slice"][0], a0["slice"][2]) if axis == 1 else (a0["slice"][1], a0["slice"][3])
            if near + far == 0:
                continue                                  # not stretched along this axis
            target = pow2(near + far + MIN_CENTER)
            if target >= size:
                notes.append(f"{gname}: {label} {size} px already minimal (target {target})")
                continue
            bad = [s for s, a, arr in members if not centre_uniform(arr, axis, near, size - far)]
            if bad:
                notes.append(f"{gname}: {label} centre not uniform in {', '.join(bad)} -> kept at {size} px")
                continue
            for stem, _, _ in members:
                plan.setdefault(stem, {})[axis] = target
    return plan, notes


def build_skin(skin, src, outdir):
    sdir = src / skin
    man = json.loads((sdir / "manifest.json").read_text(encoding="utf-8"))
    odir = outdir / skin
    odir.mkdir(parents=True, exist_ok=True)
    for old in odir.glob("*.tga"):
        old.unlink()

    seen = {}          # pixel hash -> stored stem
    stored = {}        # stem -> bytes written
    entries = []       # (stem, record)
    dupes = []
    loaded = []
    for a in man["assets"]:
        stem = a["name"][:-4].lower()
        if stem.startswith(SKIP_PREFIX):
            continue
        img = Image.open(sdir / a["name"]).convert("RGBA")
        if img.size != (a["width"], a["height"]):
            raise SystemExit(f"{skin}/{a['name']}: size {img.size} != manifest")
        loaded.append((stem, a, np.array(img, dtype=np.uint8)))
    plan, notes = plan_trims(loaded)
    trimmed = []       # (stem, old size, new size)
    for stem, a, arr in loaded:
        if stem in plan:
            L, T, R, B = a["slice"]
            old_size = (arr.shape[1], arr.shape[0])
            if 1 in plan[stem]:
                arr = trim_axis(arr, 1, L, old_size[0] - R, plan[stem][1] - L - R)
            if 0 in plan[stem]:
                arr = trim_axis(arr, 0, T, old_size[1] - B, plan[stem][0] - T - B)
            trimmed.append((stem, old_size, (arr.shape[1], arr.shape[0])))
        w, h = arr.shape[1], arr.shape[0]
        tw, th = pow2(w), pow2(h)
        canvas = np.zeros((th, tw, 4), dtype=np.uint8)
        canvas[:h, :w] = arr
        canvas = clean_rgb(canvas)
        key = hashlib.sha256(canvas.tobytes() + struct.pack("<II", tw, th)).hexdigest()
        if key in seen:
            file_stem = seen[key]
            dupes.append((stem, file_stem))
        else:
            file_stem = stem
            seen[key] = stem
            data = tga_bytes(canvas)
            (odir / f"{stem}.tga").write_bytes(data)
            stored[stem] = len(data)
        rec = {"file": f"{file_stem}.tga", "w": w, "h": h, "texW": tw, "texH": th}
        if a.get("slice"):
            rec["slice"] = a["slice"]
        # README special cases
        if stem.startswith("dropdown"):
            rec["arrowW"] = 34             # right 34 source px hold the arrow: keep fixed
        if stem == "window":
            rec["headerH"] = 72            # top 72 source px = header: keep fixed height
        if stem == "checkbox-hover":
            rec["overlay"] = True          # highlight for the UNCHECKED box; keep checkbox-on when checked
        entries.append((stem, rec))
    return man, entries, stored, dupes, trimmed, notes


def lua_val(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(v, list):
        return "{" + ", ".join(lua_val(x) for x in v) + "}"
    return repr(v) if isinstance(v, float) else str(v)


def write_lua(path, skins_out):
    L = [
        "-- generated by tools/Build-SkinAssets.py - do not edit",
        "-- w,h = content size; texW,texH = power-of-two texture canvas (content sits top-left,",
        "-- use texcoords 0..w/texW, 0..h/texH). slice = {left, top, right, bottom} in source pixels.",
        "local _, ns = ...",
        "",
        "ns.SkinData = {",
        '    order = {"clean"},',
        "    skins = {",
    ]
    for skin in SKINS:
        man, entries = skins_out[skin]
        pal = man["palette"]
        L.append(f"        {skin} = {{")
        L.append(f"            dir = {lua_val(ADDON_DIR + skin + chr(92))},")
        L.append("            meta = {")
        L.append(f"                name = {lua_val(SKIN_NAMES[skin])},")
        L.append(f"                accent = {lua_val(pal['accent'])},")
        L.append("                -- palette colours as {r, g, b} 0-1; hex in palettehex")
        L.append("                palette = {")
        for k, v in pal.items():
            L.append(f"                    {k} = {lua_val(hex_rgb(v))},")
        L.append("                },")
        L.append("                palettehex = {")
        for k, v in pal.items():
            L.append(f"                    {k} = {lua_val(v)},")
        L.append("                },")
        L.append(f"                panelBg = {lua_val(hex_rgb(pal['bg']))},")
        L.append("            },")
        L.append("            assets = {")
        for stem, rec in entries:
            order = ["file", "w", "h", "texW", "texH", "slice", "arrowW", "headerH", "overlay"]
            parts = [f"{k} = {lua_val(rec[k])}" for k in order if k in rec]
            L.append(f'                ["{stem}"] = {{ ' + ", ".join(parts) + " },")
        L.append("            },")
        L.append("        },")
    L += ["    },", "}", ""]
    path.write_text("\n".join(L), encoding="utf-8", newline="\n")


def verify(skin, src, outdir, entries):
    """Read every TGA back: raw header + Pillow decode + pixel compare against the source PNG."""
    n = 0
    roundtrip = []
    for stem, rec in entries:
        raw = (outdir / skin / rec["file"]).read_bytes()
        idlen, cmap, itype, _, _, _, _, _, w, h, bpp, desc = struct.unpack("<BBBHHBHHHHBB", raw[:18])
        assert (idlen, cmap, itype, bpp) == (0, 0, 2, 32), (skin, stem, "header")
        assert desc & 0x0F == 8 and desc & 0x20, (skin, stem, "descriptor", hex(desc))
        assert (w, h) == (rec["texW"], rec["texH"]) and len(raw) == 18 + w * h * 4, (skin, stem, "size")
        assert w & (w - 1) == 0 and h & (h - 1) == 0, (skin, stem, "pow2")
        tga = np.array(Image.open(outdir / skin / rec["file"]).convert("RGBA"))
        srcimg = np.array(Image.open(src / skin / (stem + ".png")).convert("RGBA"))
        cw, ch = rec["w"], rec["h"]
        content = tga[:ch, :cw]
        if content.shape[:2] != srcimg.shape[:2]:
            # trimmed asset: stretching it back (nearest nine-slice) must reproduce the source exactly
            assert rec.get("slice"), (skin, stem, "size differs but no slice")
            content = stretch_back(content, rec["slice"], srcimg.shape[1], srcimg.shape[0])
            roundtrip.append(stem)
        assert (content[..., 3] == srcimg[..., 3]).all(), (skin, stem, "alpha differs")
        vis = srcimg[..., 3] > 0
        assert (content[..., :3][vis] == srcimg[..., :3][vis]).all(), (skin, stem, "rgb differs")
        assert (tga[ch:, :, 3] == 0).all() and (tga[:, cw:, 3] == 0).all(), (skin, stem, "padding not transparent")
        # independent BGRA decode of the raw bytes
        px = np.frombuffer(raw, np.uint8, offset=18).reshape(h, w, 4)
        assert (px[..., [2, 1, 0, 3]] == tga).all(), (skin, stem, "raw decode")
        n += 1
    return n, roundtrip


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=str(ROOT / ".agents" / "ui-skin" / "out" / "assets"))
    ap.add_argument("--out", default=str(ROOT / "Assets" / "skin"))
    ap.add_argument("--lua", default=str(ROOT / "SkinData.lua"))
    args = ap.parse_args()
    src, outdir = Path(args.src), Path(args.out)

    skins_out, rows, fail = {}, [], False
    for skin in SKINS:
        man, entries, stored, dupes, trimmed, notes = build_skin(skin, src, outdir)
        skins_out[skin] = (man, entries)
        total = sum(stored.values())
        print(f"[{skin}] {len(entries)} assets -> {len(stored)} files, {len(dupes)} duplicate(s) folded")
        for d, s in dupes:
            print(f"    {d} == {s}")
        print(f"    trimmed {len(trimmed)} asset(s) (stretched centre cut to a pow2 strip):")
        for stem, (ow, oh), (nw, nh) in trimmed:
            print(f"      {stem:22s} {ow}x{oh} -> {nw}x{nh}")
        for n in notes:
            print(f"    not trimmed: {n}")
        for stem, size in stored.items():
            rows.append((skin, stem, size))
        print(f"    raw total {total} bytes ({total / 1024:.1f} KiB)  budget {BUDGET_BYTES} -> "
              f"{'OK' if total < BUDGET_BYTES else 'OVER'}")
        fail |= total >= BUDGET_BYTES
    write_lua(Path(args.lua), skins_out)

    print("\nfile sizes (bytes)")
    for skin, stem, size in rows:
        print(f"  {skin:8s} {stem + '.tga':32s} {size:8d}")
    for skin in SKINS:
        print(f"  SUM {skin}: {sum(s for k, _, s in rows if k == skin)}")

    for skin in SKINS:
        n, roundtrip = verify(skin, src, outdir, skins_out[skin][1])
        print(f"verify {skin}: {n} entries OK (header type2/32bpp/alpha8/top-left, pixels == source)")
        print(f"verify {skin}: round-trip {len(roundtrip)} trimmed entries stretched back == source PNG, diff 0")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
