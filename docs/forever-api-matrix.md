# WoW Forever API matrix

Measured 2026-11-09 with a temporary probe addon on WoW Forever 1.60.1 (build 70862, interface 16001), Human Paladin level 17. Retail = 12.1.5.

| Area | Forever result | Consequence for WoWraVox |
|---|---|---|
| Flavor key | `GetBuildInfo` toc `16001`; `WOW_PROJECT_ID` = 18 (not `MAINLINE` 1, not `CLASSIC` 2); `GetClassicExpansionLevel()` = 0 | Do not branch on `WOW_PROJECT_*`. Packaging selects the flavor through the TOC (`WoWraVox_Camelot.toc`). |
| Engine APIs | `C_UnitAuras`, `C_Spell`, `C_SpellBook`, `C_Item`, `C_VoiceChat.SpeakText`, `C_TTSSettings`, `C_EncodingUtil`, `C_Secrets`, `issecretvalue`, `securecallfunction`, `Settings`, `AddonCompartmentFrame` all present | Core (TTS, aura search, share, skin) runs unchanged. |
| Cooldown Manager | `C_CooldownViewer` + all four viewers + `CooldownViewerSettings` present and shown | CDM tracking and "Open CDM" stay enabled. |
| Specializations | Global `GetSpecialization` / `GetSpecializationInfo` are **nil**. `C_SpecializationInfo.GetSpecialization()` = 1, `GetSpecializationInfo(1)` = `1486, "Paladin"` (one pseudo spec per class), `GetNumSpecializations()` = 1 | `Profiles.GetCurrentSpecialization` now falls back to `C_SpecializationInfo`. Spec filter = class filter. |
| Talents | `C_ClassTalents.GetActiveConfigID` and `C_Traits` present (config 4378197) | Preset talent checks can run; no Forever data yet. |
| Spell IDs | Retail Bloodlust family (2825, 32182, 80353, 90355, 160452, 264667, 390386), Sated/Exhaustion (57724, 57723, 80354, 95809, 207610) and Shield-of-the-Righteous-era IDs resolve to `nil`. Paladin defensives 498, 642, 1022 and Shield Wall 871 resolve. | The spell database is progression-gated (expansion level 0). The Bloodlust starter rule is inert until Forever reaches TBC. Presets built on Retail IDs do not apply. |
| TTS | 12 voices | No change. |

Open: Forever progression stages change which spell IDs exist. Forever preset content has to be verified per stage.
