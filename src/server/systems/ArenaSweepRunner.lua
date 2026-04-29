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
        print(("[Sweep] cleared %d prior Map 4 tower(s) for %s"):format(removed, player.Name))
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
    print(("[Sweep] %s START — %d mobs to spawn (incl %d stage boss), mobMult=%.2f, bossMult=%.2f, heart=%d"):format(
        tostring(waveLabel), mobCount, bossCount, hpMult,
        PHASE_BOSS_HP_MULT[activePhase] or 1.0, heartBefore))

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
        local thisMult = hpMult
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
    print(("[Sweep] %s END — %.1fs, heart %d → %d (lost %d)"):format(
        tostring(waveLabel), os.clock() - startedAt, heartBefore, heartAfter, heartLost))
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
    local maxRerollsPerStage = 1
    if waveCtx.WaveConfig and waveCtx.WaveConfig.maxRerollsPerStage then
        maxRerollsPerStage = waveCtx.WaveConfig.maxRerollsPerStage
    end
    -- Sweep "phase" = story "stage" for reroll budget purposes.
    -- pickInStage 1..4 maps to the 4 picks per phase (2 breather +
    -- 2 between-waves) — fireOneUpgradePicker is called with
    -- waveIndex = 1, 2, 3, 4 in order, so (waveIndex - 1) % 4 + 1
    -- gives the right pick number.
    local pickInStage = ((waveIndex - 1) % 4) + 1
    local payload
    for _ = 1, MAX_REROLL_TRIES do
        payload = waveCtx.generateCardsForPlayer(player, waveIndex)
        local cards = (payload and payload.cards) or {}
        if #cards == 0 then return end
        local hasSpecial, highScore = false, 0
        for _, c in ipairs(cards) do
            local s = DEV_PICK_SCORE[c.rarity] or 0
            if c.rarity == "Special" then hasSpecial = true end
            if s > highScore then highScore = s end
        end
        local anyOverCommon = highScore > (DEV_PICK_SCORE.Common or 1)
        local anyOverRare   = highScore > (DEV_PICK_SCORE.Rare    or 2)
        local wantReroll = (not hasSpecial and not anyOverCommon)
                        or (pickInStage >= 3 and not anyOverRare)
        if not wantReroll then break end
        local rerollsUsed = player:GetAttribute("RerollsUsed") or 0
        local tokens      = player:GetAttribute("RerollTokens") or 0
        if rerollsUsed < maxRerollsPerStage then
            player:SetAttribute("RerollsUsed", rerollsUsed + 1)
        elseif tokens > 0 then
            player:SetAttribute("RerollTokens", tokens - 1)
        else
            break  -- nothing to spend; pick what we've got
        end
    end
    local cards = (payload and payload.cards) or {}
    if #cards == 0 then return end
    if AutoPicker.isActive() then
        local idx = AutoPicker.pickIndex(#cards, "upgradeCard")
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
            print(("[Sweep] upgrade pick @ wave %d: [%s/%s] %s → %s (auto idx %d / %d)"):format(
                waveIndex, rarity, kind, descriptor,
                tostring(picked.target or "?"), idx, #cards))
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

-- ea3-85: phase 4 placement uses targetCell=heart again, but with
-- the new "just INSIDE range" scoring (AutoPlaceStrategy ea3-85).
-- Towers cluster at the EDGE of their range from the boss instead
-- of right next to it. Per Matthew "place towers just INSIDE
-- range of pickle boss." Reverses ea3-84's avoidCell (just out of
-- range) — middle ground: still hits boss, still covers path.
local function getPhase4HeartTargetCell()
    if Workspace:GetAttribute("Map4ActivePhase") ~= 4 then return nil end
    if not _hubCtx or not _hubCtx.MAP4_COL_OFFSET then return nil end
    local pc = Config.Map4 and Config.Map4.PhaseHeartCells
        and Config.Map4.PhaseHeartCells[4]
    if not pc then return nil end
    return { col = _hubCtx.MAP4_COL_OFFSET + pc.col, row = pc.row }
end

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
    -- Score-based placement. ea3-85: phase 4 uses targetCell=heart
    -- with "just inside range" scoring so towers cluster at the
    -- range-edge from the boss. Phase 1-3 keep per-role scoring.
    local col, row = _hubCtx.findOptimalPlacementCell({
        role         = role,
        footprintW   = footprintW,
        footprintD   = footprintD,
        range        = range,
        mapId        = 4,
        placedAllies = placedAllies,
        targetCell   = getPhase4HeartTargetCell(),
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
local function runStationaryBossPhase(_player, _opts, hooks)
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

    -- ea3-60: spawn the boss at the HEART cell (not the path-start
    -- spawn cell). Per Matthew "phase 4 has the boss off the edge of
    -- the arena. can you actually just trigger the actual boss fight?
    -- only environmental change: bring in rough pickle boss model".
    -- Towers autoplaced along the path can now actually REACH the
    -- boss because it sits where they cluster (near the heart).
    -- Boss HP at 250k for a meaningful damage window regardless of
    -- kit DPS.
    -- ea3-64: boss HP bumped 250k → 1M to compensate for tower
    -- enhancements (4 upgrade picks/phase × 3 phases + 3 synthetic
    -- Core upgrades fires by phase 4 — towers chew through 250k
    -- in seconds at full upgrade stack). Per Matthew "we need to
    -- increase hp to compensate for post-stage boss tower
    -- enhancements". 1M leaves a meaningful damage-dealt window.
    local STATIONARY_BOSS_HP = 1000000
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

        -- ea3-79: position + visual now matches story-mode Pickle
        -- Lord per Matthew "in infinite, place pickle boss in same
        -- position he is in story mode and add in the model".
        --
        -- Story-mode origin = MAP3_CENTER + (0, 0, -BodyOffsetFromCenter)
        -- = 100 studs back along -Z. Body center sits 125 stud BELOW
        -- platform Y so only the visible top (head + shoulders, ~95
        -- stud) reads above ground. Sweep mirrors that offset using
        -- the phase-4 heart cell as the "platform center" stand-in.
        -- ea3-80: Config.PickleLord is actually nested under
        -- Config.Map3 (Map 3 owns the run-boss data). Direct
        -- Config.PickleLord was nil → crash on PL.BodyOffsetFromCenter
        -- per Matthew 2026-04-29 stack trace.
        local PL = (Config.Map3 and Config.Map3.PickleLord) or {}
        -- Defensive defaults so a missing Config.Map3.PickleLord
        -- block doesn't re-crash phase 4. Numbers match the live
        -- story-mode values; trace via Config.lua line 284-340.
        -- ea3-84: BodyOffsetFromCenter dropped (was used for the
        -- -100Z story-mode offset; boss is now at heart cell).
        local BodyVisibleHeight    = PL.BodyVisibleHeight    or 95
        local BodyTotalHeight      = PL.BodyTotalHeight      or 440
        local BodyWidth            = PL.BodyWidth            or 62
        local BodyDepth            = PL.BodyDepth            or 52
        local BodyColor            = PL.BodyColor            or Color3.fromRGB(60, 110, 50)
        local heartCellCfg = (Config.Map4.PhaseHeartCells
            and Config.Map4.PhaseHeartCells[4]) or Config.Map4.HeartCell
        if heartCellCfg and _hubCtx and _hubCtx.cellToWorld and _hubCtx.MAP4_COL_OFFSET then
            local absCol = _hubCtx.MAP4_COL_OFFSET + heartCellCfg.col
            local heartWorld = _hubCtx.cellToWorld(absCol, heartCellCfg.row)
            -- ea3-84: position boss directly AT the heart cell
            -- instead of -100Z back. Map 4's heart at (309, 60) is
            -- already near the +Z arena edge, so subtracting 100Z
            -- (story Map 3's "behind the platform" offset) put the
            -- boss visually in a corner / partially outside the
            -- arena. Per Matthew "pickle boss is in the corner,
            -- not the right spot". Boss at heart cell = head looms
            -- directly above the heart-cluster towers, vibe matches
            -- story's "giant pickle looming over the arena" without
            -- the off-edge artifact. The 95-stud visible head still
            -- reads above ground; the buried 345 stud below is
            -- hidden by the floor.
            local centerY = heartWorld.Y + BodyVisibleHeight - BodyTotalHeight * 0.5
            boss.CFrame = CFrame.new(heartWorld.X, centerY, heartWorld.Z)
            -- Targeting helpers — boss is now at heart cell so
            -- standard story-mode TargetRadius works (towers see
            -- distance 0, hit the body silhouette directly).
            boss:SetAttribute("TargetXZOnly", true)
            boss:SetAttribute("TargetRadius", math.max(BodyWidth, BodyDepth) * 0.5)
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
            local headOffsetFromCenter = BodyTotalHeight * 0.5 + 6
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
    local miniHp = (Config.Map3 and Config.Map3.PickleLord
        and Config.Map3.PickleLord.MiniHp) or 7000
    local miniPickleActive = true
    task.spawn(function()
        while miniPickleActive do
            if isMap4HeartDead() then break end
            -- Burst 4 mini pickles per tick, ~0.3s tick gap.
            for _ = 1, 4 do
                if not miniPickleActive then break end
                local m = waveCtx.makeMob("fast", waypoints, 1.0)
                if m then
                    m:SetAttribute("MaxHealth", miniHp)
                    m:SetAttribute("Health",    miniHp)
                    if waveCtx.activeMobs and waveCtx.activeMobs[m] then
                        local data = waveCtx.activeMobs[m]
                        data.hp     = miniHp
                        data.maxHp  = miniHp
                        data.damage = miniHp
                        -- ea3-84: refresh the BillboardGui HP text.
                        -- MobFactory line 326 sets hpText.Text =
                        -- "scaledHp / scaledHp" (= 18/18 from fast-mob
                        -- base) at spawn time; overriding the registry
                        -- hp doesn't update the displayed text. Per
                        -- Matthew "spawning random 18 hp balls?" —
                        -- the 18/18 bars are the mini-pickles
                        -- displaying their pre-override label even
                        -- though damage logic sees the 7000 HP value.
                        if data.hpText then
                            data.hpText.Text = string.format("%d / %d", miniHp, miniHp)
                        end
                        if data.hpFill then
                            data.hpFill.Size = UDim2.fromScale(1, 1)
                        end
                    end
                end
                task.wait(0.05)
            end
            task.wait(0.3)
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

    -- Run loop: wait for heart at 0 OR a hard ceiling (60s) so a
    -- broken kit doesn't stall the sweep indefinitely.
    local PHASE_4_TIME_CEILING_S = 60
    local startedAt = os.clock()
    while not isMap4HeartDead() do
        if _state and _state.aborted then break end  -- ea3-74 abort
        if os.clock() - startedAt > PHASE_4_TIME_CEILING_S then
            print("[ArenaSweepRunner] Phase 4 — time ceiling hit, terminating")
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

    -- Reset run state.
    StatLedger.setRecordingEnabled(true)
    StatLedger.reset()
    AutoPicker.beginAuto(opts.autoPickerOpts or { mode = "random" })
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
    local sweepStartedAt = os.clock()
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
            -- Phase 4 stationary boss + mini-pickle swarm.
            local phase4Result = runStationaryBossPhase(player, opts, hooks)
            result.phaseResults[4] = phase4Result
        end

        -- ea3-74: phase-end progress fire (real-time elapsed).
        fireProgressNow(comboLabel)

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

    -- 1) Pick best Core (3 runs, no aux).
    local coreScores = {}
    local stage1Total = #CoreTypes.Ids
    for i, coreId in ipairs(CoreTypes.Ids) do
        progress("stage 1 / Core sweep", i, stage1Total)
        local r = ArenaSweepRunner.runOneCombo(player, {
            coreId = coreId,
            auxIds = {},
            autoPickerOpts = opts.autoPickerOpts or { mode = "random" },
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

    -- Build aux iteration list (excludes the Pickle Lord permanent slot;
    -- TempTowers.Templates is the canonical aux roster).
    local auxIds = {}
    for id in pairs(TempTowers.Templates) do table.insert(auxIds, id) end
    table.sort(auxIds)  -- deterministic order

    -- 2) Best aux paired with bestCore.
    local auxScores = {}
    local stage2Total = #auxIds
    for i, auxId in ipairs(auxIds) do
        progress("stage 2 / aux sweep", i, stage2Total)
        local r = ArenaSweepRunner.runOneCombo(player, {
            coreId = bestCore,
            auxIds = { auxId },
            autoPickerOpts = opts.autoPickerOpts or { mode = "random" },
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
        local r = ArenaSweepRunner.runOneCombo(player, {
            coreId = bestCore,
            auxIds = { bestAux1, auxId },
            autoPickerOpts = opts.autoPickerOpts or { mode = "random" },
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
        local r = ArenaSweepRunner.runOneCombo(player, {
            coreId = bestCore,
            auxIds = { bestAux1, bestAux2, auxId },
            autoPickerOpts = opts.autoPickerOpts or { mode = "random" },
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

-- Full coverage: every (Core, aux1, aux2, aux3) combination. WAY heavier
-- than greedy — 3 × C(14,3) = 1092 combos. Used by SUPER AUTORUN.
function ArenaSweepRunner.runFullCoverageSweep(player, opts, hooks)
    opts = opts or {}
    hooks = hooks or {}
    local auxIds = {}
    for id in pairs(TempTowers.Templates) do table.insert(auxIds, id) end
    table.sort(auxIds)
    local results = {}
    local total = #CoreTypes.Ids * (#auxIds * (#auxIds - 1) * (#auxIds - 2)) / 6
    local idx = 0
    for _, coreId in ipairs(CoreTypes.Ids) do
        for i = 1, #auxIds do
            for j = i + 1, #auxIds do
                for k = j + 1, #auxIds do
                    idx = idx + 1
                    if hooks.onProgress then hooks.onProgress("full coverage", idx, total) end
                    print(("[ArenaSweepRunner.full] %d/%d — %s + %s + %s + %s"):format(
                        idx, total, coreId, auxIds[i], auxIds[j], auxIds[k]))
                    local r = ArenaSweepRunner.runOneCombo(player, {
                        coreId = coreId,
                        auxIds = { auxIds[i], auxIds[j], auxIds[k] },
                        autoPickerOpts = opts.autoPickerOpts or { mode = "random" },
                    }, {})
                    table.insert(results, { coreId = coreId, auxIds = {auxIds[i], auxIds[j], auxIds[k]}, result = r })
                end
            end
        end
    end
    print(("[ArenaSweepRunner.full] DONE — %d combos run"):format(#results))
    return { allResults = results }
end

return ArenaSweepRunner
