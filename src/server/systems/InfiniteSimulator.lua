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
local Workspace         = game:GetService("Workspace")
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
-- CYCLE_STEP retired 2026-04-27 — HP scaling now resolves through
-- IA.WaveHpRamp (piecewise per-wave function). The legacy step
-- constant only remains in Config for the simulator's UPGRADE
-- counter (cycle = ceil(wave/3); upgrades = cycle-1) but isn't
-- read here.
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
        local tankDelta = (IA.Pools_C1_TankHpDelta and IA.Pools_C1_TankHpDelta.Combined) or 0
        return {
            { type = "basic", count = 2, hp = pool * (4 / 24) },
            { type = "fast",  count = 2, hp = pool * (3 / 24) },
            { type = "tank",  count = 1, hp = pool * (10 / 24) + tankDelta },
        }
    elseif waveType == "Solo" then
        local tankDelta = (IA.Pools_C1_TankHpDelta and IA.Pools_C1_TankHpDelta.Solo) or 0
        return {
            { type = "tank", count = 1, hp = IA.Pools_C1.Solo + tankDelta },
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

-- Sim calibration knobs (hoisted up here so statsFor + the
-- per-tower-fields can read them at function-definition time —
-- Lua resolves free variables at definition time, not call time).
local SIM_CAL                  = (IA and IA.SimCalibration) or {}
-- (LobMissClusterFloor + LobCatchBaseMult removed 2026-05-01 ea3-141.
-- They were ea3-122 v4 geometry-based catch/miss classifier knobs;
-- the v5 lob model uses a single LobAccuracyMult instead. The reads
-- here had `_` prefixes marking them unused — formal removal now.
-- Config.lua field-removal note left in place there.)
local STACKING_SLOW_EFFECT     = SIM_CAL.StackingSlowEffectiveness or 0.85
local DOT_VALUE_MULT           = SIM_CAL.DotValueMult or 1.0
local STUN_VALUE_MULT          = SIM_CAL.StunValueMult or 1.0
local STACK_DOT_EFFECTIVENESS  = SIM_CAL.StackDotEffectiveness or 1.0
local AURA_VALUE_MULT          = SIM_CAL.AuraValueMult or 1.0
-- ea3-126 aura-coverage model: aux Support buff towers (PaceFlower,
-- PowerSeed, SpyglassRoot, BloodlinkVine) have LOCAL aura radii
-- (16-24 stud); SupportCore's aura is GLOBAL (auraRadius 9999).
-- Real game: only towers WITHIN the local radius receive the buff —
-- on a 36-slot path layout spanning ~80-100 studs, that's ~3-4 of 36
-- towers (~10-15%). Sim previously treated all auras as global,
-- yielding a 4-7× over-credit on aux Support contribution (see
-- ea3-125 baseline FAILURE CURVE × 105 — SpyglassRoot signed +4.62,
-- HoneyHive+SpyglassRoot worst +11.69 on Power).
--
-- Fix: when scanning aura sources, check auraRadius against
-- AURA_GLOBAL_RADIUS_THRESHOLD. Sources >= threshold get full
-- contribution; sources < threshold get scaled by AURA_LOCAL_COVERAGE
-- (the fraction of towers expected to be within the local radius
-- given the auto-place pattern).
local AURA_GLOBAL_RADIUS_THRESHOLD = SIM_CAL.AuraGlobalRadiusThreshold or 100
local AURA_LOCAL_COVERAGE          = SIM_CAL.AuraLocalCoverage or 0.30
local BLINK_VALUE_MULT         = SIM_CAL.BlinkValueMult or 1.0
local LINK_VALUE_MULT          = SIM_CAL.LinkValueMult or 1.0
local BLINK_TRANSIT_CAP        = SIM_CAL.BlinkTransitCap or 0.5
-- Per-Core surgical lift on the Core slot's own contribution.
-- Closes the residual sim-vs-real gap on Control / Support
-- anchors that AuraValueMult alone doesn't cover. See Config.lua
-- for the rationale + per-Core coefficients.
local PER_CORE_DPS_MULT        = SIM_CAL.PerCoreDpsMult or {}

-- Core variants — pulled from shared/TowerTypes for ControlCore /
-- SupportCore. Power keeps using POWER_BASE (which encodes the
-- Infinite-specific starting-upgrade-card buff that vanilla Power
-- doesn't have, so it doesn't match TowerTypes.Power 1:1).
-- Per Matthew 2026-04-27: AUTO RUN can run with any of the three
-- Cores; sim needs to recognize all three.
local TowerTypes  = require(Shared:WaitForChild("TowerTypes"))

local function statsFor(towerId)
    if towerId == "Power" then
        return {
            damage = POWER_BASE.damage, fireRate = POWER_BASE.fireRate, range = POWER_BASE.range,
            footprintW = 4, footprintD = 4,  -- ea3-151: footprint for AABB aura check
        }
    end
    if towerId == "ControlCore" or towerId == "SupportCore" then
        local t = TowerTypes[towerId]
        if t then
            -- Base + mechanic-specific fields. ControlCore exposes
            -- stackDot* fields so the per-tower DPS contribution in
            -- simulateWave can apply the exposure-aware DOT ramp.
            -- SupportCore exposes auraDamage/FireRateBonusPct so
            -- simulateWave's pre-pass can compute the per-loadout
            -- aura mult and apply it to non-Support towers.
            -- Per Matthew 2026-04-27 sim-firming pass.
            return {
                damage             = t.damage,
                fireRate           = t.fireRate,
                range              = t.range,
                -- ControlCore mechanic — nil for SupportCore (no DOT)
                stackDotTickDmg    = t.stackDotTickDmg,
                stackDotTickPerSec = t.stackDotTickPerSec,
                maxStacks          = t.maxStacks,
                -- SupportCore mechanic — nil for ControlCore (no aura)
                auraRadius           = t.auraRadius,
                auraDamageBonusPct   = t.auraDamageBonusPct,
                auraFireRateBonusPct = t.auraFireRateBonusPct,
                auraRangeBonusPct    = t.auraRangeBonusPct,
                -- ea3-151: footprint for AABB aura check.
                footprintW           = t.footprintWidth or 4,
                footprintD           = t.footprintDepth or 4,
            }
        end
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
        --
        -- 2026-04-27 stacking rework: FrostMelon now uses
        -- slowStackPct + slowStackCap. The sim's closed-form slow
        -- model expects a flat slowPct, so we approximate the
        -- stacking ramp via the StackingSlowEffectiveness knob in
        -- Config.SimCalibration (live-tunable; see comment there
        -- for tuning history).
        slowPct        = tpl.slowPct or tpl.patchSlowPct
                         or (tpl.slowStackCap and
                             tpl.slowStackCap * STACKING_SLOW_EFFECT),
        -- ea3-154 — slowSeconds is the LINGER duration (how long a
        -- mob stays slowed AFTER leaving the slow source). Was
        -- erroneously falling back to `patchSeconds` (HoneyHive),
        -- which is the patch's LIFETIME, not a slow linger.
        --
        -- Real Honey: patches set `slowDuration = 0.8` in Towers.lua
        -- (line ~1198). A mob stays slowed for 0.8s after leaving a
        -- patch, not 5s. The patchSeconds=5 fallback caused the sim
        -- to credit lingerCells = 5 × 8.8 / 2 = 22 extra cells of
        -- slow coverage (vs. real 0.8 × 8.8 / 2 = 3.5 cells), making
        -- effectiveCoverage 0.46 instead of 0.23 → slowMult 1.39
        -- instead of 1.16. Sim's lift on other towers' DPS through
        -- Honey's slow was ~2× over-credited. The Power+Honey signed
        -- delta of +2.86 wave (sim 12.32 vs real 9.46) traces almost
        -- entirely to this misinterpretation.
        --
        -- Fix: only use explicit `slowSeconds` (FrostMelon's true
        -- slow-linger field). Patch towers fall back to a hard-
        -- coded slow-linger constant matching the runtime's
        -- 0.8 used in Towers.lua. CLAUDE.md convention #7.
        slowSeconds    = tpl.slowSeconds
                         or (tpl.patchSlowPct and tpl.patchSlowPct > 0 and 0.8 or nil),
        stunSeconds    = tpl.stunSeconds,
        stunCooldown   = tpl.stunCooldown,
        -- Phase 4 AOE / splash / chain fields. The biggest of
        -- aoeRadius / splashRadius / blastRadius determines the
        -- "this is an AOE tower" flag (LightningRadish has none
        -- of these — it uses chainJumps instead).
        aoeRadius      = tpl.aoeRadius or tpl.splashRadius or tpl.blastRadius,
        chainJumps     = tpl.chainJumps,
        chainFalloff   = tpl.chainFalloff,
        -- Phase 5 DOT-lingering fields. SporePuffball uses cloud*,
        -- HoneyHive uses patch* — same shape (radius / seconds /
        -- tickDmg / tickPerSec). Whichever is set, treat as DOT.
        -- ea3-123: dotRadius added to feed the time-in-patch
        -- model in dotDamagePerShot (replaces the old fireRate ×
        -- dotSeconds stacking-factor heuristic).
        dotRadius      = tpl.cloudRadius or tpl.patchRadius,
        dotSeconds     = tpl.cloudSeconds or tpl.patchSeconds,
        dotTickDmg     = tpl.cloudTickDmg or tpl.patchTickDmg,
        dotTickPerSec  = tpl.cloudTickPerSec or tpl.patchTickPerSec,
        -- Phase 6 per-tower quirks.
        --   pierceCount:  ThornVine — each shot hits up to N+1
        --                 mobs in a line (the +1 is the primary).
        --   lobSeconds:   MushroomMortar — flight time, AOE lands
        --                 after this delay (mob may have moved).
        pierceCount    = tpl.pierceCount,
        lobSeconds     = tpl.lobSeconds,
        -- 2026-04-28 new towers (project_tower_role_philosophy):
        --   blinkInterval/Distance — BlinkBerry: every N game-sec
        --     teleport mobs in range D studs back along the path.
        --     Modeled as a transit-time multiplier (mob effectively
        --     covers less ground per game-second of wave window).
        --   auraRadius / auraDamageBonusPct / auraFireRateBonusPct /
        --     auraRangeBonusPct — PaceFlower / PowerSeed /
        --     SpyglassRoot. Same aura shape SupportCore uses. The
        --     sim's auraMultForLoadout pre-pass picks the strongest
        --     value across ALL aura sources (Cores + aux Supports).
        --   linkRadius / linkEchoFrac — BloodlinkVine. Damage to
        --     any linked mob echoes to other linked mobs. Modeled
        --     as an effective-DPS multiplier on AOE/Combined waves
        --     (multi-mob clusters where echoes deliver value).
        blinkInterval        = tpl.blinkInterval,
        blinkDistance        = tpl.blinkDistance,
        -- 2026-04-29 ea3-7: rarity-scaled AOE radius (decoupled from
        -- firing range). Currently unused by the closed-form transit
        -- model below — that math credits all mobs as caught — but
        -- carried through so future per-cluster AOE refinements can
        -- branch on it without re-plumbing the stats struct.
        blinkAoeRadius       = tpl.blinkAoeRadius or tpl.range,
        auraRadius           = tpl.auraRadius,
        auraDamageBonusPct   = tpl.auraDamageBonusPct,
        auraFireRateBonusPct = tpl.auraFireRateBonusPct,
        auraRangeBonusPct    = tpl.auraRangeBonusPct,
        linkRadius           = tpl.linkRadius,
        linkEchoFrac         = tpl.linkEchoFrac,
        -- ea3-151: footprint dimensions for the footprint-edge aura check.
        -- Aura applies if the source-center → target-footprint nearest-point
        -- distance ≤ auraRadius (instead of source-center → target-center).
        -- Lifted into stats so perTowerAuraMults can do AABB math without
        -- re-reading templates per source-target pair.
        footprintW           = tpl.footprintWidth or 4,
        footprintD           = tpl.footprintDepth or 4,
    }
end

-- Apply N cycles of upgrades. Range caps at 2× original, after which
-- damage + firerate effects boost 1.5× (matching real spawner).
--
-- IMPORTANT: shallow-copies ALL fields from `stats`, then mutates
-- damage/fireRate/range. Earlier versions only copied those three
-- fields, which silently dropped slowPct / aoeRadius / lobSeconds /
-- chainJumps / pierceCount / dot* on the way through — every Phase
-- 3-6 coefficient function read nil and returned 1.0, making the
-- whole quirk-modeling path dead. Per Matthew 2026-04-27 sim-vs-real
-- audit (mean signed delta +4.40, MushroomMortar +23 worst): the
-- bug let Mushroom solo reach wave 30 cap because no lob penalty
-- was being applied. Fix preserves the static fields verbatim
-- (upgrades only mutate damage/fireRate/range) so the Phase 3-6
-- coefficients fire as designed.
local function applyUpgrades(stats, cycles)
    local s = table.clone(stats)
    local origRange = s.range
    -- ea3-153: track aura origin so we can scale it alongside range.
    -- Skip global auras (>= 9999, SupportCore) — already map-wide.
    local origAura = (s.auraRadius and s.auraRadius > 0 and s.auraRadius < 9999)
        and s.auraRadius or nil
    local capped = false
    for _ = 1, cycles do
        local boost = capped and POST_CAP_BOOST or 1.0
        s.damage   = s.damage + UPGRADE_DAMAGE_FLAT * boost
        s.fireRate = s.fireRate * (1 + UPGRADE_FR_DELTA * boost)
        if not capped then
            s.range = s.range * (1 + UPGRADE_RANGE_DELTA)
            -- ea3-153: aura radius rides the same %-bonus as firing range.
            -- Per Matthew 2026-05-01 "range upgrade cards should increase
            -- support aura as well." Mirrors UpgradeCards.lua's per-pick
            -- live behavior so sim and real stay aligned (CLAUDE.md
            -- convention #7). Capped together with range so post-cap
            -- damage/firerate boost doesn't compound on aura too.
            if origAura then
                s.auraRadius = s.auraRadius * (1 + UPGRADE_RANGE_DELTA)
            end
            if s.range >= origRange * RANGE_CAP_MULT then
                capped = true
            end
        end
    end
    return s
end

------------------------------------------------------------
-- Phase 5: DOT lingering damage. Towers that drop a cloud /
-- patch on impact deal direct damage on the hit AND tick damage
-- over the cloud's lifetime. SporePuffball uses cloud* fields,
-- HoneyHive uses patch* fields (same shape: radius / seconds /
-- tickDmg / tickPerSec).
--
-- ea3-123: REPLACED the v1 stackingFactor + DotValueMult heuristic
-- with a physically-grounded "time-in-patch" model. Real game
-- mechanics:
--   • Tower drops a patch on a fixed SPOT (radius dotRadius)
--   • Patch persists for dotSeconds, ticking tickDmg per
--     tickPerSec to anything inside its radius
--   • A mob walking the path through that spot is INSIDE the
--     patch for time_in_patch = 2 × dotRadius / mob_speed seconds
--   • During that window the mob takes
--     time_in_patch × tickDmg × tickPerSec damage from the patch
--
-- So the per-shot DOT damage delivered to ONE mob equals the
-- damage during its transit through the patch — NOT the patch's
-- full lifetime damage. Patch lifetime > time_in_patch only
-- buffers against firing-rate drops; it doesn't multiply the
-- per-mob damage.
--
-- Old model formula:
--   dotPerShot = tickDmg × tickPerSec × dotSeconds × stackFactor × DotValueMult
--   where stackFactor floored at 0.5, DotValueMult = 0.6 (calibrated)
--
-- New model formula:
--   time_in_patch = 2 × dotRadius / DOT_BASELINE_MOB_SPEED
--   dotPerShot    = tickDmg × tickPerSec × time_in_patch
--
-- Sanity check (HoneyHive, basic mob, default speed 8.8):
--   time_in_patch = 2 × 7 / 8.8 = 1.59 s
--   dotPerShot    = 10 × 2 × 1.59 = 31.8
--   ≈ old model's 10 × 2 × 5 × 0.5 × 0.6 = 30 (similar, but the
--     new model has clear physical meaning vs. magic constants)
--
-- DOT_VALUE_MULT is kept on the multiplication so the validator
-- can still dial DOT contribution up/down without code edits, but
-- its sane default is now 1.0 (no discount needed — the model
-- already captures the time-in-patch reality).
--
-- DOT_BASELINE_MOB_SPEED uses the basic-mob speed (8.8) as a
-- representative average — most waves include basics, and slower
-- mobs (tanks at 5.5) get MORE time-in-patch in reality, which
-- compounds with their tankiness; over-counting them in the
-- baseline would over-credit DOT towers on Solo waves. Keeping
-- the baseline at basic-speed slightly under-credits DOT vs.
-- tanks, which matches the "sim's exposure assumption is too
-- generous" prior in any case.
------------------------------------------------------------
local DOT_BASELINE_MOB_SPEED = 8.8  -- basics; see comment above

local function dotDamagePerShot(stats)
    if not stats.dotTickDmg or not stats.dotTickPerSec then return 0 end
    local radius = stats.dotRadius or 0
    if radius <= 0 then
        -- Without radius, fall back to dotSeconds × tick math
        -- (legacy behavior). Should never hit on current roster
        -- since both Spore and Honey have radii defined.
        return (stats.dotTickDmg * stats.dotTickPerSec * (stats.dotSeconds or 0))
            * DOT_VALUE_MULT
    end
    local timeInPatch = (2 * radius) / DOT_BASELINE_MOB_SPEED
    return stats.dotTickDmg * stats.dotTickPerSec * timeInPatch
        * DOT_VALUE_MULT
end

------------------------------------------------------------
-- Stacking DOT (ControlCore) — exposure-aware ramp model.
--
-- ControlCore applies +1 stack per direct hit, capped at maxStacks.
-- Each active stack ticks tickDmg damage at tickPerSec rate. Stacks
-- ramp linearly from 0 to maxStacks over rampTime = maxStacks /
-- fireRate seconds, then sit at peak until the mob dies / leaves.
-- Total DOT damage delivered to one mob over its `exposureSecs` in
-- the tower's range:
--
--   if exposureSecs >= rampTime:
--     dmg = peakDPS × (exposureSecs - rampTime/2)
--             ↑ saturated at peak for (exposure - ramp) sec
--                 + linear ramp triangle area = peak × ramp/2
--   else:
--     dmg = peakDPS × exposureSecs² / (2 × rampTime)
--             ↑ partial-ramp triangle area, never reaches peak
--
-- This captures the per-mob asymmetry that makes ControlCore
-- over-tier on Solo waves (boss tank → long exposure → full
-- ramp + sustained peak) and unremarkable on AOE waves (basic mob
-- → short exposure → DOT barely ramps).
--
-- Multiplied by STACK_DOT_EFFECTIVENESS (Config.SimCalibration)
-- for a single-axis tuning knob.
------------------------------------------------------------
local function stackDotDamagePerMob(stats, exposureSecs)
    local tickDmg = stats.stackDotTickDmg or 0
    local maxStacks = stats.maxStacks or 0
    local fireRate = stats.fireRate or 0
    if tickDmg <= 0 or maxStacks <= 0 or fireRate <= 0 or exposureSecs <= 0 then
        return 0
    end
    local tickPerSec = stats.stackDotTickPerSec or 1
    local peakDPS = maxStacks * tickDmg * tickPerSec
    local rampTime = maxStacks / fireRate
    local dmg
    if exposureSecs >= rampTime then
        dmg = peakDPS * (exposureSecs - rampTime / 2)
    else
        dmg = peakDPS * exposureSecs * exposureSecs / (2 * rampTime)
    end
    return dmg * STACK_DOT_EFFECTIVENESS
end

------------------------------------------------------------
-- Aura — strongest-wins across the loadout, with global/local
-- coverage split (ea3-126).
--
-- 2026-04-28 expansion: previously only SupportCore was scanned.
-- Now scans ALL towers in the loadout for auraRadius > 0 — picks
-- up SupportCore's global aura (auraRadius 9999) AND the new aux
-- Support towers (PaceFlower / PowerSeed / SpyglassRoot) which each
-- have LOCAL auras (16-18 stud radius) and contribute a single axis.
--
-- Real game: any tower with an aura whose buff target falls in
-- range gets the strongest bonus per axis (max, not additive).
-- Closed-form: scan all auras in the loadout, scale each source's
-- contribution by its coverage factor (global=1.0; local=fraction
-- of towers within local radius given auto-place layout), then
-- take per-axis max.
--
-- ea3-126 fix for ea3-125 over-prediction: BEFORE this change, all
-- auras (global + local) were treated as full strength. SpyglassRoot
-- (auraRadius 18, ~3-4 of 36 towers actually buffed in real) was
-- treated as if it buffed all 36 towers, yielding a +4.6 signed
-- delta on Power core in the FAILURE CURVE × 105 baseline. Now its
-- contribution scales by AURA_LOCAL_COVERAGE (~0.30) before
-- competing for the strongest-wins per-axis slot — so aux Supports
-- usually lose to SupportCore's stronger global aura when both are
-- in the loadout, and only win uncontested axes (e.g. SpyglassRoot's
-- range axis when no other source has it).
--
-- Returns: dpsMult, rangeMult. Caller applies dpsMult to every
-- non-buffer tower's DPS, rangeMult to range-dependent calcs.
------------------------------------------------------------
local function auraMultForLoadout(upgradedStats, loadoutTowers)
    local bestDmg, bestFr, bestRng = 0, 0, 0
    for i, _towerId in ipairs(loadoutTowers) do
        local stats = upgradedStats[i]
        local auraR = stats and stats.auraRadius or 0
        -- Any tower with auraRadius > 0 contributes (covers
        -- SupportCore + the 3 aux Support buff towers). The
        -- towerId-specific gate is gone — pure data-driven.
        if stats and auraR and auraR > 0 then
            -- ea3-126: per-source coverage. Global auras (radius
            -- >= threshold, typically SupportCore at 9999) buff
            -- every tower; local auras (aux Supports at 16-18)
            -- buff only the few towers within their physical
            -- radius. Coverage factor scales the contribution
            -- BEFORE the per-axis strongest-wins comparison.
            local coverage = (auraR >= AURA_GLOBAL_RADIUS_THRESHOLD)
                and 1.0 or AURA_LOCAL_COVERAGE
            local d = (stats.auraDamageBonusPct or 0) * coverage
            local f = (stats.auraFireRateBonusPct or 0) * coverage
            local r = (stats.auraRangeBonusPct or 0) * coverage
            if d > bestDmg then bestDmg = d end
            if f > bestFr  then bestFr  = f end
            if r > bestRng then bestRng = r end
        end
    end
    if bestDmg == 0 and bestFr == 0 and bestRng == 0 then
        return 1.0, 1.0
    end
    -- DPS-equivalent multiplier: combined damage % × fireRate %.
    local combined  = (1 + bestDmg / 100) * (1 + bestFr / 100)
    local dpsMult   = 1.0 + (combined - 1.0) * AURA_VALUE_MULT
    -- Range mult is scalar — applied to range-dependent exposure.
    local rangeMult = 1.0 + (bestRng / 100) * AURA_VALUE_MULT
    return dpsMult, rangeMult
end

local function towerDPS(stats)
    -- Direct hit + DOT cloud per shot, multiplied by fireRate to
    -- get DPS (damage-per-second). DOT clouds stack over time but
    -- each shot drops one cloud, so per-shot total damage is the
    -- right closed-form.
    return (stats.damage + dotDamagePerShot(stats)) * stats.fireRate
end

------------------------------------------------------------
-- Per-tower role lookup (drives slot assignment in the auto-place
-- pattern). Power is forced to slot 1 regardless of role tag.
------------------------------------------------------------
local ROLE_BY_TOWER = TempTowers.RoleByTowerId or {}

-- 2026-04-29 ea3: simplified — TempTowers.RoleByTowerId now includes
-- entries for all 3 Cores (Power=DPS / ControlCore=Control /
-- SupportCore=Support), so the special-case `if towerId == "Power"`
-- branch is gone. Before that audit fix, ControlCore + SupportCore
-- silently fell through to the `or "DPS"` default — closed-form
-- sweeps placed Control/Support cores in the DPS path slot, breaking
-- the path-geometry model for those archetypes.
local function roleFor(towerId)
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
-- ea3-130: PER-TOWER-POSITION AURA MODEL
--
-- Replaces the single-knob `AuraLocalCoverage` heuristic with
-- actual placement-aware geometry. For each tower in the loadout,
-- scan every aura SOURCE; if the source's auraRadius reaches the
-- tower's slot (cell distance × CELL_SIZE ≤ auraRadius), apply
-- that source's bonuses to a per-axis strongest-wins comparison
-- for THIS tower. Otherwise the source contributes nothing to
-- this tower.
--
-- Global auras (auraRadius 9999, SupportCore) automatically reach
-- every slot — no special-casing needed. Local auras (16-18 stud
-- radius from PaceFlower/PowerSeed/SpyglassRoot) only reach
-- neighbors within ~8-9 cells.
--
-- Aura sources do NOT self-buff (preserves the ea3-126 rule that
-- SpyglassRoot's own native range stays raw). For symmetry with
-- the legacy global model, aura sources also receive 1.0 × from
-- OTHER aura sources — keeping multipliers aux-only avoids
-- cross-source double-counting that the validator wasn't tuned
-- for. Future work: model PaceFlower buffing SpyglassRoot when
-- both fit a Support cluster.
--
-- Returns: parallel array indexed by loadoutTowers[i] —
--   mults[i] = { dpsMult = X, rangeMult = Y }
-- where X/Y default to 1.0 if no aura source reaches this tower
-- (or if this tower is itself an aura source).
--
-- Caller applies mults[i].dpsMult to tower i's per-shot DPS and
-- mults[i].rangeMult to tower i's effective range — same
-- semantics as the old global pair, just per-position.
--
-- Architectural fix for SupportCore pureSupport delta. ea3-126's
-- AuraLocalCoverage=0.30 averaged out the "fraction of towers in
-- range" across all loadouts — but the actual fraction varies
-- loadout-by-loadout based on slot assignment. This helper
-- computes the per-loadout actual.
--
-- Definition-order note (CLAUDE.md convention #1): this function
-- references CELL_SIZE which is declared above. assignLoadoutSlots
-- must also stay above so the slot-shape is the same module-local
-- the caller passes in.
------------------------------------------------------------
local function perTowerAuraMults(upgradedStats, loadoutTowers, slotAssignments)
    local mults = {}
    for i = 1, #loadoutTowers do
        mults[i] = { dpsMult = 1.0, rangeMult = 1.0 }
    end

    -- Pre-collect aura sources with their slot positions.
    local sources = {}
    for j = 1, #loadoutTowers do
        local s = upgradedStats[j]
        local entry = slotAssignments and slotAssignments[j]
        local slot = entry and entry.slot
        if s and slot and (s.auraRadius or 0) > 0 then
            table.insert(sources, {
                index  = j,
                radius = s.auraRadius,
                co     = slot.co,
                ro     = slot.ro,
                dPct   = s.auraDamageBonusPct or 0,
                fPct   = s.auraFireRateBonusPct or 0,
                rPct   = s.auraRangeBonusPct or 0,
            })
        end
    end

    if #sources == 0 then return mults end

    -- For each tower, find sources whose radius reaches it.
    -- ea3-151: footprint-edge aura check. Mirrors Towers.lua runtime
    -- math (CLAUDE.md convention #7 — sim and real read same model).
    -- Distance from aura source CENTER to target footprint NEAREST
    -- POINT, not center-to-center. Effective reach increase ~33% for
    -- typical 6×6 targets.
    for i = 1, #loadoutTowers do
        local myStats = upgradedStats[i]
        local entry = slotAssignments and slotAssignments[i]
        local mySlot = entry and entry.slot
        if myStats and mySlot then
            local isAuraSource = (myStats.auraRadius or 0) > 0
            -- Aura sources don't accept any aura buff (matches the
            -- legacy `isAuraSource and 1.0 or auraMult` gate).
            if not isAuraSource then
                -- Target footprint half-extents in studs (cell space ×
                -- CELL_SIZE / 2). Default 4×4 if not set.
                local fpW = myStats.footprintW or 4
                local fpD = myStats.footprintD or 4
                local halfX = fpW * CELL_SIZE / 2
                local halfZ = fpD * CELL_SIZE / 2
                local bestDmg, bestFr, bestRng = 0, 0, 0
                for _, src in ipairs(sources) do
                    -- World displacement source → my-slot center, studs.
                    local dxStuds = math.abs(mySlot.co - src.co) * CELL_SIZE
                    local dzStuds = math.abs(mySlot.ro - src.ro) * CELL_SIZE
                    -- AABB-edge distance: shrink by my footprint half-
                    -- extent on each axis (clamped to 0 when source is
                    -- already inside).
                    local edgeX = math.max(0, dxStuds - halfX)
                    local edgeZ = math.max(0, dzStuds - halfZ)
                    local edgeDist = math.sqrt(edgeX * edgeX + edgeZ * edgeZ)
                    if edgeDist <= src.radius then
                        if src.dPct > bestDmg then bestDmg = src.dPct end
                        if src.fPct > bestFr  then bestFr  = src.fPct end
                        if src.rPct > bestRng then bestRng = src.rPct end
                    end
                end
                if bestDmg > 0 or bestFr > 0 or bestRng > 0 then
                    local combined = (1 + bestDmg / 100) * (1 + bestFr / 100)
                    mults[i].dpsMult   = 1.0 + (combined - 1.0) * AURA_VALUE_MULT
                    mults[i].rangeMult = 1.0 + (bestRng / 100) * AURA_VALUE_MULT
                end
            end
        end
    end

    return mults
end

------------------------------------------------------------
-- Phase 4: AOE / splash / chain damage coefficients.
--
-- Per project_simulator_improvement.md: the v3 sim treats every
-- tower's DPS as single-target. Towers with aoeRadius /
-- splashRadius / blastRadius hit MULTIPLE mobs per shot, so their
-- effective damage is N× the base. Chain (LightningRadish) jumps
-- to additional mobs with falloff per jump.
--
-- AOE COEFFICIENTS — by wave type, based on typical mob clustering
-- in an 8-stud splash radius:
--   AOE wave (6 basic mobs in tight cluster):  ≈ 3 mobs hit
--   Combined wave (2+2+1, more spread):         ≈ 1.5
--   Solo wave (1 tank, no neighbors):           = 1.0
-- Towers WITHOUT an AOE field always have coefficient 1.0.
--
-- CHAIN COEFFICIENT — N jumps with falloff r:
--   total = 1 + r + r² + … + r^N (geometric series)
-- Chain only counts when there's actually a secondary in range
-- (always true on AOE waves, marginal on Solo). For v1 we apply
-- the full geometric coefficient on AOE/Combined and 1.0 on Solo.
------------------------------------------------------------
-- Spawn stagger between mobs in a wave (matches the live spawner's
-- task.wait(0.08 / GameSpeed) inside spawnWave). At normal speed,
-- this is 0.08 game-sec; at high game-speeds (20×, 50×, 100×) the
-- wait drops below the frame-time floor (~16ms wallclock at 60fps),
-- so actual game-stagger inflates significantly:
--   • 1× speed:  task.wait(0.08) → 0.08  game-sec stagger
--   • 20× speed: task.wait(0.004) frame-floored to 0.0167 wallclock
--                → 0.333 game-sec stagger (4× larger than intended)
--   • 50× speed: 0.833 game-sec
--   • 100× speed: 1.667 game-sec
-- Per CLAUDE.md memory feedback_test_in_parallel.md: "speed divergence
-- diagnosis (analytical, no fix yet): At higher game speeds, the
-- stagger balloons" — this is the sim-side fix.
--
-- The stagger affects (a) within-group mob spacing on the path
-- (used by aoeCoefficient to count cluster catch) and (b) waveWindow
-- (used as count-1 × stagger + transit time). Both inflate at high
-- speeds in real game; sim must match to align.
--
-- Declared above aoeCoefficient per CLAUDE.md scope rule (Lua
-- resolves upvalues at function-definition time).
local FRAME_DT_FLOOR_WALLCLOCK = 1 / 60  -- ~16.67ms typical frame
local function currentSpawnStaggerSec()
    local gs = Workspace:GetAttribute("GameSpeed")
    if type(gs) ~= "number" or gs <= 0 then gs = 1 end
    local wallclockGap = 0.08 / gs
    if wallclockGap < FRAME_DT_FLOOR_WALLCLOCK then
        wallclockGap = FRAME_DT_FLOOR_WALLCLOCK
    end
    return wallclockGap * gs  -- back to game-seconds
end
-- Live-resolved each call into aoeCoefficient / simulateWave so the
-- sim picks up the current Workspace.GameSpeed at SIMULATE time.

-- AOE COEFFICIENT — was wave-type lookup (AOE 3.0 / Combined 1.5 /
-- Solo 1.0); replaced 2026-04-27 v4 with a GROUP-count + spacing
-- model that matches actual splash mechanics:
--
-- Each shot hits one primary mob + every other mob in the same
-- GROUP within `splash` studs of the primary. Within a group, all
-- mobs share speed → spacing = mob_speed × SPAWN_STAGGER_SEC ≈
-- 0.7 studs for basic, 1.2 for fast, 0.4 for tank. Splash 12 →
-- catches up to 12/spacing additional mobs in the line.
--
-- Capped at group.count (can't catch more mobs than exist in the
-- group). For solo-tank groups (count=1, e.g. Combined wave's
-- tank, Solo wave), aoeMult = 1.0 — splash applies but only one
-- mob is targeted.
--
-- This better matches real game where a Mushroom lob on a
-- Combined-wave-tank gets aoeMult 1.0 (tank is alone in its
-- group at impact time) rather than the old wave-type-based 1.5.
------------------------------------------------------------
-- ea3-123 spawn-ramp-up discount. The aoeCoefficient formula above
-- assumes ALL `count` mobs are on the path simultaneously, but mobs
-- spawn over `(count-1) × stagger` seconds. During that ramp-up
-- window the splash catches fewer mobs (1 mob → plateau over the
-- ramp) — average aoeMult during ramp is `(1 + plateau) / 2`.
--
-- For typical AOE waves (6 basics × 0.333 game-sec stagger at 20×
-- = 1.67s ramp; wave window ~4-5s), ramp_fraction ≈ 0.33-0.40 of
-- wave_window. Averaged aoeMult is roughly 85% of plateau.
--
-- Caught by the PepperCannon investigation 2026-05-01:
-- Pepper sim signed +1.92 to +2.01 across all 3 cores. Pepper is
-- a small-splash DPS tower (radius 7) so the ramp-up bias dominates
-- its over-prediction. Mortar is also splash — its lob model
-- already discounts (LobAccuracyMult), but the ramp-up applies
-- there too.
--
-- Single calibration constant rather than a per-call ramp_time
-- computation: aoeCoefficient doesn't have wave_window in scope,
-- and the validator can iterate this knob faster than refactoring
-- the call signature to pass wave geometry through.
local AOE_RAMP_DISCOUNT = SIM_CAL.AoeRampUpDiscount or 0.85

local function aoeCoefficient(stats, _waveType, group)
    local splash = stats.aoeRadius or 0
    if splash <= 0 then return 1.0 end
    local count = (group and group.count) or 1
    if count <= 1 then return 1.0 end
    local mobInfo = group and group.type and MOB[group.type]
    local speed = (mobInfo and mobInfo.speed) or 1.0
    -- Use live-resolved spawn stagger so the spacing matches what
    -- real game produces at the current GameSpeed (frame-floor at
    -- high speeds inflates stagger 4-20×).
    local spacing = math.max(0.5, speed * currentSpawnStaggerSec())
    local catchExtra = math.floor(splash / spacing)
    local plateau = math.min(count, 1 + catchExtra)
    -- Apply the ramp-up discount. Plateau=1 (single-mob) cases
    -- skip this anyway via the count<=1 early return above.
    return plateau * AOE_RAMP_DISCOUNT
end

local function chainCoefficient(stats, waveType)
    if stats.chainJumps and stats.chainJumps > 0 then
        local r = stats.chainFalloff or 0.6
        local n = stats.chainJumps
        -- Solo waves have no secondary mobs to chain to, so the
        -- chain bonus collapses to 1.0.
        if waveType == "Solo" then return 1.0 end
        local sum = 1.0
        local term = 1.0
        for _ = 1, n do
            term = term * r
            sum = sum + term
        end
        return sum
    end
    return 1.0
end

------------------------------------------------------------
-- Phase 6: ThornVine pierce coefficient — each shot hits primary
-- + N additional mobs in a line. Coefficient = min(N+1, mobsInLine).
-- Approximate "mobs in line" by mob count per group (a 6-basic
-- AOE wave gives more pierce uplift than a 1-tank Solo wave).
-- Capped at pierceCount + 1 (no more than the pierce limit).
------------------------------------------------------------
local function pierceCoefficient(stats, group)
    if not stats.pierceCount or stats.pierceCount <= 0 then return 1.0 end
    local lineCap = stats.pierceCount + 1   -- primary + N pierce-throughs
    -- Mobs in a line on AOE wave (6 basic) typically 2-3 in the
    -- pierce-line; Combined wave 1-2; Solo 1.
    local groupCount = (group and group.count) or 1
    local effective = math.min(lineCap, groupCount)
    return effective
end

------------------------------------------------------------
-- Phase 6: MushroomMortar lob accuracy.
--
-- HISTORY:
--   v1-v3: lerped lead-error penalty. Wrong shape; trashed.
--   v4 (2026-04-27): discrete catch/miss based on
--     `mob_move > splash`. Theory: real game target-leads to mob's
--     predicted future position; if mob movement during lob flight
--     exceeded splash radius, lob "missed." But this is wrong about
--     real game's lead model — lead-prediction means the splash
--     CENTER is on the predicted position, so mob movement ≤ splash
--     is the EXPECTED outcome, not a special "catch." Real misses
--     happen on path-waypoint turns / mob death / variable-speed
--     lead error, not from `mob_move > splash`.
--
--   v5 (2026-05-01 ea3-122): replace with a unified accuracy mult.
--     Empirical from ea3-118 baseline: Mortar in real game reached
--     wave ~13.5 across all loadouts and cores; sim under-predicted
--     by 5+ waves consistently across all 3 cores' validator outputs
--     (-5.04 / -5.26 / -5.53 signed delta). v4's geometry check
--     classified EVERY mob as a "miss" (basic 8.8 × 2.2 = 19.4 > 8
--     splash; tank 5.5 × 2.2 = 12.1 > 8 splash; fast 33.9 > 8) so
--     the cluster-floor (0.0 on Solo, 0.20 on AOE, 0.10 on Combined)
--     applied universally — Mortar dealt near-zero damage in sim.
--
--     v5 model: every shot is a "catch" (target-led correctly), with
--     a single calibration mult capturing real-world inefficiencies
--     (waypoint turns, mob death mid-flight, RNG lead error). No
--     wave-type branching — those don't differ in real game; AOE
--     just happens to also benefit from cluster catches that the
--     aoeMult elsewhere already credits.
--
-- Constant: Config.InfiniteArena.SimCalibration.LobAccuracyMult
-- (default 0.55, conservative starting guess to avoid the v3-era
-- over-prediction at wave 23). Validator iteration tunes from there.
------------------------------------------------------------
local LOB_ACCURACY_MULT = SIM_CAL.LobAccuracyMult or 0.55

local function lobAccuracyCoefficient(stats, _waveType, _mobSpeed)
    if not stats.lobSeconds or stats.lobSeconds <= 0 then return 1.0 end
    if not stats.aoeRadius or stats.aoeRadius <= 0 then return 1.0 end
    return LOB_ACCURACY_MULT
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
local SLOW_FACTOR_CAP = SIM_CAL.SlowFactorCap or 0.7

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
                -- STUN_VALUE_MULT (Config.SimCalibration) lifts the
                -- closed-form's stun contribution to model the
                -- compounding effects the simple `numStuns ×
                -- stunSeconds` formula misses (stunned mob stays
                -- in range longer → subsequent ticks see it
                -- longer; focus-fire damage during stun; etc.).
                local numStuns = exposureSecs / stats.stunCooldown
                extraStunSecs = extraStunSecs +
                    numStuns * stats.stunSeconds * STUN_VALUE_MULT
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
local function simulateWave(loadoutTowers, slotAssignments, wave, waveType)
    local groups = waveSpec(waveType)
    -- HP ramp now resolves through Config.InfiniteArena.WaveHpRamp
    -- (piecewise per-wave function) instead of the legacy linear
    -- cycle formula. Both the live spawner and this simulator read
    -- from the same Config function — single source of truth per
    -- CLAUDE.md convention 7.
    local cycle       = math.ceil(wave / 3)
    local cycleMult   = IA.WaveHpRamp(wave)
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

    -- Aura pre-pass — per-tower dpsMult + rangeMult applied below.
    -- ea3-130: replaced single global pair with per-position table.
    -- Each tower gets its OWN dpsMult/rangeMult based on which aura
    -- sources actually reach its slot (cell-distance ≤ auraRadius).
    -- Global auras (radius 9999) automatically reach every slot;
    -- local auras (16-18) only reach slot-neighbors. The
    -- AuraLocalCoverage knob is bypassed by this pathway — no
    -- global "fraction of towers in range" averaging needed.
    local towerAuraMults = perTowerAuraMults(
        upgradedStats, loadoutTowers, slotAssignments)

    -- BlinkBerry transit-extension pre-pass (2026-04-28). For each
    -- BlinkBerry in the loadout, count expected blink ticks during
    -- the wave window: ticks = waveWindow / blinkInterval. Each tick
    -- pushes mobs `blinkDistance` studs back; total backward push =
    -- ticks × distance studs. Modeled as an extra "transit cost" —
    -- mobs effectively walk further. computed inside the per-group
    -- loop below since waveWindow varies by mob speed.
    local blinkSources = {}  -- list of { interval, distance }
    for i, towerId in ipairs(loadoutTowers) do
        local stats = upgradedStats[i]
        if stats and (stats.blinkInterval or 0) > 0 then
            table.insert(blinkSources, {
                interval = stats.blinkInterval,
                distance = stats.blinkDistance or 20,
            })
        end
        _ = towerId
    end

    -- BloodlinkVine link multiplier — flat DPS uplift on AOE/Combined
    -- waves where multi-mob clusters get the echo benefit. Solo waves
    -- (1 boss) don't gain anything from link. Per-wave, computed below.
    local linkSources = {}  -- list of echoFrac per BloodlinkVine
    for i, towerId in ipairs(loadoutTowers) do
        local stats = upgradedStats[i]
        if stats and (stats.linkRadius or 0) > 0 then
            table.insert(linkSources, stats.linkEchoFrac or 0.5)
        end
        _ = towerId
    end

    local pathTotalCells = PathGeometry.pathLengthCells()

    local heartDamage = 0
    -- ea3-148: track waveFullHp (sum of mob max HPs across all
    -- groups, full strength). Returned alongside heartDamage so the
    -- runLoadout wave-loop formula can score the partial-tier
    -- credit per the new ea3-148 wave-HP-relative formula.
    local waveFullHp  = 0
    for _, group in ipairs(groups) do
        local mobInfo = MOB[group.type]
        if mobInfo and group.count > 0 then
            local mobHp = group.hp * cycleMult * loadoutMult
            local totalGroupHp = mobHp * group.count
            waveFullHp = waveFullHp + totalGroupHp

            -- Phase 2 + 3: per-tower exposure × slow/stun multiplier.
            local baseTransit = (pathTotalCells * CELL_SIZE) / mobInfo.speed
            local controlMult = computeControlMultiplier(
                slotAssignments, upgradedStats, mobInfo.speed,
                baseTransit, pathTotalCells)

            -- Phase 7: wave window = time from first-mob-spawn to
            -- last-mob-reaches-heart. Spawn stagger places mobs
            -- 0.08 sec apart; the last mob's transit is what
            -- determines wave length (assuming no premature kill).
            -- Slow/stun extend the transit time uniformly.
            local effectiveTransit = baseTransit * controlMult

            -- BlinkBerry transit-extension (2026-04-28). Each blink
            -- pushes mobs back `blinkDistance` studs along the path —
            -- conceptually equivalent to mobs walking that distance
            -- twice (forward + push-back + forward again). Translate
            -- to extra transit time: blinks_during_wave = waveWindow
            -- / blinkInterval; extra transit = blinks × distance /
            -- mobSpeed. Multiple BlinkBerries don't stack-cap (they
            -- blink independently); we sum their contributions.
            -- Ceiling at +50% transit so the heuristic doesn't run
            -- away in trios with multiple Blinks.
            if #blinkSources > 0 then
                local extraTransit = 0
                for _, src in ipairs(blinkSources) do
                    local blinks = effectiveTransit / math.max(0.1, src.interval)
                    extraTransit = extraTransit + (blinks * src.distance) / mobInfo.speed
                end
                extraTransit = extraTransit * BLINK_VALUE_MULT
                extraTransit = math.min(extraTransit, effectiveTransit * BLINK_TRANSIT_CAP)
                effectiveTransit = effectiveTransit + extraTransit
            end

            -- Live-resolved spawn stagger — matches the live spawner
            -- under the active GameSpeed (inflates at 20×/50×/100×
            -- due to wallclock frame floor).
            local waveWindow = (group.count - 1) * currentSpawnStaggerSec() + effectiveTransit

            -- BloodlinkVine link multiplier (2026-04-28). Per-mob
            -- linking distributes damage across the cluster — on
            -- multi-mob waves, effective DPS lifts because every
            -- damage event echoes (echoFrac × damage) to each other
            -- linked mob. Strongest-wins like aura. Solo waves
            -- (1 mob) get NO benefit.
            local linkMult = 1.0
            if #linkSources > 0 and group.count > 1 then
                local bestEcho = 0
                for _, e in ipairs(linkSources) do
                    if e > bestEcho then bestEcho = e end
                end
                -- Each linked mob takes its own damage + echoes from
                -- (count-1) others. Effective DPS scales to:
                --   1 + (count-1) × echoFrac
                -- Capped at 2.5× to model real-game stat-double-count
                -- and recursion guards.
                linkMult = math.min(2.5,
                    1 + (group.count - 1) * bestEcho * (LINK_VALUE_MULT or 1.0))
            end

            -- Phase 7: per-tower useful time in this wave =
            --   min(count × per_mob_exposure, wave_window)
            -- The first term is "tower can fire at one mob at a
            -- time, focus-fires through count mobs"; the second
            -- term caps it at the wave's actual duration. This
            -- replaces v6's per-mob accumulation, which counted
            -- every mob as receiving full per-mob exposure
            -- damage simultaneously — an N-fold overestimate for
            -- single-target towers on multi-mob waves.
            local availDmg = 0
            for i, slotEntry in ipairs(slotAssignments) do
                local stats = upgradedStats[i]
                if stats and slotEntry.slot then
                    -- Per-mob exposure (no control mult — already in
                    -- effectiveTransit above; we want the GEOMETRY
                    -- exposure here). Then scale by control mult to
                    -- get effective seconds-on-path.
                    -- ea3-130: rangeMult comes from the per-tower
                    -- aura table (towerAuraMults[i].rangeMult). The
                    -- helper already returns 1.0 for aura sources
                    -- (no self-buff) and 1.0 for towers with no
                    -- aura source within range, so the explicit
                    -- isAuraSource gate is no longer needed at the
                    -- call site.
                    local thisAuraMults  = towerAuraMults[i]
                        or { dpsMult = 1.0, rangeMult = 1.0 }
                    local effectiveRange = stats.range * thisAuraMults.rangeMult
                    local rangeCells = effectiveRange / CELL_SIZE
                    local exposureCells = PathGeometry.pathExposureCells(
                        slotEntry.slot.co, slotEntry.slot.ro, rangeCells)
                    local perMobExposureSec =
                        (exposureCells * CELL_SIZE) / math.max(0.001, mobInfo.speed)
                        * controlMult
                    -- Useful time = capped at wave_window (a tower
                    -- can't fire longer than the wave actually lasts).
                    local usefulTime = math.min(
                        group.count * perMobExposureSec, waveWindow)

                    -- Phase 4: per-wave-type AOE + chain coefficients.
                    local aoeMult    = aoeCoefficient(stats, waveType, group)
                    local chainMult  = chainCoefficient(stats, waveType)
                    -- Phase 6: per-tower quirks.
                    local pierceMult = pierceCoefficient(stats, group)
                    local lobMult    = lobAccuracyCoefficient(stats, waveType, mobInfo.speed)

                    -- Aura buff: per-tower dpsMult from the table.
                    -- ea3-130: helper already returns 1.0 for aura
                    -- sources (no self-buff) and 1.0 for towers no
                    -- aura source reaches.
                    local towerId = loadoutTowers[i]
                    local thisTowerAuraMult = thisAuraMults.dpsMult

                    -- Per-Core surgical lift (2026-04-28): the Core
                    -- slot is loadoutTowers[1]; aux slots are i >= 2.
                    -- ControlCore's stack-DOT carryover + multi-mob
                    -- retarget physics is under-modeled in the
                    -- closed form; SupportCore has a small residual
                    -- after the AuraValueMult pass. PerCoreDpsMult
                    -- closes both gaps without touching aux modeling.
                    local coreCalMult = 1.0
                    if i == 1 then
                        coreCalMult = PER_CORE_DPS_MULT[towerId] or 1.0
                    end

                    availDmg = availDmg + towerDPS(stats) * usefulTime
                        * aoeMult * chainMult * pierceMult * lobMult
                        * thisTowerAuraMult * linkMult * coreCalMult

                    -- Stacking DOT (ControlCore mechanic): per-mob
                    -- ramp model. Number of mobs the tower processes
                    -- during the wave = min(count, waveWindow /
                    -- perMobExposureSec). Each mob eats DOT damage
                    -- scaled by linear stack ramp + post-saturation
                    -- peak DPS. Exposure-aware so Solo waves (long
                    -- exposure → full ramp) score higher than AOE
                    -- waves (short exposure → partial ramp), matching
                    -- the real-game asymmetry.
                    --
                    -- coreCalMult applied here too so ControlCore's
                    -- stack-DOT contribution gets the same per-Core
                    -- lift as its direct DPS — this mechanic is the
                    -- main source of the ControlCore under-prediction.
                    if (stats.stackDotTickDmg or 0) > 0 and perMobExposureSec > 0 then
                        local mobsProcessed = math.min(
                            group.count,
                            math.max(1, math.floor(waveWindow / perMobExposureSec)))
                        local dotPerMob = stackDotDamagePerMob(stats, perMobExposureSec)
                        availDmg = availDmg + mobsProcessed * dotPerMob * thisTowerAuraMult * coreCalMult
                    end
                end
            end

            -- Compare total damage capacity vs total group HP.
            -- Mobs that don't get killed reach the heart with
            -- starting HP. (Closed-form approximation: if availDmg
            -- ≥ totalGroupHp → all clear; else heart_damage =
            -- totalGroupHp - availDmg.)
            if availDmg < totalGroupHp then
                heartDamage = heartDamage + (totalGroupHp - availDmg)
            end
        end
    end

    return heartDamage, waveFullHp
end

------------------------------------------------------------
-- Public: run one loadout to wave 30 cap or heart death.
------------------------------------------------------------
function Simulator.runLoadout(auxIds, coreId)
    -- coreId selects which Core archetype anchors this loadout
    -- ("Power" | "ControlCore" | "SupportCore"). Defaults to Power
    -- for backwards compat — older callers (sweep harness, tests)
    -- that pre-date Core variants pass nil and get the existing
    -- Power Core behavior. Per Matthew 2026-04-27.
    local towers = { coreId or "Power" }
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
        local waveType = testTypeForWave(wave)
        local dmg, waveFullHp = simulateWave(towers, slotAssignments, wave, waveType)
        if dmg >= heartHp then
            -- ea3-148: heart died this wave. New formula mirrors
            -- ArenaSweepRunner.computeFractionalWave (per CLAUDE.md
            -- convention 7: sim and real compute equivalent metrics):
            --   theoNextHeart = heartHp - dmg  (negative = overkill amount)
            --   finalWave     = wave + (waveFullHp + theoNextHeart) / waveFullHp
            -- Behavioral parity: clean kill (dmg=heartHp) → wave + 1;
            -- wave-equal overkill → wave + 0; 2× overkill → wave - 1.
            -- Negative fractions allowed (loadout's sustainable wave
            -- below what it touched).
            local theoNextHeart = heartHp - dmg
            local denom = math.max(1, waveFullHp)
            local frac  = (denom + theoNextHeart) / denom
            return wave + frac
        end
        heartHp = heartHp - dmg
    end
    return MAX_WAVE  -- survived to cap
end

------------------------------------------------------------
-- Public: run an entire AUTO RUN queue. Returns parallel result
-- list (one entry per loadout in queue order).
------------------------------------------------------------
function Simulator.runSweep(queue, coreId)
    -- coreId is the Core archetype to feed every loadout in the
    -- queue. Defaults to "Power" so older one-arg callers stay
    -- byte-identical. The caller (Infinite.simulateRemote handler)
    -- reads State.preferredCoreId and threads it through here.
    local results = {}
    for i, loadout in ipairs(queue) do
        local fw = Simulator.runLoadout(loadout.auxIds, coreId)
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

-- ea3-126: expose auraMultForLoadout for unit tests on the
-- coverage-split logic. Tests pass a synthetic upgradedStats table
-- with hand-crafted auraRadius / auraDamageBonusPct / etc fields and
-- assert (dpsMult, rangeMult) returns. Underscore prefix signals
-- "test-only — don't depend on this from production code."
--
-- ea3-130: kept for backward compat — the new per-tower model
-- bypasses this function, but it's still exercised by tests in
-- tests/InfiniteSimulator.lua as a regression guard on the
-- legacy contract (in case future refactors need to fall back
-- to the global pair somewhere).
Simulator._auraMultForLoadout = auraMultForLoadout
Simulator._perTowerAuraMults  = perTowerAuraMults

return Simulator
