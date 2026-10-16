# WoWraVox

**Never miss the moment that matters.** WoWraVox tells you by voice, on-screen text and sound what happens to your character and when your abilities are ready again, so you can keep your eyes on the fight.

## Why it exists

It started as a small announcer for Bloodlust, Power Infusion and defensive cooldowns. It grew into a general notification system for auras, trinkets and cooldowns, built around one idea: tell the player clearly what happens to *them*, without clutter and without having to watch icons.

## What it does

- **Auras:** announces buffs and debuffs on you, such as Bloodlust, Heroism, Time Warp, defensives and procs, when they start and when they end.
- **Cooldowns and items:** tells you when a trinket or other equipped item, a spell or a returning charge is ready again. Trinket rules can follow the slot, so swapping trinkets needs no new rule.
- **Voice:** speaks with the built-in WoW Text-to-Speech. Voice, speed and volume are set per rule.
- **On-screen text:** show your own message with your own font, size, colour and position.
- **Sounds:** play a short sound or a spoken category word, also for effects the game hides from addons in combat.
- **Profiles:** keep separate settings per character and per specialization.
- **Aura presets:** choose effects for your class and specialization, or buffs received from other players, under **Add rule → Aura**. Nothing is preselected. You can combine selected effects with your own spell IDs and customize their announcements.
- **Sharing:** send an aura group to other WoWraVox users with a chat link or as text. They see a preview first, and your personal voice and layout settings stay yours.
- **Easy setup:** find spells by name or ID, test sounds, preview on-screen text, and open the settings from the addon compartment, Titan Panel or any LibDataBroker display.

## How it works

1. Open the settings with `/wowravox` (or `/wvr`).
2. Add a rule: an aura, an equipped item or a spell cooldown.
3. Choose what you want to hear and see when it starts, ends or becomes ready.

New profiles start with a ready-made Bloodlust rule and trinket rules.

## Combat announcements

WoW can hide some effects from addons during combat. Your custom spoken text may be unavailable for those effects. A configured and registered category sound can announce the effect instead. Effects that remain readable, and supported effects you cast yourself, can still use custom text when TTS is enabled. Effect tooltips explain detection and category registration separately; unknown availability is shown explicitly.

Spell IDs are the most reliable lookup. Name search depends on names available to the client and may be incomplete.

## Good to know

- World of Warcraft Retail. The interface is available in English and German.
- Everything stays in your game. The addon does not collect or send any data.
- What is new in each version is listed in the changelog of the file on this page.

## Install

Use the Wago or CurseForge app, WowUp, or download the ZIP from the [latest release](https://github.com/Trissilein/WoWraVox/releases/latest) and extract the `WoWraVox` folder into `Interface/AddOns`. In WowUp, **Get Addons → Install from URL** with `https://github.com/Trissilein/WoWraVox` also follows tagged releases.

## Links

- Source code and issues: https://github.com/Trissilein/WoWraVox
- Report a bug: https://github.com/Trissilein/WoWraVox/issues
