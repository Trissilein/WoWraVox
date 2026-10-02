"""Lua 5.1 syntax + top-level-locals headroom check for every file in WoWraVox.toc (+ tools/*.lua).

Usage: python tools/Test-LuaSyntax.py      (needs: pip install lupa)
Exit 1 on any syntax error. Low headroom only warns (WoW limit: 200 locals per function).
"""
import glob
import os
import sys

import lupa.lua51 as lupa51

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WARN_BELOW = 10
MAX_LOCALS = 200

rt = lupa51.LuaRuntime()
# Returns nil on success, else the error message. Lupa passes bytes/str through as str.
load = rt.eval("function(s, n) local f, e = loadstring(s, n) if f then return nil end return e end")


def toc_files():
    files = []
    with open(os.path.join(ROOT, "WoWraVox.toc"), encoding="utf8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and line.lower().endswith(".lua"):
                files.append(line.replace("\\", "/"))
    return files


def headroom(src, name):
    """Largest N such that 'local d1..dN;' prepended still compiles (binary search, in memory)."""
    lo, hi = 0, MAX_LOCALS
    while lo < hi:
        mid = (lo + hi + 1) // 2
        dummy = "local " + ",".join("d%d" % i for i in range(mid)) + ";" if mid else ""
        if load(dummy + src, name) is None:
            lo = mid
        else:
            hi = mid - 1
    return lo


def main():
    paths = toc_files() + [os.path.relpath(p, ROOT).replace("\\", "/")
                           for p in sorted(glob.glob(os.path.join(ROOT, "tools", "*.lua")))]
    failed = False
    for rel in paths:
        full = os.path.join(ROOT, rel)
        if not os.path.isfile(full):
            print("FAIL %s: missing on disk" % rel)
            failed = True
            continue
        with open(full, encoding="utf8") as fh:
            src = fh.read()
        err = load(src, "@" + rel)
        if err is not None:
            print("FAIL %s: %s" % (rel, err))
            failed = True
            continue
        free = headroom(src, "@" + rel)
        if free < WARN_BELOW:
            msg = "%s: only %d free top-level locals (limit %d)" % (rel, free, MAX_LOCALS)
            print("WARN %s" % msg)
            if os.environ.get("GITHUB_ACTIONS"):
                print("::warning file=%s::%s" % (rel, msg))
        else:
            print("OK   %s (free top-level locals: %d)" % (rel, free))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
