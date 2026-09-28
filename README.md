# WoWraVox

WoWraVox is a World of Warcraft Retail addon for Heroism, Bloodlust, Time Warp, buffs, debuffs, trinkets, spell cooldowns, and spoken or on-screen notifications.

## Version

Current pre-release version: **0.9.8**. WoWraVox is approaching its first stable release and the UI, starter setup, and translations are still being refined.

## What it does

- Watches player buffs, debuffs, and item-effect auras.
- Announces when equipped items or Spellbook abilities become ready after a cooldown.
- Speaks through WoW Text-to-Speech with a per-rule voice and volume.
- Shows independent on-screen Apply, Expire, and Ready text with per-text font, size, style, color, and draggable anchor.
- Searches local spell sources by name or accepts comma-separated spell IDs.
- Offers tooltip IDs, minimap access, Titan Panel integration, resizable settings, and a rule preview.

## First launch

A new profile starts with three disabled examples:

1. **Heroism / Bloodlust** shows a completed seven-trigger aura rule.
2. **Add your defensive auras** is an empty aura rule ready for your spell IDs.
3. **Add a trinket** opens the equipped-item picker and becomes an item rule after selection.

Examples are copied only on first launch. Existing WoWraVox, AuraVox, and legacy AuraExpiryTTS settings are preserved and never replaced.

## Usage

- `/wowravox` or `/wvr` opens WoWraVox. `/auravox`, `/avox`, and `/aetts` remain legacy aliases.
- Select **Add rule** to create an Aura, Equipped item, or Spell cooldown rule.
- An equipped-item rule follows the selected item ID if it moves to another slot.
- On-screen text profiles can be previewed, recolored, and independently anchored.

## Localization

English is the base language. German is included. Locale files live in `Locales/`; a missing translation falls back to English.

## Installation

Copy this folder as `Interface/AddOns/WoWraVox`, then run `/reload` in WoW Retail.

### WowUp

In WowUp, open **Get Addons → Install from URL** and paste the repository URL: <https://github.com/Trissilein/WoWraVox>. Use the repository URL rather than a direct ZIP URL so WowUp can follow tagged releases for updates. Alternatively, search for **WoWraVox** with the Wago provider enabled.

## Development

Personal game settings live in WoW `SavedVariables` and are intentionally excluded from Git. Validate Lua syntax, deploy only addon files, compare hashes, then test `/reload` and BugSack in the Retail client.

## License

MIT. See [LICENSE](LICENSE).
