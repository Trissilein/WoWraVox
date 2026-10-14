# Build-only dependencies

These pinned tools support the Lua and addon regression harnesses. They are not WoW addon runtime dependencies. `Run-BuildHarnesses.sh` installs Fengari from the npm lockfile and the platform-specific Lupa wheel from `requirements-lupa.txt`.

## Known npm audit residual

The locked Fengari 0.1.5 dependency tree includes `sprintf-js` 1.1.3, which npm audit reports under [GHSA-hp3w-g68c-fv3c](https://github.com/advisories/GHSA-hp3w-g68c-fv3c). The advisory covers unbounded numeric precision specifiers passed to `toFixed`, `toExponential`, or `toPrecision`, which can raise an uncaught `RangeError`; no patched `sprintf-js` release is available in the registry at this pin.

The harness does execute Fengari's `string.format` implementation, which calls `sprintf-js` for numeric and string conversions. For example, `Test-AuraPresets.lua` prints its status using fixed `%d` conversions. Fengari's `scanformat` rejects width or precision fields longer than two digits, and the current harness uses fixed format strings, so it does not exercise the advisory's oversized-precision trigger. This is a build/test dependency residual; no addon runtime dependency is introduced. Reassess when Fengari or `sprintf-js` ships a patched dependency path, and validate any replacement before changing the lockfile.
