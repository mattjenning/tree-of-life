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
    for each. Waves 3-5 spawn mobs from WaveData.WAVES (boss spawn
    filtered out — bosses are tested in real story mode). Picker
    fires after waves 3 + 4 cleared. After phase boundary (1→2, 2→3,
    3→4) a synthetic Core upgrade picker fires (drives CORE AUTO
    fixed-index/sequence comparison).

    Total per phase: 4 upgrade picks + 1 synthetic Core upgrade pick
    at boundary (3 phases of boundaries). Wave 5 boss spawn skipped.

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
end

function ArenaSweepRunner.isActive(): boolean
    return _state ~= nil
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

local function isMap4HeartDead(): boolean
    -- Find Map 4's heart by partMapId == 4. ctx.partMapId reads the
    -- MapId attribute set by Hub on each tagged heart.
    if not _hubCtx then return false end
    for _, heart in ipairs(CollectionService:GetTagged(Tags.EnemyEndPoint)) do
        if _hubCtx.partMapId and _hubCtx.partMapId(heart) == 4 then
            local hp = heart:GetAttribute("Health") or 0
            return hp <= 0
        end
    end
    return false
end

-- Per-phase mob HP scaling. Phase 1 = baseline; later phases scale up
-- to roughly mimic Map 1/2/3 difficulty curves.
local PHASE_HP_MULT = { [1] = 1.0, [2] = 1.5, [3] = 2.0, [4] = 1.0 }

-- Per-phase mob composition: which WAVES table waves get spawned
-- when phase N runs. 3..5 = stage 3 worth of content (waves 3, 4, 5
-- with boss spawn filtered out).
local PHASE_WAVES_TO_RUN = { 3, 4, 5 }

local function gameSpeed(): number
    if WaveCtxBridge.ctx and WaveCtxBridge.ctx.gameSpeed then
        return WaveCtxBridge.ctx.gameSpeed
    end
    return 1
end

-- Spawn one wave's worth of mobs on Map 4. Skips boss spawns. Waits
-- for active mob count to reach 0 before returning (wave cleared).
local function runOneWave(waveData, phaseHpMult)
    local waveCtx = WaveCtxBridge.ctx
    if not waveCtx or not waveCtx.makeMob then
        warn("[ArenaSweepRunner] WaveCtxBridge.ctx.makeMob unavailable — wave skipped")
        return
    end
    local hpMult = (waveData.hpMult or 1.0) * phaseHpMult
    local waypoints = waveCtx.getWaypoints()
    if not waypoints or #waypoints == 0 then
        warn("[ArenaSweepRunner] no Map 4 waypoints — wave skipped")
        return
    end
    -- Spawn each spawn group sequentially.
    for _, spawn in ipairs(waveData.spawns) do
        if spawn.mobType == "boss" or spawn.mobType == "finalboss" then
            -- ea3-50: skip boss spawns. Bosses are tested in real
            -- story mode (player interaction needed); the sweep is
            -- meant to simulate "story mode minus the bosses".
            continue
        end
        for _ = 1, (spawn.count or 1) do
            waveCtx.makeMob(spawn.mobType, waypoints, hpMult)
            task.wait((spawn.interval or 0.5) / gameSpeed())
        end
        if spawn.gap and spawn.gap > 0 then
            task.wait(spawn.gap / gameSpeed())
        end
    end
    -- Wait for clear (or heart death — caller checks).
    while waveCtx.countActiveMobs and waveCtx.countActiveMobs() > 0 do
        if isMap4HeartDead() then return end
        task.wait(0.2)
    end
end

-- Fire one upgrade picker (auto-resolved via AutoPicker's tempTower-
-- key bypass; reuses the existing UpgradeCards.lua picker fire path
-- via a synthetic "between waves" event).
local function fireOneUpgradePicker(player, waveIndex)
    local waveCtx = WaveCtxBridge.ctx
    if not waveCtx or not waveCtx.generateCardsForPlayer then return end
    local cards = waveCtx.generateCardsForPlayer(player, waveIndex)
    if AutoPicker.isActive() then
        local idx = AutoPicker.pickIndex(#cards, "upgradeCard")
        local picked = cards[idx]
        if picked and waveCtx.applyUpgrade then
            waveCtx.applyUpgrade(player, picked)
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
    -- Score-based placement.
    local col, row = _hubCtx.findOptimalPlacementCell({
        role         = role,
        footprintW   = footprintW,
        footprintD   = footprintD,
        range        = range,
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

-- Helper for idempotent aux placement (body assigned to forward-decl).
function placePhaseAux(player, auxId)
    local tpl = TempTowers.Templates[auxId]
    if not tpl then return end
    local already = false
    for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        local t = base.Parent
        if t and t:GetAttribute("Owner") == player.UserId
           and t:GetAttribute("TowerType") == auxId then
            already = true; break
        end
    end
    if already then return end
    local role = TempTowers.RoleByTowerId and TempTowers.RoleByTowerId[auxId] or "DPS"
    placeTowerForRole(player, auxId, role,
        tpl.footprintWidth or 4,
        tpl.footprintDepth or 4,
        tpl.range or 22)
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

    -- Engage 10s tower-fire suppression.
    Workspace:SetAttribute("ArenaSweepNoFire", true)
    print(("[ArenaSweepRunner] Phase 4 START — 10s tower setup penalty engaged"):format())

    -- Spawn the stationary boss. Use an existing tank-style mob and
    -- pin its Speed = 0. Boss HP is set to a very high value so the
    -- damage measurement window is meaningful regardless of kit
    -- damage output.
    local STATIONARY_BOSS_HP = 250000
    local boss = waveCtx.makeMob("tank", waypoints, 1.0)
    if boss then
        boss:SetAttribute("MaxHealth", STATIONARY_BOSS_HP)
        boss:SetAttribute("Health",    STATIONARY_BOSS_HP)
        boss:SetAttribute("Speed",     0)
        boss:SetAttribute("MobType",   "pickle_boss")  -- StatLedger bucketing
    end
    local bossInitialHp = STATIONARY_BOSS_HP

    -- Spawn the mini-pickle swarm coroutine (continuous spawn until
    -- heart dies or the run ends). Mini pickles use the "fast" mob
    -- type (light HP, walks the path quickly) — they leak past the
    -- towers and bash the heart, providing the "overwhelmed"
    -- pressure even though the towers are firing once the penalty
    -- lifts.
    local miniPickleActive = true
    task.spawn(function()
        while miniPickleActive do
            if isMap4HeartDead() then break end
            -- Burst 4 mini pickles per tick, ~0.3s tick gap.
            for _ = 1, 4 do
                if not miniPickleActive then break end
                waveCtx.makeMob("fast", waypoints, 0.5)  -- 0.5x HP
                task.wait(0.05)
            end
            task.wait(0.3)
        end
    end)

    -- Setup-penalty timer: clear the no-fire flag after 10s.
    task.spawn(function()
        task.wait(10)
        Workspace:SetAttribute("ArenaSweepNoFire", false)
        print("[ArenaSweepRunner] Phase 4 — 10s setup penalty lifted, towers firing")
    end)

    -- Run loop: wait for heart at 0 OR a hard ceiling (60s) so a
    -- broken kit doesn't stall the sweep indefinitely.
    local PHASE_4_TIME_CEILING_S = 60
    local startedAt = os.clock()
    while not isMap4HeartDead() do
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

    -- Equip the chosen Core.
    if opts.coreId then
        for _, c in ipairs(CoreTypes.Ids) do
            player:SetAttribute(c .. "Equipped", c == opts.coreId)
        end
    end

    -- Heal hearts so prior runs don't bleed in.
    healAllHearts()

    -- Iterate phases.
    for phase = 1, 4 do
        if hooks.onPhaseStart then hooks.onPhaseStart(phase) end
        Workspace:SetAttribute("Map4ActivePhase", phase)
        task.wait(0.5)  -- let path / grid rebuild settle

        placeTowersForPhase(player, opts, phase)
        task.wait(0.3)

        if phase < 4 then
            -- 2 skipped breather waves → 2 upgrade picks
            for breather = 1, 2 do
                fireOneUpgradePicker(player, breather)
                task.wait(0.1)
            end
            -- Run waves 3, 4, 5 (boss spawn filtered out)
            local waveCleared = true
            for waveIdx, waveN in ipairs(PHASE_WAVES_TO_RUN) do
                if isMap4HeartDead() then waveCleared = false; break end
                local waveData = WaveData.WAVES[waveN]
                if waveData then
                    runOneWave(waveData, PHASE_HP_MULT[phase])
                end
                if isMap4HeartDead() then waveCleared = false; break end
                if waveIdx < #PHASE_WAVES_TO_RUN then
                    fireOneUpgradePicker(player, waveN)
                    task.wait(0.1)
                end
            end
            -- Synthetic Core upgrade pick at phase boundary.
            fireSyntheticCoreUpgrade(player, phase)
            result.phaseResults[phase] = {
                cleared = waveCleared,
                heartHp = (function()
                    for _, h in ipairs(CollectionService:GetTagged(Tags.EnemyEndPoint)) do
                        if _hubCtx and _hubCtx.partMapId and _hubCtx.partMapId(h) == 4 then
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

        if hooks.onPhaseEnd then hooks.onPhaseEnd(phase, result.phaseResults[phase]) end
    end

    if not result.finalPhase then
        result.finalPhase = 4  -- completed all 4 phases
    end
    result.statSnapshot   = StatLedger.snapshot()
    result.elapsedSeconds = os.clock() - result.startedAt

    AutoPicker.endAuto()
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
