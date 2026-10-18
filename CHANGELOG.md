# WoWraVox

## 0.13.0

- Trinket rules can be shared as a pair: Ctrl-click one of the trinket rules and both are posted as one group. The import creates one item rule per trinket, and the preview lists both with their slots and warns when a slot is already tracked. Other item rules are shared on their own.
- Trinket rules use the {slot} wildcard in their ready text, so the announcement says "Trinket 1" or "Trinket 2" in every language and a swapped trinket keeps the same wording. Existing trinket rules with the generated text switch to it on the next load; texts you wrote yourself stay.
- The German interface uses "Trinket" for the trinket slots.
- Fixed: on-screen text could fail with "Font not set" when a font was not yet set on a new text frame.

## 0.12.1

- Chat sharing is rate-limited and robust against spam, double clicks and look-alike senders. Large groups arrive reliably (the transfer timeout extends while data keeps coming) and the maximum size of a shared group is 8 KB.
- The import preview also lists the sounds and category cues a group would play. Specializations that do not belong to your class are not imported. Names and texts are trimmed and cut safely, and a shared text no longer doubles its `|` characters each time it is passed on.

- Native category sound changes wait for encounter, Mythic+, PvP and map restrictions as well as combat, then resume on restriction-state changes. Existing registrations are preserved while waiting.

- Consistent Application category / Expiration category labels, visible combat guidance, and effect tooltips explaining readable effects, own casts, unknown detection, and native category registration.
- Spell-ID-first search hint stays gray and separate from actual input; name lookup is explicitly described as potentially incomplete.
- Aura groups can be exported with the Export button in the group header. The Import card in the add-rule window and /wvimport take a copied group text, show a preview with its effects and texts, and always create a new group. Personal settings such as voice are not shared.
- Ctrl-click an aura group in the list to put a short link in your chat box; press Enter to send it in the channel you are already in. Other WoWraVox users click the link and the import window opens with your group. The data travels by addon whisper, so you must stay online until they click (the offer lasts 10 minutes). Sharing is blocked during encounters, Mythic+ and PvP.
- An imported group whose name is already taken is renamed ("Defense (2)"). The preview warns when you already track some of its effects, since both groups would announce them. Ctrl-click on the built-in Bloodlust rule says it cannot be shared.
- Item cooldown checks do less work: scans triggered by cooldown events run at most every 0.3 s, equipment and specialization are read once per scan, and the scan no longer creates temporary tables for every tracked item.
- Imported groups use the receiver's default text-to-speech voice. If a rule's sound is not available on your system (missing sound library or unknown sound ID), the default notification sound plays instead of silence.
- Texts in an imported group are checked: they are length-limited, and links or colour codes in them are shown as plain text.

## 0.12.0

### Retail compatibility

- Updated the Retail interface metadata for 12.1.5 (120105).

### Aura presets and setup

- Add rule → Aura offers class and specialization presets, external cooldowns, and Augmentation support. Effects appear as icon tiles in category cards, with real spell tooltips, availability details, and English and German interface text. Nothing is preselected; unavailable or unverified effects cannot be selected.
- Create aura combines manually entered triggers and selected preset effects in one new group. The group overview shows what will be created. Existing rules are preserved.
- Preset effects retain their own Offensive, Defensive, or Healing category. External offensive and defensive cues also say “Somebody loves you”. Setting a category on the group overrides these per-effect cues.
- Aura messages accept `{spell}` for the name of the effect that triggered the announcement. New preset groups use the effect name in their spoken message.
- Presets keep cast IDs and aura IDs separate, so an own cast can announce the effect in combat while its aura remains hidden. Talent changes refresh the chooser without losing manual selections.
- New profiles no longer contain the empty Defensives placeholder. Migration removes only that unchanged default group and preserves customized groups.

### Notifications and interface fixes

- Failed native sound removals retain their registration handles and are retried before a replacement can be registered, preventing duplicate fallback sounds.
- Aura expiry timers are reused when their deadline is unchanged and cancelled when their state is retired. Cooldown and on-screen text frames are recycled without retaining removed rules.
- The addon's text-to-speech takes priority when it can announce an aura. Native category sounds remain the fallback and no longer cause a second announcement. An own cast already announced in combat is not announced again when its hidden aura becomes readable after combat.
- The notification sound Test button plays the selected sound even when a category is configured. Category cues have matching loudness, and Healing has its own bundled cue.
- Fixed the blank Add Aura screen and an invalid text alignment error. Removed the verbose Rule Preview panel to give the editor more space.
- `/wvdebug report` opens a bounded, copyable diagnostic report for the active profile. Character identity, custom rule names and messages, unrelated profiles, and the raw debug log are omitted. It does not reload the UI or require sharing a SavedVariables file. Missing or failing diagnostics no longer prevent announcements.

### Release safeguards

- Build and test dependencies are version-locked and integrity-checked. The release workflow runs the candidate's harnesses before any platform upload.
- Resuming a GitHub upload preserves an already published ZIP. Local archive creation validates version and staging paths before file operations.

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
