--!strict
--[[
    TreeOfLife_Attachments — shared attachment specifications.

    Place as a ModuleScript named "Attachments" in ServerScriptService.
    Required by both the hub (apply at tower placement) and wave system
    (Detonator on-death AOE, Phoenix boss-respawn).

    Per-type, per-rarity numerical effects. Rarity is 1-5:
      1=Common, 2=Rare, 3=Exceptional, 4=Legendary, 5=Mythical
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rarity = require(Shared:WaitForChild("Rarity"))

local M = {}

-- Attachment rarities: Common..Mythical (indexes 1-5). The shared Rarity
-- module also defines index 6 "Special" for upgrade-card tiers, but
-- attachments can't roll Special — exposing just the first 5 here keeps
-- any `for _, name in ipairs(M.RARITY_NAMES)` loop from accidentally
-- iterating into a tier no attachment can have.
M.RARITY_NAMES  = { Rarity.Names[1], Rarity.Names[2], Rarity.Names[3], Rarity.Names[4], Rarity.Names[5] }
M.RARITY_COLORS = { Rarity.Colors[1], Rarity.Colors[2], Rarity.Colors[3], Rarity.Colors[4], Rarity.Colors[5] }

-- Drop-rate weights when a Final Boss kill rolls a rarity. Out of 100.
M.RARITY_DROP_WEIGHTS = {
    50,  -- Common
    25,  -- Rare
    12,  -- Exceptional
    8,   -- Legendary
    5,   -- Mythical
}

-- Available attachment types. Each gets a fixed effect curve over the 5
-- rarities. Adding a new type is a one-edit affair: append to TYPES below.
M.TYPES = {
    PowerCore = {
        displayName = "Power Core",
        description = "+%d base damage to your tower",
        -- effectByRarity[i] = flat damage added to tower's DamageBase
        effectByRarity = {
            5,   -- Common
            6,   -- Rare
            7,   -- Exceptional
            8,   -- Legendary
            9,   -- Mythical
        },
    },
    Detonator = {
        displayName = "Detonator",
        description = "Mobs explode on death dealing %d%% of their HP as AOE damage",
        -- effectByRarity[i] = {hpPct, radius}
        -- hpPct is the percent of the EXPLODING mob's MAX HP dealt to mobs
        -- in radius. Radius is fixed at 8 studs across all rarities.
        effectByRarity = {
            {hpPct = 0.02, radius = 8},   -- Common: 2%
            {hpPct = 0.04, radius = 8},   -- Rare: 4%
            {hpPct = 0.06, radius = 8},   -- Exceptional: 6%
            {hpPct = 0.08, radius = 8},   -- Legendary: 8%
            {hpPct = 0.10, radius = 8},   -- Mythical: 10%
        },
    },
    Phoenix = {
        displayName = "Phoenix Charm",
        description = "Blocks heart damage and teleports all mobs back. Recharges every %d min",
        -- effectByRarity[i] = cooldown in seconds (real time, ungated by
        -- waveInProgress — see tickPhoenixCooldowns in wave system).
        -- Higher rarity = shorter cooldown.
        effectByRarity = {
            10 * 60,  -- Common: 10 min
             9 * 60,  -- Rare: 9 min
             8 * 60,  -- Exceptional: 8 min
             7 * 60,  -- Legendary: 7 min
             6 * 60,  -- Mythical: 6 min
        },
    },
}

-- All known attachment types as a list (for random selection)
M.TYPE_NAMES = {"PowerCore", "Detonator", "Phoenix"}

-- Roll a random rarity using RARITY_DROP_WEIGHTS. Returns rarity int 1-5.
function M.rollRarity()
    local total = 0
    for _, w in ipairs(M.RARITY_DROP_WEIGHTS) do total = total + w end
    local r = math.random() * total
    local acc = 0
    for i, w in ipairs(M.RARITY_DROP_WEIGHTS) do
        acc = acc + w
        if r <= acc then return i end
    end
    return 1
end

-- Roll a random attachment type. Currently uniform across known types.
function M.rollType()
    return M.TYPE_NAMES[math.random(1, #M.TYPE_NAMES)]
end

-- Roll a complete random attachment award { type, rarity }.
function M.rollAttachment()
    return {type = M.rollType(), rarity = M.rollRarity()}
end

-- Convenience: get the numerical effect for an entry { type, rarity }
function M.getEffect(entry)
    if not entry then return nil end
    local def = M.TYPES[entry.type]
    if not def then return nil end
    return def.effectByRarity[entry.rarity]
end

-- Build a human-readable label for an attachment entry. Used by UI + logs.
-- e.g. "Legendary Power Core (+18 damage)"
function M.describe(entry)
    if not entry then return "(none)" end
    local def = M.TYPES[entry.type]
    if not def then return entry.type end
    local rarityName = M.RARITY_NAMES[entry.rarity] or "?"
    local effect = def.effectByRarity[entry.rarity]
    local effectStr = ""
    if entry.type == "PowerCore" and type(effect) == "number" then
        effectStr = string.format(" (+%d damage)", effect)
    elseif entry.type == "Detonator" and type(effect) == "table" then
        effectStr = string.format(" (%d%% mob HP, r=%d)",
            math.floor(effect.hpPct * 100 + 0.5), effect.radius)
    elseif entry.type == "Phoenix" and type(effect) == "number" then
        effectStr = string.format(" (%d min cooldown)", math.floor(effect / 60 + 0.5))
    end
    return string.format("%s %s%s", rarityName, def.displayName, effectStr)
end

return M
