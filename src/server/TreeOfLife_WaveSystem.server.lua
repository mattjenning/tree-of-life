-- TreeOfLife_WaveSystem_SERVER.lua
-- Companion ServerScript to TreeOfLife_Hub. Owns: mob types, wave definitions,
-- mob spawning, mob pathing & status effects (stun/knockback/AOE), tower
-- firing, wave progression, win/lose detection, upgrade card generation
-- (rarity rolls, special bonuses), reroll handling.
--
-- Reads tagged infrastructure built by the hub:
--   EnemyWaypoint (path nodes), EnemySpawn (origin), EnemyEndPoint (heart),
--   Tower (placed towers).
--
-- ============================================================
-- ARCHITECTURE NOTES (read before editing)
-- ============================================================
--
-- DEPENDENCY LAYERS (top of file = first to load = lowest layer):
--   L0  Services + Config + STAGES table         (lines ~15-260)
--   L1  Stateless helpers (rolls, descriptions)  (lines ~260-400)
--   L2  World accessors (getHeart, getWaypoints) (lines ~400-440)
--   L3  Mob factory (makeMob)                    (lines ~440-560)
--   L4  Mob/tower utilities + VFX spawners +
--       findTarget + applyHitEffects             (lines ~560-820)
--   L5  damageMob (calls L1-L4)                  (lines ~820-960)
--   L6  Per-frame loops:
--         updateMobs, updateTowers,
--         tickPhoenixCooldowns                   (lines ~960-1180)
--   L7  Wave orchestration + remote handlers +
--       Heartbeat connection                     (lines ~1180-end)
--
-- EDITING RULES:
--   1. Functions must be declared BEFORE any function that calls them.
--      Lua resolves non-local identifiers as globals at function-DEFINITION
--      time (not call time). A late-declared local resolves to nil global
--      in earlier closures and crashes only on the code path that exercises
--      the call. We had 5 such bugs before this reorder. Don't add more.
--   2. New helpers go in the appropriate layer above. If you need to call
--      something from a layer below, that's a sign the layers are wrong.
--   3. The ONE forward-declared local in this file is `gameSpeed`, because
--      it's mutated by a remote handler much later in the file but read by
--      L4-L6 closures. Keep this exception minimal.
--
-- GAME-TIME vs WALL-CLOCK:
--   gameSpeed is 1/2/3 (player toggle). When the player picks 3x:
--     - mob movement, tower fire intervals, spawn intervals, and Phoenix
--       cooldown all SCALE — 3x faster
--     - knockback slide animation, damage-number float-up, AOE/Detonator
--       VFX durations, and the boss minigame tap window all stay at REAL
--       wallclock seconds (intentional — VFX shouldn't speed up; the boss
--       tap window would be unwinnable at 3x)
--   Anywhere we set "this expires in N seconds" using os.clock(), we must
--   decide which kind of time we mean:
--     - GAME time → use `os.clock() + (N / gameSpeed)` so the wallclock
--       interval shrinks at 2x/3x
--     - REAL time → use `os.clock() + N` (visual durations only)
--   Stun and BonusDamageUntil use game-time. Look there for the pattern.
--
-- ============================================================

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

-- Shared modules. NOTE: this file also has a LOCAL `Config` table a bit
-- below (line ~120) for wave-specific tuning values. The shared Config
-- module (grid, map2 geometry, phoenix) is not yet imported here — it
-- will be added in a separate commit once the local Config is renamed
-- to avoid the name collision.
local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Tags    = require(Shared:WaitForChild("Tags"))

-- Forward-declared so closures defined earlier in the file (updateMobs,
-- updateTowers, tickPhoenixCooldowns) can capture this upvalue. Lua resolves
-- non-local identifiers as globals at the point of closure creation, so the
-- declaration MUST exist textually before any function that references it.
-- Initialized to 1 (real-time speed); the SetGameSpeed remote handler later
-- in the file ASSIGNS to this same upvalue rather than shadowing it.
local gameSpeed = 1

-- Forward-declared for the same reason as gameSpeed: gameOverFired is read
-- by onWaveCleared, advanceStage, and the upgrade-picked handler — all of
-- which sit textually ABOVE the heart-death poll task that originally
-- declared it. Without this forward decl, those earlier references resolved
-- to a separate GLOBAL gameOverFired (always nil), and the LOCAL set true
-- by the poll task never propagated. Symptom: after a death+reset, wave 1
-- ran fine, but the gameOverFired check before runWave(2) was reading nil
-- from a different variable (so it didn't block wave 2 — that part worked),
-- BUT the DEFEATED state and other "is the game over?" checks across the
-- file were inconsistent. Forward-decl ensures one shared local.
local gameOverFired = false

------------------------------------------------------------
-- Remote events
------------------------------------------------------------
local function ensureRemote(name)
    local r = ReplicatedStorage:FindFirstChild(name)
    if not r then
        r = Instance.new("RemoteEvent")
        r.Name = name
        r.Parent = ReplicatedStorage
    end
    return r
end

local remoteWaveStart     = ensureRemote(Remotes.Names.WaveStart)      -- client → server: player pressed START
local remoteWaveState     = ensureRemote(Remotes.Names.WaveState)      -- server → client: wave number, mobs remaining, etc.
local remoteShowUpgrades  = ensureRemote(Remotes.Names.ShowUpgrades)   -- server → client: show the upgrade picker
local remoteUpgradePicked = ensureRemote(Remotes.Names.UpgradePicked)  -- client → server: player chose an upgrade
local remoteGameOver      = ensureRemote(Remotes.Names.GameOver)       -- server → client: heart died (or final wave cleared)
local remoteStageCleared  = ensureRemote(Remotes.Names.StageCleared)   -- server → client: stage finished, show modal
local remoteStageContinue = ensureRemote(Remotes.Names.StageContinue)  -- client → server: continue button tapped
local remoteStageReskin   = ensureRemote(Remotes.Names.StageReskin)    -- server → client: hub-side visual transition for new stage
local remoteBossPhase     = ensureRemote(Remotes.Names.BossPhase)      -- server → client: spawn 4 tappable targets (with boss screen pos for launch)
local remoteBossTargetTap = ensureRemote(Remotes.Names.BossTargetTap)  -- client → server: target was tapped, grant bonus
local remoteBossWindup    = ensureRemote(Remotes.Names.BossWindup)     -- server → client: boss stopped, vibrate for N seconds, then spots launch
local remoteBossWeb       = ensureRemote(Remotes.Names.BossWeb)        -- server → client: player missed phase, web them for N seconds
local remoteBossPhaseMiss = ensureRemote(Remotes.Names.BossPhaseMiss)  -- client → server: phase tap window expired with incomplete taps
local remoteLeafMessage   = ensureRemote(Remotes.Names.LeafMessage)    -- server → client: show a falling-leaf narrative message with text + duration
local remoteDevAddStun    = ensureRemote(Remotes.Names.DevAddStun)     -- client → server: dev panel added a Stun stack to all owned towers
local remoteDevSkipToBoss = ensureRemote(Remotes.Names.DevSkipToBoss)  -- client → server: dev panel skip to current stage's boss with simulated upgrades
local remoteDevResetCd    = ensureRemote(Remotes.Names.DevResetCooldowns)  -- client → server: dev panel reset all per-tower cooldowns + bonus timers

------------------------------------------------------------
-- Config
------------------------------------------------------------

-- All tunable gameplay numbers in one place. Search this section first
-- when balancing.
local Config = {
    -- Status effect proc chances (per hit)
    stunTriggerChance      = 0.20,
    knockbackTriggerChance = 0.10,
    knockbackSlideTime     = 0.25,  -- seconds for the slide-back animation

    -- Reroll
    maxRerollsPerStage = 1,

    -- Pacing between waves
    upgradePickToNextWaveDelay = 3,    -- seconds after picking before next wave
    waveClearedPollInterval    = 0.3,  -- seconds between activeMobs polls

    -- Stage transitions
    stageContinueAutoDelay = 6,        -- seconds before stage clear modal auto-advances

    -- Final boss minigame: when boss HP crosses a threshold, spawn 4 tappable
    -- blobs. Tapping all in time grants a 5s "Damage Bonus" (×2 damage).
    -- Phase fires at each HP threshold (75%, 50%, 25%) provided the previous
    -- phase's blobs aren't still on screen. The "still on screen" check uses
    -- finalBossTargetWindow as the implicit cooldown — phases can't overlap.
    finalBossPhaseThresholds   = {0.75, 0.50, 0.25},
    finalBossTargetsPerPhase   = 4,
    finalBossTargetWindow      = 4,    -- seconds the targets remain tappable
    finalBossBonusDuration     = 5,    -- seconds of bonus damage on success
    finalBossBonusMultiplier   = 2.0,  -- damage multiplier during bonus
    finalBossWindupDuration    = 1.2,  -- boss stops + vibrates before launching spots
    finalBossWebDuration       = 3,    -- seconds the player is webbed on missed phase
}

-- Stage / map state. Updated as the player progresses through stages.
local StageState = {
    currentMapId   = 1,                              -- v3: which physical map. 1=Crook, 2=Climbing, 3=Canopy
    currentMapName = "Crook of the Tree (Morning)",
    currentStage   = 1,
    inTransition   = false,  -- true while between stages (prevents wave starts)
    finalBossActive = false, -- true during the final-final boss fight
}

-- Stage definitions. Stage hpMult multiplies the per-wave hpMult, so
-- a wave 5 (1.40 base) on stage 3 (2.0 stage mult) → 2.80× mob HP.
-- After clearing stages 1 + 2, the heart heals back to full.
-- After clearing stage 3's regular waves, the FINAL FINAL BOSS spawns
-- (stage 3 boss flag is in the "extra spawn" list below).
-- Stage hpMult and speedMult both scale REGULAR mobs (basic, fast, tank).
-- Stage bosses (Mold King) scale by bossHpMult instead. The final boss
-- (Pickle Lord) ignores all stage mults and has its own hardcoded stats.
--
-- Apr 22 balance pass — wave HP doubled at Day, tripled at Dusk so that
-- a player without attachments can't trivially clear past stage 1.
-- Stage boss HP: Morning = 2000 (×1.333), Day = 4500 (×3.0), Dusk = 7000 (×4.667).
-- Day's bossHpMult is 3.0 exactly = 4500. Dusk uses ratio 7000/1500 to land
-- on exactly 7000.
local Stages = {
    [1] = { name = "Crook of the Tree (Morning)", hpMult = 1.0,  speedMult = 1.0, bossHpMult = 1.333 },
    [2] = { name = "Crook of the Tree (Day)",     hpMult = 2.10, speedMult = 1.2, bossHpMult = 3.0 },
    [3] = { name = "Crook of the Tree (Dusk)",    hpMult = 3.40, speedMult = 1.3, bossHpMult = 7000/1500 },
}
-- Special name shown when the final boss spawns (after stage 3 waves cleared)
local FINAL_BOSS_MAP_NAME = "Crook of the Tree (Night)"
local TOTAL_STAGES = 3

-- Final boss runtime state. The minigame fires phase triggers each
-- time boss HP crosses one of finalBossPhaseThresholds. Each player's
-- damage bonus expires independently (tracked via attribute timer).
local FinalBossState = {
    instance        = nil,   -- Part reference to the final boss while alive
    triggeredPhases = {},    -- set of threshold indices already fired
    lastPhaseFire   = 0,     -- os.clock() of the most recent BossPhase fire
    windupUntil     = 0,     -- os.clock() value; while now < this, boss is stopped + vibrating
    pendingPhase    = nil,   -- phase index to fire when windup completes (nil otherwise)
}

-- Wave definitions. Each wave is { hpMult, spawns }. Each spawn is
-- { count, interval, mobType, gap }. mobType "boss" spawns the giant
-- end-of-stage boss as the final entry.
local WAVES = {
    -- Wave 1: gentle intro, baseline difficulty
    {
        hpMult = 1.00,
        spawns = {
            {count = 5, interval = 0.8, mobType = "basic", gap = 2.0},
            {count = 5, interval = 0.7, mobType = "basic", gap = 2.0},
            {count = 5, interval = 0.6, mobType = "basic", gap = 2.0},
            {count = 5, interval = 0.5, mobType = "basic", gap = 2.0},
            {count = 5, interval = 0.5, mobType = "basic", gap = 0},
        },
    },
    -- Wave 2: +10% HP, basic + fast mix
    {
        hpMult = 1.10,
        spawns = {
            {count = 5, interval = 0.6, mobType = "basic", gap = 1.8},
            {count = 5, interval = 0.4, mobType = "fast",  gap = 2.0},
            {count = 5, interval = 0.5, mobType = "basic", gap = 1.5},
            {count = 5, interval = 0.4, mobType = "fast",  gap = 2.0},
            {count = 5, interval = 0.4, mobType = "basic", gap = 0},
        },
    },
    -- Wave 3: +20% HP, tanks + mixed types
    {
        hpMult = 1.20,
        spawns = {
            {count = 5, interval = 0.7, mobType = "basic", gap = 2.0},
            {count = 5, interval = 1.0, mobType = "tank",  gap = 2.5},
            {count = 5, interval = 0.5, mobType = "fast",  gap = 2.0},
            {count = 5, interval = 1.0, mobType = "tank",  gap = 2.0},
            {count = 5, interval = 0.3, mobType = "basic", gap = 0},
        },
    },
    -- Wave 4: +30% HP, denser mix, more tanks. AOE-test groups bumped +4.
    {
        hpMult = 1.30,
        spawns = {
            {count = 6,  interval = 0.5, mobType = "basic", gap = 1.5},
            {count = 5,  interval = 0.8, mobType = "tank",  gap = 2.0},
            {count = 12, interval = 0.3, mobType = "fast",  gap = 1.8},  -- AOE test: 8→12
            {count = 6,  interval = 0.7, mobType = "tank",  gap = 1.5},
            {count = 12, interval = 0.3, mobType = "basic", gap = 0},    -- AOE test: 8→12
        },
    },
    -- Wave 5: +40% HP, then a single GIANT BOSS at the end. AOE-test
    -- groups bumped +4 each.
    {
        hpMult = 1.40,
        spawns = {
            {count = 12, interval = 0.4, mobType = "basic", gap = 1.5},  -- AOE test: 8→12
            {count = 6,  interval = 0.7, mobType = "tank",  gap = 1.8},
            {count = 14, interval = 0.3, mobType = "fast",  gap = 1.5},  -- AOE test: 10→14
            {count = 6,  interval = 0.6, mobType = "tank",  gap = 2.0},
            {count = 14, interval = 0.3, mobType = "basic", gap = 3.0},  -- AOE test: 10→14
            -- The boss: one giant rambling mob.
            {count = 1, interval = 0, mobType = "boss",   gap = 0},
        },
    },
}

-- Mob type definitions. All speeds bumped +10% across the board (Apr 22
-- balance pass). Final boss HP bumped +80% to compensate for stronger
-- player towers (attachment system + additive upgrade math).
local MOB_TYPES = {
    basic     = {hp = 30,    speed = 8.8,  color = Color3.fromRGB(180, 80, 70),
                 size = 2.5, displayName = "Rotten Apple"},
    fast      = {hp = 18,    speed = 15.4, color = Color3.fromRGB(200, 200, 60),
                 size = 2.0, displayName = "Sour Lemon"},
    tank      = {hp = 90,    speed = 5.5,  color = Color3.fromRGB(90,  60, 40),
                 size = 3.5, displayName = "Moldy Bread"},
    boss      = {hp = 1500,  speed = 4.4,  color = Color3.fromRGB(60, 30, 50),
                 size = 9.0, displayName = "The Mold King"},
    finalboss = {hp = 17000, speed = 3.3,  color = Color3.fromRGB(120, 30, 180),
                 size = 14,  displayName = "The Pickle Lord", isFinal = true},
}

-- Rarity tiers for core-tower upgrades, with weighted probabilities.
-- "Special" replaces a stat upgrade with a Special bonus (AOE / Knockback /
-- Stun / AmmoCapacity). Chain Lightning is intentionally NOT included.
local RARITY_TIERS = {
    {name = "Common",      weight = 50, color = Color3.fromRGB(200, 200, 200)},
    {name = "Rare",        weight = 25, color = Color3.fromRGB(80, 150, 255)},
    {name = "Exceptional", weight = 10, color = Color3.fromRGB(180, 80, 220)},
    {name = "Legendary",   weight = 5,  color = Color3.fromRGB(255, 170, 40)},
    {name = "Mythical",    weight = 2,  color = Color3.fromRGB(255, 60,  140)},
    {name = "Special",     weight = 8,  color = Color3.fromRGB(60, 220, 200)},
}

-- Per-rarity multiplier ranges for stat upgrades (Damage / Range / FireRate)
local RARITY_MULTS = {
    Common      = {min = 1.10, max = 1.20},
    Rare        = {min = 1.20, max = 1.35},
    Exceptional = {min = 1.35, max = 1.50},
    Legendary   = {min = 1.50, max = 1.65},
    Mythical    = {min = 1.65, max = 2.00},
}

-- Special bonus pool. All specials stack and can be rolled repeatedly.
local SPECIAL_TYPES = {"AOE", "Knockback", "Stun", "AmmoCapacity"}

-- For each special: attr name, base value (first time it's added),
-- increment value (each subsequent stack).
-- AmmoCapacity is a combo special: it both bumps the player's MaxCarry by
-- +10 AND doubles every owned tower's MaxShots. Because it operates on the
-- player AND on towers, the apply step is custom — see the pick handler.
local SPECIAL_EFFECTS = {
    AOE          = {attr = "AoeRadius",    base = 4,    increment = 2},
    Knockback    = {attr = "Knockback",    base = 2,    increment = 1},
    Stun         = {attr = "StunDuration", base = 0.2,  increment = 0.2},
    AmmoCapacity = {playerCarryDelta = 10, towerShotsMult = 2.0},  -- custom apply
}

local function describeSpecial(special, hasAlready)
    local eff = SPECIAL_EFFECTS[special]
    if special == "AmmoCapacity" then
        -- Wording is the same first or subsequent — it always does the same thing
        return string.format("+%d carry, double tower ammo", eff.playerCarryDelta)
    elseif special == "AOE" then
        if hasAlready then
            return string.format("Improve AOE (+%g radius)", eff.increment)
        else
            return string.format("Add AOE (+%g radius)", eff.base)
        end
    elseif special == "Knockback" then
        if hasAlready then
            return string.format("Improve Knockback (+%g)", eff.increment)
        else
            return string.format("Add Knockback (+%g, 10%% chance)", eff.base)
        end
    elseif special == "Stun" then
        if hasAlready then
            return string.format("Improve Stun (+%gs)", eff.increment)
        else
            return string.format("Add Stun (+%gs, 10%% chance)", eff.base)
        end
    end
    return special
end

local function rollRarity()
    local total = 0
    for _, tier in ipairs(RARITY_TIERS) do total = total + tier.weight end
    local r = math.random() * total
    local acc = 0
    for _, tier in ipairs(RARITY_TIERS) do
        acc = acc + tier.weight
        if r <= acc then return tier.name end
    end
    return "Common"
end

local function getTierColor(name)
    for _, tier in ipairs(RARITY_TIERS) do
        if tier.name == name then return tier.color end
    end
    return Color3.fromRGB(200, 200, 200)
end

-- Roll a stat upgrade card for a specific stat (Damage/Range/FireRate).
-- Returns a table with rarity, kind="stat", stat, multiplier, description.
-- For Damage cards we ALSO include flatDamage so the client can show "+12 damage"
-- which requires knowing the player's CURRENT damage at card-show time.
local function rollStatCard(rarity, stat, currentDamage)
    local m = RARITY_MULTS[rarity]
    local mult = m.min + math.random() * (m.max - m.min)
    -- Range is 20% weaker than Damage/FireRate at every rarity. Range
    -- compounds multiplicatively per pick and gets out of hand fast at high
    -- rarities, so we shrink the bonus portion (mult - 1) by 20%.
    if stat == "Range" then
        mult = 1 + (mult - 1) * 0.8
    end
    local pct = math.floor((mult - 1) * 100 + 0.5)
    local desc
    if stat == "Damage" then
        local flat = math.floor((currentDamage or 0) * (mult - 1) + 0.5)
        desc = string.format("+%d damage", flat)
    elseif stat == "Range" then
        desc = string.format("+%d%% Range", pct)
    elseif stat == "FireRate" then
        desc = string.format("+%d%% Fire Rate", pct)
    else
        desc = string.format("+%d%% %s", pct, stat)
    end
    return {
        kind = "stat",
        rarity = rarity,
        stat = stat,
        multiplier = mult,
        description = desc,
    }
end

-- Returns true if any of the player's towers already has the given special.
-- AmmoCapacity returns false because its wording is the same regardless of
-- prior stacks ("+10 carry, double tower ammo").
local function playerHasSpecial(player, special)
    if special == "AmmoCapacity" then return false end
    local effect = SPECIAL_EFFECTS[special]
    if not effect or not effect.attr then return false end
    for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local tower = towerBase.Parent
        if tower and tower:GetAttribute("Owner") == player.UserId then
            local val = tower:GetAttribute(effect.attr)
            if val and type(val) == "number" and val > 0 then return true end
        end
    end
    return false
end

-- Roll a special bonus card for the given player. All specials are now
-- repeatable, so no pool exclusions. Card text reflects whether the player
-- already owns the rolled special ("Add" vs "Improve" wording).
-- excludeSet (optional): {[specialName]=true} — types to skip when rolling.
-- Caller passes this to prevent duplicate Special cards in the same picker.
local function rollSpecialCard(player, excludeSet)
    excludeSet = excludeSet or {}
    -- Build the available pool by filtering out anything in excludeSet
    local pool = {}
    for _, t in ipairs(SPECIAL_TYPES) do
        if not excludeSet[t] then table.insert(pool, t) end
    end
    -- Defensive: if everything's excluded (shouldn't happen with 3 cards
    -- and 4+ specials, but just in case), fall back to the full pool
    if #pool == 0 then pool = SPECIAL_TYPES end
    local pick = pool[math.random(1, #pool)]
    local hasAlready = playerHasSpecial(player, pick)
    return {
        kind = "special",
        rarity = "Special",
        special = pick,
        description = describeSpecial(pick, hasAlready),
    }
end

------------------------------------------------------------
-- References
--
-- v3 multi-map: each map has its own Heart, EnemySpawn, and EnemyPath
-- folder, all coexisting in Workspace at different physical locations.
-- Tagged Parts get a MapId attribute (1, 2, 3...) and the active-map
-- accessors filter by StageState.currentMapId. Map 1 = Crook of the
-- Tree (existing). Map 2 = Climbing the Tree (new this session).
--
-- Backward-compat: if a tagged Part has NO MapId attribute, it's treated
-- as belonging to map 1 (so old hub builds without MapId still work).
------------------------------------------------------------
local tdRoom = Workspace:WaitForChild("TreeOfLifeTDRoom")

local function partMapId(part)
    return part:GetAttribute("MapId") or 1
end

local function activeMapId()
    return (StageState and StageState.currentMapId) or 1
end

local function getHeart()
    local id = activeMapId()
    for _, h in ipairs(CollectionService:GetTagged(Tags.EnemyEndPoint)) do
        if partMapId(h) == id then return h end
    end
    return nil
end

local function getSpawnPart()
    local id = activeMapId()
    for _, s in ipairs(CollectionService:GetTagged(Tags.EnemySpawn)) do
        if partMapId(s) == id then return s end
    end
    return nil
end

local function getWaypoints()
    -- Find the EnemyPath folder belonging to the active map. Each map's
    -- folder is parented under its own Model (e.g. Map2Room) or under
    -- the tdRoom for map 1. We scan Workspace descendants for any folder
    -- named "EnemyPath" and pick the one whose MapId matches.
    local id = activeMapId()
    local chosenFolder = nil
    for _, descendant in ipairs(Workspace:GetDescendants()) do
        if descendant:IsA("Folder") and descendant.Name == "EnemyPath" then
            local folderMapId = descendant:GetAttribute("MapId") or 1
            if folderMapId == id then
                chosenFolder = descendant
                break
            end
        end
    end
    if not chosenFolder then return {} end
    local wps = {}
    for i = 1, 50 do  -- bumped from 20 to 50 for longer map 2 path
        local wp = chosenFolder:FindFirstChild("Waypoint" .. i)
        if wp then
            table.insert(wps, wp)
        else
            break
        end
    end
    return wps
end

------------------------------------------------------------
-- Mob management
------------------------------------------------------------
local activeMobs = {}  -- [mob instance] = {hp, maxHp, speed, damage, waypointIndex, ...}

local function makeMob(mobType, waypoints, hpMult)
    local def = MOB_TYPES[mobType]
    local spawnPart = getSpawnPart()
    if not spawnPart or #waypoints == 0 then return nil end

    -- HP and speed scaling rules:
    --   Regular mobs (basic/fast/tank): scale by stage hpMult + speedMult
    --   Stage boss (Mold King): scale by stage bossHpMult only (NOT hpMult)
    --   Final boss (Pickle Lord): skip stage scaling entirely; +30% speed
    local playerCount = math.max(1, #Players:GetPlayers())
    local waveMult = hpMult or 1.0
    local isStageBoss = (mobType == "boss") and not def.isFinal
    local isFinalBoss = (mobType == "finalboss") or def.isFinal
    local stageHpMult, stageSpeedMult
    local s = Stages[StageState.currentStage]
    if isFinalBoss then
        stageHpMult, stageSpeedMult = 1.0, 1.0
    elseif isStageBoss then
        stageHpMult    = (s and s.bossHpMult) or 1.0
        stageSpeedMult = 1.0  -- stage boss speed isn't bumped
    else
        stageHpMult    = (s and s.hpMult)    or 1.0
        stageSpeedMult = (s and s.speedMult) or 1.0
    end
    -- Bosses ignore waveMult (the per-wave HP ramp). bossHpMult is the
    -- sole boss scaling knob. Regular mobs and the final boss still use
    -- the wave-specific multiplier (which is 1.0 for the final boss's
    -- synthetic "wave 0" anyway).
    local effectiveWaveMult = (isStageBoss) and 1.0 or waveMult
    local scaledHp = math.floor(def.hp * playerCount * effectiveWaveMult * stageHpMult + 0.5)
    local scaledSpeed = def.speed * stageSpeedMult
    if def.isFinal then scaledSpeed = scaledSpeed * 1.3 end

    local mob = Instance.new("Part")
    mob.Name = "Mob_" .. mobType
    mob.Shape = Enum.PartType.Ball
    mob.Size = Vector3.new(def.size, def.size, def.size)
    mob.Material = def.isFinal and Enum.Material.Neon or Enum.Material.SmoothPlastic
    mob.Color = def.color
    mob.CFrame = CFrame.new(spawnPart.Position + Vector3.new(0, def.size / 2, 0))
    mob.Anchored = true
    mob.CanCollide = false
    mob.CastShadow = false
    mob.Parent = tdRoom
    CollectionService:AddTag(mob, Tags.Mob)
    if def.isFinal then
        CollectionService:AddTag(mob, Tags.FinalBoss)
        -- Purple point light
        local light = Instance.new("PointLight")
        light.Color = Color3.fromRGB(180, 60, 220)
        light.Brightness = 4
        light.Range = 30
        light.Parent = mob
    end

    -- HP bar above the mob
    local bbAnchor = Instance.new("Part")
    bbAnchor.Size = Vector3.new(0.1, 0.1, 0.1)
    bbAnchor.Transparency = 1
    bbAnchor.CanCollide = false
    bbAnchor.Anchored = true
    bbAnchor.CFrame = mob.CFrame + Vector3.new(0, def.size * 0.9, 0)
    bbAnchor.Parent = mob

    local bb = Instance.new("BillboardGui")
    bb.Size = UDim2.new(0, 80, 0, 18)
    bb.AlwaysOnTop = true
    bb.LightInfluence = 0
    bb.MaxDistance = 200
    bb.Parent = bbAnchor

    local hpBg = Instance.new("Frame")
    hpBg.Size = UDim2.fromScale(1, 1)
    hpBg.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    hpBg.BackgroundTransparency = 0.3
    hpBg.BorderSizePixel = 0
    hpBg.Parent = bb

    local hpFill = Instance.new("Frame")
    hpFill.Size = UDim2.new(1, -2, 1, -2)
    hpFill.Position = UDim2.new(0, 1, 0, 1)
    hpFill.BackgroundColor3 = Color3.fromRGB(240, 80, 80)
    hpFill.BorderSizePixel = 0
    hpFill.Parent = hpBg

    local hpText = Instance.new("TextLabel")
    hpText.Size = UDim2.fromScale(1, 1)
    hpText.BackgroundTransparency = 1
    hpText.Text = string.format("%d / %d", scaledHp, scaledHp)
    hpText.TextColor3 = Color3.fromRGB(255, 255, 255)
    hpText.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    hpText.TextStrokeTransparency = 0
    hpText.Font = Enum.Font.FredokaOne
    hpText.TextSize = 12
    hpText.ZIndex = 2
    hpText.Parent = hpBg

    activeMobs[mob] = {
        hp = scaledHp,
        maxHp = scaledHp,
        speed = scaledSpeed,
        damage = scaledHp,  -- damage to heart = mob's max HP (beefier mobs hurt more)
        waypointIndex = 1,
        size = def.size,
        hpFill = hpFill,
        hpText = hpText,
        bbAnchor = bbAnchor,
    }
    return mob
end

local function spawnDamageNumber(worldPos, amount)
    local anchor = Instance.new("Part")
    anchor.Size = Vector3.new(0.1, 0.1, 0.1)
    anchor.Transparency = 1
    anchor.CanCollide = false
    anchor.Anchored = true
    anchor.CFrame = CFrame.new(worldPos + Vector3.new(
        math.random(-10, 10) * 0.1, 2, math.random(-10, 10) * 0.1))
    anchor.Parent = tdRoom

    local bb = Instance.new("BillboardGui")
    bb.Size = UDim2.new(0, 60, 0, 30)
    bb.AlwaysOnTop = true
    bb.LightInfluence = 0
    bb.MaxDistance = 250
    bb.Parent = anchor

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Text = "-" .. math.floor(amount)
    label.TextColor3 = Color3.fromRGB(255, 230, 100)
    label.TextStrokeColor3 = Color3.fromRGB(80, 20, 0)
    label.TextStrokeTransparency = 0
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 22
    label.Parent = bb

    -- Animate: float up and fade
    task.spawn(function()
        local startTime = os.clock()
        local duration = 0.8
        local startPos = anchor.Position
        while true do
            local elapsed = os.clock() - startTime
            local t = elapsed / duration
            if t >= 1 then break end
            anchor.CFrame = CFrame.new(startPos + Vector3.new(0, t * 3, 0))
            label.TextTransparency = t
            label.TextStrokeTransparency = t
            RunService.Heartbeat:Wait()
        end
        anchor:Destroy()
    end)
end

-- ============================================================
-- VFX SPAWNERS, TARGETING, EFFECT APPLICATION, MOB UTILITIES
-- These all live ABOVE damageMob because damageMob (and updateTowers,
-- updateMobs) call into them. Reordered Apr 22 to eliminate the
-- forward-declaration pattern that produced 5 different nil-call bugs.
-- ============================================================

local function countActiveMobs()
    local n = 0
    for _ in pairs(activeMobs) do n = n + 1 end
    return n
end

-- Forward-declared Phoenix state so clearAllMobs/RunReset can clear it.
-- Full init + function-body declarations happen further down once the
-- VFX helpers (spawnFireVFX) are defined.
local PhoenixGrace = { activeUntil = 0 }
local PhoenixQueue = { items = {}, nextReleaseAt = 0 }

local function clearAllMobs()
    for mob, data in pairs(activeMobs) do
        if data.stunStars then
            for _, star in ipairs(data.stunStars) do star:Destroy() end
        end
        if mob.Parent then mob:Destroy() end
    end
    activeMobs = {}
    -- Also clear the Phoenix respawn queue — mobs in there were destroyed above
    PhoenixQueue.items = {}
    PhoenixQueue.nextReleaseAt = 0
    PhoenixGrace.activeUntil = 0
end

-- Target selection supports three modes:
--   First    : mob furthest along the path (about to reach the heart)
--   Strongest: mob with highest current HP
--   Center   : mob with the most other mobs clustered near it (within 8 studs)
-- All modes are single-target; only priority differs. Ties broken by: further
-- along the path > higher HP > closer to tower.
local function findTarget(towerPos, range, mode)
    mode = mode or "First"
    local waypoints = getWaypoints()
    local CLUSTER_RADIUS = 8

    -- Gather all mobs in range with their progress metric
    local candidates = {}
    for mob, data in pairs(activeMobs) do
        if mob.Parent and not data._phoenixQueued then
            local d = (mob.Position - towerPos).Magnitude
            if d <= range then
                -- Progress score: waypointIndex + (fraction to next waypoint).
                -- Higher = further along the path.
                local prog = data.waypointIndex or 1
                local nextWp = waypoints[prog]
                if nextWp then
                    local prevWp = waypoints[prog - 1]
                    local legStart = prevWp and prevWp.Position or mob.Position
                    local legEnd = nextWp.Position
                    local legLen = (legEnd - legStart).Magnitude
                    if legLen > 0.01 then
                        local traveled = (mob.Position - legStart).Magnitude
                        prog = prog + math.clamp(traveled / legLen, 0, 1)
                    end
                end
                table.insert(candidates, {
                    mob = mob,
                    data = data,
                    dist = d,
                    progress = prog,
                })
            end
        end
    end

    if #candidates == 0 then return nil end

    if mode == "Strongest" then
        table.sort(candidates, function(a, b)
            if a.data.hp ~= b.data.hp then return a.data.hp > b.data.hp end
            if a.progress ~= b.progress then return a.progress > b.progress end
            return a.dist < b.dist
        end)
        return candidates[1].mob
    end

    if mode == "Center" then
        -- For each candidate, count how many other mobs are within CLUSTER_RADIUS
        for _, c in ipairs(candidates) do
            local n = 0
            for other in pairs(activeMobs) do
                if other ~= c.mob and other.Parent then
                    if (other.Position - c.mob.Position).Magnitude <= CLUSTER_RADIUS then
                        n = n + 1
                    end
                end
            end
            c.neighbors = n
        end
        table.sort(candidates, function(a, b)
            if a.neighbors ~= b.neighbors then return a.neighbors > b.neighbors end
            if a.progress ~= b.progress then return a.progress > b.progress end
            return a.dist < b.dist
        end)
        return candidates[1].mob
    end

    -- "Last" — opposite of First. Targets the mob LEAST far along the path.
    -- Designed for the explosive-blob problem on map 2: the player wants
    -- to kill back-of-pack first so the explosion damages the rest of the
    -- group, instead of detonating in empty space at the front.
    if mode == "Last" then
        table.sort(candidates, function(a, b)
            if a.progress ~= b.progress then return a.progress < b.progress end
            return a.dist < b.dist
        end)
        return candidates[1].mob
    end

    -- Default: "First" — furthest along the path
    table.sort(candidates, function(a, b)
        if a.progress ~= b.progress then return a.progress > b.progress end
        return a.dist < b.dist
    end)
    return candidates[1].mob
end

local function fireBolt(fromPos, toPos, color)
    local mid = (fromPos + toPos) * 0.5
    local dir = toPos - fromPos
    local len = dir.Magnitude
    local bolt = Instance.new("Part")
    bolt.Name = "Bolt"
    bolt.Size = Vector3.new(0.3, 0.3, len)
    bolt.CFrame = CFrame.lookAt(mid, toPos)
    bolt.Anchored = true
    bolt.CanCollide = false
    bolt.CastShadow = false
    bolt.Material = Enum.Material.Neon
    bolt.Color = color or Color3.fromRGB(255, 200, 120)
    bolt.Transparency = 0.1
    bolt.Parent = tdRoom
    game:GetService("Debris"):AddItem(bolt, 0.12)
end

-- AOE burst: short-lived expanding sphere at the target position.
-- This is an assignment to the forward-declared upvalue near the top of
-- the file (NOT a new local) so damageMob's closure can reach it.
local function spawnAoeBurst(centerPos, radius)
    local burst = Instance.new("Part")
    burst.Name = "AoeBurst"
    burst.Shape = Enum.PartType.Ball
    burst.Size = Vector3.new(1, 1, 1)
    burst.Anchored = true
    burst.CanCollide = false
    burst.CastShadow = false
    burst.Material = Enum.Material.Neon
    burst.Color = Color3.fromRGB(255, 180, 100)
    burst.Transparency = 0.2
    burst.CFrame = CFrame.new(centerPos)
    burst.Parent = tdRoom

    task.spawn(function()
        local startTime = os.clock()
        local duration = 0.25
        local maxDiameter = radius * 2
        while true do
            local elapsed = os.clock() - startTime
            local t = elapsed / duration
            if t >= 1 then break end
            local d = 1 + (maxDiameter - 1) * t
            burst.Size = Vector3.new(d, d, d)
            burst.Transparency = 0.2 + 0.7 * t
            RunService.Heartbeat:Wait()
        end
        burst:Destroy()
    end)
end

-- Detonator burst: visually distinct from spawnAoeBurst so players can
-- tell Detonator-attachment explosions apart from regular AOE-special
-- area damage. Style: brief bright-yellow core flash + a ring of red
-- "shrapnel" cubes that fly outward and fade. Faster and more violent
-- than the soft orange AOE bloom.
local function spawnDetonatorBurst(centerPos, radius)
    -- Core flash: small bright sphere that pulses and fades quickly
    local core = Instance.new("Part")
    core.Name = "DetonatorCore"
    core.Shape = Enum.PartType.Ball
    core.Size = Vector3.new(2, 2, 2)
    core.Anchored = true
    core.CanCollide = false
    core.CastShadow = false
    core.Material = Enum.Material.Neon
    core.Color = Color3.fromRGB(255, 240, 120)  -- bright yellow
    core.Transparency = 0
    core.CFrame = CFrame.new(centerPos)
    core.Parent = tdRoom

    -- Shrapnel: 8 small cubes flung outward in a ring
    local shrapnel = {}
    local SHRAPNEL_COUNT = 8
    for i = 1, SHRAPNEL_COUNT do
        local s = Instance.new("Part")
        s.Name = "DetonatorShrapnel"
        s.Size = Vector3.new(0.6, 0.6, 0.6)
        s.Anchored = true
        s.CanCollide = false
        s.CastShadow = false
        s.Material = Enum.Material.Neon
        s.Color = Color3.fromRGB(255, 90, 60)  -- red-orange
        s.Transparency = 0
        s.CFrame = CFrame.new(centerPos)
        s.Parent = tdRoom
        local angle = (i - 1) * (math.pi * 2 / SHRAPNEL_COUNT)
        shrapnel[i] = {
            part = s,
            dir = Vector3.new(math.cos(angle), 0.2, math.sin(angle)),
        }
    end

    task.spawn(function()
        local startTime = os.clock()
        local duration = 0.35  -- faster than AOE bloom (0.25 was too short for the chunky effect)
        while true do
            local elapsed = os.clock() - startTime
            local t = elapsed / duration
            if t >= 1 then break end
            -- Core pulses bigger then fades fast
            local coreScale = 2 + (radius * 0.5) * t
            core.Size = Vector3.new(coreScale, coreScale, coreScale)
            core.Transparency = t  -- 0→1 linear fade
            -- Shrapnel flies outward and fades
            for _, s in ipairs(shrapnel) do
                local distance = radius * t
                s.part.CFrame = CFrame.new(centerPos + s.dir * distance)
                s.part.Transparency = t
            end
            RunService.Heartbeat:Wait()
        end
        core:Destroy()
        for _, s in ipairs(shrapnel) do s.part:Destroy() end
    end)
end

-- Apply secondary effects (knockback, stun) to a hit mob.
-- Each effect rolls a 10% chance per hit. damageMob already applied the HP hit.
-- Assignment to forward-declared upvalue (NOT a new local) so damageMob can
-- reach this from its earlier definition.
-- applyHitEffects(towerModel, primaryMob) -> procCount
--   Rolls stun and knockback (each 10% chance, independent). Applies the
--   status effect on each successful proc and returns the TOTAL number of
--   procs (0, 1, or 2). Callers in updateTowers and damageMob use the
--   return value to deal one extra hit of normal attack damage per proc
--   ("on a stun/knockback proc, do another normal attack damage hit").
--
--   CC values are the SAME for bosses and regular mobs. The previous
--   2x-for-non-bosses multiplier was removed when stun/knockback gained
--   the extra-damage-per-proc behavior — the damage component now does
--   most of the work, so symmetric CC durations keep the math simple.
local function applyHitEffects(towerModel, primaryMob)
    if not primaryMob then return 0 end
    local data = activeMobs[primaryMob]
    if not data then return 0 end

    local knockback = towerModel:GetAttribute("Knockback")
    local stunDur   = towerModel:GetAttribute("StunDuration")
    local procCount = 0

    -- Knockback (10% chance): set up a sliding state instead of teleporting.
    if knockback and math.random() < Config.knockbackTriggerChance then
        local waypoints = getWaypoints()
        local prevIdx = math.max(1, (data.waypointIndex or 1) - 1)
        local curIdx  = data.waypointIndex or 1
        local prevWp  = waypoints[prevIdx]
        local curWp   = waypoints[curIdx]
        if prevWp and curWp then
            local dir = (curWp.Position - prevWp.Position)
            if dir.Magnitude > 0.01 then
                dir = dir.Unit
                local startPos = primaryMob.Position
                local targetPos = startPos - dir * knockback
                -- Don't push past the spawn point
                local spawn = getSpawnPart()
                if spawn then
                    local fromSpawn = (targetPos - spawn.Position).Magnitude
                    if fromSpawn < 1 then targetPos = spawn.Position end
                end
                data.knockback = {
                    fromPos = startPos,
                    toPos = Vector3.new(targetPos.X, startPos.Y, targetPos.Z),
                    startTime = os.clock(),
                    duration = Config.knockbackSlideTime,
                }
                procCount = procCount + 1
            end
        end
    end

    -- Stun (10% chance). Duration uses os.clock() (wallclock) but should
    -- last `stunDur` GAME-seconds, so divide by gameSpeed. So at 3x speed
    -- a 0.6s game-time stun expires after 0.2s wallclock — which IS 0.6s
    -- in game time. Without this, stun was 1/3 as long at 3x.
    if stunDur and stunDur > 0 and math.random() < Config.stunTriggerChance then
        data.stunUntil = os.clock() + (stunDur / gameSpeed)
        procCount = procCount + 1
    end

    return procCount
end


-- ============================================================
-- PHOENIX CHARM (death-save mechanic)
-- ============================================================
-- When the heart would take fatal damage, if any tower has a ready Phoenix
-- attachment, we instead:
--   1. Restore heart to full HP (no damage taken).
--   2. Teleport every active mob back to waypoint 1, keeping their current HP.
--   3. Open a 5-second "grace window" — any mob that reaches the heart during
--      this window also gets teleported back instead of dealing damage. This
--      prevents the next-mob-in-line from instantly killing the heart again.
--   4. Consume the charge: PhoenixReady=false, CdRemaining=PhoenixCooldown.
-- The cooldown ticks down only during active waves (existing tickPhoenixCooldowns).
-- A run reset destroys towers, which clears the cooldown state — so restarting
-- a map gives you a fresh Phoenix even if the cooldown wasn't done.

-- PhoenixGrace forward-declared above (near clearAllMobs).

-- Spawn a fire VFX (ParticleEmitter on a hidden anchor part) at a position.
-- Lasts `duration` seconds, then auto-cleans up. Server-spawned so the VFX
-- replicates to all clients automatically — no remote needed.
--
-- The anchor is a 0.1-stud invisible Part. ParticleEmitter does the work.
-- We stagger the emission so particles continue spawning for ~half the
-- duration, then we let the existing particles finish their lifetime
-- naturally before destroying the anchor.
local function spawnFireVFX(position, duration, scale)
    duration = duration or 2.5
    scale = scale or 1.0
    local anchor = Instance.new("Part")
    anchor.Name = "PhoenixFireVFX"
    anchor.Size = Vector3.new(0.1, 0.1, 0.1)
    anchor.Anchored = true
    anchor.CanCollide = false
    anchor.CanQuery = false
    anchor.CanTouch = false
    anchor.Transparency = 1
    anchor.CFrame = CFrame.new(position)
    anchor.Parent = Workspace

    local pe = Instance.new("ParticleEmitter")
    pe.Texture = "rbxasset://textures/particles/fire_main.dds"
    pe.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0,    Color3.fromRGB(255, 230, 120)),
        ColorSequenceKeypoint.new(0.5,  Color3.fromRGB(255, 130,  40)),
        ColorSequenceKeypoint.new(1,    Color3.fromRGB(120,  20,  20)),
    })
    pe.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0,   1.4 * scale),
        NumberSequenceKeypoint.new(0.5, 2.2 * scale),
        NumberSequenceKeypoint.new(1,   0.4 * scale),
    })
    pe.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0,   0.1),
        NumberSequenceKeypoint.new(0.7, 0.4),
        NumberSequenceKeypoint.new(1,   1.0),
    })
    pe.Lifetime = NumberRange.new(0.5, 0.9)
    pe.Rate = 60 * scale
    pe.Speed = NumberRange.new(2, 5)
    pe.SpreadAngle = Vector2.new(180, 180)  -- omnidirectional puff
    pe.Acceleration = Vector3.new(0, 6, 0)  -- rises like fire
    pe.LightEmission = 0.8
    pe.LightInfluence = 0
    pe.Rotation = NumberRange.new(0, 360)
    pe.RotSpeed = NumberRange.new(-90, 90)
    pe.Parent = anchor

    -- Emit for the active portion of the duration, then let particles fade.
    task.delay(duration * 0.6, function()
        if pe.Parent then pe.Enabled = false end
    end)
    task.delay(duration + 1.0, function()  -- +1s to let last particles fade
        if anchor.Parent then anchor:Destroy() end
    end)
end

-- Spawn a ring of fire on the floor showing the Phoenix AOE boundary.
-- Used when Phoenix fires — players see exactly how far the effect reaches.
-- Creates 16 fire anchors arranged in a circle of the given radius around
-- `centerPos`, each with a small upward-burning ParticleEmitter. All fade
-- out after `duration` seconds.
local function spawnPhoenixAOEFloorFire(centerPos, radius, duration)
    local NUM_ANCHORS = 16
    local anchors = {}
    for i = 0, NUM_ANCHORS - 1 do
        local angle = (i / NUM_ANCHORS) * math.pi * 2
        local pos = centerPos + Vector3.new(math.cos(angle) * radius, 0.5, math.sin(angle) * radius)
        local anchor = Instance.new("Part")
        anchor.Name = "PhoenixAOEFloorFire"
        anchor.Size = Vector3.new(0.1, 0.1, 0.1)
        anchor.Anchored = true
        anchor.CanCollide = false
        anchor.CanQuery = false
        anchor.CanTouch = false
        anchor.Transparency = 1
        anchor.CFrame = CFrame.new(pos)
        anchor.Parent = Workspace

        local pe = Instance.new("ParticleEmitter")
        pe.Texture = "rbxasset://textures/particles/fire_main.dds"
        pe.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0,   Color3.fromRGB(255, 200, 100)),
            ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 120,  40)),
            ColorSequenceKeypoint.new(1,   Color3.fromRGB(140,  30,  20)),
        })
        pe.Size = NumberSequence.new({
            NumberSequenceKeypoint.new(0,   1.8),
            NumberSequenceKeypoint.new(0.5, 3.2),
            NumberSequenceKeypoint.new(1,   0.6),
        })
        pe.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0,   0.2),
            NumberSequenceKeypoint.new(0.8, 0.6),
            NumberSequenceKeypoint.new(1,   1.0),
        })
        pe.Lifetime = NumberRange.new(0.6, 1.2)
        pe.Rate = 24
        pe.Speed = NumberRange.new(2, 4)
        pe.SpreadAngle = Vector2.new(35, 35)  -- mostly upward
        pe.Acceleration = Vector3.new(0, 5, 0)
        pe.LightEmission = 0.8
        pe.Rotation = NumberRange.new(0, 360)
        pe.RotSpeed = NumberRange.new(-90, 90)
        pe.Parent = anchor
        anchors[i + 1] = {anchor = anchor, pe = pe}
    end
    -- Fade out the emitters `duration * 0.7` in so particles stop
    -- emitting while the tail continues to burn.
    task.delay(duration * 0.7, function()
        for _, a in ipairs(anchors) do
            if a.pe.Parent then a.pe.Enabled = false end
        end
    end)
    -- Destroy the anchors once all particles have faded.
    task.delay(duration + 1.2, function()
        for _, a in ipairs(anchors) do
            if a.anchor.Parent then a.anchor:Destroy() end
        end
    end)
end

local PHOENIX_AOE_RADIUS = 50       -- studs, centered on heart
local PHOENIX_GRACE_DURATION = 5    -- seconds — AOE keeps catching mobs during this window
local PHOENIX_BURN_DURATION = 10    -- seconds of fire VFX on each released mob

-- Phoenix respawn queue.
--
-- On Phoenix trigger (or during grace window sweep), every mob in AOE is
-- CAPTURED: hidden offscreen, HP preserved, and queued with its original
-- path-distance-from-heart. Queue is sorted closest-to-heart first. A
-- scheduler releases them from the path start in that order, with delays
-- based on ORIGINAL spacing:
--   delay_N = (pathDist_N - pathDist_(N-1)) / speed_N
-- So if A was 7 studs from heart, B was 13, C was 27:
--   A releases at t=0
--   B releases at t = (13-7)/B.speed = 6/B.speed seconds later
--   C releases at t_B + (27-13)/C.speed
-- This recreates the original wave pacing.
--
-- Each released mob gets a burning VFX (follows them) and their original HP.
-- The queue can outlive the grace window — grace just controls when new
-- entries get captured.
-- PhoenixQueue forward-declared above (near clearAllMobs) with {items={}, nextReleaseAt=0}.

-- Compute a mob's path-distance-from-heart (studs). 0 = at heart. Higher =
-- further from heart, closer to spawn.
local function computePathDistFromHeart(mob, data, waypoints)
    -- Total path length forward of this mob = distance to next waypoint +
    -- sum of segment lengths from that waypoint through the final one.
    local idx = data.waypointIndex or 1
    local total = 0
    local nextWp = waypoints[idx]
    if nextWp then
        total = (nextWp.Position - mob.Position).Magnitude
        for i = idx, #waypoints - 1 do
            total = total + (waypoints[i + 1].Position - waypoints[i].Position).Magnitude
        end
    end
    return total
end

-- Attach a fire ParticleEmitter to a mob for PHOENIX_BURN_DURATION seconds.
-- Parented to the mob so it follows them. If the mob dies before burn
-- expires, emitter is destroyed with the mob automatically.
local function attachBurningEffect(mob, data)
    if data._burnEmitter and data._burnEmitter.Parent then
        data._burnEmitter:Destroy()
    end
    local pe = Instance.new("ParticleEmitter")
    pe.Texture = "rbxasset://textures/particles/fire_main.dds"
    pe.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0,   Color3.fromRGB(255, 230, 120)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 130,  40)),
        ColorSequenceKeypoint.new(1,   Color3.fromRGB(120,  20,  20)),
    })
    local scale = math.max(0.5, (data.size or 1.5) * 0.35)
    pe.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0,   0.8 * scale),
        NumberSequenceKeypoint.new(0.5, 1.3 * scale),
        NumberSequenceKeypoint.new(1,   0.2 * scale),
    })
    pe.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0,   0.15),
        NumberSequenceKeypoint.new(0.7, 0.4),
        NumberSequenceKeypoint.new(1,   1.0),
    })
    pe.Lifetime = NumberRange.new(0.4, 0.8)
    pe.Rate = 30
    pe.Speed = NumberRange.new(1, 3)
    pe.SpreadAngle = Vector2.new(180, 180)
    pe.Acceleration = Vector3.new(0, 4, 0)
    pe.LightEmission = 0.8
    pe.Rotation = NumberRange.new(0, 360)
    pe.RotSpeed = NumberRange.new(-90, 90)
    pe.Parent = mob

    data._burnEmitter = pe
    task.delay(PHOENIX_BURN_DURATION, function()
        if pe.Parent then pe.Enabled = false end
        task.delay(1, function() if pe.Parent then pe:Destroy() end end)
    end)
end

-- LIMBO position: far below all maps so queued mobs are invisible/unreachable
-- while they wait for release. Per-mob offset so many queued mobs don't stack.
local PHOENIX_LIMBO_BASE = Vector3.new(-10000, -500, -10000)

-- Capture a mob into the Phoenix queue: hide it, record HP + pathDist,
-- insert into the queue sorted by pathDist ascending (closest-to-heart first).
-- Caller guarantees mob.Parent and not already queued.
local PHOENIX_BURN_IN_PLACE_DURATION = 0.5  -- seconds mobs freeze + burn visibly before going to limbo

-- Phase 1 of Phoenix capture: mob catches fire + freezes in place for
-- PHOENIX_BURN_IN_PLACE_DURATION seconds. Still in world, still targetable
-- by towers, still damageable — but doesn't move. Once the burn timer
-- expires, moveToPhoenixLimbo transitions to phase 2 (queue + hidden).
--
-- The pathDist is captured NOW (at burn start) so queue ordering reflects
-- the mob's original position, not anything that happens during burn.
local function startPhoenixBurn(mob, data, waypoints)
    data._phoenixBurning = true
    data._phoenixBurnUntil = os.clock() + PHOENIX_BURN_IN_PLACE_DURATION
    data._phoenixPathDist = computePathDistFromHeart(mob, data, waypoints)
    data.knockback = nil
    attachBurningEffect(mob, data)
end

-- Phase 2 of Phoenix capture: mob moves to limbo (hidden far below map)
-- and enters the respawn queue. Called from updateMobs when the burn-in-
-- place timer expires. Mob's current HP is captured into the queue entry
-- (may be LESS than original if towers damaged it during the burn window).
local function moveToPhoenixLimbo(mob, data)
    data._phoenixBurning = nil
    data._phoenixBurnUntil = nil
    data._phoenixQueued = true
    local pathDist = data._phoenixPathDist or 0
    data._phoenixPathDist = nil

    -- Hide in limbo: offset by queue length so multiple captures don't stack
    local limboPos = PHOENIX_LIMBO_BASE + Vector3.new(#PhoenixQueue.items * 5, 0, 0)
    mob.CFrame = CFrame.new(limboPos)
    if data.bbAnchor then
        data.bbAnchor.CFrame = CFrame.new(limboPos)
    end
    table.insert(PhoenixQueue.items, {
        mob = mob,
        data = data,
        hp = data.hp,  -- current HP (may have been damaged during burn window)
        pathDist = pathDist,
        speed = data.speed or 1,
        released = false,
    })
    -- Keep queue sorted by pathDist ascending (closest-to-heart goes first)
    table.sort(PhoenixQueue.items, function(a, b)
        if a.released ~= b.released then return not a.released and b.released end
        return a.pathDist < b.pathDist
    end)
    -- If this was the first mob queued, kick off its release now. Otherwise,
    -- leave nextReleaseAt alone — the existing scheduler handles it.
    if PhoenixQueue.nextReleaseAt == 0 or PhoenixQueue.nextReleaseAt == math.huge then
        PhoenixQueue.nextReleaseAt = os.clock()
    end
end

-- Legacy entry point for capture — kicks off phase 1. Kept as the public
-- name used by heart-arrival + capturePhoenixAOEMobs.
local function capturePhoenixMob(mob, data, waypoints)
    startPhoenixBurn(mob, data, waypoints)
end

-- Release the next queued mob: teleport to start, restore HP, attach burn,
-- clear queue flag. Updates nextReleaseAt for the subsequent mob.
local function releaseNextPhoenixMob(now, waypoints)
    -- Find first unreleased entry
    local entry = nil
    local entryIdx = nil
    for i, e in ipairs(PhoenixQueue.items) do
        if not e.released then
            entry = e
            entryIdx = i
            break
        end
    end
    if not entry then return false end

    local mob = entry.mob
    local data = entry.data
    if not mob.Parent then
        -- Mob was destroyed while in limbo (can't really happen but defensive)
        entry.released = true
        return true
    end
    local startPos = waypoints[1].Position
    local spawnPos = startPos + Vector3.new(0, data.size / 2, 0)
    mob.CFrame = CFrame.new(spawnPos)
    data.waypointIndex = 1
    data.knockback = nil
    data.hp = entry.hp  -- restore original HP
    data._phoenixQueued = nil
    -- Restore HP bar tracking (mob update loop will reposition the anchor)
    if data.hpFill then
        data.hpFill.Size = UDim2.new(math.max(0, data.hp / data.maxHp), -2, 1, -2)
    end
    if data.hpText then
        data.hpText.Text = string.format("%d / %d", math.max(0, math.floor(data.hp)), data.maxHp)
    end
    attachBurningEffect(mob, data)
    entry.released = true

    -- Schedule next release based on ORIGINAL spacing.
    -- delay = (this.pathDist - prev.pathDist) / this.speed (for mobs AFTER this one)
    -- Look at the NEXT unreleased entry to compute delay.
    local nextEntry = nil
    for j = entryIdx + 1, #PhoenixQueue.items do
        if not PhoenixQueue.items[j].released then
            nextEntry = PhoenixQueue.items[j]
            break
        end
    end
    if nextEntry then
        local distGap = math.max(0, nextEntry.pathDist - entry.pathDist)
        local delay = distGap / math.max(0.1, nextEntry.speed)
        PhoenixQueue.nextReleaseAt = now + delay
    else
        PhoenixQueue.nextReleaseAt = math.huge  -- no more to release
    end
    return true
end

-- Called every frame from updateMobs: if the queue has a due mob, release it.
local function processPhoenixQueue(now)
    if #PhoenixQueue.items == 0 then return end
    local waypoints = getWaypoints()
    if #waypoints == 0 then return end
    while now >= PhoenixQueue.nextReleaseAt do
        local released = releaseNextPhoenixMob(now, waypoints)
        if not released then break end
    end
    -- Clean up fully-released queue so we don't iterate old entries forever
    local allReleased = true
    for _, e in ipairs(PhoenixQueue.items) do
        if not e.released then allReleased = false; break end
    end
    if allReleased then
        PhoenixQueue.items = {}
        PhoenixQueue.nextReleaseAt = 0
    end
end

-- Called every frame from updateMobs: during grace, capture any mob that
-- newly entered the AOE into the queue.
local function capturePhoenixAOEMobs(now, heart, waypoints)
    local heartPos = heart.Position
    local radiusSq = PHOENIX_AOE_RADIUS * PHOENIX_AOE_RADIUS
    for mob, data in pairs(activeMobs) do
        -- Skip mobs already in burn-phase-1 (_phoenixBurning) or limbo (_phoenixQueued)
        if mob.Parent and not data._phoenixQueued and not data._phoenixBurning then
            if (mob.Position - heartPos).Magnitude ^ 2 <= radiusSq then
                capturePhoenixMob(mob, data, waypoints)
            end
        end
    end
end

-- Try to consume a Phoenix charge. Returns true if a Phoenix triggered.
local function tryConsumePhoenix()
    local now = os.clock()
    if now < PhoenixGrace.activeUntil then
        return true  -- grace already active from earlier trigger
    end
    local phoenixTower = nil
    for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local t = towerBase.Parent
        if t and t:GetAttribute("EquippedType") == "Phoenix"
               and t:GetAttribute("PhoenixReady") == true
               and (t:GetAttribute("PhoenixCooldown") or 0) > 0 then
            phoenixTower = t
            break
        end
    end
    if not phoenixTower then return false end

    -- Consume: start cooldown, open grace
    local cd = phoenixTower:GetAttribute("PhoenixCooldown") or 0
    phoenixTower:SetAttribute("PhoenixReady", false)
    phoenixTower:SetAttribute("PhoenixCdRemaining", cd)
    phoenixTower:SetAttribute("PhoenixGraceRemaining", PHOENIX_GRACE_DURATION)

    -- Big fire ring at heart + floor-level AOE indicator
    local heart = getHeart()
    local waypoints = getWaypoints()
    if heart then
        spawnFireVFX(heart.Position + Vector3.new(0, 1.5, 0), 3.0, 4.0)
        spawnPhoenixAOEFloorFire(heart.Position, PHOENIX_AOE_RADIUS, PHOENIX_GRACE_DURATION)
    end

    -- Start burn-in-place on all AOE mobs NOW. They'll transition to the
    -- limbo queue after PHOENIX_BURN_IN_PLACE_DURATION (handled in updateMobs).
    if heart and #waypoints > 0 then
        capturePhoenixAOEMobs(now, heart, waypoints)
    end

    PhoenixGrace.activeUntil = now + PHOENIX_GRACE_DURATION
    print(("[Waves] Phoenix consumed — cooldown %ds (AOE %d studs, %.1fs grace)"):format(
        cd, PHOENIX_AOE_RADIUS, PHOENIX_GRACE_DURATION))
    return true
end


-- damageMob(mob, amount, sourceTower, isChainDamage)
--   sourceTower: the tower that originated this damage (used to read Detonator
--                attributes off the killer for the on-death AOE). Optional.
--   isChainDamage: true when this hit is itself a Detonator AOE result; we
--                  set this to prevent infinite Detonator chains.
local function damageMob(mob, amount, sourceTower, isChainDamage)
    local data = activeMobs[mob]
    if not data then return false end
    if data._phoenixQueued then return false end  -- mob is in limbo, invulnerable
    data.hp = data.hp - amount
    spawnDamageNumber(mob.Position, amount)
    if data.hpFill then
        data.hpFill.Size = UDim2.new(math.max(0, data.hp / data.maxHp), -2, 1, -2)
    end
    if data.hpText then
        data.hpText.Text = string.format("%d / %d", math.max(0, math.floor(data.hp)), data.maxHp)
    end

    -- Final boss minigame: fire a phase each time HP crosses 75%, 50%, 25% —
    -- but ONLY if the previous phase's blobs aren't still on screen (i.e. we're
    -- past the tap window). If the boss takes a huge HP drop while a phase is
    -- already active, the intermediate threshold will fire AS SOON AS the
    -- previous tap window ends, and we skip ahead to the lowest met threshold
    -- so we don't backfire phase-1 after the player just tapped phase-2.
    if mob == FinalBossState.instance and data.hp > 0 then
        local hpFrac = data.hp / data.maxHp
        local now = os.clock()
        -- A phase is "active" if it's either winding up OR the tap window is open.
        local windupActive = now < FinalBossState.windupUntil
        local tapWindowActive = (now - FinalBossState.lastPhaseFire) < Config.finalBossTargetWindow
        local phaseActive = windupActive or tapWindowActive or FinalBossState.pendingPhase ~= nil
        if not phaseActive then
            -- Find the LOWEST threshold (deepest into HP) that's been met
            -- but not yet triggered.
            local fireIndex = nil
            for i, threshold in ipairs(Config.finalBossPhaseThresholds) do
                if hpFrac <= threshold and not FinalBossState.triggeredPhases[i] then
                    fireIndex = i  -- keep overwriting; last one wins = deepest
                end
            end
            if fireIndex then
                -- Mark every untriggered threshold up to and including this
                -- one as triggered, so we don't backfire earlier phases.
                for i = 1, fireIndex do
                    FinalBossState.triggeredPhases[i] = true
                end
                -- Start the wind-up. Actual BossPhase (tap spots) fires later
                -- when updateMobs sees windupUntil has elapsed. Pass the boss
                -- position to the client so it knows where to launch spots FROM.
                FinalBossState.windupUntil  = now + Config.finalBossWindupDuration
                FinalBossState.pendingPhase = fireIndex
                remoteBossWindup:FireAllClients({
                    phase          = fireIndex,
                    duration       = Config.finalBossWindupDuration,
                    bossPosition   = mob.Position,
                })
            end
        end
    end

    if data.hp <= 0 then
        -- DETONATOR: if the killing tower has Detonator attributes set, spawn
        -- a violent shrapnel burst at the dying mob's position and damage all
        -- OTHER mobs in radius. Damage scales with the EXPLODING mob's MAX HP
        -- (the bigger the mob you blow up, the bigger the boom). Skip if this
        -- damage was itself a chain reaction. Stun/knockback rolls also apply
        -- to chained mobs (apply BEFORE the damage so a kill doesn't strand
        -- the roll).
        if sourceTower and not isChainDamage then
            local detRadius = sourceTower:GetAttribute("DetonatorRadius")
            local detPct    = sourceTower:GetAttribute("DetonatorHpPct")
            if detRadius and detPct and detRadius > 0 and detPct > 0 then
                local detDamage = math.max(1, math.floor(data.maxHp * detPct + 0.5))
                local centerPos = mob.Position
                spawnDetonatorBurst(centerPos, detRadius)
                for other, _ in pairs(activeMobs) do
                    if other ~= mob and other.Parent then
                        if (other.Position - centerPos).Magnitude <= detRadius then
                            applyHitEffects(sourceTower, other)
                            damageMob(other, detDamage, sourceTower, true)  -- chain
                        end
                    end
                end
            end
        end

        if data.stunStars then
            for _, star in ipairs(data.stunStars) do star:Destroy() end
            data.stunStars = nil
        end
        if mob == FinalBossState.instance then
            FinalBossState.instance = nil
        end
        activeMobs[mob] = nil
        mob:Destroy()
        return true
    end
    return false
end

local function updateMobs(dt)
    -- Apply game-speed multiplier to time delta. All path movement (mob
    -- speeds along waypoints) uses dt — multiplying here scales the whole
    -- mob movement layer. Knockback below uses wall-clock so it visually
    -- stays the same brief slide regardless of game speed.
    dt = dt * gameSpeed
    local heart = getHeart()
    local waypoints = getWaypoints()
    local now = os.clock()

    -- Boss windup transition: once the windup timer expires, fire the actual
    -- BossPhase remote so the client spawns + launches the tap spots. This is
    -- intentionally done once per frame (not per mob) because it's a single
    -- global state transition, not per-mob logic.
    if FinalBossState.pendingPhase and now >= FinalBossState.windupUntil then
        local boss = FinalBossState.instance
        local bossPos = (boss and boss.Parent) and boss.Position or nil
        FinalBossState.lastPhaseFire = now
        remoteBossPhase:FireAllClients({
            phase          = FinalBossState.pendingPhase,
            targetCount    = Config.finalBossTargetsPerPhase,
            window         = Config.finalBossTargetWindow,
            bonusDuration  = Config.finalBossBonusDuration,
            bossPosition   = bossPos,
            webDuration    = Config.finalBossWebDuration,
        })
        FinalBossState.pendingPhase = nil
    end

    -- Phoenix queue: if the queue has mobs waiting to be released, process
    -- their timed spawn. See comment on PhoenixQueue declaration.
    processPhoenixQueue(now)

    -- Phoenix grace sweep: while grace is active, any mob that enters the
    -- AOE (and isn't already queued) gets captured into the respawn queue.
    if now < PhoenixGrace.activeUntil and heart and #waypoints > 0 then
        capturePhoenixAOEMobs(now, heart, waypoints)
    end

    for mob, data in pairs(activeMobs) do
        if not mob.Parent then
            activeMobs[mob] = nil
        elseif data._phoenixQueued then
            -- In Phoenix limbo: hidden offscreen, waiting to be released
            -- from the queue. Skip all update logic (movement, HP bar, etc.)
            -- The queue scheduler moves the mob back into play when due.
        elseif data._phoenixBurning then
            -- Phoenix burn-in-place phase: mob catches fire and freezes for
            -- 0.5s so players see the effect register, towers can get shots
            -- in, and then it transitions to limbo (queue). Still targetable
            -- and damageable during this window (tower-targeting check uses
            -- _phoenixQueued, not _phoenixBurning).
            if data.bbAnchor then
                data.bbAnchor.CFrame = mob.CFrame + Vector3.new(0, data.size * 0.9, 0)
            end
            if now >= (data._phoenixBurnUntil or 0) then
                moveToPhoenixLimbo(mob, data)
            end
        else
            -- Knockback slide (active while data.knockback set): overrides path
            local knocking = false
            if data.knockback then
                local kb = data.knockback
                local t = (now - kb.startTime) / kb.duration
                if t >= 1 then
                    -- Slide done: snap to final, clear state
                    mob.CFrame = CFrame.new(kb.toPos)
                    data.knockback = nil
                else
                    -- Interpolate: ease-out (1 - (1-t)^2)
                    local ease = 1 - (1 - t) * (1 - t)
                    local pos = kb.fromPos:Lerp(kb.toPos, ease)
                    mob.CFrame = CFrame.new(pos)
                    knocking = true
                end
            end

            local stunned = data.stunUntil and now < data.stunUntil
            -- Boss freezes during phase wind-up (the 1.2s stop-and-vibrate
            -- before the tap spots launch). Only applies to the final boss.
            local windingUp = (mob == FinalBossState.instance) and (now < FinalBossState.windupUntil)
            local targetIdx = data.waypointIndex
            local targetWp = waypoints[targetIdx]
            if targetWp then
                local current = mob.Position
                if not stunned and not knocking and not windingUp then
                    local target = targetWp.Position
                    target = Vector3.new(target.X, current.Y, target.Z)
                    local diff = target - current
                    local distance = diff.Magnitude
                    local stepDist = data.speed * dt
                    if stepDist >= distance then
                        mob.CFrame = CFrame.new(target)
                        data.waypointIndex = data.waypointIndex + 1
                        if data.waypointIndex > #waypoints then
                            if heart then
                                local hp = heart:GetAttribute("Health") or 0
                                local dmg = data.damage or data.maxHp
                                local inGrace = os.clock() < PhoenixGrace.activeUntil

                                if inGrace then
                                    -- Active Phoenix grace window: the per-frame
                                    -- AOE sweep normally catches mobs before they
                                    -- reach the heart; but if one slips through
                                    -- (frame-skip, boss knockback), we queue it
                                    -- here with its current HP so it also goes
                                    -- through the phoenix staggered respawn.
                                    capturePhoenixMob(mob, data, waypoints)
                                elseif tryConsumePhoenix() then
                                    -- Phoenix fired: this mob has been queued by
                                    -- capturePhoenixAOEMobs inside tryConsumePhoenix.
                                    -- Do nothing else.
                                else
                                    heart:SetAttribute("Health", math.max(0, hp - dmg))
                                    activeMobs[mob] = nil
                                    mob:Destroy()
                                end
                            else
                                activeMobs[mob] = nil
                                mob:Destroy()
                            end
                        end
                    else
                        local dir = diff.Unit
                        mob.CFrame = CFrame.new(current + dir * stepDist)
                    end
                end
                -- Always update HP bar anchor (so it tracks even when stunned/knocked)
                if data.bbAnchor and mob.Parent then
                    data.bbAnchor.CFrame = mob.CFrame + Vector3.new(0, data.size * 0.9, 0)
                end
                -- Stun stars: 3 small yellow parts orbiting above the mob's head
                if stunned then
                    if not data.stunStars then
                        local stars = {}
                        for i = 1, 3 do
                            local star = Instance.new("Part")
                            star.Name = "StunStar"
                            star.Shape = Enum.PartType.Ball
                            star.Size = Vector3.new(0.45, 0.45, 0.45)
                            star.Anchored = true
                            star.CanCollide = false
                            star.CastShadow = false
                            star.Material = Enum.Material.Neon
                            star.Color = Color3.fromRGB(255, 230, 60)
                            star.Parent = tdRoom
                            stars[i] = star
                        end
                        data.stunStars = stars
                    end
                    -- Orbit them around a point just above the mob's head
                    local ox = mob.Position.X
                    local oz = mob.Position.Z
                    local oy = mob.Position.Y + data.size * 0.9 + 0.3
                    local radius = data.size * 0.45
                    local angleBase = now * 4  -- orbit speed
                    for i, star in ipairs(data.stunStars) do
                        local a = angleBase + (i - 1) * (2 * math.pi / 3)
                        star.CFrame = CFrame.new(ox + math.cos(a) * radius, oy, oz + math.sin(a) * radius)
                    end
                else
                    if data.stunStars then
                        for _, star in ipairs(data.stunStars) do star:Destroy() end
                        data.stunStars = nil
                    end
                end
            else
                -- Out of waypoints — clean up any attached visuals
                if data.stunStars then
                    for _, star in ipairs(data.stunStars) do star:Destroy() end
                    data.stunStars = nil
                end
                activeMobs[mob] = nil
                mob:Destroy()
            end
        end
    end
end

------------------------------------------------------------
-- Tower firing
------------------------------------------------------------
-- Per-tower caches keyed by tower model. All three are cleaned by the
-- tower-removed signal below so destroyed towers (DevReset, manual sell,
-- etc.) don't slowly leak entries across runs.
local towerLastFire       = {}  -- [tower model] = os.clock() of last shot
local towerOwnerCache     = {}  -- [tower model] = Player (resolved once at first lookup)
local phoenixDisplayCd    = {}  -- [tower model] = last integer-second value written to attribute
local phoenixDisplayGrace = {}  -- [tower model] = float-precision grace remaining (wallclock)

-- The owner of a tower never changes after placement, so we resolve it once
-- via getTowerOwner and cache. Saves a per-frame Players:GetPlayerByUserId
-- call per tower.
local function getTowerOwner(towerModel)
    local cached = towerOwnerCache[towerModel]
    if cached and cached.Parent then return cached end
    local ownerId = towerModel:GetAttribute("Owner")
    if not ownerId then return nil end
    local p = Players:GetPlayerByUserId(ownerId)
    if p then towerOwnerCache[towerModel] = p end
    return p
end

-- Clean per-tower cache entries when a tower is removed. Without this,
-- DevReset destroys towers but the table entries linger across runs —
-- a slow leak. The tag is removed when the tower model is destroyed,
-- which fires GetInstanceRemovedSignal.
CollectionService:GetInstanceRemovedSignal(Tags.Tower):Connect(function(taggedPart)
    -- The tagged instance is the tower's BasePart, not the model. Walk
    -- both to be safe — caches might key on either depending on insertion site.
    local model = taggedPart.Parent
    if model then
        towerLastFire[model]      = nil
        towerOwnerCache[model]    = nil
        phoenixDisplayCd[model]   = nil
        phoenixDisplayGrace[model] = nil
    end
    towerLastFire[taggedPart]      = nil
    towerOwnerCache[taggedPart]    = nil
    phoenixDisplayCd[taggedPart]   = nil
    phoenixDisplayGrace[taggedPart] = nil
end)

local function updateTowers(towerList)
    local now = os.clock()
    for _, towerBase in ipairs(towerList) do
        local towerModel = towerBase.Parent
        if towerModel and towerModel.Parent then
            local shots = towerModel:GetAttribute("Shots") or 0
            -- Resolve owner once via the cache (cheap on subsequent frames)
            local owner = getTowerOwner(towerModel)
            local unlimited = owner and owner:GetAttribute("DevUnlimitedAmmo") == true
            if shots > 0 or unlimited then
                local baseDamage = towerModel:GetAttribute("Damage") or 10
                -- Per-player bonus damage (final boss minigame).
                local damage = baseDamage
                if owner then
                    local until_ = owner:GetAttribute("BonusDamageUntil") or 0
                    if now < until_ then
                        damage = baseDamage * Config.finalBossBonusMultiplier
                    end
                end
                local range    = towerModel:GetAttribute("Range")    or 25
                local fireRate = towerModel:GetAttribute("FireRate") or 1
                local aoeRadius = towerModel:GetAttribute("AoeRadius")
                local lastFire = towerLastFire[towerModel] or 0
                -- Effective fire rate scales with the global gameSpeed so
                -- towers shoot in proportion to mob movement during 2x/3x.
                local interval = 1 / (fireRate * gameSpeed)
                if now - lastFire >= interval then
                    local tp = towerBase.Position
                    local mode = towerModel:GetAttribute("TargetMode") or "First"
                    local target = findTarget(tp, range, mode)
                    if target then
                        -- Apply secondary effects (stun/knockback) BEFORE the
                        -- damage hit. If the damage kills the target, the mob
                        -- gets removed from activeMobs and applyHitEffects
                        -- becomes a no-op. Doing it first preserves the roll.
                        -- Each proc returns a count; for every proc we deal an
                        -- EXTRA hit of normal damage (so a stun-and-knockback
                        -- double-proc = 3 total damage hits in one shot).
                        local procs = applyHitEffects(towerModel, target)
                        damageMob(target, damage, towerModel)
                        for i = 1, procs do
                            damageMob(target, damage, towerModel)
                        end
                        fireBolt(tp + Vector3.new(0, 10, 0), target.Position, Color3.fromRGB(255, 120, 80))

                        if aoeRadius and aoeRadius > 0 then
                            local targetPos = target.Position
                            spawnAoeBurst(targetPos, aoeRadius)
                            for mob, _ in pairs(activeMobs) do
                                if mob ~= target and mob.Parent then
                                    if (mob.Position - targetPos).Magnitude <= aoeRadius then
                                        local mobProcs = applyHitEffects(towerModel, mob)
                                        damageMob(mob, damage, towerModel)
                                        for i = 1, mobProcs do
                                            damageMob(mob, damage, towerModel)
                                        end
                                    end
                                end
                            end
                        end

                        towerLastFire[towerModel] = now
                        if not unlimited then
                            towerModel:SetAttribute("Shots", shots - 1)
                        end
                    end
                end
            end
        end
    end
end

-- Phoenix attachment cooldown tick. Runs every frame from the main
-- Heartbeat connection at the bottom of this file. Gated on waveInProgress
-- so cooldowns only count game-time, not real-time.

-- Phoenix cooldowns tick down only while a wave is actively in progress
-- (per the design: "game time" excludes between-wave / upgrade picker).
-- When CdRemaining hits 0, the tower is marked PhoenixReady=true again.
--
-- The Phoenix GRACE window (post-trigger 5 seconds where mobs reaching the
-- heart get teleported back) ticks INDEPENDENTLY of waveInProgress and
-- uses wallclock — those teleports are happening regardless of game state
-- and the grace exists to cover physical mobs already at the heart.
--
-- Performance: maintain the float-precision cooldown in `phoenixDisplayCd`
-- (a script-local table, no replication). Only WRITE the attribute when
-- math.ceil(rem) changes — i.e. when a new integer second is crossed.
-- This drops the per-frame attribute write rate from 60Hz to ~1Hz, which
-- matters because attribute writes replicate to ALL clients. Over a
-- 12-minute Phoenix cooldown that's 43,200 → 720 messages saved.
-- Same precision-cache pattern is used for grace via phoenixDisplayGrace.

local function tickPhoenixCooldowns(dt, towerList)
    -- Both cooldown and grace tick wallclock, ungated. (Earlier the cooldown
    -- ticked only during waveInProgress with gameSpeed scaling — but that
    -- meant a player watching the HUD between waves would see it freeze,
    -- which read as a bug. Wallclock + ungated matches player intuition:
    -- "the indicator counts down at the rate it shows.")
    for _, towerBase in ipairs(towerList) do
        local t = towerBase.Parent
        if t and t:GetAttribute("EquippedType") == "Phoenix" then
            -- COOLDOWN tick
            if t:GetAttribute("PhoenixReady") == false then
                local rem = phoenixDisplayCd[t] or t:GetAttribute("PhoenixCdRemaining") or 0
                rem = rem - dt
                if rem <= 0 then
                    phoenixDisplayCd[t] = nil
                    t:SetAttribute("PhoenixCdRemaining", 0)
                    t:SetAttribute("PhoenixReady", true)
                else
                    phoenixDisplayCd[t] = rem
                    local prevDisplayed = t:GetAttribute("PhoenixCdRemaining") or 0
                    local newDisplayed = math.ceil(rem)
                    if newDisplayed ~= math.ceil(prevDisplayed) then
                        t:SetAttribute("PhoenixCdRemaining", newDisplayed)
                    end
                end
            end

            -- GRACE tick (wallclock, 0.1s precision write)
            local graceFloat = phoenixDisplayGrace[t] or t:GetAttribute("PhoenixGraceRemaining") or 0
            if graceFloat > 0 then
                graceFloat = graceFloat - dt
                if graceFloat <= 0 then
                    phoenixDisplayGrace[t] = nil
                    t:SetAttribute("PhoenixGraceRemaining", 0)
                else
                    phoenixDisplayGrace[t] = graceFloat
                    local prevTenths = math.floor((t:GetAttribute("PhoenixGraceRemaining") or 0) * 10 + 0.5)
                    local newTenths = math.floor(graceFloat * 10 + 0.5)
                    if newTenths ~= prevTenths then
                        t:SetAttribute("PhoenixGraceRemaining", newTenths / 10)
                    end
                end
            end
        end
    end
end


------------------------------------------------------------
-- Wave orchestration
------------------------------------------------------------
local currentWave = 0  -- 0 = not started / between waves
local waveInProgress = false
-- Set true by DevSkipWave handler. The spawn loop checks this before
-- spawning each new mob and bails early; remaining mobs are cleared in the
-- handler so the wave-clear poll fires immediately afterward.
local skipRequested = false
local waveEndPending = false

-- Monotonically-increasing token identifying the current wave-run. Every
-- call to runWave increments it; every spawner coroutine captures its
-- token at start and bails if the global token has moved on. This catches
-- races where DevSkipToBoss (or a future similar dev action) starts a new
-- run while an old spawner coroutine is still alive inside a task.wait.
-- Without this, the old spawner would wake up after its sleep and happily
-- spawn the next mob in its sequence — producing "a group spawned with
-- the boss."
local waveRunToken = 0

-- Game speed multiplier (1, 2, or 3). Scales mob movement, tower fire rate,
-- spawn intervals, and Phoenix cooldown ticking. The final-boss minigame's
-- tap window stays at REAL seconds (otherwise unwinnable at 3x).
-- NOTE: gameSpeed is forward-declared near the top of this file so the
-- updateMobs/updateTowers/tickPhoenixCooldowns closures can reach it.
-- This line is just initialization, not a new local.
gameSpeed = 1
local ALLOWED_SPEEDS = {[1] = true, [2] = true, [3] = true, [5] = true, [10] = true}

local function ensureRemoteEvent(name)
    local r = ReplicatedStorage:FindFirstChild(name)
    if not r then
        r = Instance.new("RemoteEvent")
        r.Name = name
        r.Parent = ReplicatedStorage
    end
    return r
end

local setGameSpeedRemote      = ensureRemoteEvent("SetGameSpeed")       -- client → server
local gameSpeedChangedRemote  = ensureRemoteEvent("GameSpeedChanged")   -- server → all clients

setGameSpeedRemote.OnServerEvent:Connect(function(_player, requested)
    if type(requested) ~= "number" then return end
    requested = math.floor(requested)
    if not ALLOWED_SPEEDS[requested] then return end
    if requested == gameSpeed then return end
    gameSpeed = requested
    gameSpeedChangedRemote:FireAllClients(gameSpeed)
    print(("[Waves] Game speed → %dx"):format(gameSpeed))
end)

-- Hand the current speed to any client that joins or asks (via PlayerAdded)
Players.PlayerAdded:Connect(function(p)
    task.wait(1)  -- let the client's listener wire up
    gameSpeedChangedRemote:FireClient(p, gameSpeed)
end)

local function broadcastWaveState()
    local payload = {
        map = StageState.currentMapName,
        stage = StageState.currentStage,
        wave = currentWave,
        totalWaves = #WAVES,
        mobsAlive = countActiveMobs(),
        inProgress = waveInProgress,
        finalBossActive = StageState.finalBossActive,
    }
    remoteWaveState:FireAllClients(payload)
end

local function runWave(waveIndex)
    if waveInProgress then return end
    local wave = WAVES[waveIndex]
    if not wave then return end
    local spawns = wave.spawns
    local hpMult = wave.hpMult or 1.0
    waveInProgress = true
    skipRequested = false  -- fresh wave; clear any leftover skip flag
    currentWave = waveIndex
    waveRunToken = waveRunToken + 1
    local myToken = waveRunToken
    broadcastWaveState()

    local waypoints = getWaypoints()
    task.spawn(function()
        for _, spawn in ipairs(spawns) do
            for i = 1, spawn.count do
                -- Token mismatch: another runWave or DevSkipToBoss started.
                -- Full abort — do NOT fall through to drain-loop + onWaveCleared.
                if waveRunToken ~= myToken then return end
                -- DevSkipWave: stop spawning, fall through to drain loop so
                -- onWaveCleared still fires.
                if skipRequested then break end
                local heart = getHeart()
                if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
                    waveInProgress = false
                    broadcastWaveState()
                    return
                end
                local mob = makeMob(spawn.mobType, waypoints, hpMult)
                if spawn.mobType == "finalboss" and mob then
                    FinalBossState.instance = mob
                    FinalBossState.triggeredPhases = {}
                    StageState.finalBossActive = true
                end
                broadcastWaveState()
                task.wait(spawn.interval / gameSpeed)
            end
            if waveRunToken ~= myToken then return end
            if skipRequested then break end
            task.wait(spawn.gap / gameSpeed)
        end
        -- All spawns done (or skipped) — wait for remaining mobs to die or leak
        while countActiveMobs() > 0 do
            if waveRunToken ~= myToken then return end
            local heart = getHeart()
            if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
                waveInProgress = false
                broadcastWaveState()
                return
            end
            task.wait(Config.waveClearedPollInterval)
            broadcastWaveState()
        end
        -- Wave cleared
        waveInProgress = false
        broadcastWaveState()
        onWaveCleared(waveIndex)
    end)
end

-- Helper: get the player's strongest tower's current Damage attribute,
-- so Damage cards can show flat damage added (e.g. "+12 damage").
-- Returns 0 if the player owns no towers yet.
-- Returns the BASE damage of the player's strongest tower. With additive
-- upgrades, the flat damage added per pick = base × (mult - 1), so this
-- (not the live value) is what feeds the "+X damage" card description.
local function getPlayerBaseDamage(player)
    local maxBase = 0
    for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local tower = towerBase.Parent
        if tower and tower:GetAttribute("Owner") == player.UserId then
            local d = tower:GetAttribute("DamageBase")
                  or tower:GetAttribute("Damage")  -- legacy fallback
                  or 0
            if d > maxBase then maxBase = d end
        end
    end
    return maxBase
end

-- RUN LUCK: numeric mapping for rarity names. Used by generateCardsForPlayer
-- to track running average across all cards offered this run, exposed to the
-- client via the RunLuckSum + RunLuckCount player attributes (and reset by
-- RunReset). Specials roll about as often as Exceptionals (8% vs 10%) and
-- are clearly mid-to-high value, so we score them at 3.
local RARITY_TO_SCORE = {
    Common = 1, Rare = 2, Exceptional = 3, Legendary = 4, Mythical = 5,
    Special = 3,
}

local function generateCardsForPlayer(player, waveIndex)
    local stats = {"Damage", "Range", "FireRate"}
    local currentDamage = getPlayerBaseDamage(player)

    local cards = {}
    local usedSpecials = {}  -- {[specialName]=true} — prevents duplicate Special cards
    -- ALWAYS produce one card per stat slot. Rarity is rolled per slot.
    -- If a slot rolls "Special", swap it for a Special bonus card instead,
    -- excluding any Special types already drawn earlier in this picker.
    for _, stat in ipairs(stats) do
        local rarity = rollRarity()
        local card
        if rarity == "Special" then
            card = rollSpecialCard(player, usedSpecials)
            usedSpecials[card.special] = true
        else
            card = rollStatCard(rarity, stat, currentDamage)
        end
        card.color = getTierColor(card.rarity)
        table.insert(cards, card)
    end

    local rerollsUsed = player:GetAttribute("RerollsUsed") or 0
    return {
        wave = waveIndex,
        cards = cards,
        rerollsRemaining = math.max(0, Config.maxRerollsPerStage - rerollsUsed),
    }
end

function onWaveCleared(waveIndex)
    -- If the heart died on the same tick the last mob died, don't offer
    -- upgrades — the game is already lost.
    local heart = getHeart()
    if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
        gameOverFired = true
        local completedStages = math.max(0, StageState.currentStage - 1)
        local wavesSoFar = completedStages * #WAVES + math.max(0, (currentWave or 1) - 1)
        remoteGameOver:FireAllClients({
            result = "lose",
            finalWave = waveIndex,
            totalWavesDefeated = wavesSoFar,
        })
        return
    end
    if gameOverFired then return end

    local isLastWaveOfStage = waveIndex >= #WAVES
    local isLastStage = StageState.currentStage >= TOTAL_STAGES
    local isFinalBossWave = waveIndex == 0  -- "wave 0" of the final fight (special)

    -- The final-final boss cleared → real game win
    if isFinalBossWave then
        StageState.finalBossActive = false
        FinalBossState.instance = nil
        -- Award persistent attachment(s) before the win modal fires so
        -- players see their inventory bumped on the next run.
        local bossDefeatedBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.BossDefeated)
        if bossDefeatedBindable then
            bossDefeatedBindable:Fire()
        end
        -- Total waves defeated across the whole run = stages × waves-per-stage
        -- plus one for the final boss fight itself.
        local totalDefeated = TOTAL_STAGES * #WAVES
        remoteGameOver:FireAllClients({
            result = "win",
            finalWave = waveIndex,  -- 0 sentinel (kept for back-compat)
            totalWavesDefeated = totalDefeated,
            defeatedFinalBoss = true,
        })
        return
    end

    if isLastWaveOfStage then
        if isLastStage then
            -- Stage 3's wave 5 cleared → spawn the final boss
            -- (heart NOT healed here; carry-over HP into the final fight)
            StageState.finalBossActive = true
            StageState.currentMapName = FINAL_BOSS_MAP_NAME
            -- Tell the hub to do the night reskin (sun sets, torches lit)
            remoteStageReskin:FireAllClients({
                stage     = StageState.currentStage,
                stageName = FINAL_BOSS_MAP_NAME,
                isNight   = true,
            })
            local stageAdvancedBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.StageAdvanced)
            if stageAdvancedBindable then
                -- Use stage 4 sentinel to signal "night / final boss" to the hub
                stageAdvancedBindable:Fire({stage = 4, mapId = StageState.currentMapId or 1})
            end
            -- Run the boss as its own "wave" using waveIndex 0 sentinel.
            task.spawn(function()
                local waypoints = getWaypoints()
                local mob = makeMob("finalboss", waypoints, 1.0)
                if mob then
                    FinalBossState.instance = mob
                    FinalBossState.triggeredPhases = {}
                end
                broadcastWaveState()
                -- Wait for boss death OR heart death
                while FinalBossState.instance and FinalBossState.instance.Parent do
                    if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
                        return  -- heart died; main loop's gameOver handler takes over
                    end
                    task.wait(Config.waveClearedPollInterval)
                end
                onWaveCleared(0)  -- final boss dead → win
            end)
        else
            -- Stages 1 and 2: fire StageCleared modal (heal + transition)
            StageState.inTransition = true
            remoteStageCleared:FireAllClients({
                stage          = StageState.currentStage,
                nextStage      = StageState.currentStage + 1,
                totalStages    = TOTAL_STAGES,
                autoContinueIn = Config.stageContinueAutoDelay,
            })
            task.delay(Config.stageContinueAutoDelay, function()
                if StageState.inTransition then
                    advanceStage()
                end
            end)
        end
        return
    end

    -- Mid-stage wave clear → offer upgrade picks
    for _, player in ipairs(Players:GetPlayers()) do
        remoteShowUpgrades:FireClient(player, generateCardsForPlayer(player, waveIndex))
    end
end

-- Advance from the current stage to the next: heal heart, broadcast reskin
-- to the hub server (which animates sun + grows trees), reset wave counter
-- to 0, restart wave 1 after a short countdown.
function advanceStage()
    if not StageState.inTransition then return end
    StageState.inTransition = false
    StageState.currentStage = StageState.currentStage + 1
    -- Heal heart to full (the only stage reward)
    local heart = getHeart()
    if heart then
        local maxHp = heart:GetAttribute("MaxHealth") or 500
        heart:SetAttribute("Health", maxHp)
    end
    -- Reset rerolls for the new stage
    for _, p in ipairs(Players:GetPlayers()) do
        p:SetAttribute("RerollsUsed", 0)
    end
    -- Update the map name for the HUD if the stage has its own name
    local cfg = Stages[StageState.currentStage]
    if cfg and cfg.name then
        StageState.currentMapName = cfg.name
    end
    -- Tell the hub to do the visual transition
    remoteStageReskin:FireAllClients({
        stage    = StageState.currentStage,
        stageName = (cfg and cfg.name) or "",
    })
    -- Also notify the hub's server-side handler (geometry changes, lighting)
    local stageAdvancedBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.StageAdvanced)
    if stageAdvancedBindable then
        stageAdvancedBindable:Fire({stage = StageState.currentStage, mapId = StageState.currentMapId or 1})
    end
    -- Reset wave counter and broadcast countdown to next wave
    currentWave = 0
    remoteWaveState:FireAllClients({
        map = StageState.currentMapName,
        stage = StageState.currentStage,
        wave = 0, totalWaves = #WAVES, mobsAlive = 0,
        inProgress = false,
        pendingCountdown = Config.upgradePickToNextWaveDelay,
    })
    task.delay(Config.upgradePickToNextWaveDelay, function()
        if not waveInProgress and not gameOverFired then
            runWave(1)
        end
    end)
    print(("[Waves] Advanced to stage %d (%s)"):format(StageState.currentStage, (cfg and cfg.name) or "?"))
end

-- Player tapped Continue on the stage clear modal. We allow any player to
-- advance; the others' modals will auto-dismiss when the next wave starts.
remoteStageContinue.OnServerEvent:Connect(function(player)
    if not StageState.inTransition then return end
    advanceStage()
end)

-- Reroll handler: a player asks for a fresh set of 3 cards. Capped at
-- Config.maxRerollsPerStage per stage (cleared on DevReset).
local rerollRemote = ReplicatedStorage:WaitForChild(Remotes.Names.RerollUpgrades)
rerollRemote.OnServerEvent:Connect(function(player, waveIndex)
    if type(waveIndex) ~= "number" then return end
    local rerollsUsed = player:GetAttribute("RerollsUsed") or 0
    if rerollsUsed >= Config.maxRerollsPerStage then return end
    player:SetAttribute("RerollsUsed", rerollsUsed + 1)
    remoteShowUpgrades:FireClient(player, generateCardsForPlayer(player, waveIndex))
    print(("[Waves] %s rerolled upgrades (%d/%d used)"):format(
        player.Name, rerollsUsed + 1, Config.maxRerollsPerStage))
end)

-- Free reward bindable: hub server fires this when a player places their first
-- tower of the run. Generates a normal card set and shows the picker.
local giveFreeRewardBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.GiveFreeReward)
if not giveFreeRewardBindable then
    giveFreeRewardBindable = Instance.new("BindableEvent")
    giveFreeRewardBindable.Name = Remotes.Names.GiveFreeReward
    giveFreeRewardBindable.Parent = ReplicatedStorage
end
giveFreeRewardBindable.Event:Connect(function(player)
    if not player or not player:IsA("Player") then return end
    -- Use waveIndex 0 since this is pre-wave; the picker just shows cards.
    remoteShowUpgrades:FireClient(player, generateCardsForPlayer(player, 0))
    print(("[Waves] Free reward granted to %s (first tower placed)"):format(player.Name))
end)

------------------------------------------------------------
-- Final boss minigame: client fires once when ALL 4 blobs tapped in time
-- → grants 5s of bonus damage. No stacking.
------------------------------------------------------------
remoteBossTargetTap.OnServerEvent:Connect(function(player)
    if not StageState.finalBossActive then return end
    local now = os.clock()
    -- Same correctness fix as the stun timer: bonus damage should last
    -- `finalBossBonusDuration` GAME-seconds. Divide by gameSpeed so the
    -- wallclock window shrinks proportionally at 2x/3x.
    local until_ = now + (Config.finalBossBonusDuration / gameSpeed)
    -- Don't shorten an existing longer bonus; otherwise extend
    local existing = player:GetAttribute("BonusDamageUntil") or 0
    if existing < until_ then
        player:SetAttribute("BonusDamageUntil", until_)
    end
    print(("[Waves] %s completed boss minigame → %.1fs game-time bonus"):format(
        player.Name, Config.finalBossBonusDuration))
end)

-- Client fires this when the tap window expires without all spots tapped.
-- Server broadcasts BossWeb back to that player for the web overlay and
-- movement freeze. The client side handles the actual movement block —
-- server trusts it because the penalty is cosmetic/QoL, not a loophole.
remoteBossPhaseMiss.OnServerEvent:Connect(function(player)
    if not StageState.finalBossActive then return end
    remoteBossWeb:FireClient(player, {
        duration = Config.finalBossWebDuration,
    })
    print(("[Waves] %s missed boss phase → webbed for %ds"):format(
        player.Name, Config.finalBossWebDuration))
end)

------------------------------------------------------------
-- Apply a picked upgrade to the player's core towers
------------------------------------------------------------
-- applyUpgrade(player, upgrade): apply an upgrade payload to the player's
-- towers as if they had just picked it from the upgrade picker. Updates
-- RUN LUCK tracking. Used by the remoteUpgradePicked handler AND by the
-- dev "skip to boss" path (which synthesizes picks server-side).
--
-- Upgrade payload shape (matches what generateCardsForPlayer produces):
--   stat card:    {kind="stat", stat=..., multiplier=..., rarity=..., description=...}
--   special card: {kind="special", special=..., rarity="Special", description=...}
local function applyUpgrade(player, upgrade)
    if type(upgrade) ~= "table" then return end
    local kind = upgrade.kind or "stat"  -- legacy cards default to stat

    -- RUN LUCK tracking: score this pick by its rarity. Validation: trust
    -- only the known rarity names; anything else (or missing) scores 1
    -- so a malicious client can't inflate by sending rarity="Mythical".
    -- Score scale matches RARITY_TO_SCORE used elsewhere: Common=1 ... Mythical=5,
    -- Special=3 (Specials sit between Exceptional and Legendary in drop weight).
    do
        local pickedScore = RARITY_TO_SCORE[upgrade.rarity] or 1
        local prevSum   = player:GetAttribute("RunLuckSum")   or 0
        local prevCount = player:GetAttribute("RunLuckCount") or 0
        player:SetAttribute("RunLuckSum",   prevSum + pickedScore)
        player:SetAttribute("RunLuckCount", prevCount + 1)
    end

    -- STAT UPGRADE: ADDITIVE bonus percentages. Each pick adds (mult-1)*100
    -- to a cumulative ${Stat}BonusPct attribute, then recomputes the live
    -- stat from the immutable base. This avoids exponential compounding
    -- (10 stacked +20% picks = +200% bonus, NOT 1.20^10 = +519%).
    if kind == "stat" then
        local stat = upgrade.stat
        local mult = tonumber(upgrade.multiplier)
        if not stat or not mult then return end
        if stat ~= "Damage" and stat ~= "Range" and stat ~= "FireRate" then return end
        if mult < 1 or mult > 5 then return end
        local addedPct = (mult - 1) * 100
        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local towerModel = towerBase.Parent
            if towerModel and towerModel:GetAttribute("Owner") == player.UserId then
                -- Fall back to the current value as the "base" for legacy
                -- towers placed before the BaseStat snapshots existed.
                local baseVal = towerModel:GetAttribute(stat .. "Base")
                if not baseVal then
                    baseVal = towerModel:GetAttribute(stat) or 0
                    towerModel:SetAttribute(stat .. "Base", baseVal)
                end
                local curBonusPct = towerModel:GetAttribute(stat .. "BonusPct") or 0
                local newBonusPct = curBonusPct + addedPct
                towerModel:SetAttribute(stat .. "BonusPct", newBonusPct)
                towerModel:SetAttribute(stat, baseVal * (1 + newBonusPct / 100))
            end
        end
        print(("[Waves] %s picked %s upgrade: %s (+%g%% → cumulative %s bonus)"):format(
            player.Name, upgrade.rarity or "?", upgrade.description or "?",
            addedPct, stat))

    -- SPECIAL: AOE / Knockback / Stun / AmmoCapacity
    elseif kind == "special" then
        local special = upgrade.special
        local effect = SPECIAL_EFFECTS[special]
        if not effect then return end

        if special == "AmmoCapacity" then
            -- Bump the player's carry cap by +playerCarryDelta. Fallback
            -- mirrors the hub's starting capacity (15).
            local curCarry = player:GetAttribute("MaxCarry") or 15
            player:SetAttribute("MaxCarry", curCarry + effect.playerCarryDelta)
            -- Double every owned tower's MaxShots (cap only — current Shots unchanged)
            for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                local towerModel = towerBase.Parent
                if towerModel and towerModel:GetAttribute("Owner") == player.UserId then
                    local maxShots = towerModel:GetAttribute("MaxShots") or 50
                    towerModel:SetAttribute("MaxShots", math.floor(maxShots * effect.towerShotsMult + 0.5))
                end
            end
        else
            -- AOE / Knockback / Stun: stack on each owned tower
            for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                local towerModel = towerBase.Parent
                if towerModel and towerModel:GetAttribute("Owner") == player.UserId then
                    local current = towerModel:GetAttribute(effect.attr)
                    if current then
                        towerModel:SetAttribute(effect.attr, current + effect.increment)
                    else
                        towerModel:SetAttribute(effect.attr, effect.base)
                    end
                end
            end
        end
        print(("[Waves] %s picked SPECIAL: %s"):format(player.Name, special))
    end
end

remoteUpgradePicked.OnServerEvent:Connect(function(player, upgrade)
    applyUpgrade(player, upgrade)

    -- Auto-start the next wave 3 seconds after picking
    if currentWave < #WAVES and not waveInProgress and not gameOverFired then
        remoteWaveState:FireAllClients({
            wave = currentWave, totalWaves = #WAVES, mobsAlive = 0,
            inProgress = false, pendingCountdown = Config.upgradePickToNextWaveDelay,
        })
        task.delay(Config.upgradePickToNextWaveDelay, function()
            if not waveInProgress and not gameOverFired and currentWave < #WAVES then
                runWave(currentWave + 1)
            end
        end)
    end
end)

------------------------------------------------------------
-- DEV: add a Stun stack to all of the calling player's towers. Mirrors
-- what picking a Stun special card does (uses SPECIAL_EFFECTS["Stun"]
-- base/increment), but bypasses the upgrade-picked path so it doesn't
-- inflate RUN LUCK or affect the wave-progression flow. Used from the
-- dev panel for testing the stun mechanic without waiting on RNG.
------------------------------------------------------------
remoteDevAddStun.OnServerEvent:Connect(function(player)
    local effect = SPECIAL_EFFECTS["Stun"]
    if not effect then return end
    local touched = 0
    for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local towerModel = towerBase.Parent
        if towerModel and towerModel:GetAttribute("Owner") == player.UserId then
            local current = towerModel:GetAttribute(effect.attr)
            if current then
                towerModel:SetAttribute(effect.attr, current + effect.increment)
            else
                towerModel:SetAttribute(effect.attr, effect.base)
            end
            touched = touched + 1
        end
    end
    print(("[Waves] DEV: %s added Stun stack to %d tower(s)"):format(player.Name, touched))
end)

------------------------------------------------------------
-- DEV: reset all per-tower cooldowns AND timed buffs for the calling
-- player. Useful for testing Phoenix without waiting 12+ minutes between
-- triggers, and for clearing leftover BonusDamageUntil from boss minigame
-- testing. Iterates only towers owned by the caller.
------------------------------------------------------------
remoteDevResetCd.OnServerEvent:Connect(function(player)
    local touched = 0
    for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local t = towerBase.Parent
        if t and t:GetAttribute("Owner") == player.UserId then
            -- Phoenix: ready immediately, no cooldown, no active grace.
            -- Set the attributes regardless of EquippedType — cheap, and
            -- harmless on towers without Phoenix (they just get unused
            -- attributes set to 0/true, which they ignore).
            if t:GetAttribute("EquippedType") == "Phoenix" then
                t:SetAttribute("PhoenixReady", true)
                t:SetAttribute("PhoenixCdRemaining", 0)
                t:SetAttribute("PhoenixGraceRemaining", 0)
                phoenixDisplayCd[t]    = nil
                phoenixDisplayGrace[t] = nil
            end
            touched = touched + 1
        end
    end
    -- Server-side grace state (for the actual mob-teleport check) — clear it
    -- too so a "reset" really means everything is cold.
    PhoenixGrace.activeUntil = 0
    -- Final-boss bonus damage timer (set by completing the tap minigame).
    player:SetAttribute("BonusDamageUntil", 0)
    print(("[Waves] DEV: %s reset cooldowns on %d tower(s)"):format(player.Name, touched))
end)

------------------------------------------------------------
-- DEV: skip to the current stage's boss, with the player's towers
-- upgraded as if they'd played to that wave with average luck (display = 5
-- on the luck meter, which corresponds to a "greedy best-of-3" pick
-- average score of 2.71 per pick).
--
-- Pick simulation rules (each iteration):
--   1. Call generateCardsForPlayer to roll 3 cards using normal RNG.
--   2. Sort cards by rarity score (high → low), break ties by index.
--   3. Walk the sorted list: skip Range stat cards if the player's
--      cumulative RangeBonusPct on any owned tower is already >= 60%.
--      This matches the user's playstyle: never overcap on Range.
--   4. Apply the first non-skipped card via applyUpgrade (which
--      handles tower attribute updates AND RUN LUCK tracking).
--
-- Then we stop any in-progress wave, clear active mobs, and spawn just
-- the boss (skipping the stage's wave-5 mob spawns). On boss death the
-- normal wave-5-cleared path runs (stage transition or final boss).
------------------------------------------------------------

-- Score map for "which card is best" — separate from RARITY_TO_SCORE
-- because here Special clearly outranks Exceptional/Rare for picking
-- purposes (a stacking effect is more impactful than a +20% stat bump).
-- Used only inside the dev simulator.
local DEV_PICK_SCORE = {
    Mythical = 6,
    Special = 5,
    Legendary = 4,
    Exceptional = 3,
    Rare = 2,
    Common = 1,
}

local function getPlayerRangeBonus(player)
    -- Return the highest RangeBonusPct across the player's owned towers.
    -- (They should all be the same since picks apply to all owned towers,
    --  but be defensive.)
    local maxBonus = 0
    for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local t = towerBase.Parent
        if t and t:GetAttribute("Owner") == player.UserId then
            local b = t:GetAttribute("RangeBonusPct") or 0
            if b > maxBonus then maxBonus = b end
        end
    end
    return maxBonus
end

local function simulateOnePick(player)
    -- Use the existing card generator so the rarity rolls match real picks.
    -- Pass waveIndex=0 (it's only used for the payload return field, which we discard).
    local payload = generateCardsForPlayer(player, 0)
    local cards = payload.cards or {}
    if #cards == 0 then return end

    -- Sort indexes by score, descending. (Sort indexes not cards so we
    -- preserve original order for tie-break stability if desired.)
    local order = {}
    for i = 1, #cards do order[i] = i end
    table.sort(order, function(a, b)
        local sa = DEV_PICK_SCORE[cards[a].rarity] or 0
        local sb = DEV_PICK_SCORE[cards[b].rarity] or 0
        if sa ~= sb then return sa > sb end
        return a < b
    end)

    local rangeBonus = getPlayerRangeBonus(player)
    local pickIdx = nil
    for _, i in ipairs(order) do
        local c = cards[i]
        local isRange = (c.kind == "stat" and c.stat == "Range")
        local isAmmoCap = (c.kind == "special" and c.special == "AmmoCapacity")
        if isRange and rangeBonus >= 60 then
            -- Skip — Range is already capped per the user's preference
        elseif isAmmoCap then
            -- Skip — AmmoCapacity is a QoL pick that doesn't contribute to
            -- DPS, and the dev simulator is meant to produce a combat-ready
            -- tower to fight the boss. Leave it for the real player to pick.
        else
            pickIdx = i
            break
        end
    end

    -- Fallback: if every card was skipped (extremely rare), pick the first.
    if not pickIdx then pickIdx = order[1] end

    applyUpgrade(player, cards[pickIdx])
end

remoteDevSkipToBoss.OnServerEvent:Connect(function(player)
    -- Cancel any in-progress wave, clear all mobs and stage-boss state.
    -- Bumping waveRunToken is the important part: it invalidates any
    -- still-alive spawner coroutine from the prior wave, so a mob group
    -- waking up from task.wait(spawn.interval) won't continue spawning
    -- alongside the boss.
    skipRequested = true
    waveInProgress = false
    waveRunToken = waveRunToken + 1
    local myToken = waveRunToken
    clearAllMobs()
    FinalBossState.instance = nil
    FinalBossState.triggeredPhases = {}
    FinalBossState.windupUntil = 0
    FinalBossState.pendingPhase = nil

    -- How many picks SHOULD the player have done by the start of this
    -- stage's wave 5? Each stage gives 4 pickers (after waves 1-4). So
    -- by the boss of stage S, the player has had (S-1)*4 + 4 = S*4 picks
    -- from prior stages and current stage waves 1-4.
    local targetPicks = StageState.currentStage * 4
    local currentPicks = player:GetAttribute("RunLuckCount") or 0
    local picksNeeded = math.max(0, targetPicks - currentPicks)

    -- Synthesize the picks.
    for _ = 1, picksNeeded do
        simulateOnePick(player)
    end

    print(("[Waves] DEV: %s skipping to stage %d boss; simulated %d pick(s)"):format(
        player.Name, StageState.currentStage, picksNeeded))

    -- Now spawn the boss as if the wave-5 mob spawns had completed.
    -- Reuses the wave-5-cleared path: when the boss dies, onWaveCleared(5)
    -- runs and triggers the appropriate next step (stage transition for
    -- stages 1-2, final boss spawn for stage 3).
    currentWave = #WAVES  -- = 5
    waveInProgress = true
    skipRequested = false
    broadcastWaveState()

    task.spawn(function()
        local waypoints = getWaypoints()
        makeMob("boss", waypoints, 1.0)  -- waveMult ignored for bosses anyway
        broadcastWaveState()
        -- Wait for boss death OR heart death OR another token bump
        while countActiveMobs() > 0 do
            if waveRunToken ~= myToken then return end
            local heart = getHeart()
            if not heart or (heart:GetAttribute("Health") or 0) <= 0 then
                waveInProgress = false
                broadcastWaveState()
                return
            end
            task.wait(Config.waveClearedPollInterval)
            broadcastWaveState()
        end
        if waveRunToken ~= myToken then return end
        waveInProgress = false
        broadcastWaveState()
        onWaveCleared(#WAVES)
    end)
end)

------------------------------------------------------------
-- Game over detection (heart dies). gameOverFired is forward-declared at
-- the top of the file so onWaveCleared, advanceStage, the upgrade-picked
-- handler, and this poll task all share the SAME local. This line is just
-- initialization, not a new local.
------------------------------------------------------------
gameOverFired = false
task.spawn(function()
    while true do
        task.wait(0.5)
        local heart = getHeart()
        if heart and not gameOverFired then
            local hp = heart:GetAttribute("Health") or 0
            if hp <= 0 then
                gameOverFired = true
                clearAllMobs()
                waveInProgress = false
                broadcastWaveState()
                -- Total waves cleared so far = (completed stages × #WAVES)
                -- plus current wave minus 1 (wave in progress wasn't cleared).
                local completedStages = math.max(0, StageState.currentStage - 1)
                local wavesSoFar = completedStages * #WAVES + math.max(0, (currentWave or 1) - 1)
                remoteGameOver:FireAllClients({
                    result = "lose",
                    finalWave = currentWave,
                    totalWavesDefeated = wavesSoFar,
                })
            end
        end
    end
end)

-- Reset gameOverFired when DevReset fires (so you can restart after losing)
local devResetRemote = ReplicatedStorage:WaitForChild(Remotes.Names.DevReset)
devResetRemote.OnServerEvent:Connect(function(player)
    gameOverFired = false
    clearAllMobs()
    currentWave = 0
    waveInProgress = false
    broadcastWaveState()
end)

-- DEV: Skip Wave — kill all active mobs so the natural wave-cleared logic
-- fires. Works during waves (skips the rest) and during the final boss
-- (instakills the boss → triggers victory). No-op if no mobs alive.
local devSkipWaveRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.DevSkipWave)
if not devSkipWaveRemote then
    devSkipWaveRemote = Instance.new("RemoteEvent")
    devSkipWaveRemote.Name = Remotes.Names.DevSkipWave
    devSkipWaveRemote.Parent = ReplicatedStorage
end
devSkipWaveRemote.OnServerEvent:Connect(function(player)
    print(("[Dev] %s pressed Skip Wave"):format(player.Name))
    -- Tell the spawn loop to stop spawning new mobs THIS wave
    skipRequested = true
    -- Wipe everything currently alive so the post-spawn drain loop completes
    -- immediately and onWaveCleared fires next poll.
    for mob, data in pairs(activeMobs) do
        if mob and mob.Parent then
            data.hp = 0
            if data.hpFill then data.hpFill:Destroy() end
            if data.hpText then data.hpText:Destroy() end
            if data.bbAnchor then data.bbAnchor:Destroy() end
            if mob == FinalBossState.instance then
                FinalBossState.instance = nil
            end
            mob:Destroy()
            activeMobs[mob] = nil
        end
    end
    broadcastWaveState()
end)

-- DEV: Unlimited Ammo — toggle a per-player flag. updateTowers reads it
-- via the tower's owner and skips Shots decrement when set.
local devUnlimitedAmmoRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.DevUnlimitedAmmo)
if not devUnlimitedAmmoRemote then
    devUnlimitedAmmoRemote = Instance.new("RemoteEvent")
    devUnlimitedAmmoRemote.Name = Remotes.Names.DevUnlimitedAmmo
    devUnlimitedAmmoRemote.Parent = ReplicatedStorage
end
devUnlimitedAmmoRemote.OnServerEvent:Connect(function(player, enabled)
    player:SetAttribute("DevUnlimitedAmmo", enabled and true or false)
    print(("[Dev] %s toggled Unlimited Ammo: %s"):format(
        player.Name, tostring(enabled and true or false)))
end)

------------------------------------------------------------
-- Wave start request from client
------------------------------------------------------------
remoteWaveStart.OnServerEvent:Connect(function(player)
    if waveInProgress then return end
    if gameOverFired then return end
    local nextWave = currentWave + 1
    if nextWave > #WAVES then return end
    print(("[Waves] %s started wave %d"):format(player.Name, nextWave))
    runWave(nextWave)
end)

-- Auto-start listener: hub server fires this when a player places their first
-- tower, with a 5 second delay. Triggers wave 1 just like manual start.
local autoStartBindable = ReplicatedStorage:WaitForChild(Remotes.Names.WaveAutoStart)
autoStartBindable.Event:Connect(function(player)
    if waveInProgress then return end
    if gameOverFired then return end
    if currentWave ~= 0 then return end  -- only auto-start the VERY first wave
    print(("[Waves] Auto-starting wave 1 (triggered by %s)"):format(player.Name))
    runWave(1)
end)

-- RunReset listener: hub fires this on DevReset so wave system fully resets
-- its run/stage state in addition to the hub's tower/grid/heart resets.
local runResetBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.RunReset)
if not runResetBindable then
    runResetBindable = Instance.new("BindableEvent")
    runResetBindable.Name = Remotes.Names.RunReset
    runResetBindable.Parent = ReplicatedStorage
end
runResetBindable.Event:Connect(function()
    StageState.currentStage = 1
    StageState.currentMapId   = 1
    StageState.currentMapName = (Stages[1] and Stages[1].name) or "Crook of the Tree (Morning)"
    StageState.inTransition = false
    StageState.finalBossActive = false
    FinalBossState.instance = nil
    FinalBossState.triggeredPhases = {}
    FinalBossState.lastPhaseFire = 0
    FinalBossState.windupUntil = 0
    FinalBossState.pendingPhase = nil
    currentWave = 0
    waveInProgress = false
    gameOverFired = false
    -- Bump the token so any in-flight wave spawner sees it's been replaced
    -- and aborts on its next iteration. Prevents a mob group from a
    -- pre-reset wave spawning into the post-reset game.
    waveRunToken = waveRunToken + 1
    -- Clear any active mobs (hub will have already destroyed towers)
    clearAllMobs()
    -- Reset per-player RUN LUCK tracking so each new run starts fresh
    for _, p in ipairs(Players:GetPlayers()) do
        p:SetAttribute("RunLuckSum", 0)
        p:SetAttribute("RunLuckCount", 0)
    end
    print("[Waves] RunReset: stage→1, mobs cleared, state cleared, run luck reset")
end)

------------------------------------------------------------
-- SwitchMap listener: hub fires this when the player walks through a
-- map portal. Sets the active map id, broadcasts wave state so client
-- HUDs update, clears active mobs and stage state for the new map's
-- wave 1 to start fresh. Heart HP is owned per-map (set at map build
-- time in the hub) so we don't touch it here.
--
-- Payload: {mapId = 2, mapName = "Climbing the Tree"}
------------------------------------------------------------
local switchMapBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
if not switchMapBindable then
    switchMapBindable = Instance.new("BindableEvent")
    switchMapBindable.Name = Remotes.Names.SwitchMap
    switchMapBindable.Parent = ReplicatedStorage
end
switchMapBindable.Event:Connect(function(payload)
    if not payload or not payload.mapId then return end
    local newId = payload.mapId
    local newName = payload.mapName or ("Map " .. tostring(newId))

    -- Bump the wave run token so any in-flight spawner from the prior map
    -- bails on its next iteration and doesn't keep spawning into map 2.
    waveRunToken = waveRunToken + 1
    waveInProgress = false
    skipRequested = true
    gameOverFired = false  -- reset — switching maps is a clean slate (also covers dev-teleporting-after-death)
    clearAllMobs()
    FinalBossState.instance = nil
    FinalBossState.triggeredPhases = {}
    FinalBossState.windupUntil = 0
    FinalBossState.pendingPhase = nil

    StageState.currentMapId   = newId
    StageState.currentMapName = newName
    StageState.currentStage   = 1  -- new map starts at stage 1
    StageState.inTransition   = false
    StageState.finalBossActive = false
    currentWave = 0

    -- Broadcast cleared wave state. Client HUDs will see Wave 0 and the
    -- new map name.
    remoteWaveState:FireAllClients({
        wave = 0,
        totalWaves = #WAVES,
        mobsAlive = 0,
        inProgress = false,
        map = newName,
        stage = 1,
        pendingCountdown = nil,
    })

    -- Auto-start wave 1 of the new map after a short pause to let the
    -- player look around / read the leaf message.
    task.delay(4.5, function()
        if StageState.currentMapId == newId and not waveInProgress then
            skipRequested = false
            runWave(1)
        end
    end)

    print(("[Waves] SwitchMap → mapId=%d (%s); wave 1 auto-starts in 4.5s"):format(newId, newName))
end)

------------------------------------------------------------
-- Main update loop: move mobs, fire towers, tick Phoenix cooldowns.
-- The tower list is fetched once per Heartbeat and shared by both
-- updateTowers and tickPhoenixCooldowns — they previously each called
-- CollectionService:GetTagged(Tags.Tower) independently every frame, doing
-- the same allocation work twice.
------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
    if dt > 0.1 then dt = 0.1 end  -- clamp to avoid teleports on lag spikes
    local towerList = CollectionService:GetTagged(Tags.Tower)
    updateMobs(dt)
    updateTowers(towerList)
    tickPhoenixCooldowns(dt, towerList)
end)

print("[Waves] Wave system v1.83 ready.")
