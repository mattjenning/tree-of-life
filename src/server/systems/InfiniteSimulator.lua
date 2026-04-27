--[[
    InfiniteSimulator.lua — Pure-math closed-form simulation of the
    AUTO RUN sweep. Eliminates substep cost entirely; runs all 81
    loadouts in milliseconds rather than minutes.

    Per Matthew 2026-04-27: "put together a full Pure-math closed-
    form simulation (Option C from earlier) — full rewrite,
    eliminates substep cost entirely. have it as an option. [...]
    keep this data separate until I can validate it."

    HOW IT WORKS
    ────────────
    For each loadout in the queue:
      For each wave (1..30):
        Compute mob HP = baseHp × cycleMult × loadoutMult
        Compute total tower DPS-time available against the mob during
          its path traversal (path-length / mob-speed seconds, scaled
          by per-tower range coverage)
        If damage-available ≥ mob-HP: mob killed, no heart damage
        Else: mob reaches heart, deals damage = its starting HP
        Sum heart damage; subtract from heart HP
        If heart HP ≤ 0: record fractionalWave + break
      Return finalWave

    SIMPLIFICATIONS — what's MODELED:
      ✓ Per-cycle HP scaling (cycleMult = 1 + (cycle-1) × 0.2)
      ✓ Per-loadout multiplier (1.0 / 1.25 / 1.6 for solo/duo/trio)
      ✓ Per-cycle tower upgrades (damage += 3, fireRate × 1.15,
                                  range × 1.15 capped)
      ✓ Tower DPS = damage × fireRate
      ✓ Range coverage = clamp((range × 2) / PATH_LENGTH, 0, 1)
      ✓ Mob path traversal time = PATH_LENGTH / mobSpeed

    SIMPLIFICATIONS — what's NOT MODELED (yet):
      ✗ AOE / splash / chain interactions (each tower's DPS treated
        as single-target; underestimates AOE-heavy loadouts)
      ✗ Slow / stun (would extend mob path-time, increasing damage)
      ✗ DOT lingering past initial hit (cloud / DOT ramps)
      ✗ Target-priority switching (assumes uniform target distribution)
      ✗ Knockback (would briefly push mob back, extending path-time)
      ✗ Tower-fire ordering / focus-fire (sum-DPS spread evenly)

    These omissions tend to UNDERESTIMATE Control-tower combos
    (no slow/stun benefit) and OVERESTIMATE single-target DPS combos
    (no targeting overlap). Compare results to real-sweep data to
    calibrate the gap.

    USAGE:
      local Sim = require(script.Parent.InfiniteSimulator)
      local results = Sim.runSweep(queue, params)
      -- results = list of { idx, auxIds, label, finalWave, testType="Sim" }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared      = ReplicatedStorage:WaitForChild("Shared")
local TempTowers  = require(Shared:WaitForChild("TempTowers"))
local Config      = require(Shared:WaitForChild("Config"))
local PathGeometry = require(script.Parent:WaitForChild("InfinitePathGeometry"))

local Simulator = {}

------------------------------------------------------------
-- Tunable constants — pulled from Config.InfiniteArena so the
-- simulator and the live spawner (server/systems/Infinite.lua)
-- never drift. Per Matthew 2026-04-27 cleanup: single source of
-- truth for sweep tuning.
------------------------------------------------------------
local IA           = Config.InfiniteArena
local CYCLE_STEP   = IA.CycleStep
local MAX_WAVE     = IA.MaxAutoRunWave
local HEART_HP     = (Config.Map4 and Config.Map4.HeartMaxHp) or 50000

-- (Phase 2 replaced the v1 single PATH_LENGTH constant with
-- per-segment line-circle intersection math — see
-- InfinitePathGeometry.lua. Real path on Map 4 is ~394 studs
-- across 5 segments; per-tower exposure depends on placement.)

local LOADOUT_MULT = IA.LoadoutMult
local MOB          = IA.MobBaseline

-- Wave specs — cycle-1 HP per mob, derived from Pools_C1 in Config.
-- Combined splits the pool 4:3:10 across basic:fast:tank with
-- counts 2:2:1 (24x = pool). Solo is one tank with the full pool.
-- AOE is N basic mobs sharing the pool (count = 6).
local function waveSpec(waveType)
    if waveType == "AOE" then
        local pool, count = IA.Pools_C1.AOE, 6
        return {
            { type = "basic", count = count, hp = pool / count },
        }
    elseif waveType == "Combined" then
        local pool = IA.Pools_C1.Combined
        return {
            { type = "basic", count = 2, hp = pool * (4 / 24) },
            { type = "fast",  count = 2, hp = pool * (3 / 24) },
            { type = "tank",  count = 1, hp = pool * (10 / 24) },
        }
    elseif waveType == "Solo" then
        return {
            { type = "tank", count = 1, hp = IA.Pools_C1.Solo },
        }
    end
    return {}
end

local function testTypeForWave(wave)
    local m = wave % 3
    if m == 1 then return "AOE"
    elseif m == 2 then return "Combined"
    else return "Solo"
    end
end

------------------------------------------------------------
-- Tower stats — base + per-cycle upgrade application
------------------------------------------------------------
-- Power Core baseline. Mirror of the real Power tower (lives in
-- shared/TowerTypes); kept here in Config so a balance pass to
-- the Power Core flows into the simulator without needing to
-- rebuild the tower model.
local POWER_BASE = IA.PowerCoreStats

-- Per-cycle upgrade deltas — pulled from Config.InfiniteArena.Upgrade
-- so the simulator stays in lockstep with applyWaveCycleUpgrades
-- in Infinite.lua. Single source of truth (changing in Config
-- updates both the live spawner and this sim).
local UPGRADE_DAMAGE_FLAT = IA.Upgrade.DamageFlat
local UPGRADE_FR_DELTA    = IA.Upgrade.FireRateMult
local UPGRADE_RANGE_DELTA = IA.Upgrade.RangeMult
local RANGE_CAP_MULT      = IA.Upgrade.RangeCapMult
local POST_CAP_BOOST      = IA.Upgrade.PostCapBoost

local function statsFor(towerId)
    if towerId == "Power" then
        return { damage = POWER_BASE.damage, fireRate = POWER_BASE.fireRate, range = POWER_BASE.range }
    end
    local tpl = TempTowers.Templates[towerId]
    if not tpl then return nil end
    return {
        damage   = tpl.damage   or 1,
        fireRate = tpl.fireRate or 1,
        range    = tpl.range    or 24,
        -- Phase 3 control-effect fields (nil-safe — non-Control
        -- towers won't have these). HoneyHive's patchSlowPct +
        -- patchSeconds map to the same slow model as FrostMelon's
        -- slowPct + slowSeconds.
        slowPct        = tpl.slowPct or tpl.patchSlowPct,
        slowSeconds    = tpl.slowSeconds or tpl.patchSeconds,
        stunSeconds    = tpl.stunSeconds,
        stunCooldown   = tpl.stunCooldown,
    }
end

-- Apply N cycles of upgrades. Range caps at 2× original, after which
-- damage + firerate effects boost 1.5× (matching real spawner).
local function applyUpgrades(stats, cycles)
    local s = { damage = stats.damage, fireRate = stats.fireRate, range = stats.range }
    local origRange = s.range
    local capped = false
    for _ = 1, cycles do
        local boost = capped and POST_CAP_BOOST or 1.0
        s.damage   = s.damage + UPGRADE_DAMAGE_FLAT * boost
        s.fireRate = s.fireRate * (1 + UPGRADE_FR_DELTA * boost)
        if not capped then
            s.range = s.range * (1 + UPGRADE_RANGE_DELTA)
            if s.range >= origRange * RANGE_CAP_MULT then
                capped = true
            end
        end
    end
    return s
end

local function towerDPS(stats)
    return stats.damage * stats.fireRate
end

------------------------------------------------------------
-- Per-tower role lookup (drives slot assignment in the auto-place
-- pattern). Power is forced to slot 1 regardless of role tag.
------------------------------------------------------------
local ROLE_BY_TOWER = TempTowers.RoleByTowerId or {}

local function roleFor(towerId)
    if towerId == "Power" then return "DPS" end
    return ROLE_BY_TOWER[towerId] or "DPS"
end

local CELL_SIZE = (Config.Grid and Config.Grid.CellSize) or 2

------------------------------------------------------------
-- Build slot assignments for a loadout. Returns parallel array:
--   { { towerId = ..., slot = {co, ro, role} }, ... }
-- Called once per loadout (path geometry doesn't change wave-to-
-- wave) so 30 waves of one loadout share the same assignment.
------------------------------------------------------------
local function assignLoadoutSlots(loadoutTowers)
    local roles = {}
    for i, id in ipairs(loadoutTowers) do
        roles[i] = roleFor(id)
    end
    local slots = PathGeometry.assignSlots(roles)
    local out = {}
    for i, id in ipairs(loadoutTowers) do
        out[i] = { towerId = id, slot = slots[i] }
    end
    return out
end

------------------------------------------------------------
-- Phase 3: Slow + stun closed-form multiplier.
--
-- For each tower in the loadout that has slowPct or stunSeconds:
--   • slow contribution = slowPct × (slow_tower_exposure / path_total)
--     — assume slow refreshes while mob is in range (every slow
--     tower in the test pool fires faster than its slowSeconds, so
--     this holds). Cap at 0.7 (no >70% slow).
--   • extra stun seconds = num_stuns_per_mob × stunSeconds
--     where num_stuns = exposure_secs / stunCooldown (cap-limited)
--
-- transit_multiplier = (1 / (1 - slow_factor)) × (1 + extraStunSecs / baseTransit)
-- This multiplier scales every other tower's exposure-seconds.
--
-- Per project_simulator_improvement.md Phase 3: "After this phase,
-- FrostMelon/HoneyHive/RootSprout should stop reading as bottom-tier."
------------------------------------------------------------
local SLOW_FACTOR_CAP = 0.7

local function computeControlMultiplier(slotAssignments, upgradedStats, mobSpeed, baseTransitSecs, pathTotalCells)
    local slowFactor = 0
    local extraStunSecs = 0
    for i, slotEntry in ipairs(slotAssignments) do
        local stats = upgradedStats[i]
        if stats and slotEntry.slot then
            -- Compute this tower's exposure for the slow / stun math.
            local rangeCells = stats.range / CELL_SIZE
            local exposureCells = PathGeometry.pathExposureCells(
                slotEntry.slot.co, slotEntry.slot.ro, rangeCells)
            local exposureSecs = (exposureCells * CELL_SIZE) / math.max(0.001, mobSpeed)

            if stats.slowPct and stats.slowPct > 0 then
                -- Effective slow coverage = in-range exposure + lingering
                -- post-exit slow. Mobs stay slow for slowSeconds after
                -- leaving range, so the slow's effective reach extends by
                -- slowSeconds × mob_speed studs (= slowSeconds × mob_speed
                -- / cellSize cells). Conservative cap at the path total.
                local lingerCells = 0
                if stats.slowSeconds then
                    lingerCells = (stats.slowSeconds * mobSpeed) / CELL_SIZE
                end
                local effectiveCoverage = math.min(1.0,
                    (exposureCells + lingerCells) / math.max(0.001, pathTotalCells))
                local contribution = stats.slowPct * effectiveCoverage
                if contribution > slowFactor then
                    slowFactor = contribution
                end
            end
            if stats.stunSeconds and stats.stunCooldown and stats.stunCooldown > 0 then
                local numStuns = exposureSecs / stats.stunCooldown
                extraStunSecs = extraStunSecs + numStuns * stats.stunSeconds
            end
        end
    end
    if slowFactor > SLOW_FACTOR_CAP then slowFactor = SLOW_FACTOR_CAP end
    local slowMult = 1 / (1 - slowFactor)
    local stunMult = 1.0
    if baseTransitSecs > 0 and extraStunSecs > 0 then
        stunMult = 1 + (extraStunSecs / baseTransitSecs)
    end
    return slowMult * stunMult
end

------------------------------------------------------------
-- Simulate one wave — return total damage to heart this wave.
------------------------------------------------------------
local function simulateWave(loadoutTowers, slotAssignments, cycle, waveType)
    local groups = waveSpec(waveType)
    local cycleMult   = 1 + (cycle - 1) * CYCLE_STEP
    local loadoutMult = LOADOUT_MULT[#loadoutTowers - 1] or 1.0  -- minus Power

    -- Cycle-upgrade count: upgrades fire after every Solo wave
    -- (every 3 waves = 1 cycle of upgrades). After cycle N has
    -- completed, N upgrades have been applied. We're computing
    -- stats DURING cycle N, so cycle-1 upgrades are in effect.
    local upgrades = math.max(0, cycle - 1)

    -- Pre-compute upgraded stats per tower.
    local upgradedStats = {}
    for i, towerId in ipairs(loadoutTowers) do
        local base = statsFor(towerId)
        if base then
            upgradedStats[i] = applyUpgrades(base, upgrades)
        end
    end

    local pathTotalCells = PathGeometry.pathLengthCells()

    local heartDamage = 0
    for _, group in ipairs(groups) do
        local mobInfo = MOB[group.type]
        if mobInfo then
            local mobHp = group.hp * cycleMult * loadoutMult

            -- Phase 2 + 3: per-tower exposure × slow/stun multiplier.
            -- Each tower gets its line-circle intersection exposure;
            -- then ALL towers' exposures get multiplied by the
            -- loadout's combined Control multiplier (slow extends
            -- transit time, stun adds frozen seconds).
            local baseTransit = (pathTotalCells * CELL_SIZE) / mobInfo.speed
            local controlMult = computeControlMultiplier(
                slotAssignments, upgradedStats, mobInfo.speed,
                baseTransit, pathTotalCells)

            local availDmg = 0
            for i, slotEntry in ipairs(slotAssignments) do
                local stats = upgradedStats[i]
                if stats and slotEntry.slot then
                    local exposureSec = PathGeometry.exposureSecondsForTower(
                        slotEntry.slot, stats.range, mobInfo.speed, CELL_SIZE)
                    availDmg = availDmg + towerDPS(stats) * exposureSec * controlMult
                end
            end

            for _ = 1, group.count do
                if availDmg < mobHp then
                    -- Mob reaches heart: deals damage equal to its
                    -- starting HP (heart-damage = mob.damage = mob HP).
                    heartDamage = heartDamage + mobHp
                end
            end
        end
    end

    return heartDamage
end

------------------------------------------------------------
-- Public: run one loadout to wave 30 cap or heart death.
------------------------------------------------------------
function Simulator.runLoadout(auxIds)
    local towers = { "Power" }
    for _, id in ipairs(auxIds) do
        table.insert(towers, id)
    end

    -- Phase 2: assign each tower to its INFINITE_PATTERN slot ONCE
    -- per loadout (path geometry doesn't change wave-to-wave). This
    -- is the input the per-wave simulateWave() consumes via
    -- slotEntry.slot to compute per-tower exposure seconds.
    local slotAssignments = assignLoadoutSlots(towers)

    local heartHp = HEART_HP
    for wave = 1, MAX_WAVE do
        local cycle    = math.ceil(wave / 3)
        local waveType = testTypeForWave(wave)
        local dmg      = simulateWave(towers, slotAssignments, cycle, waveType)
        if dmg >= heartHp then
            -- Heart died this wave — fractional credit for damage
            -- absorbed before the killing blow.
            local frac = math.max(0, math.min(1.0, heartHp / dmg))
            return wave - 1 + frac
        end
        heartHp = heartHp - dmg
    end
    return MAX_WAVE  -- survived to cap
end

------------------------------------------------------------
-- Public: run an entire AUTO RUN queue. Returns parallel result
-- list (one entry per loadout in queue order).
------------------------------------------------------------
function Simulator.runSweep(queue)
    local results = {}
    for i, loadout in ipairs(queue) do
        local fw = Simulator.runLoadout(loadout.auxIds)
        table.insert(results, {
            idx       = i,
            auxIds    = loadout.auxIds,
            label     = loadout.label,
            finalWave = fw,
            testType  = "Sim",
        })
    end
    return results
end

return Simulator
