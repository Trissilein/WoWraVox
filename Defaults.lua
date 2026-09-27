local _, ns = ...

ns.Defaults = {
    version = 1,
    auras = {
        {
            presetID = "heroism-bloodlust",
            name = "Heroism / Bloodlust",
            spellIDs = { 2825, 32182, 80353, 90355, 264667, 390386, 466904 },
            enabled = false,
            expireEnabled = true,
            expireMessage = "Bloodlust expired",
            applyEnabled = false,
            applyMessage = "",
        },
        {
            presetID = "defensives",
            name = "Add your defensive auras",
            spellIDs = {},
            enabled = false,
            applyEnabled = false,
            applyMessage = "",
            expireEnabled = false,
            expireMessage = "",
        },
    },
    items = {
        {
            presetID = "trinket",
            starter = "trinket",
            itemID = 0,
            name = "Add a trinket",
            enabled = false,
            message = "",
        },
    },
}
