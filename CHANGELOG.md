# WoWraVox

## 0.11.0

### Profiles

- A character that logs in for the first time now starts with the starter rules, like a fresh install, instead of a copy of the Default profile: the built-in Bloodlust rule, an empty defensives rule and one rule for each trinket slot (the empty "Add a trinket" placeholder is gone). To reuse a setup on another character, use **Copy profile**. Existing characters keep their profile.

### Item groups and wildcards

- One item rule can now hold several items or equipment slots, for example both trinket slots. Use **Add item** above the list of items; every entry announces on its own when its cooldown ends.
- The message accepts the wildcards `{item}` (name of the item that became ready) and `{slot}` (its slot, for example Trinket 1), in the spoken text and the on-screen text. Text without wildcards is spoken as typed; unknown wildcards stay as typed. A "?" next to the Ready heading lists them.
- A rule that tracks a slot is named after the slot ("Trinket 1"), not after the trinket that sits there, so a rule keeps making sense when you swap items or play another character; the list shows the current item below the name. Existing slot rules still carrying an item's name are renamed once when the profile loads; names you typed yourself are kept. Rules for one exact item keep the item's name.
- When a second entry joins a rule that still uses the generated message, the message becomes "{item} ready". Messages you wrote yourself are never changed.
- Each entry shows its name and item ID on one line, with a tag (Item, or the slot). Click the tag to switch between tracking that exact item and whatever is equipped in its slot; click the icon to pick another item. This replaces the "Track the slot, not the item" checkbox in the editor (the checkbox in the item picker stays).
- Existing item rules convert automatically when the addon loads. Downgrading to 0.10.0 afterwards leaves item rules without an item, so back up your SavedVariables first (see README).

### On-screen text

- The on-screen text is no longer cut off: the anchor is the centre of the text, and the text only wraps beyond 80 % of the screen width. **Anchor** shows a grid over the whole screen (a faint line every 10 px, every fifth one stronger, gold centre lines), a crosshair at the text and a coordinate field at the top of the screen. The text snaps to a grid line within 6 px, and Shift places it freely. Saved positions are converted automatically. Anchor mode ends by itself when you close the window, select another rule or enter combat.

### Interface skins

- The options window can use one of two looks: **WoWraVox** (default, unchanged) or **Clean**. Choose one under **Display options → Interface skin** or with `/wvskin`; a change takes effect after `/reload`.
- In Clean the remove buttons in the lists and the close button of the window are just a cross without a box: muted red, brighter on hover, grey when disabled.

### Bloodlust from other players in combat

- Blizzard hides most buffs from addons in combat, so an external Bloodlust only played the category word and its end was never announced. The matching debuffs (Sated, Exhaustion, Temporal Displacement, Insanity, Fatigued) are marked readable by Blizzard, so the addon can track them in combat.
- The **Heroism / Bloodlust** rule is now built in: it always exists (it is recreated if missing), cannot be deleted, and its buff and debuff triggers cannot be removed. It can still be switched off, and texts, voice and sounds stay editable. It starts enabled on new profiles; existing profiles get it added or completed on the next login. If you keep your own Bloodlust rule next to it, switch one of them off or you hear the announcement twice.
- New rule option **Treat triggers as one effect**: the start is announced when the first trigger appears, the end when the last one is gone. For Bloodlust that means "Bloodlust" once at the start and "Bloodlust ready" once when the Sated debuff ends, not after the 40 s buff. It is on for the built-in rule and available for your own rules.
- The fallback category cues are on in the starter set (Bloodlust: **Bloodlust**, Defensives: **Defensive**; the empty rule is now simply called "Defensives"). An existing built-in Bloodlust rule gets its cue switched on once. WoW plays that word itself whenever the addon does not speak the aura, for example when application text-to-speech is off; where the addon speaks (readable aura, TTS on) the word stays silent so nothing is announced twice.
- New **Expiration-Fallback** in the Expiration panel: WoW plays the category word when the aura ends, also in combat when the addon cannot read it. It is the same word as on application, so use Expiration text-to-speech where you need to tell start from end. Rules that treat their triggers as one effect (Bloodlust) do not use it, their end comes from the readable debuff.
- Auras Blizzard marks as readable are now treated as reliably gone when they disappear in combat, and they no longer also play the native category word (the addon speaks them itself).
- Each trigger in the list shows **combat: spoken**, **combat: own casts** or **combat: sound only**, with a tooltip explaining what can play in combat. `/wvdebug secrecy` lists Blizzard's classification of every aura ID in your rules.
- `/wvdebug sim` plays a short Bloodlust (buff 6 s, Sated 14 s) through the real code in two variants, with the buff hidden as in combat and with both readable, and reports PASS or FAIL in the chat. You hear one start and one end each time; no second player needed.

### Options window

- The Application, Expiration and TTS panels collapse and expand with a click on their heading (plus/minus icon, hint on the right). The state is remembered per rule until you leave the game; Expiration starts collapsed while none of its channels is on. The plus/minus icon now keeps its distance from the panel edge.
- Item and spell rules stack their panels like aura rules: header, items (or spell trigger), Ready and TTS follow each other with the same 6 px gap. The TTS panel no longer sticks to the bottom of the window, so collapsing it keeps its heading in place. The "NOTIFICATIONS" heading is gone; the spell trigger has its own panel, and the source hint ("Choose an equipped item", "Spellbook · ID") sits in the Ready heading.

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
