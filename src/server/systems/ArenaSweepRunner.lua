--[[
    ArenaSweepRunner.lua — Phase D (2026-04-29 ea3-50).

    Runs ONE combo through the 4-phase bounds-shrinking arena sweep
    on Map 4. Wraps:
      • AutoPicker (server-side bypass for upgrade picker / Core
        upgrade picker fired during the sweep)
      • AutoPlaceStrategy (role-aware tower placement scoring)
      • WaveCtxBridge (cross-script makeMob / countActiveMobs)
      • Workspace.Map4ActivePhase (drives bounds + path geometry)

    Per Matthew 2026-04-29 design:
      Phase 1 (Solo):     Map 1 size, 5 waves. Place Core only.
      Phase 2 (Duo):      Map 2 size + staircase blocker, 5 waves. +1 aux.
      Phase 3 (Trio):     Map 3 size, 5 waves. +1 aux.
      Phase 4 (Quad):     Stationary Pickle Lord + mini-pickle swarm. +1 aux.

    Per phase: waves 1-2 are breather (no mobs), upgrade picker fires
    for each. Waves 3-5 spawn mobs from WaveData.WAVES. Wave 5 spawns
    the stage end-of-stage boss (ea3-65: per Matthew "wave 5 should
    come with the end of stage boss, same cadence"). MAP bosses
    (Mold King BIG / Web Weaver / Canopy Bird) are still filtered —
    those have player-interaction mechanics tested in real story mode.
    Picker fires after waves 3 + 4 cleared. After phase boundary
    (1→2, 2→3, 3→4) a synthetic Core upgrade picker fires (drives
    CORE AUTO fixed-index/sequence comparison).

    Total per phase: 4 upgrade picks + 1 synthetic Core upgrade pick
    at boundary (3 phases of boundaries). Wave 5 stage boss spawns
    in phases 1-3; phase 4 runs the stationary Pickle Lord scenario
    instead of standard waves.

    PHASE 4 SPECIFICS — see runStationaryBossPhase below. Mini-pickle
    swarm spawns BEFORE the 10s tower setup penalty (towers placed
    but can't fire); damage measured until towers overwhelmed.

    USAGE:
        ArenaSweepRunner.runOneCombo(player, {
            coreId = "Power",
            auxIds = { "AcornSniper", "HoneyHive", "PaceFlower" },  -- 3 auxes
            autoPickerOpts = { mode = "random" },
        }, {
            onPhaseStart = function(phase) ... end,
            onPhaseEnd   = function(phase, phaseResult) ... end,
            onComplete   = function(comboResult) ... end,
            onFailed     = function(diedAtPhase, comboResult) ... end,
        })
]]

local Workspace           = game:GetService("Workspace")
local CollectionService   = game:GetService("CollectionService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tags         = require(Shared:WaitForChild("Tags"))
local Config       = require(Shared:WaitForChild("Config"))
local TempTowers   = require(Shared:WaitForChild("TempTowers"))
local TowerTypes   = require(Shared:WaitForChild("TowerTypes"))
local CoreUpgrades = require(Shared:WaitForChild("CoreUpgrades"))
local CoreTypes    = require(Shared:WaitForChild("CoreTypes"))

local AutoPicker    = require(script.Parent:WaitForChild("AutoPicker"))
-- AutoPlaceStrategy is consumed via ctx.findOptimalPlacementCell
-- (published by Hub during setup); no direct require needed here.
local StatLedger    = require(script.Parent:WaitForChild("StatLedger"))
local WaveCtxBridge = require(ServerScriptService:WaitForChild("WaveCtxBridge"))

local WaveData = require(ServerScriptService:WaitForChild("WaveData"))

local ArenaSweepRunner = {}

-- Module state. Single-active assumption (one combo at a time on a server).
local _state: any = nil
local _hubCtx: any = nil

-- ea3-132: per-wave / per-pick / per-combo log spam during sweeps.
-- Default OFF — the per-combo finalWave summary (printed via the
-- "[ArenaSweepRunner.failureCurve] N/M — ..." headline) plus the
-- end-of-sweep tier list dump from Infinite.lua are sufficient for
-- normal balance-pass workflow. Flip to true when debugging a
-- stuck sweep, an unexpected reroll loop, a heart-damage anomaly,
-- or a tower placement that doesn't seat. The verbose stream
-- includes:
--   • per-wave START / END (mob count, hpMult, heart before/after)
--   • [Sweep diag] combo start (path/bridge/etc cell counts)
--   • cleared-prior-towers bookkeeping
--   • [Sweep][Reroll] intermediate attempts (final KEPT/STUCK
--     decisions stay on regardless — those are diagnostic signals)
--   • per-upgrade-pick selection ([Sweep] upgrade pick @ wave N)
local SWEEP_VERBOSE = false

function ArenaSweepRunner.setup(ctx)
    _hubCtx = ctx
    -- ea3-58: ensure the HUD remotes EXIST in ReplicatedStorage at
    -- boot so the client's WaitForChild doesn't hang. Server fires
    -- these via FindFirstChild (no auto-create), so without an
    -- explicit getOrCreate the remotes never appear.
    local Remotes = require(Shared:WaitForChild("Remotes"))
    Remotes.getOrCreate(Remotes.Names.InfiniteArenaComboInfo, "RemoteEvent")
    Remotes.getOrCreate(Remotes.Names.InfiniteArenaProgress,  "RemoteEvent")
end

function ArenaSweepRunner.isActive(): boolean
    return _state ~= nil
end

-- ea3-74: cooperative abort for the SIMULATE → STOP toggle.
-- Client fires InfiniteArenaStop while a sweep is running; the
-- Infinite handler calls this; runOneCombo's safe-point checks
-- (between phases, between waves, inside runOneWave's wait loop)
-- bail early. Outer multi-combo loops (LONG VALIDATE, AUTORUN)
-- check ArenaSweepRunner.isAborted() between combos so the abort
-- propagates up.
function ArenaSweepRunner.requestAbort(): boolean
    if _state then
        _state.aborted = true
        warn("[ArenaSweepRunner] abort requested — sweep will exit at next safe point")
        return true
    end
    return false
end

function ArenaSweepRunner.isAborted(): boolean
    return _state ~= nil and _state.aborted == true
end

-- ===========================================================================
-- Helpers
-- ===========================================================================

local function healAllHearts()
    for _, heart in ipairs(CollectionService:GetTagged(Tags.EnemyEndPoint)) do
        local maxHp = heart:GetAttribute("MaxHealth")
        if maxHp then heart:SetAttribute("Health", maxHp) end
    end
end

-- Clear every Map 4 tower owned by `player` and refund Stock so a
-- fresh combo doesn't inherit prior-run towers. ea3-55 — Matthew
-- "if it was phase 1 why was there an aux tower?": prior auxes
-- placed on Map 4 (manual placement, abandoned sweep, etc.) stayed
-- on the field across runOneCombo calls because placeTowersForPhase
-- is idempotent (won't double-place) but doesn't clean up.
local function clearPlayerMap4Towers(player)
    local removed = 0
    for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local t = base.Parent
        if t and t:GetAttribute("Owner") == player.UserId then
            -- Only Map 4 towers — anchorCol >= MAP4_COL_OFFSET. Hub
            -- ctx publishes MAP4_COL_OFFSET; default 225 if unset.
            local map4Off = (_hubCtx and _hubCtx.MAP4_COL_OFFSET) or 225
            local anchorCol = t:GetAttribute("AnchorCol")
            if anchorCol and anchorCol >= map4Off then
                -- Free grid cells the tower occupied.
                if _hubCtx and _hubCtx.gridState then
                    local fw = t:GetAttribute("FootprintW") or 4
                    local fd = t:GetAttribute("FootprintD") or 4
                    local ar = t:GetAttribute("AnchorRow") or 0
                    for dc = 0, fw - 1 do
                        for dr = 0, fd - 1 do
                            local c = anchorCol + dc
                            local r = ar + dr
                            if _hubCtx.gridState[c] and _hubCtx.gridState[c][r] == "occupied" then
                                _hubCtx.gridState[c][r] = "open"
                            end
                        end
                    end
                end
                t:Destroy()
                removed = removed + 1
            end
        end
    end
    if removed > 0 then
        if SWEEP_VERBOSE then
            print(("[Sweep] cleared %d prior Map 4 tower(s) for %s"):format(removed, player.Name))
        end
        if _hubCtx and _hubCtx.broadcastGrid then _hubCtx.broadcastGrid() end
    end
end

-- Fire the InfiniteRoundUpdate remote so the InfiniteHUD's banner
-- ("THE PICKLE SWAMP") gets replaced with the active wave/phase.
-- ea3-55 — per Matthew "add a wave counter to replace THE PICKLE
-- SWAMP during sim runs".
local function fireRoundUpdate(player, phase, waveN)
    local roundRemote = ReplicatedStorage:FindFirstChild("InfiniteRoundUpdate")
    if not roundRemote then return end
    roundRemote:FireClient(player, {
        wave     = waveN,
        testType = ("PHASE %d"):format(phase),
    })
end

-- ea3-56 — second HUD row info. Server fires this with {coreId,
-- auxIds, phase, simulatedMapName} so the InfiniteHUD shows what
-- combo + simulated map the sweep is running.
local PHASE_TO_STORY_MAP = {
    [1] = "Map 1 (Crook of the Tree)",
    [2] = "Map 2 (Climbing the Tree)",
    [3] = "Map 3 (Canopy Nest)",
    [4] = "Pickle Lord scenario",
}
local function fireComboInfo(player, opts, phase)
    local remoteName = "InfiniteArenaComboInfo"
    local r = ReplicatedStorage:FindFirstChild(remoteName)
    if not r then return end
    -- ea3-81: slice auxIds to (phase - 1) since placeTowersForPhase
    -- only places that many auxes per phase: phase 1 = 0, phase 2 = 1,
    -- phase 3 = 2, phase 4 = 3. Pre-fix the HUD showed all 3 auxes
    -- on every phase, which mismatched the placed-tower reality.
    -- Per Matthew "should only have 2 aux towers on map 3" — Map 3 =
    -- phase 3 = Core + 2 auxes per the design spec; the HUD now
    -- reflects only what's actually on the field.
    local fullAuxIds = opts.auxIds or {}
    local activeAuxCount = math.max(0, math.min(phase - 1, #fullAuxIds))
    local visibleAuxIds = {}
    for i = 1, activeAuxCount do visibleAuxIds[i] = fullAuxIds[i] end
    r:FireClient(player, {
        coreId          = opts.coreId,
        auxIds          = visibleAuxIds,
        phase           = phase,
        simulatedMap    = PHASE_TO_STORY_MAP[phase] or "?",
    })
end

-- ea3-118 — FAILURE CURVE combo-info. Same remote as VALIDATE
-- (InfiniteArenaComboInfo), but builds a simulatedMap string of the
-- form "CURVE 23/105" instead of mapping a phase to a story map.
-- The HUD's existing renderer composes it as "Power + Pepper /
-- Honey / Pace  •  CURVE 23/105" on the second top-bar row.
--
-- ea3-136: opts.hudPrefix overrides the default "CURVE" so SUPER
-- CURVE × 495 can show "SUPER CURVE A (10/495)" mid-Phase-A,
-- "SUPER CURVE B (350/495)" mid-Phase-B. idx + total are caller-
-- adjusted to overall counts (hudIdxOffset / hudTotalOverride in
-- runFailureCurveSweep) so the user sees absolute progress, not
-- per-Core-slice progress.
local function fireFailureCurveComboInfo(player, opts, idx, total)
    local r = ReplicatedStorage:FindFirstChild("InfiniteArenaComboInfo")
    if not r then return end
    local prefix = opts.hudPrefix or "CURVE"
    r:FireClient(player, {
        coreId       = opts.coreId or "Power",
        auxIds       = opts.auxIds or {},
        phase        = 0,
        simulatedMap = ("%s (%d/%d)"):format(prefix, idx, total),
    })
end

-- ea3-57 — progress bar remote. Server fires {elapsedSec, totalSec,
-- label, fraction} so the InfiniteHUD's middle progress bar renders
-- + counts down. fraction = elapsed / total clamped [0,1].
local function fireProgress(player, elapsedSec, totalSec, label)
    local r = ReplicatedStorage:FindFirstChild("InfiniteArenaProgress")
    if not r then return end
    local fraction = totalSec > 0 and math.min(1, elapsedSec / totalSec) or 0
    r:FireClient(player, {
        elapsedSec = elapsedSec,
        totalSec   = totalSec,
        label      = label or "",
        fraction   = fraction,
    })
end

-- Per-phase time estimates (real-time at 20× game speed, derived
-- from observed per-wave durations + 4 picker ticks). Phase 4 is
-- 10s setup + ~30s boss-vs-swarm + cleanup.
local PHASE_REAL_TIME_S = { [1] = 50, [2] = 55, [3] = 65, [4] = 50 }
local function comboEstimateSec(): number
    local total = 0
    for i = 1, 4 do total = total + (PHASE_REAL_TIME_S[i] or 50) end
    return total  -- ~220s = 3.7 min
end

local function isMap4HeartDead(): boolean
    -- Find Map 4's heart by partMapId == 4. ctx.partMapId reads the
    -- MapId attribute set by Hub on each tagged heart.
    -- ea3-57: partMapId is published on WaveSystem's ctx (via
    -- WaveCtxBridge), NOT Hub's ctx. Was reading nil from
    -- _hubCtx.partMapId — every heart skipped → returned false
    -- on dead-heart, but isMap4HeartDead happens to return false
    -- in the no-match case so the bug went unnoticed except in
    -- heart-HP logs which fell back to 0. Fix: read MapId
    -- attribute directly (no need for partMapId proxy).
    for _, heart in ipairs(CollectionService:GetTagged(Tags.EnemyEndPoint)) do
        if heart:GetAttribute("MapId") == 4 then
            local hp = heart:GetAttribute("Health") or 0
            return hp <= 0
        end
    end
    return false
end

-- ea3-138: read Map 4's heart HP. Used to snapshot heart-at-start-
-- of-wave so the killing-wave's starting heart HP can be recorded
-- on result entries. Returns nil if no Map 4 heart is tagged
-- (defensive: the sweep runner shouldn't be called outside of a
-- Map 4 setup but better to nil-out than read a stale tag).
local function getMap4HeartHp(): number?
    for _, h in ipairs(CollectionService:GetTagged(Tags.EnemyEndPoint)) do
        if h:GetAttribute("MapId") == 4 then
            local hp = h:GetAttribute("Health")
            return (type(hp) == "number") and hp or nil
        end
    end
    return nil
end

-- ea3-138: install the heart-overkill capture hook on the WaveSystem
-- ctx for a sweep combo. Mirrors Infinite.lua's enter() install at
-- line 3110 (which used to be the only consumer; the new sweep
-- runner had no equivalent so killing-blow overkill was being
-- discarded for both AUTORUN and FAILURE CURVE). MobUpdate fires
-- the callback when a mob delivers a killing blow with damage >
-- heart's remaining HP. Caller passes a `captureSlot` table; the
-- hook writes killingBlowOverkill / killingBlowDamage /
-- heartHpBeforeKill / killingMob into it on heart-death (last-
-- write-wins, but in practice the heart dies on the first 0-HP
-- transition so this fires exactly once per combo). Returns the
-- prior callback so the caller can restore on teardown.
local function installHeartOverkillHook(captureSlot)
    local ctx = WaveCtxBridge.ctx
    if not ctx then return nil end
    local prior = ctx.onHeartOverkill
    ctx.onHeartOverkill = function(overkill, dmg, heartHpBefore, mob)
        captureSlot.killingBlowOverkill = overkill or 0
        captureSlot.killingBlowDamage   = dmg or 0
        captureSlot.heartHpBeforeKill   = heartHpBefore or 0
        captureSlot.killingMob          = mob
    end
    return prior
end

local function uninstallHeartOverkillHook(prior)
    local ctx = WaveCtxBridge.ctx
    if not ctx then return end
    ctx.onHeartOverkill = prior
end

-- Per-phase mob HP scaling. Per Matthew 2026-04-29 (ea3-66):
--   "go with 1 / 1.6 / 2.3, map 1 has no enhancements, and
--    enhancements definitely do not add that much"
-- ea3-76 follow-up: "increase all non-boss hp by 10%" — every
-- value bumped 10% (regular mobs only; PHASE_BOSS_HP_MULT below
-- and the stationary Pickle Lord HP stay where they are).
-- Phase 1 = Solo Core baseline. Phase 2/3 step up modestly to
-- reflect the upgrade-pick + Core-upgrade enhancement value gain.
-- Phase 4 = stationary scenario (regular mobs aren't spawned
-- during phase 4; the mini-pickle swarm uses Config.PickleLord.MiniHp
-- directly, so PHASE_HP_MULT[4] is unused but kept for symmetry).
local PHASE_HP_MULT = { [1] = 1.10, [2] = 1.76, [3] = 2.53, [4] = 1.10 }

-- Per-phase wave-5 stage-boss HP scale. Mirrors PHASE_HP_MULT (per
-- ea3-66's "1 / 1.6 / 2.3" guidance) instead of the steeper
-- story-mode Stages.bossHpMult (1.333 / 3.0 / 4.667) — sweep mode
-- has fewer towers per phase than story (Solo / Duo / Trio vs. full
-- aux roster), so boss HP scaling tracks the mob ramp rather than
-- the story-mode boss ramp. Boss base HP is 1500, so phase 3 lands
-- at 1500 × 2.3 = 3450 HP. Phase 4 has no wave-5 boss —
-- it runs runStationaryBossPhase instead.
local PHASE_BOSS_HP_MULT = { [1] = 1.0, [2] = 1.6, [3] = 2.3 }

-- Per-phase mob composition: which WAVES table waves get spawned
-- when phase N runs. 3..5 = stage 3 worth of content (waves 3, 4, 5).
-- Wave 5 fires the stage end-of-stage boss as in story mode (per
-- Matthew 2026-04-29 "wave 5 should come with the end of stage boss,
-- same cadence"). Map bosses (Mold King / Web Weaver / Canopy Bird)
-- are still filtered — those are tested in real story mode.
local PHASE_WAVES_TO_RUN = { 3, 4, 5 }

-- Mob types that represent MAP bosses (post-stage-3 final encounters
-- with player-interaction mechanics). These remain filtered out of
-- sweep wave spawns; they're tested in real story mode. Stage bosses
-- (mobType="boss" → light Mold King 1500 HP) DO spawn on wave 5.
local function isMapBoss(mobType: string): boolean
    return mobType == "finalboss"  -- map 1 BIG Mold King (15000 HP, phase mechanics)
        or mobType == "spider"     -- map 2 Web Weaver (web-clicking)
        or mobType == "bird"       -- map 3 Canopy Bird (player grab/dive)
end

local function gameSpeed(): number
    if WaveCtxBridge.ctx and WaveCtxBridge.ctx.gameSpeed then
        return WaveCtxBridge.ctx.gameSpeed
    end
    return 1
end

-- Spawn one wave's worth of mobs on Map 4. Skips boss spawns. Waits
-- for active mob count to reach 0 before returning (wave cleared).
-- ea3-55: per-wave stats logged so VALIDATE / AUTORUN progress is
-- readable from the server log without screen-watching the swarm.
local function runOneWave(waveData, phaseHpMult, waveLabel)
    local waveCtx = WaveCtxBridge.ctx
    if not waveCtx or not waveCtx.makeMob then
        warn("[ArenaSweepRunner] WaveCtxBridge.ctx.makeMob unavailable — wave skipped")
        return
    end
    local hpMult = (waveData.hpMult or 1.0) * phaseHpMult
    local activePhase = Workspace:GetAttribute("Map4ActivePhase") or 1
    local waypoints = waveCtx.getWaypoints()
    if not waypoints or #waypoints == 0 then
        warn("[ArenaSweepRunner] no Map 4 waypoints — wave skipped")
        return
    end
    -- Per-wave header. Count includes the wave-5 stage boss (it
    -- spawns now per Matthew "wave 5 should come with the end of
    -- stage boss"); excludes only map bosses (Mold King / Web Weaver
    -- / Canopy Bird — the post-stage-3 player-interaction encounters).
    local mobCount = 0
    local bossCount = 0
    for _, spawn in ipairs(waveData.spawns) do
        if not isMapBoss(spawn.mobType) then
            mobCount = mobCount + (spawn.count or 1)
            if spawn.mobType == "boss" then
                bossCount = bossCount + (spawn.count or 1)
            end
        end
    end
    local startedAt = os.clock()
    local heartBefore = (function()
        for _, h in ipairs(CollectionService:GetTagged(Tags.EnemyEndPoint)) do
            if h:GetAttribute("MapId") == 4 then
                return h:GetAttribute("Health") or 0
            end
        end
        return 0
    end)()
    if SWEEP_VERBOSE then
        print(("[Sweep] %s START — %d mobs to spawn (incl %d stage boss), mobMult=%.2f, bossMult=%.2f, heart=%d"):format(
            tostring(waveLabel), mobCount, bossCount, hpMult,
            PHASE_BOSS_HP_MULT[activePhase] or 1.0, heartBefore))
    end

    -- Spawn each spawn group sequentially.
    for _, spawn in ipairs(waveData.spawns) do
        if isMapBoss(spawn.mobType) then
            -- ea3-65: only filter MAP bosses (Mold King / Web Weaver
            -- / Canopy Bird). Stage bosses (mobType="boss") DO spawn
            -- on wave 5 per Matthew's "wave 5 should come with the
            -- end of stage boss" guidance. Map bosses still skipped —
            -- those need player interaction so they're tested in real
            -- story mode.
            continue
        end
        -- ea3-117 fix: include spawn.hpMult when present. WaveData.WAVES
        -- entries (the 4-phase scripted sweep's source) leave spawn.hpMult
        -- nil → falls back to 1.0 → byte-identical prior behavior. The
        -- v2 failure-curve sweep's buildFailureCurveWaveData computes
        -- per-spawn hpMult with WaveHpRamp + LoadoutMult baked in (so
        -- AOE basics, Combined fasts, and Solo tanks each scale to the
        -- correct per-mob HP from Pools_C1). Without this, every v2 mob
        -- spawned at baseHp × 1.0 — heart took zero damage all 28 waves
        -- and every loadout trivially "survived" to cap.
        local thisMult = hpMult * (spawn.hpMult or 1.0)
        for _ = 1, (spawn.count or 1) do
            local m = waveCtx.makeMob(spawn.mobType, waypoints, thisMult)
            -- ea3-81: stage-boss HP override. MobFactory sets
            -- effectiveWaveMult = 1.0 for mobType="boss" (line 98:
            -- "Bosses ignore waveMult"); story uses Stages.bossHpMult
            -- + a STAGE_BOSS_HP override table keyed on (mapId,
            -- stage). Sweep on Map 4 has neither in scope, so the
            -- boss came in at base 1500 × Map1-reduction-0.6885 ≈
            -- ~1000-2000 HP regardless of PHASE_BOSS_HP_MULT. Per
            -- Matthew "map 3 wave 5 boss only had 2k hp?" — same
            -- registry-vs-attribute pattern as the stationary boss
            -- fix in ea3-77, applied to the per-phase wave-5 boss.
            if m and spawn.mobType == "boss" then
                local bossMult = PHASE_BOSS_HP_MULT[activePhase] or 1.0
                local mobDef = waveCtx.MOB_TYPES and waveCtx.MOB_TYPES.boss
                local bossBaseHp = (mobDef and mobDef.hp) or 1500
                local bossHp = math.floor(bossBaseHp * bossMult + 0.5)
                m:SetAttribute("MaxHealth", bossHp)
                m:SetAttribute("Health",    bossHp)
                if waveCtx.activeMobs and waveCtx.activeMobs[m] then
                    local data = waveCtx.activeMobs[m]
                    data.hp     = bossHp
                    data.maxHp  = bossHp
                    data.damage = bossHp
                    -- ea3-84: refresh the BillboardGui label so the
                    -- HP bar shows the override value (e.g. 3450 /
                    -- 3450 for phase 3) instead of the makeMob-
                    -- computed scaledHp (~4800 with stale Map 1
                    -- reduction). Per Matthew "map 3 wave 5 boss
                    -- only had 4800 hp?" — the bar was reading
                    -- scaledHp; data.hp was overridden but hpText
                    -- wasn't refreshed until first hit.
                    if data.hpText then
                        data.hpText.Text = string.format("%d / %d", bossHp, bossHp)
                    end
                    if data.hpFill then
                        data.hpFill.Size = UDim2.fromScale(1, 1)
                    end
                end
            end
            task.wait((spawn.interval or 0.5) / gameSpeed())
        end
        if spawn.gap and spawn.gap > 0 then
            task.wait(spawn.gap / gameSpeed())
        end
    end
    -- Wait for clear (or heart death — caller checks).
    -- ea3-73: max-wait ceiling so a stalled wave (e.g. orphan
    -- never-dying mob, accidental pause that the new pause-block
    -- in WaveSystem missed because it was set BEFORE sweep started)
    -- doesn't lock the sweep coroutine forever. 30 real seconds at
    -- 20× game speed is 600 game seconds — way longer than any
    -- legitimate wave clear. If the ceiling hits we abandon the
    -- wave + log a warning; runOneCombo's heart-dead check catches
    -- the failed-phase case, and a healthy wave never gets close.
    local waitStartedAt = os.clock()
    local WAVE_WAIT_CEILING_REAL = 30
    while waveCtx.countActiveMobs and waveCtx.countActiveMobs() > 0 do
        if isMap4HeartDead() then break end
        -- ea3-74: cooperative abort — if STOP was clicked, drop
        -- the wave wait + bail. Caller (runOneCombo) sees the
        -- aborted flag at its own safe point and exits.
        if _state and _state.aborted then
            if waveCtx.clearAllMobs then waveCtx.clearAllMobs() end
            break
        end
        if os.clock() - waitStartedAt > WAVE_WAIT_CEILING_REAL then
            warn(("[Sweep] %s — wait-clear ceiling hit (%ds real); abandoning wave with %d mobs alive"):format(
                tostring(waveLabel), WAVE_WAIT_CEILING_REAL,
                waveCtx.countActiveMobs() or 0))
            -- Wipe leftovers so the next wave / combo starts clean.
            if waveCtx.clearAllMobs then waveCtx.clearAllMobs() end
            break
        end
        task.wait(0.2)
    end

    -- Per-wave footer.
    local heartAfter = (function()
        for _, h in ipairs(CollectionService:GetTagged(Tags.EnemyEndPoint)) do
            if h:GetAttribute("MapId") == 4 then
                return h:GetAttribute("Health") or 0
            end
        end
        return 0
    end)()
    local heartLost = heartBefore - heartAfter
    if SWEEP_VERBOSE then
        print(("[Sweep] %s END — %.1fs, heart %d → %d (lost %d)"):format(
            tostring(waveLabel), os.clock() - startedAt, heartBefore, heartAfter, heartLost))
    end
end

-- Fire one upgrade picker (auto-resolved via AutoPicker's tempTower-
-- key bypass; reuses the existing UpgradeCards.lua picker fire path
-- via a synthetic "between waves" event).
local function fireOneUpgradePicker(player, waveIndex)
    local waveCtx = WaveCtxBridge.ctx
    if not waveCtx or not waveCtx.generateCardsForPlayer then return end
    -- ea3-78: replicate story-mode auto-pick reroll logic. Story's
    -- offerUpgradesOrAutoPick (UpgradeCards.lua simulateOnePick at
    -- line 693) loops up to MaxRerollTries, regenerating cards if:
    --   • no Special AND no card better than Common, OR
    --   • pick #3+ in stage AND no card better than Rare
    -- Spends RerollsUsed up to maxRerollsPerStage, then RerollTokens.
    -- Pre-ea3-78 ArenaSweepRunner did SINGLE-SHOT RNG with no reroll —
    -- bad-luck Common-only sets passed through, dragging sweep
    -- rarity averages well below what real story-mode players see.
    -- Per Matthew "is infinite using the reroll logic? it seems to
    -- be getting bad luck." It wasn't. Now it is.
    local DEV_PICK_SCORE = {
        Mythical = 6, Special = 5, Legendary = 4,
        Exceptional = 3, Rare = 2, Common = 1,
    }
    local MAX_REROLL_TRIES = (Config.UpgradeCards and Config.UpgradeCards.MaxRerollTries) or 3
    -- ea3-98: realistic story-mode reroll model — per Matthew's clarification:
    --   • 3 starting tokens (carry across phases)
    --   • +1 per-map (perMap) reroll at start of each phase 1-3 (EXPIRES at phase end)
    --   • +1 token granted on boss defeat (end of phase 1-3)
    --   • Phase 4 (Pickle Lord) gets NO new perMap (player goes straight
    --     into the fight after picking an aux in story) — only leftover
    --     tokens spendable on the 24 catch-up picks.
    -- Bookkeeping:
    --   • RerollTokens (player attr) — persistent pool, set to 3 at combo
    --     start, +1 on each phase 1-3 boss kill, decremented when picker
    --     spends a token.
    --   • RerollsUsed (player attr) — perMap counter, reset to 0 at phase
    --     start; if RerollsUsed < maxRerollsPerStage, picker spends the
    --     perMap; once that's exhausted, picker falls through to spending
    --     RerollTokens.
    -- maxRerollsPerStage is the perMap cap per phase. 1 in phases 1-3
    -- (matches story "1 per map that expires"); 0 in phase 4 catch-up.
    local activePhase = Workspace:GetAttribute("Map4ActivePhase") or 1
    local maxRerollsPerStage = (activePhase < 4) and 1 or 0
    local pickInStage = ((waveIndex - 1) % 4) + 1
    local payload
    -- ea3-95: per-attempt diagnostic print so we can audit what the
    -- reroll loop actually does during a sweep — each line shows the
    -- offered card rarities, the reroll decision (kept / rerolled +
    -- reason), and which budget bucket paid for the reroll. If the
    -- loop exits without rerolling at all, no extra print fires
    -- beyond the existing "[Sweep] upgrade pick" line.
    for attempt = 1, MAX_REROLL_TRIES do
        payload = waveCtx.generateCardsForPlayer(player, waveIndex)
        local cards = (payload and payload.cards) or {}
        if #cards == 0 then return end
        local hasSpecial, highScore = false, 0
        local rarityList = {}
        for _, c in ipairs(cards) do
            local s = DEV_PICK_SCORE[c.rarity] or 0
            if c.rarity == "Special" then hasSpecial = true end
            if s > highScore then highScore = s end
            rarityList[#rarityList + 1] = tostring(c.rarity or "?")
        end
        local anyOverCommon = highScore > (DEV_PICK_SCORE.Common or 1)
        local anyOverRare   = highScore > (DEV_PICK_SCORE.Rare    or 2)
        local commonReject  = (not hasSpecial and not anyOverCommon)
        -- ea3-97/98: rare-reject applies to EVERY pick (was pickInStage
        -- >= 3 only — picks 1 and 2 silently passed through Rare-or-
        -- below sets without rerolling). Per Matthew "run the logic for
        -- fake waves 1 and 2" — fake-wave-1/2 picks get the same
        -- aggressive rare-reject treatment as pick 3. With ea3-98's
        -- realistic token model the picker now self-rate-limits via
        -- perMap-then-tokens; an aggressive trigger just means "burn
        -- the budget eagerly" rather than "guaranteed reroll".
        local rareReject = (not anyOverRare)
        local wantReroll = commonReject or rareReject
        if not wantReroll then
            if attempt > 1 then
                print(("[Sweep][Reroll] wave %d pick %d: KEPT on attempt %d (offered: %s)"):format(
                    waveIndex, pickInStage, attempt, table.concat(rarityList, "/")))
            end
            break
        end
        local rerollsUsed = player:GetAttribute("RerollsUsed") or 0
        local tokens      = player:GetAttribute("RerollTokens") or 0
        local reason
        if commonReject and rareReject then
            reason = "common-only & no>Rare"
        elseif commonReject then
            reason = "common-only"
        else
            reason = ("no>Rare (pick %d/4)"):format(pickInStage)
        end
        local source
        if rerollsUsed < maxRerollsPerStage then
            player:SetAttribute("RerollsUsed", rerollsUsed + 1)
            source = ("stage budget %d/%d"):format(rerollsUsed + 1, maxRerollsPerStage)
        elseif tokens > 0 then
            player:SetAttribute("RerollTokens", tokens - 1)
            source = ("token (%d → %d)"):format(tokens, tokens - 1)
        else
            print(("[Sweep][Reroll] wave %d pick %d: STUCK on attempt %d, no budget left (offered: %s, reason: %s)"):format(
                waveIndex, pickInStage, attempt, table.concat(rarityList, "/"), reason))
            break  -- nothing to spend; pick what we've got
        end
        if SWEEP_VERBOSE then
            print(("[Sweep][Reroll] wave %d pick %d: REROLL attempt %d → %d (reason: %s, paid: %s, offered: %s)"):format(
                waveIndex, pickInStage, attempt, attempt + 1, reason, source, table.concat(rarityList, "/")))
        end
    end
    local cards = (payload and payload.cards) or {}
    if #cards == 0 then return end
    if AutoPicker.isActive() then
        -- ea3-121: rarity-greedy pick (was uniform random). The reroll
        -- loop above ensures a strong offer; this picks the best card
        -- in it instead of randomly grabbing one of three.
        local idx = AutoPicker.pickFromCards(cards, "upgradeCard")
        local picked = cards[idx]
        if picked and waveCtx.applyUpgrade then
            waveCtx.applyUpgrade(player, picked)
            -- ea3-69/-70: log the picked card so the analyst can
            -- see which upgrades the sweep gives the player. Card
            -- shape from UpgradeCards.lua:
            --   stat:    { kind="stat",    stat, multiplier, rarity, description, target }
            --   special: { kind="special", special, rarity, description, target }
            local kind = picked.kind or "?"
            local rarity = picked.rarity or "?"
            local descriptor
            if kind == "stat" then
                descriptor = ("%s ×%.2f"):format(
                    tostring(picked.stat or "?"),
                    tonumber(picked.multiplier) or 1.0)
            elseif kind == "special" then
                descriptor = ("Special: %s"):format(tostring(picked.special or "?"))
            else
                descriptor = picked.description or "(unknown card)"
            end
            if SWEEP_VERBOSE then
                print(("[Sweep] upgrade pick @ wave %d: [%s/%s] %s → %s (auto idx %d / %d)"):format(
                    waveIndex, rarity, kind, descriptor,
                    tostring(picked.target or "?"), idx, #cards))
            end
        end
    end
end

-- Synthetic Core upgrade picker fire at phase boundary. Drives the
-- CORE AUTO comparison (AutoPicker fixed-index/sequence picks the
-- option index; commitPick stamps it + applies the effect).
local function fireSyntheticCoreUpgrade(player, mapId)
    local coreId = "Power"
    for _, c in ipairs(CoreTypes.Ids) do
        if player:GetAttribute(c .. "Equipped") == true then
            coreId = c
            break
        end
    end
    local options = CoreUpgrades.optionsFor(coreId)
    if not options or #options == 0 then return end
    if not AutoPicker.isActive() then
        -- Non-sweep callers shouldn't end up here; the picker fires
        -- via real BossRewardClaimed in story mode.
        return
    end
    local idx = AutoPicker.pickIndex(#options, "coreUpgrade")
    local opt = options[idx]
    if opt and opt.id then
        local attrName = opt.id .. "Stacks"
        local existing = player:GetAttribute(attrName) or 0
        player:SetAttribute(attrName, existing + 1)
        -- Apply via the same applyUpgradeEffect path CoreUpgrades
        -- uses internally. CoreUpgrades doesn't expose that, so we
        -- fire the CoreUpgradeResolved bindable directly so any
        -- listener (TempTowerRewards cutscene gate) fires; for
        -- effect application we fire the picked remote which
        -- routes to commitPick.
        local Remotes = require(Shared:WaitForChild("Remotes"))
        local pickedRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.CoreUpgradePicked)
        if pickedRemote then
            -- pickedRemote.OnServerEvent expects a real player +
            -- pending state. Skip the route + apply effect inline
            -- via a direct re-fire of CoreUpgradeResolved.
            local resolved = ReplicatedStorage:FindFirstChild(Remotes.Names.CoreUpgradeResolved)
            if resolved then
                resolved:Fire({ player = player, mapId = mapId })
            end
        end
        print(("[ArenaSweepRunner] synthetic Core upgrade for %s: %s (stacks=%d)"):format(
            player.Name, opt.id, existing + 1))
    end
end

-- ===========================================================================
-- Tower placement per phase
-- ===========================================================================

-- ea3-87: phase-4 placement now uses default per-role scoring
-- (path coverage etc) instead of targetCell=heart. The boss moved
-- to MAP4_CENTER with a wide TargetRadius (~120) so every path-
-- side tower in Map 4 has reach to the boss; clustering near a
-- specific cell isn't needed anymore. Towers go where path
-- coverage is best AND still hit the boss. Per Matthew
-- "pickle and towers in the wrong place" + screenshot showing
-- mini-pickles untouched at one end while towers were stuck at
-- the heart corner.

-- Place ONE tower for a player using AutoPlaceStrategy + ctx.placeTowerForPlayer.
-- Returns true on success.
local function placeTowerForRole(player, towerType, role, footprintW, footprintD, range)
    if not _hubCtx or not _hubCtx.placeTowerForPlayer or not _hubCtx.findOptimalPlacementCell then
        warn("[ArenaSweepRunner] hub ctx placement helpers missing")
        return false
    end
    -- Build allies list from previously-placed towers on Map 4 owned by player.
    local placedAllies = {}
    for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local t = base.Parent
        if t and t:GetAttribute("Owner") == player.UserId then
            local tType = t:GetAttribute("TowerType")
            local aRole
            if CoreTypes.isCore(tType) then
                aRole = "Core"
            else
                aRole = TempTowers.RoleByTowerId and TempTowers.RoleByTowerId[tType] or "DPS"
            end
            local aCol = t:GetAttribute("AnchorCol")
            local aRow = t:GetAttribute("AnchorRow")
            local fw   = t:GetAttribute("FootprintW") or 4
            local fd   = t:GetAttribute("FootprintD") or 4
            if aCol and aRow then
                table.insert(placedAllies, {
                    role        = aRole,
                    anchorCol   = aCol, anchorRow = aRow,
                    footprintW  = fw,   footprintD = fd,
                    centerC     = aCol + (fw - 1) / 2,
                    centerR     = aRow + (fd - 1) / 2,
                })
            end
        end
    end
    -- Score-based placement. ea3-87: every phase uses default
    -- per-role scoring (path coverage / corner / aura). Phase 4's
    -- boss has a wide TargetRadius so path-side towers still hit
    -- it without needing a targetCell hint.
    -- ea3-127: read the tower template's auraRadius so Support
    -- placement scoring counts allies within the actual aura reach,
    -- not the (often larger) shooting range. Per Matthew "make sure
    -- as many towers as possible can get an aura."
    local auraRadius
    if role == "Support" then
        local tpl = TempTowers and TempTowers.Templates and TempTowers.Templates[towerType]
        auraRadius = (tpl and tpl.auraRadius) or 18  -- aux Support default
    end
    local col, row = _hubCtx.findOptimalPlacementCell({
        role         = role,
        footprintW   = footprintW,
        footprintD   = footprintD,
        range        = range,
        auraRadius   = auraRadius,
        mapId        = 4,
        placedAllies = placedAllies,
    })
    if not col or not row then
        warn(("[ArenaSweepRunner] no fit for %s (%s) on map 4 phase=%s"):format(
            tostring(towerType), tostring(role),
            tostring(Workspace:GetAttribute("Map4ActivePhase"))))
        return false
    end
    -- Grant stock + Equipped.
    player:SetAttribute(towerType .. "Stock",    (player:GetAttribute(towerType .. "Stock")    or 0) + 1)
    player:SetAttribute(towerType .. "Equipped", true)
    _hubCtx.placeTowerForPlayer(player, towerType, col, row)
    return true
end

-- Forward decl for placePhaseAux (assigned later in this same scope).
-- Lua resolves free vars at function-DEFINITION time per CLAUDE.md
-- convention #1; placeTowersForPhase calls placePhaseAux so we need
-- the upvalue to exist when placeTowersForPhase is defined.
local placePhaseAux

-- Place towers up to and including the given phase's loadout size.
-- Phase 1: Core only. Phase 2: Core + 1 aux. Phase 3: Core + 2 aux.
-- Phase 4: Core + 3 aux. Idempotent — won't double-place if a tower
-- type is already on the field.
local function placeTowersForPhase(player, opts, phase)
    -- ea3-75: phase 4 entry — wipe phase-3 placements so the
    -- boss-cluster scoring (targetCell=heart in placeTowerForRole)
    -- can re-place every tower near the heart cell. Pre-fix, towers
    -- placed along the phase-3 path stayed put through the phase 4
    -- transition; the stationary boss spawned at the heart cell
    -- was outside their range and took 0 damage every run.
    -- Per Matthew "replace towers to be able to hit the pickles
    -- boss before phase 4".
    if phase == 4 then
        clearPlayerMap4Towers(player)
    end
    if phase >= 1 then
        -- Place Core if not already placed.
        local coreId = opts.coreId
        local coreType = TowerTypes[coreId]
        if coreType then
            local already = false
            for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                local t = base.Parent
                if t and t:GetAttribute("Owner") == player.UserId
                   and t:GetAttribute("TowerType") == coreId then
                    already = true; break
                end
            end
            if not already then
                placeTowerForRole(player, coreId, "Core",
                    coreType.footprintWidth or 4,
                    coreType.footprintDepth or 4,
                    coreType.range or 22)
            end
        end
    end
    -- Auxes: phase 2 adds auxIds[1], phase 3 adds [2], phase 4 adds [3].
    if phase >= 2 then
        local auxId = opts.auxIds and opts.auxIds[1]
        if auxId then placePhaseAux(player, auxId) end
    end
    if phase >= 3 then
        local auxId = opts.auxIds and opts.auxIds[2]
        if auxId then placePhaseAux(player, auxId) end
    end
    if phase >= 4 then
        local auxId = opts.auxIds and opts.auxIds[3]
        if auxId then placePhaseAux(player, auxId) end
    end
end

-- Helper for aux placement — places ALL stock copies the tower
-- has in story mode (tpl.stock, range 1-4 across the aux roster).
-- ea3-74: per Matthew "are we getting and placing the typical
-- amount of stock for each tower?" — pre-fix the sweep placed
-- exactly 1 of each tower, so a 4-stock aux (tpl.stock = 4) was
-- 25% as effective in the sweep as it would be for a story-mode
-- player who'd accumulated all 4 instances. Big balance fidelity
-- gap vs the story-mode loadout the sweep is meant to mimic.
-- Now we count existing instances of this towerType and place
-- (tpl.stock - existing) more so the field has exactly tpl.stock
-- copies of this aux. Idempotent across phase boundaries: phase 2
-- placement of aux1 results in 4 instances; phase 3 adds aux2 (4
-- of those) without re-placing aux1's; etc.
function placePhaseAux(player, auxId)
    local tpl = TempTowers.Templates[auxId]
    if not tpl then return end
    local existingCount = 0
    for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local t = base.Parent
        if t and t:GetAttribute("Owner") == player.UserId
           and t:GetAttribute("TowerType") == auxId then
            existingCount = existingCount + 1
        end
    end
    local stockTarget = tpl.stock or 1
    local toPlace = stockTarget - existingCount
    if toPlace <= 0 then return end
    local role = TempTowers.RoleByTowerId and TempTowers.RoleByTowerId[auxId] or "DPS"
    for _ = 1, toPlace do
        local placed = placeTowerForRole(player, auxId, role,
            tpl.footprintWidth or 4,
            tpl.footprintDepth or 4,
            tpl.range or 22)
        if not placed then break end  -- arena full / no fit; stop early
    end
end

-- ===========================================================================
-- Phase 4 stationary Pickle Lord scenario — placeholder until commit E.
-- ===========================================================================

-- ea3-51 Phase E: stationary Pickle Lord scenario.
-- Timeline (per Matthew 2026-04-29):
--   t=0      mini-pickle swarm starts spawning continuously
--   t=0      Workspace.ArenaSweepNoFire = true (towers held — 10s
--            setup penalty: simulates player still positioning)
--   t=0      stationary boss spawns at the heart cell with massive
--            HP + speed=0 so it doesn't move
--   t=10s    setup penalty ends — towers begin firing
--   continue stationary boss takes damage; mini pickles overwhelm
--            heart eventually
--   END      heart at 0 → record total damage dealt to boss as
--            phase-4 result
local function runStationaryBossPhase(player, opts, hooks)
    local waveCtx = WaveCtxBridge.ctx
    if not waveCtx or not waveCtx.makeMob then
        warn("[ArenaSweepRunner] Phase 4: WaveCtxBridge.ctx unavailable — skipping")
        return { cleared = false, bossDamageDealt = 0 }
    end
    local waypoints = waveCtx.getWaypoints()
    if not waypoints or #waypoints == 0 then
        warn("[ArenaSweepRunner] Phase 4: no waypoints — skipping")
        return { cleared = false, bossDamageDealt = 0 }
    end

    -- ea3-56/61: phase 4 banner. roundRemote drives the legacy
    -- WAVE banner (now hidden during arena sweeps). Progress bar
    -- gets "PICKLE LORD" instead of "MAP N • WAVE M" since phase
    -- 4 is one continuous boss + swarm scenario.
    if _state and _state.player then
        local roundRemote = ReplicatedStorage:FindFirstChild("InfiniteRoundUpdate")
        if roundRemote then
            roundRemote:FireClient(_state.player, {
                wave = 0,
                testType = "PHASE 4 BOSS",
            })
        end
        -- Progress bar label: PICKLE LORD (no MAP/WAVE — single
        -- continuous scenario). ea3-74: real-time elapsed via the
        -- helper runOneCombo stashed on _state.
        if _state.fireProgressNow then
            _state.fireProgressNow("PICKLE LORD")
        end
    end

    -- Engage 10s tower-fire suppression.
    Workspace:SetAttribute("ArenaSweepNoFire", true)
    print(("[ArenaSweepRunner] Phase 4 START — 10s tower setup penalty engaged"):format())

    -- ea3-92: ea3-91's "lock Core onto boss via TargetMode=Strongest"
    -- removed. Per Matthew "they need to focus on killing the
    -- pickles while killing the boss" — towers should split
    -- attention naturally between the swarm and the boss instead
    -- of the Core hard-locking onto the boss. Default "First" mode
    -- on every tower means they primarily fire at path-progressed
    -- mini-pickles, with whatever AOE / leakage / spillover damage
    -- naturally lands on the boss. Boss-damage measurement = real
    -- secondary-fire DPS.

    -- ea3-60: spawn the boss at the HEART cell (not the path-start
    -- spawn cell). Per Matthew "phase 4 has the boss off the edge of
    -- the arena. can you actually just trigger the actual boss fight?
    -- only environmental change: bring in rough pickle boss model".
    -- Towers autoplaced along the path can now actually REACH the
    -- boss because it sits where they cluster (near the heart).
    -- Boss HP at 250k for a meaningful damage window regardless of
    -- kit DPS.
    -- ea3-96: boss HP now reads from Config.Map3.PickleLord.Hp (single
    -- source of truth across story + sweep). Set to 12000 to match the
    -- 50% pass-rate target on a 5-game-min fight at the catch-up loadout
    -- (see balance memo + Config block). Prior history: 250k → 1M
    -- pre-balance-target, before the math was anchored to a specific
    -- win-rate goal.
    local STATIONARY_BOSS_HP = (Config.Map3 and Config.Map3.PickleLord and Config.Map3.PickleLord.Hp) or 12000
    local boss = waveCtx.makeMob("tank", waypoints, 1.0)
    if boss then
        boss:SetAttribute("MaxHealth", STATIONARY_BOSS_HP)
        boss:SetAttribute("Health",    STATIONARY_BOSS_HP)
        boss:SetAttribute("MobType",   "pickle_boss")  -- StatLedger bucketing
        -- ea3-77: same Health-attribute-vs-activeMobs.hp bug as the
        -- mini-pickle fix in ea3-71. Damage.lua subtracts from
        -- activeMobs[mob].hp directly (line 202: data.hp = data.hp -
        -- amount); the Health attribute is just a mirror written on
        -- every hit. Pre-fix activeMobs[boss].hp was the makeMob
        -- "tank" base HP (~90 × map mults), so towers nuked it in
        -- milliseconds, the boss got destroyed, the Health attribute
        -- mirror dropped to 0, and bossDamageDealt = 1M - 0 = "100%
        -- in 3.4s". Per Matthew "no way they did that much damage."
        -- Override the registry hp + maxHp to STATIONARY_BOSS_HP so
        -- the boss actually has 1M HP that towers chew through.
        if waveCtx.activeMobs and waveCtx.activeMobs[boss] then
            waveCtx.activeMobs[boss].hp     = STATIONARY_BOSS_HP
            waveCtx.activeMobs[boss].maxHp  = STATIONARY_BOSS_HP
            -- ea3-62: actually stop the boss walking. The Speed
            -- attribute is decorative; MobUpdate reads from
            -- activeMobs[mob].speed which is set at makeMob time.
            -- Without overriding that, the boss walks waypoint[1] →
            -- ... → heart at full tank speed regardless of the
            -- attribute. Per Matthew "pickle boss is not supposed
            -- to walk the path".
            waveCtx.activeMobs[boss].speed = 0
        end
        boss:SetAttribute("Speed", 0)  -- decorative, but kept for any read-the-attr code

        -- ea3-88: layout per Matthew 2026-04-29 "heart is bottom
        -- right, spawn top left, pickle boss top middle".
        -- Phase 4 path already does spawn at local (5, 7) =
        -- top-left and heart at (84, 60) = bottom-right (Config.Map4
        -- .PhasePaths[4]). Placing boss at local cell (45, 5) =
        -- centred X, top-row Z makes it the "top middle" sentinel
        -- the player faces from the spawn vantage.
        local PL = (Config.Map3 and Config.Map3.PickleLord) or {}
        local BodyVisibleHeight    = PL.BodyVisibleHeight    or 95
        local BodyTotalHeight      = PL.BodyTotalHeight      or 440
        local BodyWidth            = PL.BodyWidth            or 62
        local BodyDepth            = PL.BodyDepth            or 52
        local BodyColor            = PL.BodyColor            or Color3.fromRGB(60, 110, 50)
        if _hubCtx and _hubCtx.cellToWorld and _hubCtx.MAP4_COL_OFFSET then
            local bossCol = _hubCtx.MAP4_COL_OFFSET + 45  -- centred along width
            local bossRow = 5                              -- top edge (low Z)
            local bossWorld = _hubCtx.cellToWorld(bossCol, bossRow)
            local centerY = bossWorld.Y + BodyVisibleHeight - BodyTotalHeight * 0.5
            boss.CFrame = CFrame.new(bossWorld.X, centerY, bossWorld.Z)
            -- Wide TargetRadius (~Map 4 half-extent + margin) so
            -- every path-side tower has reach to the boss "edge".
            -- The path's farthest cell from boss = (84, 60) — that's
            -- ~111 stud (=39 col×2 + 55 row×2 ≈ 111 stud
            -- Manhattan, ~117 Euclidean). 120 covers it.
            boss:SetAttribute("TargetXZOnly", true)
            boss:SetAttribute("TargetRadius", 120)
            boss:SetAttribute("TargetAimOffsetY",
                (BodyTotalHeight * 0.5) - BodyVisibleHeight + 2)
            boss:SetAttribute("DisplayName", "The Pickle Lord")
        end

        -- Hide the makeMob "tank" placeholder Part — the proper
        -- pickle body below replaces it visually.
        boss.Transparency = 1
        boss.CanCollide = false

        -- ea3-85: tag as FinalBoss so broadcastWaveState picks up
        -- the boss and renders the top-of-screen HUD HP bar (same
        -- path as the story-mode Pickle Lord / Web Weaver / Canopy
        -- Bird). Per Matthew "show hp bar on pickle boss".
        CollectionService:AddTag(boss, Tags.FinalBoss)
        -- Lift the in-world HP-bar anchor to the visible head.
        -- MobUpdate.lua (line 86, 297) sets bbAnchor.CFrame =
        -- mob.CFrame + Vector3.new(0, data.size * 0.9, 0) every
        -- frame, so a one-shot CFrame write would be overwritten.
        -- Override data.size such that data.size * 0.9 = the offset
        -- from boss center to where we want the bar (just above the
        -- visible head, ~BodyTotalHeight/2 + a bit of margin).
        if waveCtx.activeMobs and waveCtx.activeMobs[boss] then
            -- ea3-100: HP bar lowered 30 studs per Matthew. Was previously
            -- BodyTotalHeight * 0.5 + 6 (just above visible head); the
            -- boss is so tall that the bar floated way up where the
            -- player rarely looks. Drop by 30 stud puts it closer to
            -- the eye-stripe / shoulder line.
            local headOffsetFromCenter = BodyTotalHeight * 0.5 + 6 - 30
            waveCtx.activeMobs[boss].size = headOffsetFromCenter / 0.9
        end

        -- Pickle Lord body: 62×440×52 Block with SpecialMesh.Sphere
        -- so the non-uniform Size renders as a stretched ellipsoid
        -- (Roblox's native Ball shape would render as a sphere using
        -- the smallest dim — that's why story mode uses Block + sphere
        -- mesh). Color/material match Config.PickleLord.BodyColor.
        local body = Instance.new("Part")
        body.Name        = "PickleLordBody"
        body.Size        = Vector3.new(BodyWidth, BodyTotalHeight, BodyDepth)
        body.CFrame      = boss.CFrame
        body.Material    = Enum.Material.Slate
        body.Color       = BodyColor
        body.CanCollide  = false
        body.Anchored    = true   -- boss is anchored (speed=0); body inherits
        body.Parent      = boss
        do
            local mesh = Instance.new("SpecialMesh")
            mesh.MeshType = Enum.MeshType.Sphere
            mesh.Parent = body
        end

        -- Two eye spheres on the +Z hemisphere (toward the heart-side
        -- viewer). Match story-mode style — sphere SpecialMesh +
        -- white sclera. Eye Y is inside the visible-top portion
        -- (head ~5 stud below the top edge for an eye-stripe look).
        local bossPos = boss.Position
        local eyeXOffset = 9
        local eyeY = bossPos.Y + BodyTotalHeight * 0.5 - 5
        local eyeZ = bossPos.Z + BodyDepth * 0.5 + 0.3
        for _, sign in ipairs({ -1, 1 }) do
            local eye = Instance.new("Part")
            eye.Name        = ("PickleLordEye_%s"):format(sign > 0 and "R" or "L")
            eye.Size        = Vector3.new(5.2, 5.2, 1.2)
            eye.CFrame      = CFrame.new(bossPos.X + sign * eyeXOffset, eyeY, eyeZ)
            eye.Material    = Enum.Material.SmoothPlastic
            eye.Color       = Color3.fromRGB(245, 245, 235)
            eye.CanCollide  = false
            eye.Anchored    = true
            eye.Parent      = boss
            local em = Instance.new("SpecialMesh")
            em.MeshType = Enum.MeshType.Sphere
            em.Parent = eye
            -- Black pupil (smaller sphere flush in front of the eye).
            local pupil = Instance.new("Part")
            pupil.Name        = "PickleLordPupil"
            pupil.Size        = Vector3.new(2.5, 2.5, 0.6)
            pupil.CFrame      = CFrame.new(bossPos.X + sign * eyeXOffset, eyeY, eyeZ + 0.4)
            pupil.Material    = Enum.Material.SmoothPlastic
            pupil.Color       = Color3.fromRGB(20, 20, 20)
            pupil.CanCollide  = false
            pupil.Anchored    = true
            pupil.Parent      = boss
            local pm = Instance.new("SpecialMesh")
            pm.MeshType = Enum.MeshType.Sphere
            pm.Parent = pupil
        end
    end
    local bossInitialHp = STATIONARY_BOSS_HP

    -- ea3-102: PERMANENT lock on Pickle Lord during phase 4, mirroring
    -- a player who hit the manual-target ("G") binding on the boss.
    -- Ea3-99's auto-release-on-low-HP rule was removed: in practice
    -- the boss is geometrically isolated from the mini-pickle path,
    -- so released-Core towers couldn't finish him via AOE overflow
    -- and he'd sit at low HP until the failsafe (combo 5 of ea3-100
    -- LONG VALIDATE × 8 — 28 real-sec / 560 game-sec stuck at 2126 HP).
    --
    -- ea3-102: opts.lockAllTowersOnBoss extends the lock to EVERY
    -- player-owned tower (Core + Aux) — not just Core. LONG VALIDATE
    -- alternates this per-combo so we get a paired comparison of
    -- "Core-only focus" vs "all-team focus" in one sweep.
    --
    -- Mechanism: Targeting.lua's ctx.towerManualTargets[tower] = mob
    -- override (the same channel the bullseye / "G" UI writes through).
    local lockAll = opts and opts.lockAllTowersOnBoss
    local lockedTowers = {}
    if boss and waveCtx.towerManualTargets then
        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local towerModel = towerBase.Parent
            if towerModel and towerModel:GetAttribute("Owner") == player.UserId then
                local isCore = CoreTypes.isCore(towerModel:GetAttribute("TowerType"))
                if lockAll or isCore then
                    waveCtx.towerManualTargets[towerModel] = boss
                    lockedTowers[#lockedTowers + 1] = towerModel
                end
            end
        end
        print(("[ArenaSweepRunner] phase 4: locked %d %s tower(s) onto Pickle Lord (PERMANENT)"):format(
            #lockedTowers, lockAll and "ALL" or "Core"))
    end

    -- Spawn the mini-pickle swarm coroutine (continuous spawn until
    -- heart dies or the run ends). Mini pickles use the "fast" mob
    -- type (walks the path quickly) — they leak past the towers and
    -- bash the heart, providing the "overwhelmed" pressure even
    -- though the towers are firing once the penalty lifts.
    -- ea3-71: per Matthew "increase infinite mini pickles to have
    -- same hp as pickles on pickle lord fight mini pickles" — HP
    -- now matches Config.PickleLord.MiniHp (7000 by default) so
    -- the sweep mini pickles are a credible threat for towers
    -- enhanced through 3 phases. Pre-fix HP was 9 (fast base 18 ×
    -- 0.5 mult); towers nuked them in milliseconds and the boss
    -- damage measurement reflected only chaff cleanup, not the
    -- real story-mode pressure.
    -- ea3-80: same Config-path fix as the boss block — PickleLord
    -- is nested under Config.Map3, not at top level. Pre-fix worked
    -- only because the fallback (7000) happened to match.
    local PL = (Config.Map3 and Config.Map3.PickleLord) or {}
    local miniHp           = PL.MiniHp or 7000
    -- ea3-93: match story-mode mini-pickle bunched-spawn cadence
    -- per Matthew "mini pickles are supposed to come in bunches of
    -- 3s. go back and take a long look at story mode pickle boss
    -- fight." Story (PickleLordBoss.lua line 1391-1436):
    --   first-spawn delay: MiniFirstSpawnDelayGameSec (5 game-sec)
    --   per 6-mini cycle waits between spawns:
    --     1→2: 0.5s (bunch)
    --     2→3: 0.5s (bunch — first three arrive in 1 game-sec)
    --     3→4: 5s   (spread)
    --     4→5: 5s
    --     5→6: 5s
    --     6→1: 8s   (long reset before next bunch)
    --   Total: 24 game-sec / 6 minis = 4 sec/mini avg (matches
    --   MiniSpawnIntervalGameSec = 4 in average rate, but clumpier
    --   so AOE / splash towers can capitalize on the bunched arrivals)
    --
    -- ea3-89's even 4-sec spacing matched the average rate but
    -- killed the bunching mechanic — multi-target towers had no
    -- bunched targets to splash across, dropping their effective
    -- DPS contribution.
    local miniSpeed         = PL.MiniMoveSpeedStud or 7
    local firstDelayGame    = PL.MiniFirstSpawnDelayGameSec or 5.0
    -- Per-mini wait sequence (6-cycle). Indexed 1-6 for "wait AFTER
    -- mini N spawned"; wraps via modulo.
    local CYCLE_WAITS = { 0.5, 0.5, 5.0, 5.0, 5.0, 8.0 }
    local miniPickleActive = true
    task.spawn(function()
        -- Story warm-up: wait MiniFirstSpawnDelayGameSec before the
        -- first mini so the player has a beat after the boss appears.
        task.wait(firstDelayGame / math.max(1, gameSpeed()))
        local count = 0
        while miniPickleActive do
            if isMap4HeartDead() then break end
            count = count + 1
            local m = waveCtx.makeMob("fast", waypoints, 1.0)
            if m then
                m:SetAttribute("MaxHealth", miniHp)
                m:SetAttribute("Health",    miniHp)
                if waveCtx.activeMobs and waveCtx.activeMobs[m] then
                    local data = waveCtx.activeMobs[m]
                    data.hp     = miniHp
                    data.maxHp  = miniHp
                    data.damage = miniHp
                    -- Speed override (story-mode parity). MobUpdate
                    -- reads activeMobs[m].speed, not the Speed attr.
                    data.speed  = miniSpeed
                    -- HP-bar text refresh after override.
                    if data.hpText then
                        data.hpText.Text = string.format("%d / %d", miniHp, miniHp)
                    end
                    if data.hpFill then
                        data.hpFill.Size = UDim2.fromScale(1, 1)
                    end
                end
            end
            if not miniPickleActive then break end
            local positionInCycle = ((count - 1) % 6) + 1
            local waitGame = CYCLE_WAITS[positionInCycle]
            task.wait(waitGame / math.max(1, gameSpeed()))
        end
    end)

    -- ea3-64: setup-penalty in GAME TIME, not real time. At 20×
    -- game speed, the 10s player-perspective setup is 0.5s real;
    -- without dividing by gameSpeed the simulation paused towers
    -- for 200 game-seconds (40× longer than story-mode players
    -- experience). Per Matthew "tower penalty should adjust for
    -- speed up". gameSpeed of 1× preserves the legacy 10s wait.
    local penaltyRealSec = 10 / math.max(1, gameSpeed())
    task.spawn(function()
        task.wait(penaltyRealSec)
        Workspace:SetAttribute("ArenaSweepNoFire", false)
        print(("[ArenaSweepRunner] Phase 4 — setup penalty lifted (%.2fs real / 10s game), towers firing"):format(
            penaltyRealSec))
    end)

    -- Run loop: wait for natural exit conditions. Per Matthew
    -- 2026-04-29 "5 minute timer isn't a hard stop, it's when the
    -- pickles should overrun the player ... remove all stops unless
    -- they're failsafes" — the design intent is that the heart
    -- naturally dies around 5 game-min from mini-pickle pressure,
    -- not that a script ceiling stops the fight at 5 min.
    --
    -- Natural exits:
    --   1) heart dies (loadout failed to keep pace with swarm)
    --   2) boss dies (loadout outpaced the swarm + nuked boss)
    --   3) STOP clicked (cooperative abort)
    --
    -- Failsafe exit:
    --   4) 30 game-min runaway guard — only fires if neither the
    --      heart nor the boss died, which means towers are too
    --      strong AND the swarm is too weak, an unbalanced kit.
    --      Failsafe is generous so it doesn't masquerade as a
    --      design stop.
    local FAILSAFE_GAME_SEC = 1800  -- 30 game-min
    local realFailsafe = FAILSAFE_GAME_SEC / math.max(1, gameSpeed())
    local startedAt = os.clock()
    local function isBossDead(): boolean
        if not boss or not boss.Parent then return true end
        if waveCtx.activeMobs and waveCtx.activeMobs[boss] then
            return (waveCtx.activeMobs[boss].hp or 0) <= 0
        end
        return false
    end
    while not isMap4HeartDead() do
        if _state and _state.aborted then break end
        if isBossDead() then
            print("[ArenaSweepRunner] Phase 4 — boss dead, exiting")
            break
        end
        if os.clock() - startedAt > realFailsafe then
            print(("[ArenaSweepRunner] Phase 4 — failsafe ceiling hit (%d game-sec / %.0f real-sec at %dx) — kit may be unbalanced"):format(
                FAILSAFE_GAME_SEC, realFailsafe, gameSpeed()))
            break
        end
        task.wait(0.2)
    end

    -- Stop the mini-pickle spawner.
    miniPickleActive = false
    Workspace:SetAttribute("ArenaSweepNoFire", false)

    -- Compute damage dealt to the boss.
    local bossFinalHp = (boss and boss:GetAttribute("Health")) or 0
    local bossDamageDealt = bossInitialHp - bossFinalHp

    -- Cleanup: kill the stationary boss model + any leftover mini
    -- pickles (clearAllMobs from waveCtx wipes mob registry too).
    if waveCtx.clearAllMobs then waveCtx.clearAllMobs() end

    print(("[ArenaSweepRunner] Phase 4 END — boss damage = %d / %d (%d%%) in %.1fs"):format(
        bossDamageDealt, bossInitialHp,
        math.floor(bossDamageDealt / bossInitialHp * 100 + 0.5),
        os.clock() - startedAt))

    if hooks and hooks.onPhase4End then
        hooks.onPhase4End({
            bossDamageDealt = bossDamageDealt,
            bossInitialHp   = bossInitialHp,
            elapsedSeconds  = os.clock() - startedAt,
        })
    end

    return {
        cleared          = true,  -- phase 4 always "ends" — measure is damage, not survival
        bossDamageDealt  = bossDamageDealt,
        bossInitialHp    = bossInitialHp,
        elapsedSeconds   = os.clock() - startedAt,
    }
end

-- ea3-86: per-phase descendant breakdown so we can pinpoint where
-- the +194/combo Map 4 descendant leak (logged via ea3-77) is
-- coming from. Counts the total Map 4 descendants AND the
-- size of each prime-suspect folder (PathTiles rebuilt per phase
-- change; SlimeRiver / Bridges / Volcano scenery toggled per
-- sweep; SteamClouds / PickleTrees built once at boot). Spaced
-- out per phase end + at sweep start/end so we can see WHICH
-- transition adds the 194 between two consecutive combos.
local function diagDescendants(label: string)
    local map4Room = Workspace:FindFirstChild("TreeOfLifeMap4Room")
    if not map4Room then return end
    local total = #map4Room:GetDescendants()
    local function folderCount(name: string): number
        local f = map4Room:FindFirstChild(name)
        return f and #f:GetDescendants() or 0
    end
    if SWEEP_VERBOSE then
        print(("[Sweep diag] %s — total=%d  paths=%d river=%d bridges=%d volcano=%d steam=%d trees=%d"):format(
            label, total,
            folderCount("Map4PathTiles"),
            folderCount("Map4SlimeRiver"),
            folderCount("Map4Bridges"),
            folderCount("Map4Volcano"),
            folderCount("Map4SteamClouds"),
            folderCount("Map4PickleTrees")))
    end
end

-- ===========================================================================
-- Public: runOneCombo
-- ===========================================================================

function ArenaSweepRunner.runOneCombo(player: Player, opts: any, hooks: any)
    if _state ~= nil then
        warn("[ArenaSweepRunner] runOneCombo called while another combo is active — ignoring")
        return false
    end
    if not player or not player.Parent then
        warn("[ArenaSweepRunner] runOneCombo with no valid player")
        return false
    end
    opts = opts or {}
    hooks = hooks or {}
    local result = {
        coreId       = opts.coreId,
        auxIds       = opts.auxIds or {},
        phaseResults = {},
        finalPhase   = nil,
        statSnapshot = nil,
        startedAt    = os.clock(),
    }

    _state = { player = player, opts = opts, result = result }

    -- ea3-138: heart-overkill capture for AUTORUN. Same hook
    -- runFailureCurveCombo uses; without it, killing-blow overkill
    -- data was being discarded for AUTORUN runs (the legacy enter()/
    -- exit() flow installed it but ArenaSweepRunner didn't). Stored
    -- on result so the per-combo log + post-sweep summary can show
    -- it. AUTORUN's data path doesn't flow into the cumulative pool
    -- the same way FAILURE CURVE's does (different aggregation —
    -- finalPhase vs finalWave), so we don't add fields to the
    -- arena-result schema here; just capture for log visibility.
    local heartCapture = {}
    local priorOverkillHook = installHeartOverkillHook(heartCapture)
    result.heartCapture = heartCapture  -- exposed for printing post-combo
    -- ea3-79: visuals stay at whatever the user has set them to.
    -- Pre-fix ea3-55 auto-disabled InfiniteVisuals so the analyst
    -- wouldn't have to watch the swarm — but per Matthew 2026-04-29
    -- "monsters still do not spawn" — combined with MobFactory's
    -- visuals-off branch (Transparency=1 when InfiniteVisuals~=true),
    -- mobs were rendering invisibly even though the server log
    -- confirmed them spawning. Default-on now so the player can
    -- actually see the sweep. Stash the prior value anyway in case
    -- a future toggle overrides during the sweep — restore on
    -- completion stays.
    local visualsBefore = Workspace:GetAttribute("InfiniteVisuals")
    if visualsBefore == nil then
        Workspace:SetAttribute("InfiniteVisuals", true)
    end
    _state.visualsBefore = visualsBefore
    -- ea3-68: hide Map 4 scenery (river / bridge / volcano) +
    -- free river-cells during the sweep. Map4.lua listens to
    -- Workspace.Map4ArenaSweepActive and re-parents the three
    -- scenery folders to ServerStorage's CullStash + flips
    -- "river" cells to "open". On combo end we set it back so
    -- the live Pickle Swamp shows scenery again. Per Matthew
    -- 2026-04-29 "put the river bridge and volcano back but
    -- remove it when you rebuild for sims".
    Workspace:SetAttribute("Map4ArenaSweepActive", true)
    -- ea3-73: force-unpause if the game was paused before the
    -- sweep started (e.g. user paused, then clicked LONG VALIDATE
    -- without unpausing). WaveSystem's pause handler now ignores
    -- subsequent pause requests during a sweep (Map4ArenaSweepActive
    -- gate), but it can't undo a pause that was set BEFORE the
    -- gate was raised. This direct attribute reset + ctx.paused
    -- clear unblocks the wave system's mob/tower loops so the
    -- sweep's wait-for-clear actually drains.
    if Workspace:GetAttribute("GamePaused") == true then
        Workspace:SetAttribute("GamePaused", false)
        if WaveCtxBridge.ctx then
            WaveCtxBridge.ctx.paused = false
        end
        print("[ArenaSweepRunner] cleared pre-existing pause state for sweep start")
    end

    -- Equip the chosen Core.
    if opts.coreId then
        for _, c in ipairs(CoreTypes.Ids) do
            player:SetAttribute(c .. "Equipped", c == opts.coreId)
        end
    end

    -- Heal hearts so prior runs don't bleed in.
    healAllHearts()

    -- ea3-55: clear stale Map 4 towers from prior runs so phase 1
    -- (Core only) doesn't inherit auxes that were on the field
    -- before the sweep started. Each phase's placeTowersForPhase
    -- is idempotent; this is what makes the SWEEP idempotent.
    clearPlayerMap4Towers(player)

    -- ea3-67: defensive state reset between sweeps. Three leaks
    -- compound across back-to-back VALIDATE / AUTORUN runs and
    -- crashed Studio mid-phase-2 in the ea3-66 second-run dump:
    --   1) <towerId>Stock attrs accumulate (placeTowerForRole does
    --      Stock = existing + 1 with no decrement, so run 2 starts
    --      double-stocked).
    --   2) Core upgrade <id>Stacks attrs accumulate across runs;
    --      synthetic Core upgrade fires once per phase boundary,
    --      so run 2's phase-1 towers carry run 1's stacks.
    --   3) Leftover mobs from a heart-died phase: runOneWave's
    --      spawn loop spawns ALL mobs unconditionally then checks
    --      heart state — orphan mobs continue walking the path
    --      with no caller waiting on them. Run 2's countActiveMobs
    --      sees them, plus run 2's spawns also pile on; at 20×
    --      game speed the combined pressure exceeds Roblox's
    --      script-runtime budget → disconnect.
    -- Wipe leftover mobs (orphan walkers).
    if WaveCtxBridge.ctx and WaveCtxBridge.ctx.clearAllMobs then
        WaveCtxBridge.ctx.clearAllMobs()
    end
    -- Zero accumulated tower Stock attributes.
    for _, c in ipairs(CoreTypes.Ids) do
        player:SetAttribute(c .. "Stock", 0)
    end
    for id in pairs(TempTowers.Templates) do
        player:SetAttribute(id .. "Stock", 0)
        -- Also reset the Equipped flag to false; the explicit aux
        -- placements below set it back to true on the chosen ones.
        player:SetAttribute(id .. "Equipped", false)
    end
    -- Zero accumulated Core upgrade stacks (all 3 Cores).
    for _, c in ipairs(CoreTypes.Ids) do
        local options = CoreUpgrades.optionsFor(c)
        if options then
            for _, opt in ipairs(options) do
                if opt and opt.id then
                    player:SetAttribute(opt.id .. "Stacks", 0)
                end
            end
        end
    end
    -- ea3-80: clear RUN LUCK between combos. RunLuckSum / RunLuckCount
    -- track the average rarity score of every upgrade card SHOWN
    -- during the run (UpgradeCards.lua line 370-373). Story mode
    -- resets these on RunReset; sweep now resets per combo so the
    -- 8 LONG VALIDATE combos are statistically independent.
    --
    -- ea3-83: seed at display 5/10 ("average greedy player" baseline).
    -- Per Matthew "start runluck at 5". UpgradeCards' DevPanel mapper
    -- anchors avg rarity 2.71 → display 5 (line 857). count=1, sum=2.71
    -- gives display 5 instantly; the seed dissipates fast (after 1
    -- real pick the seed is half the weight, after 4 picks it's 1/5)
    -- so the displayed luck still tracks actual sweep RNG —
    -- it just opens the combo at 5/10 instead of 0.
    player:SetAttribute("RunLuckSum",   2.71)
    player:SetAttribute("RunLuckCount", 1)
    player:SetAttribute("MapPickCount", 0)

    -- ea3-94: clear CUMULATIVE UPGRADE BONUSES between combos.
    -- UpgradeCards.applyUpgrade writes player-level cumulative
    -- attributes (CoreDamageFlat, CoreRangePct, CoreFireRatePct,
    -- CoreAoeRadius, CoreStunDuration/Chance, CoreKnockback/Chance,
    -- CoreMaxShotsMult, MaxCarry, plus the Aux mirrors). New towers
    -- placed in the NEXT combo READ these attributes during placement
    -- and inherit the previous combo's bonuses — so combo 2's wave 5
    -- clear was 2.6s vs combo 1's 5.3s with full heart, etc.
    --
    -- The Stock/Equipped/Stacks reset above zeros the per-tower model
    -- attributes (which get destroyed and rebuilt anyway), but the
    -- player-level mirrors persist on the Player Instance until we
    -- explicitly clear them here.
    --
    -- Defaults match UpgradeCards.applyUpgrade fallbacks:
    --   MaxCarry default 15 (line 550)
    --   CoreMaxShotsMult default 1.0 (line 564)
    --   AOE/Knockback/Stun default nil ("not picked yet")
    for _, cat in ipairs({ "Core", "Aux" }) do
        player:SetAttribute(cat .. "DamageFlat",   0)
        player:SetAttribute(cat .. "RangePct",     0)
        player:SetAttribute(cat .. "FireRatePct",  0)
    end
    player:SetAttribute("CoreAoeRadius",       nil)
    player:SetAttribute("CoreKnockback",       nil)
    player:SetAttribute("CoreKnockbackChance", nil)
    player:SetAttribute("CoreStunDuration",    nil)
    player:SetAttribute("CoreStunChance",      nil)
    player:SetAttribute("MaxCarry",            15)
    player:SetAttribute("CoreMaxShotsMult",    1.0)
    -- Ammo-threshold guards (UpgradeCards line 688-691) used by the
    -- DevPanel "force ammo at SPS X" logic. Clear so each combo's
    -- ammo decisions are independent.
    player:SetAttribute("DevAmmoPickedAt5",  false)
    player:SetAttribute("DevAmmoPickedAt15", false)

    -- ea3-98: realistic story-mode reroll model. Combo starts with 3
    -- reroll TOKENS (persistent pool); each phase 1-3 grants 1 perMap
    -- reroll on entry (set via maxRerollsPerStage in fireOneUpgradePicker)
    -- and 1 token on boss-defeat exit; phase 4 catch-up gets no perMap
    -- but spends leftover tokens. See picker comment block for full
    -- mechanics. Per Matthew "realistic reroll budget across runs".
    player:SetAttribute("RerollTokens", 3)
    player:SetAttribute("RerollsUsed",  0)

    -- ea3-74: ETA bar uses REAL wall-clock time elapsed since sweep
    -- start, refreshed on every fireProgress call. Pre-fix the
    -- elapsed value bumped only at phase end (PHASE_REAL_TIME_S
    -- chunks of 50-65s), so the ETA "Xs left" stayed stuck for
    -- ~50s at a time even though the LABEL changed per wave.
    -- Per Matthew "status bar not updating after waves" — now
    -- ETA decrements continuously in 0.2-3s steps as fireProgress
    -- fires from each wave start / pick / phase boundary.
    local comboTotalSec  = (opts.totalEstimateSec) or comboEstimateSec()
    local comboLabel     = opts.progressLabel or "VALIDATE"
    -- ea3-106: prefer caller-supplied sweep start timestamp so multi-combo
    -- runs (LONG VALIDATE × 8) see a CONTINUOUSLY decrementing ETA across
    -- all 8 combos, not a per-combo reset. Pre-fix: each combo overwrote
    -- sweepStartedAt = os.clock() at start, but comboTotalSec was still
    -- the SWEEP-WIDE total (220s × 8 = 1,760s) — so the bar jumped from
    -- "26m left" back to "29m left" at every combo boundary. Now LONG
    -- VALIDATE captures os.clock() before the combo loop and passes it
    -- via opts.sweepStartedAt; single-combo callers (regular VALIDATE)
    -- omit it and get the local fresh-clock behavior as before.
    local sweepStartedAt = opts.sweepStartedAt or os.clock()
    local function fireProgressNow(label)
        local elapsed = os.clock() - sweepStartedAt
        fireProgress(player, elapsed, comboTotalSec, label)
    end
    -- Stash on _state so runStationaryBossPhase can fire its own
    -- progress label ("PICKLE LORD") with the right elapsed/total.
    if _state then
        _state.sweepStartedAt = sweepStartedAt
        _state.comboTotalSec  = comboTotalSec
        _state.fireProgressNow = fireProgressNow
    end

    -- ea3-86: combo-start descendant snapshot (anchor for comparison).
    diagDescendants("combo start (post-reset)")

    -- Iterate phases.
    for phase = 1, 4 do
        -- ea3-74: cooperative abort check at top of phase loop.
        if _state and _state.aborted then break end
        if hooks.onPhaseStart then hooks.onPhaseStart(phase) end
        -- ea3-78: reset RerollsUsed at phase start so each phase has
        -- its own reroll budget (story does this per stage; sweep
        -- "phase" = stage). Without the reset, phase 2 inherits
        -- phase 1's exhausted reroll counter and the auto-pick
        -- can't reroll past Common-only sets in phases 2-4.
        player:SetAttribute("RerollsUsed", 0)
        Workspace:SetAttribute("Map4ActivePhase", phase)
        task.wait(0.5)  -- let path / grid rebuild settle
        -- ea3-86: phase-start snapshot (after the path / scenery
        -- rebuild settles). Comparing this vs combo-start tells us
        -- if the path-tile / scenery rebuild on phase change is
        -- leaking; comparing this vs phase-end tells us if waves /
        -- towers / boss spawns leak.
        diagDescendants(("phase %d start"):format(phase))
        fireComboInfo(player, opts, phase)
        fireProgressNow(comboLabel)

        placeTowersForPhase(player, opts, phase)
        task.wait(0.3)

        if phase < 4 then
            -- 2 skipped breather waves → 2 upgrade picks.
            for breather = 1, 2 do
                if _state and _state.aborted then break end
                fireProgressNow(("MAP %d  •  UPGRADE %d/4"):format(phase, breather))
                fireOneUpgradePicker(player, breather)
                task.wait(0.1)
            end
            -- Run waves 3, 4, 5 (boss spawn filtered out)
            local waveCleared = true
            for waveIdx, waveN in ipairs(PHASE_WAVES_TO_RUN) do
                if _state and _state.aborted then waveCleared = false; break end
                if isMap4HeartDead() then waveCleared = false; break end
                fireRoundUpdate(player, phase, waveN)
                fireProgressNow(("MAP %d  •  WAVE %d"):format(phase, waveN))
                local waveData = WaveData.WAVES[waveN]
                if waveData then
                    runOneWave(waveData, PHASE_HP_MULT[phase],
                        ("phase %d wave %d"):format(phase, waveN))
                end
                if isMap4HeartDead() then waveCleared = false; break end
                if waveIdx < #PHASE_WAVES_TO_RUN then
                    fireProgressNow(("MAP %d  •  UPGRADE %d/4"):format(phase, 2 + waveIdx))
                    fireOneUpgradePicker(player, waveN)
                    task.wait(0.1)
                end
            end
            -- ea3-98: boss-defeat reward — +1 reroll token. Story mode
            -- grants a token on each map-boss kill; sweep mirrors that
            -- here at end-of-phase 1-3 (assuming the phase cleared,
            -- since a heart-death exit means boss never died). The
            -- token persists into the next phase. Phase 4's Pickle Lord
            -- doesn't fire this since the run ends with that fight
            -- (no future picks to spend a token on anyway).
            if waveCleared then
                local prevTokens = player:GetAttribute("RerollTokens") or 0
                player:SetAttribute("RerollTokens", prevTokens + 1)
                print(("[Sweep] phase %d boss reward: +1 reroll token (now %d total)"):format(
                    phase, prevTokens + 1))
            end

            -- Synthetic Core upgrade pick at phase boundary.
            -- ea3-74: status update before the synthetic Core fire
            -- so the bar advances even though the pick itself is
            -- silent. Without this fire, the bar sits on "WAVE 5"
            -- through the synthetic + the 0.5s phase-rebuild wait.
            if not (_state and _state.aborted) then
                fireProgressNow(("MAP %d  •  CORE UPGRADE"):format(phase))
            end
            fireSyntheticCoreUpgrade(player, phase)
            result.phaseResults[phase] = {
                cleared = waveCleared,
                heartHp = (function()
                    for _, h in ipairs(CollectionService:GetTagged(Tags.EnemyEndPoint)) do
                        if h:GetAttribute("MapId") == 4 then
                            return h:GetAttribute("Health") or 0
                        end
                    end
                    return 0
                end)(),
            }
            if not waveCleared then
                result.finalPhase = phase
                break
            end
        else
            -- ea3-90: catch-up upgrade picks before the Pickle Lord
            -- fight. Sweep accumulates ~12 wave-card picks across
            -- phases 1-3 (4 per phase × 3); a real story-mode player
            -- arriving at the Pickle Lord has ~36 picks (4 per
            -- stage × 3 stages × 3 maps). Per Matthew "player
            -- should be able to live for 5 minutes at 1x on pickle
            -- boss" — the sweep heart was leaking in 60-100 game-sec
            -- because towers carrying 1/3 the upgrade load couldn't
            -- maintain a 95% mini-pickle kill rate. 24 catch-up
            -- picks bring sweep towers up to story-equivalent.
            -- ea3-97: reroll-budget reset now lives INSIDE
            -- fireOneUpgradePicker (resets every 3 picks via the
            -- pickInStage == 1 check) — no need for a per-batch
            -- pre-reset here. Catch-up just fires picks linearly;
            -- waveIndex 1..24 maps via (waveIdx - 1) % 3 to batches
            -- of 3 → 8 reroll-budget refreshes across the 24 picks.
            local CATCHUP_PICKS = 24
            fireProgressNow(("MAP %d  •  CATCHING UP (%d picks)"):format(phase, CATCHUP_PICKS))
            print(("[Sweep] phase 4 catch-up — firing %d upgrade picks to reach story-equivalent tower power"):format(
                CATCHUP_PICKS))
            for i = 1, CATCHUP_PICKS do
                if _state and _state.aborted then break end
                fireOneUpgradePicker(player, i)
                task.wait(0.05)
            end
            -- Phase 4 stationary boss + mini-pickle swarm.
            local phase4Result = runStationaryBossPhase(player, opts, hooks)
            result.phaseResults[4] = phase4Result
        end

        -- ea3-74: phase-end progress fire (real-time elapsed).
        fireProgressNow(comboLabel)

        -- ea3-86: phase-end descendant snapshot.
        diagDescendants(("phase %d end"):format(phase))

        if hooks.onPhaseEnd then hooks.onPhaseEnd(phase, result.phaseResults[phase]) end
    end

    if not result.finalPhase then
        result.finalPhase = 4  -- completed all 4 phases
    end
    -- ea3-74: surface aborted flag on result so multi-combo
    -- callers (LONG VALIDATE, AUTORUN, SUPER) break out of their
    -- outer loops when STOP was clicked.
    result.aborted = (_state and _state.aborted) == true
    result.statSnapshot   = StatLedger.snapshot()
    result.elapsedSeconds = os.clock() - result.startedAt

    -- ea3-77: part-count diagnostic so we can see if Workspace
    -- instances accumulate across combos (suspected cause of the
    -- combo-2 mid-phase-4 Studio disconnect on the ea3-76 LONG
    -- VALIDATE dump). Counts only Map-4-relevant containers so
    -- noise from Map 1/2/3 builds doesn't drown the signal.
    local map4Room = Workspace:FindFirstChild("TreeOfLifeMap4Room")
    local map4Parts = map4Room and #map4Room:GetDescendants() or 0
    local activeMobCount = 0
    if WaveCtxBridge.ctx and WaveCtxBridge.ctx.countActiveMobs then
        activeMobCount = WaveCtxBridge.ctx.countActiveMobs()
    end
    local taggedTowers = 0
    for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local t = base.Parent
        if t and t:GetAttribute("Owner") == player.UserId then
            taggedTowers = taggedTowers + 1
        end
    end
    print(("[Sweep] combo end — Map4 descendants=%d, active mobs=%d, player towers=%d"):format(
        map4Parts, activeMobCount, taggedTowers))

    AutoPicker.endAuto()
    -- ea3-55: restore InfiniteVisuals to pre-sweep value (was set to
    -- false at start so the analyst doesn't have to watch the swarm).
    Workspace:SetAttribute("InfiniteVisuals", _state.visualsBefore)
    -- ea3-68: restore Map 4 scenery (river / bridge / volcano).
    Workspace:SetAttribute("Map4ArenaSweepActive", false)
    -- ea3-69: restore the live Pickle Swamp to phase 3 (full bounds,
    -- full heart, full path). Per Matthew "bring the full pickle
    -- swamp map 4 build back after a sim runs". Without this, the
    -- last-active phase's narrow bounds + small heart linger
    -- (e.g. phase 1's Map-1-equivalent inner area) until the next
    -- sweep starts. Map4.lua's GetAttributeChangedSignal handler
    -- picks this up + rebuilds grid / waypoints / heart pos /
    -- visual path tiles to phase 3 defaults.
    Workspace:SetAttribute("Map4ActivePhase", 3)
    -- ea3-57: clear progress bar (fraction=1 + label="DONE" so the
    -- HUD can fade it out cleanly).
    fireProgress(player, comboTotalSec, comboTotalSec, "DONE")
    _state = nil

    -- ea3-103: capture luck snapshot for this combo before returning.
    -- RunLuckSum / RunLuckCount are player-attribute counters
    -- (UpgradeCards.lua:370-373) that increment per card SHOWN. The
    -- combo's "average rarity score" = RunLuckSum / RunLuckCount,
    -- where 1=Common, 2=Rare, 3=Exceptional/Special, 4=Legendary,
    -- 5=Mythical (RARITY_TO_SCORE in UpgradeCards). 2.71 is the
    -- expected mean given the 50/25/10/5/2/8 default distribution
    -- and the seed at combo start. Higher avg = better rolls.
    do
        local luckSum   = (player:GetAttribute("RunLuckSum")   or 0)
        local luckCount = (player:GetAttribute("RunLuckCount") or 0)
        result.luckSum   = luckSum
        result.luckCount = luckCount
        result.luckAvg   = (luckCount > 0) and (luckSum / luckCount) or 0
    end

    -- ea3-138: tear down the overkill hook + log the capture.
    uninstallHeartOverkillHook(priorOverkillHook)
    if heartCapture.killingBlowOverkill and heartCapture.killingBlowOverkill > 0 then
        print(("[ArenaSweepRunner.oneCombo]   killingBlowOverkill=%d  heartHpBeforeKill=%d  killingBlowDamage=%d"):format(
            math.floor(heartCapture.killingBlowOverkill + 0.5),
            math.floor((heartCapture.heartHpBeforeKill or 0) + 0.5),
            math.floor((heartCapture.killingBlowDamage or 0) + 0.5)))
    end

    if result.finalPhase == 4 then
        if hooks.onComplete then hooks.onComplete(result) end
    else
        if hooks.onFailed then hooks.onFailed(result.finalPhase, result) end
    end
    return result
end

-- ===========================================================================
-- ea3-52 Phase F — sweep mode outer loops
-- ===========================================================================

-- Greedy search: 3 cores × 1 + 14 auxes × 1 + 13 × 1 + 12 × 1 = 42 runs.
-- Picks the best Core, then best aux for that Core, etc. Returns the
-- aggregated summary.
function ArenaSweepRunner.runGreedySweep(player, opts, hooks)
    opts = opts or {}
    hooks = hooks or {}
    local results = {}
    local function progress(label, current, total)
        print(("[ArenaSweepRunner.greedy] %s — %d/%d"):format(label, current, total))
        if hooks.onProgress then hooks.onProgress(label, current, total) end
    end

    -- ea3-113: sweep-wide ETA so the HUD progress bar reflects total run
    -- progress (X of 42 combos remaining), not per-combo. Without this,
    -- the bar resets every ~50s as each combo starts. Same pattern LONG
    -- VALIDATE / SPOT CHECK use. PER_COMBO_SEC is the observed wall time
    -- per 4-phase combo at 20× game speed (~50s each per ea3-112 logs);
    -- 60s gives a small safety margin so the bar never goes negative.
    local PER_COMBO_SEC = 60
    -- 3 cores + 14 + 13 + 12 = 42, but build aux list first to use real count.
    local auxIds = {}
    for id in pairs(TempTowers.Templates) do table.insert(auxIds, id) end
    table.sort(auxIds)
    local totalCombos = #CoreTypes.Ids + #auxIds + (#auxIds - 1) + (#auxIds - 2)
    local sweepStartedAt = os.clock()
    local totalEstimateSec = PER_COMBO_SEC * totalCombos
    local comboIdx = 0

    -- 1) Pick best Core (3 runs, no aux).
    local coreScores = {}
    local stage1Total = #CoreTypes.Ids
    for i, coreId in ipairs(CoreTypes.Ids) do
        progress("stage 1 / Core sweep", i, stage1Total)
        comboIdx += 1
        local r = ArenaSweepRunner.runOneCombo(player, {
            coreId = coreId,
            auxIds = {},
            autoPickerOpts = opts.autoPickerOpts or { mode = "random" },
            progressLabel    = ("AUTO %d/%d"):format(comboIdx, totalCombos),
            totalEstimateSec = totalEstimateSec,
            sweepStartedAt   = sweepStartedAt,
        }, {})
        coreScores[coreId] = r and r.finalPhase or 0
        table.insert(results, { stage = 1, coreId = coreId, result = r })
    end
    local bestCore = "Power"
    local bestCoreScore = -1
    for cid, s in pairs(coreScores) do
        if s > bestCoreScore then bestCoreScore = s; bestCore = cid end
    end
    print(("[ArenaSweepRunner.greedy] best Core = %s (phase %d)"):format(bestCore, bestCoreScore))

    -- Aux iteration list is hoisted above (used for totalCombos calc).
    -- TempTowers.Templates is the canonical aux roster (excludes the
    -- Pickle Lord permanent slot).

    -- 2) Best aux paired with bestCore.
    local auxScores = {}
    local stage2Total = #auxIds
    for i, auxId in ipairs(auxIds) do
        progress("stage 2 / aux sweep", i, stage2Total)
        comboIdx += 1
        local r = ArenaSweepRunner.runOneCombo(player, {
            coreId = bestCore,
            auxIds = { auxId },
            autoPickerOpts = opts.autoPickerOpts or { mode = "random" },
            progressLabel    = ("AUTO %d/%d"):format(comboIdx, totalCombos),
            totalEstimateSec = totalEstimateSec,
            sweepStartedAt   = sweepStartedAt,
        }, {})
        auxScores[auxId] = r and r.finalPhase or 0
        table.insert(results, { stage = 2, coreId = bestCore, auxIds = {auxId}, result = r })
    end
    local bestAux1 = nil
    local bestAux1Score = -1
    for aux, s in pairs(auxScores) do
        if s > bestAux1Score then bestAux1Score = s; bestAux1 = aux end
    end

    -- 3) Best 2nd aux given (bestCore, bestAux1).
    local aux2Scores = {}
    local stage3Total = #auxIds - 1
    local stage3Idx = 0
    for _, auxId in ipairs(auxIds) do
        if auxId == bestAux1 then continue end
        stage3Idx = stage3Idx + 1
        progress("stage 3 / 2nd aux", stage3Idx, stage3Total)
        comboIdx += 1
        local r = ArenaSweepRunner.runOneCombo(player, {
            coreId = bestCore,
            auxIds = { bestAux1, auxId },
            autoPickerOpts = opts.autoPickerOpts or { mode = "random" },
            progressLabel    = ("AUTO %d/%d"):format(comboIdx, totalCombos),
            totalEstimateSec = totalEstimateSec,
            sweepStartedAt   = sweepStartedAt,
        }, {})
        aux2Scores[auxId] = r and r.finalPhase or 0
        table.insert(results, { stage = 3, coreId = bestCore, auxIds = {bestAux1, auxId}, result = r })
    end
    local bestAux2 = nil
    local bestAux2Score = -1
    for aux, s in pairs(aux2Scores) do
        if s > bestAux2Score then bestAux2Score = s; bestAux2 = aux end
    end

    -- 4) Best 3rd aux given (bestCore, bestAux1, bestAux2).
    local aux3Scores = {}
    local stage4Total = #auxIds - 2
    local stage4Idx = 0
    for _, auxId in ipairs(auxIds) do
        if auxId == bestAux1 or auxId == bestAux2 then continue end
        stage4Idx = stage4Idx + 1
        progress("stage 4 / 3rd aux", stage4Idx, stage4Total)
        comboIdx += 1
        local r = ArenaSweepRunner.runOneCombo(player, {
            coreId = bestCore,
            auxIds = { bestAux1, bestAux2, auxId },
            autoPickerOpts = opts.autoPickerOpts or { mode = "random" },
            progressLabel    = ("AUTO %d/%d"):format(comboIdx, totalCombos),
            totalEstimateSec = totalEstimateSec,
            sweepStartedAt   = sweepStartedAt,
        }, {})
        aux3Scores[auxId] = r and r.finalPhase or 0
        table.insert(results, { stage = 4, coreId = bestCore, auxIds = {bestAux1, bestAux2, auxId}, result = r })
    end
    local bestAux3 = nil
    local bestAux3Score = -1
    for aux, s in pairs(aux3Scores) do
        if s > bestAux3Score then bestAux3Score = s; bestAux3 = aux end
    end

    print(("[ArenaSweepRunner.greedy] DONE — best: %s + %s + %s + %s (final phase %d)"):format(
        bestCore, tostring(bestAux1), tostring(bestAux2), tostring(bestAux3), bestAux3Score))

    return {
        bestCore = bestCore,
        bestAux1 = bestAux1, bestAux2 = bestAux2, bestAux3 = bestAux3,
        bestFinalPhase = bestAux3Score,
        allResults = results,
    }
end

-- (runFullCoverageSweep removed 2026-05-01 ea3-139 — was the
-- 3 × C(14,3) = 1092-combo full coverage sweep called only by the
-- now-removed SUPER AUTORUN handler. Superseded by SUPER CURVE ×
-- 495 which produces clean fractional finalWave on every loadout
-- via the wave-1..28 force-failure pipeline instead of wave-30-cap
-- saturation. See ea3-135 commit.)

-- ===========================================================================
-- ea3-116 Phase G — FAILURE CURVE × N (v2 of FAILURE SWEEP)
--
-- Replaces the legacy autoRunRemote-based FAILURE SWEEP × 105 stopgap.
-- Same goal (climb each loadout through ramping waves until heart-death,
-- capture fractional finalWave for the simulator validator), but with
-- placement that uses AutoPlaceStrategy (max path coverage, role-aware)
-- instead of the legacy hand-tuned INFINITE_PATTERN slot table.
--
-- See memory project_failure_curve_v2.md for the full design rationale.
-- Per Matthew 2026-04-30 (cyan-circle vs red-square screenshot): the
-- legacy slot table puts towers at corners with ~25% range bulging
-- off-map; AutoPlaceStrategy puts them where the path actually winds.
--
-- Single-source-of-truth alignment with InfiniteSimulator.simulateWave:
-- both consume Config.InfiniteArena.{ Pools_C1, WaveHpRamp, LoadoutMult,
-- Pools_C1_TankHpDelta }. Per CLAUDE.md convention #7. Tuning here
-- propagates to BOTH the live failure-curve sweep AND the closed-form
-- predictor automatically.
-- ===========================================================================

-- Failure-curve wave caps. Mirrors Config.InfiniteArena.MaxAutoRunWave
-- so a loadout that survives this many waves auto-promotes to S-tier
-- regardless of where the cap sits. Single source of truth.
local FAILURE_CURVE_MAX_WAVE = (Config.InfiniteArena and Config.InfiniteArena.MaxAutoRunWave) or 28

-- Build a synthetic waveData entry for failure-curve wave N. Returns
-- the same shape runOneWave consumes: { spawns = [...], hpMult, ... }.
-- Wave-type cycles AOE → Combined → Solo every 3 waves. HP scaling
-- factors are read from Config.InfiniteArena (single source of truth
-- with InfiniteSimulator.simulateWave) so tuning propagates to both
-- the live sweep AND the closed-form predictor.
--
-- Mob ratios mirror Infinite.lua's TEST_TYPES (the legacy autoRun's
-- per-cycle spawner): AOE = 6 basics; Combined = 2:2:1 basic:fast:tank
-- pool-split 4:3:10; Solo = 1 tank with full pool. Per-mob hpMult
-- back-derives from MOB_TYPES base HPs (basic 30 / fast 18 / tank 90)
-- so the spawned mob's effective HP = baseHp × hpMult = pool × ratio.
local function buildFailureCurveWaveData(waveIdx, loadoutMult)
    local IA = Config.InfiniteArena
    local mod = waveIdx % 3
    local waveType
    if     mod == 1 then waveType = "AOE"
    elseif mod == 2 then waveType = "Combined"
    else                  waveType = "Solo"
    end

    local rampMult = (IA.WaveHpRamp and IA.WaveHpRamp(waveIdx)) or 1.0
    local hpScale  = rampMult * (loadoutMult or 1.0)
    local pools    = IA.Pools_C1 or { AOE = 4200, Combined = 5250, Solo = 6825 }
    local tankDeltaC = (IA.Pools_C1_TankHpDelta and IA.Pools_C1_TankHpDelta.Combined) or 0
    local tankDeltaS = (IA.Pools_C1_TankHpDelta and IA.Pools_C1_TankHpDelta.Solo)     or 0

    local spawns = {}
    if waveType == "AOE" then
        local pool  = pools.AOE
        local count = 6
        spawns[1] = { mobType = "basic", count = count,
                      hpMult = (pool / (count * 30)) * hpScale,
                      interval = 0.5 }
    elseif waveType == "Combined" then
        local pool    = pools.Combined
        local basicHp = pool * (4 / 24)
        local fastHp  = pool * (3 / 24)
        local tankHp  = pool * (10 / 24) + tankDeltaC
        spawns[1] = { mobType = "basic", count = 2, hpMult = (basicHp / 30) * hpScale, interval = 0.5 }
        spawns[2] = { mobType = "fast",  count = 2, hpMult = (fastHp  / 18) * hpScale, interval = 0.5 }
        spawns[3] = { mobType = "tank",  count = 1, hpMult = (tankHp  / 90) * hpScale, interval = 0.5 }
    else  -- Solo
        local pool = pools.Solo + tankDeltaS
        spawns[1] = { mobType = "tank", count = 1, hpMult = (pool / 90) * hpScale, interval = 0.5 }
    end

    return {
        spawns   = spawns,
        hpMult   = 1.0,  -- per-spawn hpMult already includes WaveHpRamp + LoadoutMult
        waveType = waveType,
        waveIdx  = waveIdx,
    }
end
ArenaSweepRunner._buildFailureCurveWaveData = buildFailureCurveWaveData  -- exposed for tests

-- Loadout-mult lookup: 1.0 / 1.25 / 1.45 for solo / duo / trio loadouts.
-- Single source of truth — InfiniteSimulator.simulateWave reads the same.
local function loadoutMultFor(numAux)
    local IA = Config.InfiniteArena
    if not IA or not IA.LoadoutMult then return 1.0 end
    return IA.LoadoutMult[numAux] or IA.LoadoutMult[1] or 1.0
end

-- Compute fractional finalWave when the heart dies mid-wave.
--
-- ea3-148: formula rewrite per Matthew 2026-05-01. Replaces the
-- ea3-147 `(waveIdx-1) + timeFrac × heartMaxHp/(heartMaxHp+overkill)`
-- with a wave-HP-relative scoring:
--
--   theoreticalNextHeart = -(killingBlowOverkill + postKillThreatHp)
--   finalWave = waveOfDeath + (waveFullHp + theoreticalNextHeart) / waveFullHp
--
-- Where:
--   waveOfDeath     = waveIdx (the wave the heart died on)
--   waveFullHp      = sum of mob max HPs in the killing wave (full
--                     strength, not damaged) — caller-provided
--   theoreticalNextHeart = how much damage past zero the wave delivered
--                     (negative; =0 for clean kill at exactly heart=0)
--
-- Behavioral notes:
--   • Clean kill: finalWave = waveOfDeath + 1 (loadout sustained
--     up to "wave + 1's threshold" of damage capacity)
--   • Wave-equal overkill (overkill = waveFullHp): finalWave = waveOfDeath
--   • 2× overkill: finalWave = waveOfDeath - 1 (heart was already
--     over-budget at the previous wave; just got "lucky")
--   • Negative fractions allowed — expresses "loadout's
--     sustainable-wave class is below what it actually touched"
--
-- timeFrac dropped: the new formula doesn't use wave-time-progress.
-- Two waves dying with the same heart context score the same
-- regardless of when in the wave the killing blow landed. Aligns
-- with sim (which has no time concept inside a wave).
--
-- timeFrac argument retained as 4th param for API compat — ignored
-- by the new formula. Caller still passes captureSlot.killingBlowOverkill
-- and the new waveFullHp (sum of mob max HPs).
local function computeFractionalWave(waveIdx, waveFullHp, killingBlowOverkill)
    local postKillThreatHp = 0
    local waveCtx     = WaveCtxBridge.ctx
    if waveCtx and waveCtx.activeMobs then
        for mob in pairs(waveCtx.activeMobs) do
            if mob and mob.Parent then
                local hp = mob:GetAttribute("Health") or 0
                if type(hp) == "number" and hp > 0 then
                    postKillThreatHp = postKillThreatHp + hp
                end
            end
        end
    end
    local theoreticalNextHeart = -((killingBlowOverkill or 0) + postKillThreatHp)
    local denom = math.max(1, waveFullHp or 1)
    local frac  = (denom + theoreticalNextHeart) / denom
    return waveIdx + frac, postKillThreatHp
end

-- ea3-148: compute the killing wave's full mob HP (sum of
-- count × baseHp × spawn.hpMult across spawns). Mirrors the spawn
-- loop's effective-HP math in runOneWave so waveFullHp matches the
-- HP a tower would need to deplete to clear the wave at full
-- strength. Skips map bosses (they're filtered out of the spawn
-- loop too — see isMapBoss check in runOneWave).
local function computeWaveFullHp(waveData): number
    local waveCtx = WaveCtxBridge.ctx
    if not (waveCtx and waveCtx.MOB_TYPES and waveData and waveData.spawns) then
        return 0
    end
    local total = 0
    for _, spawn in ipairs(waveData.spawns) do
        if not isMapBoss(spawn.mobType) then
            local def = waveCtx.MOB_TYPES[spawn.mobType]
            local baseHp = (def and def.hp) or 0
            local hpMult = spawn.hpMult or 1.0
            local count = spawn.count or 1
            total = total + count * baseHp * hpMult
        end
    end
    return total
end

-- ea3-138: helpers moved above runOneCombo (was here, now declared
-- earlier in the file before runOneCombo references them — per
-- CLAUDE.md convention #1, Lua resolves free variables at function-
-- DEFINITION time, so a function can't reference a local declared
-- later in the file).

-- Place Core + auxes for the failure-curve combo. Sequential: Core
-- first (anchors path-coverage scoring), then DPS auxes, then Control,
-- then Support — matches AutoPlaceStrategy's role precedence so each
-- placement informs the next via its placedAllies list (Core's centre
-- becomes a corner-proximity reference for Control, an aura-overlap
-- reference for Support, etc.).
local function placeFailureCurveLoadout(player, opts)
    local coreId = opts.coreId or "Power"
    local auxIds = opts.auxIds or {}

    -- Core first.
    local coreDef = TowerTypes[coreId]
    if not coreDef then
        warn(("[ArenaSweepRunner.failureCurve] unknown coreId %s — skipping"):format(tostring(coreId)))
        return false
    end
    local placedCore = placeTowerForRole(player, coreId, "Core",
        coreDef.footprintWidth or 4, coreDef.footprintDepth or 4, coreDef.range or 22)
    if not placedCore then
        warn("[ArenaSweepRunner.failureCurve] Core placement failed — skipping combo")
        return false
    end

    -- Auxes in role order: DPS → Control → Support. AutoPlaceStrategy
    -- scores Control by corner-proximity-to-Core, Support by aura-
    -- overlap-with-allies, so DPS placement before Control/Support
    -- gives Control/Support more allies to score against.
    local roleOrder = { "DPS", "Control", "Support" }
    for _, role in ipairs(roleOrder) do
        for _, auxId in ipairs(auxIds) do
            local auxRole = (TempTowers.RoleByTowerId and TempTowers.RoleByTowerId[auxId]) or "DPS"
            if auxRole == role then
                local def = TempTowers.Templates[auxId]
                if def then
                    placeTowerForRole(player, auxId, role,
                        def.footprintWidth or 4, def.footprintDepth or 4, def.range or 22)
                end
            end
        end
    end
    return true
end

-- Reset per-combo state. Mirrors the equivalent block in runOneCombo
-- (lines 1276-1437) so the failure-curve combo starts from the same
-- clean slate. Common pattern: wipe everything that could leak from
-- a prior run (mobs, towers, stocks, stacks, cumulative bonuses,
-- reroll budget, run-luck counters).
local function setupFailureCurveCombo(player, opts)
    StatLedger.setRecordingEnabled(true)
    StatLedger.reset()
    AutoPicker.beginAuto(opts.autoPickerOpts or { mode = "random" })

    -- Wave system / placement / scenery hooks engage on this flag.
    -- Map4.lua:1003 hides scenery; GameOverBanner suppresses; WaveSystem
    -- ignores pause requests during sweep — all keyed off this attr.
    Workspace:SetAttribute("Map4ArenaSweepActive", true)
    -- Force-unpause if the user paused before clicking FAILURE CURVE.
    if Workspace:GetAttribute("GamePaused") == true then
        Workspace:SetAttribute("GamePaused", false)
        if WaveCtxBridge.ctx then WaveCtxBridge.ctx.paused = false end
    end

    -- Phase 3 = full Map 4 path bounds (matches the simulator's path
    -- model — InfinitePathGeometry reads MAP4_PATH_CELLS which IS the
    -- phase-3 path). Phase 1/2 are narrower Map-1/-2 equivalents only
    -- used by the 4-phase scripted sweep.
    Workspace:SetAttribute("Map4ActivePhase", 3)
    -- ea3-123: defensive reset of story-mode StageState. MobFactory.makeMob
    -- reads ctx.StageState.currentStage to apply per-stage hpMult/speedMult
    -- (Stages[3] = 3.4× HP, 1.3× speed). The DEV skip-to-MAP-BOSS handler
    -- (TreeOfLife_WaveSystem.server.lua line ~1537) sets currentStage=3 and
    -- never resets it — if a player fires that dev tool then immediately
    -- clicks FAILURE CURVE × 105, the FIRST few combos spawn mobs at 3.4×
    -- HP / 1.3× speed and tower DPS can't keep up.
    --
    -- Caught 2026-05-01 (ea3-122 sweep): user fired DEV skip-to-MAP-BOSS
    -- 3× before sweep, combo 1 (Power+FrostMelon) wave 1 lost 13,399
    -- heart vs. expected ~3,000. Math fits: 6 basics × 2300 base × 3.4
    -- = 46,920 total HP, wave timing 3.2s ≈ baseline 4.1s ÷ 1.3 (speed
    -- mult). State self-cleared after a few combos because... well,
    -- not certain why; this defensive reset removes the dependency.
    --
    -- Force currentStage = 1 so stageHpMult / stageSpeedMult both = 1.0.
    -- Sweep manages its own per-wave HP via WaveHpRamp + per-spawn hpMult,
    -- so no stage-progression scaling is wanted.
    -- Extracted to ArenaSweepRunner._resetSweepStageState so the unit
    -- test in tests/ArenaSweepRunner.lua can replay the dev-skip-leak
    -- regression without booting the full WaveSystem context.
    ArenaSweepRunner._resetSweepStageState(WaveCtxBridge.ctx)
    task.wait(0.5)  -- let path / grid rebuild settle before placement

    -- Equip the chosen Core.
    if opts.coreId then
        for _, c in ipairs(CoreTypes.Ids) do
            player:SetAttribute(c .. "Equipped", c == opts.coreId)
        end
    end

    -- Heart reset, prior-tower wipe, leftover-mob wipe.
    healAllHearts()
    clearPlayerMap4Towers(player)
    if WaveCtxBridge.ctx and WaveCtxBridge.ctx.clearAllMobs then
        WaveCtxBridge.ctx.clearAllMobs()
    end

    -- Override the heart to Config.Map4.HeartMaxHp (= 40000 per the
    -- 2026-04-30 Pickle Lord balance pass). The Map4ActivePhase=3 set
    -- above triggers Map4.lua's phase-change handler which resets the
    -- heart to PhaseHeartHp[3] = 50000 — that's the value the 4-phase
    -- ARENA AUTORUN uses for parity with phase-3 mob density. v2's
    -- failure curve mirrors the SIMULATOR's heart model instead, which
    -- reads HEART_HP = Config.Map4.HeartMaxHp at module load. Without
    -- this override the live heart at 50k survives more waves than the
    -- sim predicts at 40k → consistent positive delta independent of
    -- model accuracy. CLAUDE.md convention #7 — single-source-of-truth.
    local heartMaxHp = (Config.Map4 and Config.Map4.HeartMaxHp) or 40000
    for _, h in ipairs(CollectionService:GetTagged(Tags.EnemyEndPoint)) do
        if h:GetAttribute("MapId") == 4 then
            h:SetAttribute("MaxHealth", heartMaxHp)
            h:SetAttribute("Health",    heartMaxHp)
        end
    end

    -- Zero per-tower stocks + flags (placeTowerForRole grants 1 stock
    -- on placement; we want a known baseline).
    for _, c in ipairs(CoreTypes.Ids) do
        player:SetAttribute(c .. "Stock", 0)
    end
    for id in pairs(TempTowers.Templates) do
        player:SetAttribute(id .. "Stock", 0)
        player:SetAttribute(id .. "Equipped", false)
    end

    -- Zero accumulated Core upgrade stacks (carry-over kills sim alignment).
    for _, c in ipairs(CoreTypes.Ids) do
        local options = CoreUpgrades.optionsFor(c)
        if options then
            for _, opt in ipairs(options) do
                if opt and opt.id then
                    player:SetAttribute(opt.id .. "Stacks", 0)
                end
            end
        end
    end

    -- RunLuck reset (seed at display 5/10 — same as runOneCombo).
    player:SetAttribute("RunLuckSum",   2.71)
    player:SetAttribute("RunLuckCount", 1)
    player:SetAttribute("MapPickCount", 0)

    -- Cumulative upgrade bonuses (player-attribute mirrors persist on
    -- Player Instance until explicitly cleared — see runOneCombo's
    -- ea3-94 block for the leak rationale).
    for _, cat in ipairs({ "Core", "Aux" }) do
        player:SetAttribute(cat .. "DamageFlat",   0)
        player:SetAttribute(cat .. "RangePct",     0)
        player:SetAttribute(cat .. "FireRatePct",  0)
    end
    player:SetAttribute("CoreAoeRadius",       nil)
    player:SetAttribute("CoreKnockback",       nil)
    player:SetAttribute("CoreKnockbackChance", nil)
    player:SetAttribute("CoreStunDuration",    nil)
    player:SetAttribute("CoreStunChance",      nil)
    player:SetAttribute("MaxCarry",            15)
    player:SetAttribute("CoreMaxShotsMult",    1.0)
    player:SetAttribute("DevAmmoPickedAt5",  false)
    player:SetAttribute("DevAmmoPickedAt15", false)

    -- Reroll budget — 3 starting tokens (failure curve has no per-map
    -- grants since there are no map transitions; just spends tokens).
    player:SetAttribute("RerollTokens", 3)
    player:SetAttribute("RerollsUsed",  0)
end

-- Teardown. Mirrors runOneCombo's epilogue (lines 1635-1653): restore
-- visuals + scenery flags, fire DONE progress, clear _state.
local function teardownFailureCurveCombo(player)
    AutoPicker.endAuto()
    Workspace:SetAttribute("Map4ArenaSweepActive", false)
    -- Restore the live Pickle Swamp to phase 3 (full bounds, full heart).
    Workspace:SetAttribute("Map4ActivePhase", 3)
    -- Final progress fire so HUD's progress bar fades out cleanly.
    local comboTotalSec = (_state and _state.comboTotalSec) or 60
    fireProgress(player, comboTotalSec, comboTotalSec, "DONE")
    _state = nil
end

-- Run ONE failure-curve combo: place loadout via AutoPlaceStrategy,
-- climb waves 1..MaxAutoRunWave with Config.InfiniteArena.WaveHpRamp
-- HP scaling, fire upgrade picker on each cycle boundary (every 3
-- waves — matches simulator's per-cycle applyUpgrades), capture
-- fractional finalWave on heart-death OR wave-cap. Returns:
--   { coreId, auxIds, finalWave, waveType, towersPlaced, elapsed,
--     luckSum, luckCount, luckAvg, aborted }
function ArenaSweepRunner.runFailureCurveCombo(player, opts, hooks)
    if _state ~= nil then
        warn("[ArenaSweepRunner] runFailureCurveCombo called while another combo is active")
        return false
    end
    if not player or not player.Parent then
        warn("[ArenaSweepRunner] runFailureCurveCombo with no valid player")
        return false
    end
    opts  = opts  or {}
    hooks = hooks or {}

    local result = {
        coreId       = opts.coreId or "Power",
        auxIds       = opts.auxIds or {},
        finalWave    = 0,
        startedAt    = os.clock(),
        towersPlaced = 0,
        aborted      = false,
    }
    _state = { player = player, opts = opts, result = result }
    -- Per-combo ETA bar (caller-sweep-aware via opts.sweepStartedAt).
    local comboTotalSec  = opts.totalEstimateSec or comboEstimateSec()
    local comboLabel     = opts.progressLabel or "FAILURE CURVE"
    local sweepStartedAt = opts.sweepStartedAt or os.clock()
    local function fireProgressNow(label)
        fireProgress(player, os.clock() - sweepStartedAt, comboTotalSec, label)
    end
    _state.sweepStartedAt = sweepStartedAt
    _state.comboTotalSec  = comboTotalSec
    _state.fireProgressNow = fireProgressNow

    setupFailureCurveCombo(player, opts)
    fireProgressNow(comboLabel)
    -- Combo-info row (top HUD): "Power + Pepper / Honey / Pace  •
    -- FAILURE CURVE 23/105". Lets the user cross-reference combo
    -- index with the sweep-wide countdown bar below.
    if opts.sweepIdx and opts.sweepTotal then
        fireFailureCurveComboInfo(player, opts, opts.sweepIdx, opts.sweepTotal)
    end
    diagDescendants("failure curve combo start")

    -- Place the loadout via AutoPlaceStrategy.
    local placed = placeFailureCurveLoadout(player, opts)
    if not placed then
        teardownFailureCurveCombo(player)
        result.finalWave = 0
        return result
    end
    result.towersPlaced = (1 + #(opts.auxIds or {}))  -- Core + auxes
    task.wait(0.3)  -- let placements settle before first wave

    -- Heart HP for fractional-wave calculation. Matches setupFailureCurve
    -- Combo's override (Config.Map4.HeartMaxHp = 40000) so the closed-
    -- form simulator's HEART_HP and v2's heart agree — see the override
    -- comment in setupFailureCurveCombo for the convention #7 rationale.
    local heartMaxHp = (Config.Map4 and Config.Map4.HeartMaxHp) or 40000
    local loadoutMult = loadoutMultFor(#(opts.auxIds or {}))

    -- ea3-138: heart-overkill capture. Install the hook on the wave
    -- ctx BEFORE the loop so the very first wave's killing blow (if
    -- any) is captured. captureSlot fields populated by MobUpdate
    -- when a mob lands a killing blow:
    --   killingBlowOverkill — dmg past zero from the killing mob
    --   killingBlowDamage   — full damage value of the killing mob
    --   heartHpBeforeKill   — heart HP just before the killing blow
    --   killingMob          — the mob instance (for wave-attribution)
    -- killingWaveHeartStart (heart HP at start of the killing wave)
    -- is captured separately below from the per-wave heart-HP
    -- snapshot — different value (start-of-wave vs. just-before-
    -- killing-blow).
    local captureSlot = {}
    local priorHook = installHeartOverkillHook(captureSlot)

    -- Climb waves 1..28 ramping HP per Config.InfiniteArena.WaveHpRamp
    -- × LoadoutMult. fireOneUpgradePicker runs on each cycle boundary
    -- (every 3 waves) so tower stats track the simulator's per-cycle
    -- applyUpgrades model.
    local heartDead = false
    local lastCycle = 0
    local heartHpAtWaveStart = heartMaxHp
    for waveIdx = 1, FAILURE_CURVE_MAX_WAVE do
        if _state and _state.aborted then result.aborted = true; break end

        local cycle = math.ceil(waveIdx / 3)
        if cycle > lastCycle and lastCycle > 0 then
            -- Cycle boundary — fire one upgrade pick. Caller's auto-
            -- picker resolves it. (waveIdx - 1 here = the wave that
            -- JUST cleared; matches story-mode "after-wave" picker fire.)
            fireProgressNow(("WAVE %d  •  UPGRADE"):format(waveIdx))
            fireOneUpgradePicker(player, waveIdx - 1)
            task.wait(0.1)
        end
        lastCycle = cycle

        local waveData = buildFailureCurveWaveData(waveIdx, loadoutMult)
        local waveLabel = ("failure curve wave %d (%s, hpMult ramped)"):format(
            waveIdx, waveData.waveType)
        fireProgressNow(("WAVE %d (%s)"):format(waveIdx, waveData.waveType))

        -- ea3-148: precompute the wave's full mob HP (sum of mob
        -- max HPs at full strength, undamaged). Captured BEFORE
        -- runOneWave so towers haven't shaved any HP yet — the
        -- value is the wave's total damage-absorbing capacity.
        -- Used by computeFractionalWave below if heart dies.
        local waveFullHp = computeWaveFullHp(waveData)

        -- ea3-138: snapshot heart HP at the START of this wave, BEFORE
        -- runOneWave runs. If this wave kills the heart, this value is
        -- the killingWaveHeartStart. Stored on result.heartHpAtKillingWaveStart
        -- in the heart-death branch below.
        heartHpAtWaveStart = getMap4HeartHp() or heartHpAtWaveStart

        runOneWave(waveData, 1.0, waveLabel)

        -- Heart-death capture.
        if isMap4HeartDead() then
            -- ea3-148: new fractional formula uses waveFullHp +
            -- theoreticalNextHeart instead of the prior timeFrac ×
            -- overkillMult. captureSlot.killingBlowOverkill was
            -- populated by the onHeartOverkill hook (installed
            -- before the wave loop); nil-safe inside
            -- computeFractionalWave with 0 fallback.
            local frac, postKillThreatHp = computeFractionalWave(
                waveIdx, waveFullHp, captureSlot.killingBlowOverkill)
            result.finalWave = frac
            result.waveType  = waveData.waveType
            -- ea3-138 heart-death recording. Per Matthew 2026-05-01:
            -- delineate boss rounds via heart-start + overkill data.
            -- heartHpAtKillingWaveStart   = heart HP entering the wave
            -- killingBlowOverkill         = mob's dmg past zero (real)
            -- postKillThreatHp            = sum of mob HP still alive
            --   at heart-death (HP-as-damage proxy — most mobs have
            --   damage ≈ HP per MobFactory convention).
            -- theoreticalNextWaveHeartHp  = virtual heart's HP after
            --   absorbing ALL the wave's threat in an infinite-heart
            --   world. Per Matthew "theoretical overkill aka
            --   theoretical starting heart health on the next round
            --   (negative in this case)."
            --
            -- Math: heart at wave start = H. Wave delivers
            --   pre-kill damage = (H - heartHpBeforeKill) absorbed,
            --   killing blow    = heartHpBeforeKill + killingBlowOverkill,
            --   post-kill threat = postKillThreatHp (unleashed, not
            --                      delivered because heart already 0).
            -- Virtual heart after wave:
            --   = H - (H - heartHpBeforeKill) - killingBlowDamage - postKillThreatHp
            --   = heartHpBeforeKill - killingBlowDamage - postKillThreatHp
            --   = -(killingBlowOverkill + postKillThreatHp)
            -- The H and heartHpBeforeKill terms cancel — only the
            -- overkill components show up as the negative balance.
            result.heartMaxHp                  = heartMaxHp
            result.heartHpAtKillingWaveStart   = heartHpAtWaveStart
            result.killingBlowOverkill         = captureSlot.killingBlowOverkill or 0
            result.killingBlowDamage           = captureSlot.killingBlowDamage or 0
            result.postKillThreatHp            = postKillThreatHp
            result.theoreticalNextWaveHeartHp  =
                -((captureSlot.killingBlowOverkill or 0) + postKillThreatHp)
            -- ea3-148: waveFullHp is the denominator of the new
            -- fractional formula. Stored so analysis tools can
            -- recompute fractions per loadout if needed (e.g. to
            -- compare ea3-148 formula vs prior ea3-147 formula on
            -- the same data).
            result.waveFullHp                  = waveFullHp
            heartDead = true
            break
        end
    end

    uninstallHeartOverkillHook(priorHook)

    -- Survived to cap — return MaxAutoRunWave (matches simulator's
    -- "survived to cap" return path at InfiniteSimulator.lua:1028).
    if not heartDead and not result.aborted then
        result.finalWave = FAILURE_CURVE_MAX_WAVE
        result.waveType  = "Survived"
    end

    result.elapsed = os.clock() - result.startedAt
    -- Capture luck snapshot.
    local luckSum   = (player:GetAttribute("RunLuckSum")   or 0)
    local luckCount = (player:GetAttribute("RunLuckCount") or 0)
    result.luckSum   = luckSum
    result.luckCount = luckCount
    result.luckAvg   = (luckCount > 0) and (luckSum / luckCount) or 0

    teardownFailureCurveCombo(player)

    print(("[ArenaSweepRunner.failureCurve] %s + %s → finalWave=%.2f (%s) towers=%d luckAvg=%.2f"):format(
        result.coreId, table.concat(result.auxIds, "+"),
        result.finalWave, tostring(result.waveType),
        result.towersPlaced, result.luckAvg))
    -- ea3-138: heart-death telemetry on the per-combo summary so the
    -- boss-round-delineation signal shows up immediately in the log.
    -- Only prints when heart actually died (Survived runs skip).
    if result.heartHpAtKillingWaveStart then
        print(("[ArenaSweepRunner.failureCurve]   heartStart=%d  killingBlowOverkill=%d  postKillThreat=%d  theoreticalNextHeart=%d  waveFullHp=%d"):format(
            math.floor((result.heartHpAtKillingWaveStart or 0) + 0.5),
            math.floor((result.killingBlowOverkill or 0) + 0.5),
            math.floor((result.postKillThreatHp or 0) + 0.5),
            math.floor((result.theoreticalNextWaveHeartHp or 0) + 0.5),
            math.floor((result.waveFullHp or 0) + 0.5)))
    end

    if hooks.onComboComplete then hooks.onComboComplete(result) end
    return result
end

-- Run an entire FAILURE CURVE × N sweep over a queue of loadouts.
-- Returns parallel { auxIds, label, finalWave, testType, coreId,
-- balanceVersion } records that the existing validator + tier-list
-- code consumes unchanged. Caller in Infinite.lua handles the
-- cumulativeResults flush + runSimForCore validator hookup.
function ArenaSweepRunner.runFailureCurveSweep(player, opts, hooks)
    opts  = opts  or {}
    hooks = hooks or {}
    local queue = opts.queue or {}
    local coreId = opts.coreId or "Power"
    local results = {}

    -- Sweep-wide ETA wiring — same pattern as greedy / full coverage.
    -- Initial seed prefers the persisted observed average from the
    -- previous completed sweep (opts.perComboSecHint, fed by
    -- InfiniteRunHistoryStore.loadTimingHint("failureCurve") in
    -- Infinite.lua). Falls back to 60s — matches VALIDATE / FULL
    -- COVERAGE — when no hint is on file (first sweep ever, or DataStore
    -- unavailable). Hard floor of 30s guards against a corrupt/tiny
    -- value poisoning the seed.
    --
    -- After every completed combo we refresh the estimate from the
    -- observed average, but ONLY upward — the ETA can grow but never
    -- shrink, so the countdown always overshoots reality. Caught
    -- 2026-04-30 (ea3-118): a 30s seed underestimated by ~30 min on the
    -- 105-combo sweep, leading the user to disconnect before completion.
    --
    -- ea3-136: outer-sweep awareness for SUPER CURVE × 495.
    --   opts.outerSweepStartedAt — anchor ETA to this timestamp instead
    --     of os.clock() at function start. Lets the HUD progress bar
    --     reflect overall × 495 elapsed time across Core boundaries.
    --   opts.outerTotalEstimateSec — total ETA for the outer × 495 run
    --     instead of just this Core's × 105 slice.
    -- When outer mode is set, the inner auto-update of totalEstimateSec
    -- is disabled (the outer caller manages the cross-Core ETA).
    --
    -- HUD label customization (also ea3-136):
    --   opts.hudPrefix — combo-info row prefix (default "CURVE",
    --     SUPER CURVE × 495 sets "SUPER CURVE A" / "SUPER CURVE B")
    --   opts.hudIdxOffset — added to per-combo idx so absolute
    --     progress shows (default 0; SUPER CURVE × 495 sets the
    --     count of combos completed in prior Cores/phases)
    --   opts.hudTotalOverride — absolute total instead of #queue
    --     (default nil → use #queue; SUPER CURVE × 495 passes 495)
    local hintedSec      = (opts.perComboSecHint and opts.perComboSecHint > 0)
                              and opts.perComboSecHint or nil
    local PER_COMBO_SEC  = math.max(30, hintedSec or 60)
    local sweepStartedAt = opts.outerSweepStartedAt or os.clock()
    local totalEstimateSec = opts.outerTotalEstimateSec
                              or (PER_COMBO_SEC * #queue)
    local outerMode = opts.outerSweepStartedAt ~= nil
    local hudPrefix = opts.hudPrefix or "CURVE"
    local hudIdxOffset = opts.hudIdxOffset or 0
    local hudTotalOverride = opts.hudTotalOverride

    for idx, loadout in ipairs(queue) do
        if hooks.shouldAbort and hooks.shouldAbort() then
            print(("[ArenaSweepRunner.failureCurve] sweep aborted at %d/%d"):format(idx - 1, #queue))
            break
        end
        if hooks.onProgress then hooks.onProgress("failure curve", idx, #queue) end
        local hudIdx   = idx + hudIdxOffset
        local hudTotal = hudTotalOverride or #queue
        print(("[ArenaSweepRunner.failureCurve] %d/%d — %s + %s"):format(
            hudIdx, hudTotal, coreId, table.concat(loadout.auxIds, "+")))
        local r = ArenaSweepRunner.runFailureCurveCombo(player, {
            coreId           = coreId,
            auxIds           = loadout.auxIds,
            autoPickerOpts   = opts.autoPickerOpts or { mode = "random" },
            progressLabel    = hudPrefix,
            totalEstimateSec = totalEstimateSec,
            sweepStartedAt   = sweepStartedAt,
            sweepIdx         = hudIdx,
            sweepTotal       = hudTotal,
            hudPrefix        = hudPrefix,
        }, {})
        if r and not r.aborted then
            local entry = {
                auxIds    = loadout.auxIds,
                label     = loadout.label or ("%s + %s"):format(coreId, table.concat(loadout.auxIds, " + ")),
                finalWave = r.finalWave,
                testType  = r.waveType or "FailureCurve",
                coreId    = coreId,
                luckAvg   = r.luckAvg,
                -- ea3-138 heart-death recording. nil for Survived runs
                -- (heart never died → no killing-wave context). Boss-
                -- round delineation: heartHpAtKillingWaveStart matches
                -- a recent wave's worth of damage on regular waves
                -- but is much higher on stage-boss waves where one
                -- spike kills the heart with HP to spare. Captured
                -- only when r.finalWave is fractional (mid-wave death).
                heartMaxHp                 = r.heartMaxHp,
                heartHpAtKillingWaveStart  = r.heartHpAtKillingWaveStart,
                killingBlowOverkill        = r.killingBlowOverkill,
                killingBlowDamage          = r.killingBlowDamage,
                postKillThreatHp           = r.postKillThreatHp,
                theoreticalNextWaveHeartHp = r.theoreticalNextWaveHeartHp,
                waveFullHp                 = r.waveFullHp,
            }
            table.insert(results, entry)
            -- ea3-133: per-combo checkpoint hook. Caller (Infinite.lua)
            -- appends the entry to cumulativeResults and flushes to
            -- DataStore every N combos so a Studio crash mid-sweep
            -- preserves work. Without this, an overnight SUPER FAILURE
            -- CURVE × 315 (~4.4 hours) loses ALL data on a single drop.
            -- onResult signature: (entry, completedIdx, totalCount).
            if hooks.onResult then hooks.onResult(entry, idx, #queue) end
        end
        if r and r.aborted then break end

        -- Adaptive ETA refresh — monotonic only. Once we have observed
        -- timings, project from the average; if it's larger than the
        -- current estimate, bump up. Never shrinks, so the chyron's
        -- countdown will always reach zero at or after sweep completion.
        --
        -- ea3-136: outer mode skips the inner auto-update. The outer
        -- caller (SUPER CURVE × 495 wrapper) manages cross-Core ETA;
        -- if we updated totalEstimateSec here, each Core would shrink
        -- the outer estimate based on its own slice's pace, causing
        -- the chyron to drift backward at Core boundaries.
        if not outerMode then
            local observedPerCombo = (os.clock() - sweepStartedAt) / idx
            local projected        = observedPerCombo * #queue
            if projected > totalEstimateSec then
                totalEstimateSec = projected
            end
        end
    end

    print(("[ArenaSweepRunner.failureCurve] DONE — %d/%d combos completed"):format(
        #results, #queue))

    -- Observed average for the caller to persist as the next sweep's
    -- seed. Only meaningful if we ran enough combos for the average
    -- to be statistically stable; the caller gates on this count.
    local sweepElapsed = os.clock() - sweepStartedAt
    local observedPerComboSec = (#results > 0) and (sweepElapsed / #results) or nil
    return {
        allResults         = results,
        observedPerComboSec = observedPerComboSec,
        completedCombos    = #results,
        sweepElapsedSec    = sweepElapsed,
    }
end

-- ea3-123: defensive reset of story-mode StageState. Public so the
-- unit test in tests/ArenaSweepRunner.lua can replay the dev-skip-
-- to-MAP-BOSS leak regression without booting the full WaveSystem.
-- Called from setupFailureCurveCombo right after the phase set-up.
--
-- See setupFailureCurveCombo's full comment block for the regression
-- context (currentStage = 3 leak → 3.4× HP / 1.3× speed mob spawns).
function ArenaSweepRunner._resetSweepStageState(waveCtx)
    if waveCtx and waveCtx.StageState then
        waveCtx.StageState.currentStage = 1
    end
end

return ArenaSweepRunner
