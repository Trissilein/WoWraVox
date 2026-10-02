# WoWraVox

## 0.10.0

### Profiles and settings

- Settings now live in profiles, with per-character and per-specialization assignment. Downgrading to 0.9.8 or earlier starts with empty settings; back up your SavedVariables first (see README).
- The options window has one fixed layout instead of resizable tiers; text boxes, dropdowns and the Text-to-Speech panel share the same grid.
- The Expiration panel now shows a plus/minus icon and a "Click to expand/collapse" hint.
- The minimap button and its setting are gone. Open WoWraVox from the addon compartment, Titan Panel or any LibDataBroker display.
- Settings of the pre-WoWraVox addons (AuraVox, AuraExpiryTTS) are no longer imported, and their `/auravox`, `/avox`, `/aetts` commands are removed.

### Announcements

- Defensive and other self-only buffs (for example Ardent Defender) are announced in combat from your own successful cast. Announcements cover only what happens to you; the other-target option was removed.
- Aura rules can adjust Text-to-Speech speed from 100% to 200%.
- Auras the addon cannot read in combat can still play a native category word (Defensive, Offensive, Bloodlust) or a selected sound through the game. Your own self-cast buffs are spoken instead.
- Several announcements raised in the same frame with the same voice are spoken as one sentence.

### Cooldowns and items

- "Gains a Charge" announces every returning charge (0 to 1 and 1 to 2) for any charge spell, also when WoW hides the charge count in combat.
- Holy Armaments is one rule that announces each charge. Existing linked Holy Bulwark / Sacred Weapon rules are merged on load; the Sacred Weapon rule is disabled, not deleted.
- Item rules can track an equipment slot instead of a fixed item (preset for trinkets): swapping trinkets keeps one rule and announces "Trinket 1 ready" once per cooldown.
- Click a rule's icon to point an item rule at another equipped item.

### Search and diagnostics

- Spell-name search builds a local index, so partial searches also find spells outside your spellbook.
- Diagnostics: `/wvdebug on|off|clear|show`, `/wvttstest <rule>` and `/wvprof` (load times, add-on profiler metrics, per-event timing after `/wvprof on`).
- The release ZIP is about 2 MB smaller.

## 0.9.8

- Spell ID searches now show partial numeric matches, with exact matches first.
- Spell IDs and names are handled more consistently in action bar and macro tooltips.
- Rule editor, starter item selection, tooltip hooks, and on-screen text controls are more reliable.
- Display options and rule preview are easier to reach while configuring rules.

## 0.9.7

- First public pre-release.
- Aura, equipped-item, and Spellbook cooldown notifications.
- Spoken and individually positioned on-screen text profiles.
