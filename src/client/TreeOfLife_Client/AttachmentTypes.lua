--[[
    AttachmentTypes.lua — Client-side display data for permanent attachments.
    Mirror of server's AttachmentDefs (kept in sync manually); drifting only
    shows stale effect numbers in the inventory / reveal modal, no gameplay
    impact.

    Extracted from AttachmentsModal.lua so DevPanel.lua's reveal modal (fires
    after Final Boss kill) can share the same TYPE_DEFS + describeEffect.
    Previously DevPanel referenced bare `TYPE_DEFS` / `describeEffect` /
    `RARITY_NAMES` / `RARITY_COLORS` globals that were never declared in its
    module — selene flagged it as undefined-variable; runtime would have
    crashed the modal as soon as a player got their first attachment.

    USAGE:
        local AttachmentTypes = require(script.Parent.AttachmentTypes)
        local def = AttachmentTypes.TYPE_DEFS[type]
        local txt = AttachmentTypes.describeEffect(type, rarity)
]]

local AttachmentTypes = {}

AttachmentTypes.TYPE_DEFS = {
    PowerCore = {
        displayName = "Power Core",
        blurb = "+%d base damage",
        effectByRarity = {5, 6, 7, 8, 9},
    },
    Detonator = {
        displayName = "Detonator",
        blurb = "Mobs explode on death (%d%% of mob HP, r=%d)",
        effectByRarity = {
            {hpPct = 0.02, radius = 8},
            {hpPct = 0.04, radius = 8},
            {hpPct = 0.06, radius = 8},
            {hpPct = 0.08, radius = 8},
            {hpPct = 0.10, radius = 8},
        },
    },
    Phoenix = {
        displayName = "Phoenix Charm",
        blurb = "Saves the heart from a fatal blow. Recharges every %d min of wave time.",
        effectByRarity = {20 * 60, 18 * 60, 16 * 60, 14 * 60, 12 * 60},
    },
}

AttachmentTypes.TYPE_ORDER = {"PowerCore", "Detonator", "Phoenix"}

function AttachmentTypes.describeEffect(attType, rarity)
    local def = AttachmentTypes.TYPE_DEFS[attType]
    if not def then return "" end
    -- entry.rarity is guaranteed integer 1..6 by AttachmentStore's load +
    -- tryAward boundary coercion (see AttachmentStore.coerceRarity).
    local eff = def.effectByRarity[rarity]
    if not eff then return "" end
    if attType == "PowerCore" then
        return string.format(def.blurb, eff)
    elseif attType == "Detonator" then
        return string.format(def.blurb,
            math.floor(eff.hpPct * 100 + 0.5), eff.radius)
    elseif attType == "Phoenix" then
        return string.format(def.blurb, math.floor(eff / 60 + 0.5))
    end
    return ""
end

return AttachmentTypes
