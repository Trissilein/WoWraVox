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
    },
    -- One rule per trinket slot; they follow whatever trinket is worn.  Name and message are re-generated in
    -- the player's language by ns.CreateStarterDatabase().
    items = {
        {
            presetID = "trinket-1",
            name = "Trinket 1",
            enabled = true,
            message = "{slot} ready",
            members = { { slotID = 13 } },
        },
        {
            presetID = "trinket-2",
            name = "Trinket 2",
            enabled = true,
            message = "{slot} ready",
            members = { { slotID = 14 } },
        },
    },
}

-- Remove only the exact legacy starter shape, before current normalization adds fields with dynamic defaults.
-- Any extra, missing, or changed field leaves provenance uncertain, so preserve the group.
local REMOVED_DEFENSIVES_FIELDS = {
    id = true, presetID = true, name = true, alertCategory = true, spellIDs = true, enabled = true,
    applyEnabled = true, applyMessage = true, expireEnabled = true, expireMessage = true,
}

function ns.Defaults.isPristineRemovedDefensives(rule)
    if type(rule) ~= "table" or rule.presetID ~= "defensives" or rule.name ~= "Defensives" then return false end
    if rule.id ~= nil and (type(rule.id) ~= "string" or not rule.id:match("^rule%-[1-9]%d*$")) then return false end
    if type(rule.spellIDs) ~= "table" or next(rule.spellIDs) ~= nil then return false end
    if rule.alertCategory ~= "defensive" or rule.enabled ~= false or rule.applyEnabled ~= false
        or rule.applyMessage ~= "" or rule.expireEnabled ~= false or rule.expireMessage ~= "" then return false end
    for key in pairs(rule) do
        if not REMOVED_DEFENSIVES_FIELDS[key] then return false end
    end
    return true
end

function ns.Defaults.migrateRemovedDefensives(source)
    local rules = type(source) == "table" and source.auras or source
    if type(rules) ~= "table" then return 0 end
    local removed = 0
    for index = #rules, 1, -1 do
        if ns.Defaults.isPristineRemovedDefensives(rules[index]) then
            table.remove(rules, index)
            removed = removed + 1
        end
    end
    return removed
end
