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
    r:FireClient(player, {
        coreId          = opts.coreId,
        auxIds          = opts.auxIds or {},
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
-- ea3-55: per-wave stats logged so VALIDATE / AUTORUN progress is
-- readable from the server log without screen-watching the swarm.
local function runOneWave(waveData, phaseHpMult, waveLabel)
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
    -- Per-wave header.
    local mobCount = 0
    for _, spawn in ipairs(waveData.spawns) do
        if spawn.mobType ~= "boss" and spawn.mobType ~= "finalboss" then
            mobCount = mobCount + (spawn.count or 1)
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
    print(("[Sweep] %s START — %d mobs to spawn, hpMult=%.2f, heart=%d"):format(
        tostring(waveLabel), mobCount, hpMult, heartBefore))

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
        if isMap4HeartDead() then break end
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
        -- continuous scenario).
        if _state.comboElapsed and _state.comboTotalSec then
            fireProgress(_state.player, _state.comboElapsed,
                _state.comboTotalSec, "PICKLE LORD")
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
        -- ea3-62: actually stop the boss walking. The Speed attribute
        -- is decorative; MobUpdate reads from activeMobs[mob].speed
        -- which is set at makeMob time. Without overriding that, the
        -- boss walks waypoint[1] → ... → heart at full tank speed
        -- regardless of the attribute. Per Matthew "pickle boss is
        -- not supposed to walk the path".
        if waveCtx.activeMobs and waveCtx.activeMobs[boss] then
            waveCtx.activeMobs[boss].speed = 0
        end
        boss:SetAttribute("Speed", 0)  -- decorative, but kept for any read-the-attr code

        -- Reposition to Map 4's heart cell + clear ahead of it.
        -- Heart cell is Config.Map4.HeartCell (local col, row);
        -- ctx publishes cellToWorld via Hub setup. Boss sits 6
        -- studs in front of the heart so towers around the heart
        -- ring still fire at it (reading targets in their range).
        local heartCellCfg = Config.Map4.HeartCell
        if heartCellCfg and _hubCtx and _hubCtx.cellToWorld and _hubCtx.MAP4_COL_OFFSET then
            local absCol = _hubCtx.MAP4_COL_OFFSET + heartCellCfg.col
            local heartWorld = _hubCtx.cellToWorld(absCol, heartCellCfg.row)
            -- Lift the boss 4 studs so its hit-volume centre sits
            -- above the floor (matches default mob spawn vertical).
            boss.CFrame = CFrame.new(heartWorld.X - 8, heartWorld.Y + 4, heartWorld.Z)
        end

        -- Rough Pickle Lord visual — green elongated capsule attached
        -- to the boss model so the player visually identifies the
        -- target as a Pickle Lord. The actual hit-volume stays the
        -- existing makeMob "tank" body underneath; this is just
        -- decoration.
        local pickleSkin = Instance.new("Part")
        pickleSkin.Name = "PickleLordSkin"
        pickleSkin.Shape = Enum.PartType.Cylinder
        pickleSkin.Size = Vector3.new(12, 5, 5)  -- horizontal cylinder = pickle
        pickleSkin.Material = Enum.Material.Neon
        pickleSkin.Color = Color3.fromRGB(80, 200, 80)
        pickleSkin.Transparency = 0.15
        pickleSkin.CanCollide = false
        pickleSkin.Anchored = false
        pickleSkin.CFrame = boss.CFrame
              * CFrame.Angles(0, 0, math.rad(90))  -- stand cylinder vertical
        pickleSkin.Parent = boss
        -- Weld the skin to the boss so they move together (or stay
        -- together while pinned at speed=0).
        local weld = Instance.new("WeldConstraint")
        weld.Part0 = boss:IsA("BasePart") and boss
                     or boss:FindFirstChildWhichIsA("BasePart")
        weld.Part1 = pickleSkin
        weld.Parent = pickleSkin
        -- Two eye dots (small white spheres) on the front face.
        for side = -1, 1, 2 do
            local eye = Instance.new("Part")
            eye.Name = ("PickleEye%s"):format(side > 0 and "R" or "L")
            eye.Shape = Enum.PartType.Ball
            eye.Size = Vector3.new(0.9, 0.9, 0.9)
            eye.Material = Enum.Material.Neon
            eye.Color = Color3.fromRGB(255, 255, 255)
            eye.CanCollide = false
            eye.Anchored = false
            eye.CFrame = boss.CFrame
                  * CFrame.new(side * 1.6, 1.2, -2.6)
            eye.Parent = boss
            local eyeWeld = Instance.new("WeldConstraint")
            eyeWeld.Part0 = pickleSkin
            eyeWeld.Part1 = eye
            eyeWeld.Parent = eye
        end
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
    -- ea3-55: auto-disable Map 4 visuals during the sweep so the
    -- analyst doesn't have to watch the swarm chaos. Workspace.
    -- InfiniteVisuals = true means VISIBLE; we save the prior value
    -- and restore on completion. Per Matthew "i stopped it; it was
    -- just spamming 9 hp mobs" — read the log for progress instead.
    local visualsBefore = Workspace:GetAttribute("InfiniteVisuals")
    Workspace:SetAttribute("InfiniteVisuals", false)
    _state.visualsBefore = visualsBefore

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

    -- ea3-57: ETA bar — total combo time + progress remote fired
    -- per phase boundary (and at each wave end) so the HUD bar
    -- fills smoothly. comboTotalSec defaults to ~220s; sweep
    -- runners (greedy / full) will multiply this by combo count.
    local comboTotalSec = (opts.totalEstimateSec) or comboEstimateSec()
    local comboElapsed  = 0
    local comboLabel    = opts.progressLabel or "VALIDATE"
    -- Stash on _state so runStationaryBossPhase can fire its own
    -- progress label ("PICKLE LORD") with the right elapsed/total.
    if _state then
        _state.comboElapsed  = comboElapsed
        _state.comboTotalSec = comboTotalSec
    end

    -- Iterate phases.
    for phase = 1, 4 do
        if hooks.onPhaseStart then hooks.onPhaseStart(phase) end
        Workspace:SetAttribute("Map4ActivePhase", phase)
        task.wait(0.5)  -- let path / grid rebuild settle
        -- ea3-56: fire combo-info to the HUD second row.
        fireComboInfo(player, opts, phase)
        -- ea3-57: phase-start progress fire.
        fireProgress(player, comboElapsed, comboTotalSec, comboLabel)

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
                fireRoundUpdate(player, phase, waveN)
                -- ea3-61: progress bar label per wave start —
                -- "MAP N  •  WAVE M". Phase 1-3 maps to MAP 1-3;
                -- phase 4 special-cased below.
                fireProgress(player, comboElapsed, comboTotalSec,
                    ("MAP %d  •  WAVE %d"):format(phase, waveN))
                local waveData = WaveData.WAVES[waveN]
                if waveData then
                    runOneWave(waveData, PHASE_HP_MULT[phase],
                        ("phase %d wave %d"):format(phase, waveN))
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

        -- ea3-57: phase-end progress fire — accumulate the phase's
        -- estimated cost into comboElapsed.
        comboElapsed = comboElapsed + (PHASE_REAL_TIME_S[phase] or 50)
        if _state then _state.comboElapsed = comboElapsed end
        fireProgress(player, comboElapsed, comboTotalSec, comboLabel)

        if hooks.onPhaseEnd then hooks.onPhaseEnd(phase, result.phaseResults[phase]) end
    end

    if not result.finalPhase then
        result.finalPhase = 4  -- completed all 4 phases
    end
    result.statSnapshot   = StatLedger.snapshot()
    result.elapsedSeconds = os.clock() - result.startedAt

    AutoPicker.endAuto()
    -- ea3-55: restore InfiniteVisuals to pre-sweep value (was set to
    -- false at start so the analyst doesn't have to watch the swarm).
    Workspace:SetAttribute("InfiniteVisuals", _state.visualsBefore)
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
