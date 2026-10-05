local _, ns = ...

ns.Defaults = {
    version = 1,
    auras = {
        {
            presetID = "heroism-bloodlust",
            name = "Heroism / Bloodlust",
            -- Built in: cannot be deleted, these triggers cannot be removed (see ns.ensureBuiltinRules).
            -- Buffs first; the Sated family after them is readable in combat, where the buffs are hidden.
            -- oneEffect: one announcement when the first one appears, one when the last one is gone.
            builtin = true,
            oneEffect = true,
            spellIDs = { 2825, 32182, 80353, 90355, 264667, 390386, 466904, 57724, 57723, 80354, 95809, 264689, 390435 },
            enabled = true,
            -- Fallback: WoW plays the category word itself when the addon does not speak (TTS off).
            alertCategory = "bloodlust",
            expireEnabled = true,
            expireMessage = "Bloodlust ready",
            applyEnabled = true,
            applyMessage = "Bloodlust",
        },
        {
            presetID = "defensives",
            name = "Defensives",
            alertCategory = "defensive",
            spellIDs = {},
            enabled = false,
            applyEnabled = false,
            applyMessage = "",
            expireEnabled = false,
            expireMessage = "",
        },
    },
    -- One rule per trinket slot; they follow whatever trinket is worn.  Name and message are re-generated in
    -- the player's language by ns.CreateStarterDatabase().
    items = {
        {
            presetID = "trinket-1",
            name = "Trinket 1",
            enabled = true,
            message = "Trinket 1 ready",
            members = { { slotID = 13 } },
        },
        {
            presetID = "trinket-2",
            name = "Trinket 2",
            enabled = true,
            message = "Trinket 2 ready",
            members = { { slotID = 14 } },
        },
    },
}
