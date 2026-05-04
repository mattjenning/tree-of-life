--!strict
--[[
    CoreUpgrades.lua — Per-Core upgrade options offered after every
    map boss defeat. Player picks ONE of three upgrades scoped to
    their currently-equipped Core archetype.

    9 upgrades total: 3 per Core × 3 Cores. Cadence = 3 picks per
    run (one after each of the 3 map bosses; Pickle Lord doesn't
    fire one — he's the run boss, not a map boss).

    Per Matthew 2026-04-29 design dump (memory:
    project_core_upgrade_picker.md). Phase B (THIS FILE) ships the
    DATA + UI shell only; the gameplay effects land in Phase C with
    actual stat/mechanic plumbing.

    Each upgrade entry:
      id          — stable identifier; stamped on the player as
                    `<id>Stacks` (count of times picked) so future
                    repeat picks compound. Must NOT collide with any
                    existing player attribute name.
      title       — card heading shown in the picker modal.
      description — card body text. Should be one-line readable.
      flavor      — short italic flavor line, optional. Mirrors the
                    TempTowerReward card style.

    USAGE:
        local CoreUpgrades = require(ReplicatedStorage.Shared.CoreUpgrades)
        local options = CoreUpgrades.optionsFor("Power")  -- 3 entries
        for _, opt in ipairs(options) do print(opt.title) end

        local opt = CoreUpgrades.byId("PowerBaseDamage")  -- single lookup

    The server's CoreUpgrades system reads optionsFor() to fire the
    picker remote, then applyPick() (Phase C) when the player picks.
]]

local CoreUpgrades = {}

CoreUpgrades.Options = table.freeze({
    Power = table.freeze({
        table.freeze({
            id          = "PowerBaseDamage",
            title       = "+1 Base Damage",
            description = "All towers gain +1 base damage. Stacks across picks.",
            flavor      = "A flat lift across the board — every tick hits a little harder.",
        }),
        table.freeze({
            id          = "PowerStunKbBonus",
            title       = "Bonus on Stun/KB",
            description = "Hits on stunned or knocked-back targets deal bonus damage.",
            flavor      = "Punish the helpless. Coordination is the lever.",
        }),
        table.freeze({
            id          = "PowerCoreCrit",
            title       = "10% Core Crit",
            description = "Your Core tower has a 10% chance per shot to deal 2× damage.",
            flavor      = "Sometimes the right shot finds the right gap.",
        }),
    }),

    ControlCore = table.freeze({
        table.freeze({
            id          = "ControlDotTickDamage",
            title       = "+1 DOT Tick",
            description = "Every stacking-DOT tick deals +1 extra damage. Stacks across picks.",
            flavor      = "The poison takes longer than they expected.",
        }),
        table.freeze({
            id          = "ControlDotSpread",
            title       = "DOT Spreads on Death",
            description = "When a stacked enemy dies, its DOT stacks spread to enemies in range.",
            flavor      = "A chain of slow ruin.",
        }),
        table.freeze({
            id          = "ControlAddSlow",
            title       = "+5% Slow",
            description = "Adds a 5% slow that stacks with other slow sources.",
            flavor      = "Just a little drag — but it never stops.",
        }),
    }),

    SupportCore = table.freeze({
        table.freeze({
            id          = "SupportEnemyVuln",
            title       = "+5% Damage Taken",
            description = "Enemies take +5% more damage from all sources. Stacks across picks.",
            flavor      = "Mark them. The team finishes the work.",
        }),
        table.freeze({
            id          = "SupportAuraBoost",
            title       = "+5% Both Auras",
            description = "Boosts both the damage AND fire-rate aura percentages by +5.",
            flavor      = "More rhythm, more bite.",
        }),
        table.freeze({
            id          = "SupportHeartRegen",
            title       = "Heart +0.5%/sec",
            description = "The heart heals 0.5% of max HP per second.",
            flavor      = "Slow growth. Steady defense.",
        }),
    }),
})

-- Returns the 3-entry array of upgrade options for a given Core
-- archetype, or nil if the archetype is unknown. Caller MUST treat
-- the array as read-only (it's frozen).
function CoreUpgrades.optionsFor(coreId: string?): { any }?
    if type(coreId) ~= "string" then return nil end
    return CoreUpgrades.Options[coreId]
end

-- Single-upgrade lookup by id. Walks all 3 Cores' options. Returns
-- nil for unknown ids. Used by the server's apply-pick handler to
-- validate the client's selection.
function CoreUpgrades.byId(upgradeId: string?): any?
    if type(upgradeId) ~= "string" then return nil end
    for _, options in pairs(CoreUpgrades.Options) do
        for _, opt in ipairs(options) do
            if opt.id == upgradeId then return opt end
        end
    end
    return nil
end

-- True if the upgrade exists for the given Core (rejects an id from
-- a different Core). Used at apply-pick time so a malicious client
-- can't pick a Control upgrade while equipped with Power.
function CoreUpgrades.belongsToCore(upgradeId: string?, coreId: string?): boolean
    if type(upgradeId) ~= "string" or type(coreId) ~= "string" then return false end
    local options = CoreUpgrades.Options[coreId]
    if not options then return false end
    for _, opt in ipairs(options) do
        if opt.id == upgradeId then return true end
    end
    return false
end

table.freeze(CoreUpgrades)
return CoreUpgrades
