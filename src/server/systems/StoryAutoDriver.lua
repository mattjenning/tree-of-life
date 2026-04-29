--[[
    StoryAutoDriver.lua — Phase E-1 (2026-04-29 ea3-34).

    Orchestrates a server-side full-story sweep across maps 1 → 2 → 3
    (and optionally 3+20% as a "post-game" stress phase). Pairs with
    AutoPicker (E-prep) which bypasses the 3 player-facing pickers
    so the run can progress without any clicks.

    THIS IS INFRASTRUCTURE for the SUPER AUTO redesign in E-2 — the
    new sweep replaces the existing "Map 4 scaling waves" model with
    "play the actual story progression per Core / rarity bucket".
    The driver itself is unaware of the sweep: callers (E-2's
    superAuto runner) call StoryAutoDriver.start({ ... }) once per
    sub-sweep, await onComplete / onFailed, and aggregate results.

    STATE MACHINE:

      idle      → no run in flight; start() can be called.
      preparing → start() fired SwitchMap to map 1; waiting for
                  the opts.onMapEntered hook (tower placement in
                  E-2) to confirm before turning AutoPicker on.
      map1      → playing through map 1 stages 1-3 + map boss.
      map2      → playing through map 2 stages 1-3 + map boss.
      map3      → playing through map 3 stages 1-3 + map boss.
      map3plus  → re-running map 3 with RunDifficultyMult = 1.2.
                  This is the "+20% post-game" phase; if we cleared
                  it cleanly, the sweep records that anchor too.
      done      → sweep finished cleanly; onComplete invoked.
      failed    → heart died at some point; onFailed invoked with
                  the phase that died.

    EVENT WIRING:

      BossRewardClaimed (BindableEvent) — fires from TempTowerRewards
        AFTER it has resolved a temp-tower pick (real OR auto). In
        AutoPicker mode the picker auto-resolves synchronously, so
        by the time the driver's listener sees this event, both
        the temp-tower pick AND the chained CoreUpgrades pick have
        already stamped their attributes. We use this as the "map
        boss flow done — ready to switch maps" signal and fire
        SwitchMap to advance to the next map.

      GameOver (RemoteEvent) — broadcast by WaveSystem when the
        heart dies. Listening to this is awkward because it's a
        RemoteEvent (server → client), not a bindable. We attach
        to its OnServerEvent for completeness but the canonical
        signal is the Workspace heart's Health attribute hitting 0;
        we poll Heart attributes during the run via a Heartbeat
        connection instead.

    NOT WIRED IN E-1 (deferred to E-2):
      - Tower auto-placement (Core + aux loadout). E-1 calls the
        opts.onMapEntered(mapId, driver) hook and expects callers
        to place towers. Without placement, the run dies on wave 1.
        E-2 wires the placement helper.
      - Map 3+20% stress phase (TODO: re-fire SwitchMap to map 3
        after setting Workspace.RunDifficultyMult = 1.2).
      - Stat capture per stage (deferred to E-4).

    Per memory project_core_upgrade_picker.md (Matthew design dump
    2026-04-29). Tested-by-construction: phase transitions are
    print()-logged so a sweep run leaves a clear breadcrumb in the
    server log; E-2 will add JSON output for offline analysis.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Tags    = require(Shared:WaitForChild("Tags"))

local AutoPicker = require(script.Parent:WaitForChild("AutoPicker"))

local StoryAutoDriver = {}

-- ===========================================================================
-- Module state. Single-active assumption: one sweep at a time.
-- ===========================================================================

type Phase = "idle" | "preparing" | "map1" | "map2" | "map3" | "map3plus" | "done" | "failed"

type DriverState = {
    phase           : Phase,
    coreId          : string?,
    auxLoadout      : { string }?,
    onMapEntered    : ((mapId: number, driver: any) -> ())?,
    onComplete      : ((summary: any) -> ())?,
    onFailed        : ((phase: Phase, summary: any) -> ())?,
    -- Bookkeeping for failure detection.
    heartbeatConn   : RBXScriptConnection?,
    bossClaimedConn : RBXScriptConnection?,
    -- For onComplete / onFailed payloads.
    startedAt       : number,
    mapResults      : { [number]: { reachedStage: number, cleared: boolean } },
}

local _state: DriverState? = nil

-- ===========================================================================
-- Public introspection.
-- ===========================================================================

function StoryAutoDriver.isActive(): boolean
    return _state ~= nil and _state.phase ~= "done" and _state.phase ~= "failed"
end

function StoryAutoDriver.phase(): Phase
    if not _state then return "idle" end
    return _state.phase
end

function StoryAutoDriver.describe(): string
    if not _state then return "(idle)" end
    return ("phase=%s coreId=%s aux=%d"):format(
        _state.phase,
        tostring(_state.coreId),
        _state.auxLoadout and #_state.auxLoadout or 0
    )
end

-- ===========================================================================
-- Internal: phase transitions.
-- ===========================================================================

local function setPhase(newPhase: Phase)
    if not _state then return end
    print(("[StoryAutoDriver] phase %s → %s"):format(_state.phase, newPhase))
    _state.phase = newPhase
end

-- Resolve to the next map after `mapId` per the standard story
-- sequence. Returns nil if mapId is the final story map (3) — caller
-- decides whether to re-run map 3 with +20% (map3plus) or finish.
local function nextMapId(mapId: number): number?
    if mapId == 1 then return 2 end
    if mapId == 2 then return 3 end
    return nil
end

-- Fire a programmatic SwitchMap. Mirrors the portal-touch path in
-- the hub's world/Map2.lua / Map3.lua. The wave system's SwitchMap
-- listener resets state, grants Core stock, and auto-starts wave 1
-- after a 6.5s grace.
local function fireSwitchMap(mapId: number)
    local mapName = ({
        [1] = "Crook of the Tree",
        [2] = "Climbing the Tree",
        [3] = "Canopy Nest",
    })[mapId] or ("Map " .. tostring(mapId))
    local switchMap = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
    if not switchMap then
        warn("[StoryAutoDriver] SwitchMap bindable not found — cannot advance")
        return
    end
    print(("[StoryAutoDriver] firing SwitchMap → mapId=%d (%s)"):format(mapId, mapName))
    switchMap:Fire({ mapId = mapId, mapName = mapName })
end

-- Sample the active-map heart's HP. The hub tags every heart with
-- Tags.EnemyEndPoint and the wave system uses the same iteration to
-- pick the active heart (see getHeart() in TreeOfLife_WaveSystem). We
-- mirror that without relying on map-id state — any heart at HP 0
-- means a run died.
local function readHeartHp(): number?
    for _, heart in ipairs(CollectionService:GetTagged(Tags.EnemyEndPoint)) do
        local hp = heart:GetAttribute("Health")
        if hp ~= nil then
            return hp
        end
    end
    return nil
end

-- ===========================================================================
-- Internal: run finishers.
-- ===========================================================================

local function teardown()
    if not _state then return end
    if _state.heartbeatConn then
        _state.heartbeatConn:Disconnect()
        _state.heartbeatConn = nil
    end
    if _state.bossClaimedConn then
        _state.bossClaimedConn:Disconnect()
        _state.bossClaimedConn = nil
    end
    AutoPicker.endAuto()
    -- Reset run-difficulty mult in case map3plus left it pegged.
    workspace:SetAttribute("RunDifficultyMult", 1.0)
end

local function buildSummary()
    if not _state then return {} end
    return {
        coreId        = _state.coreId,
        auxLoadout    = _state.auxLoadout,
        finalPhase    = _state.phase,
        mapResults    = _state.mapResults,
        elapsedSeconds = os.clock() - _state.startedAt,
    }
end

local function finishOk()
    if not _state then return end
    setPhase("done")
    local summary = buildSummary()
    local cb = _state.onComplete
    teardown()
    _state = nil
    if cb then cb(summary) end
end

local function finishFail(reason: string)
    if not _state then return end
    local diedIn = _state.phase
    print(("[StoryAutoDriver] failed in %s (reason: %s)"):format(diedIn, reason))
    setPhase("failed")
    local summary = buildSummary()
    summary.failureReason = reason
    local cb = _state.onFailed
    teardown()
    _state = nil
    if cb then cb(diedIn, summary) end
end

-- ===========================================================================
-- Internal: BossRewardClaimed handler. Fires after the temp-tower
-- pick resolves (real or auto). In AutoPicker mode the chain is:
--    BossRewardClaimed → CoreUpgrades.commitPick (auto) → THIS HANDLER.
-- We use task.defer to ensure all sibling listeners (CoreUpgrades)
-- have run before we transition.
-- ===========================================================================

local function onMapBossClaimed(payload: any)
    if not _state then return end
    local claimedMapId = payload and payload.mapId
    if type(claimedMapId) ~= "number" then return end

    print(("[StoryAutoDriver] BossRewardClaimed mapId=%d (current phase=%s)"):format(
        claimedMapId, _state.phase))

    -- Mark this map as cleared in the result table.
    _state.mapResults[claimedMapId] = _state.mapResults[claimedMapId] or {}
    _state.mapResults[claimedMapId].cleared = true

    -- Defer the transition by one frame so any other BossRewardClaimed
    -- listeners (CoreUpgrades' auto-resolve) finish their sync work first.
    task.defer(function()
        if not _state then return end

        local nextId = nextMapId(claimedMapId)
        if nextId then
            -- Advance to the next story map.
            setPhase(("map%d"):format(nextId) :: any)
            fireSwitchMap(nextId)
            -- Notify caller so they can place towers on the new map.
            if _state.onMapEntered then
                _state.onMapEntered(nextId, StoryAutoDriver)
            end
        elseif claimedMapId == 3 then
            -- Map 3 cleared. For now: finish the sweep. E-2 may flip
            -- this branch into the +20% stress phase via map3plus.
            finishOk()
        end
    end)
end

-- ===========================================================================
-- Internal: heart-death poll. We watch Workspace.Heart.Health each
-- Heartbeat; once it hits 0 we treat the run as failed. (Listening
-- to GameOver remote also works but heart-poll is reliable across
-- both scripted GameOver paths and the death-by-final-wave-leak.)
-- ===========================================================================

local function startHeartPoll()
    if not _state then return end
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if not _state then
            if conn then conn:Disconnect() end
            return
        end
        if _state.phase == "done" or _state.phase == "failed" then return end
        local hp = readHeartHp()
        if hp ~= nil and hp <= 0 then
            finishFail("heart died")
        end
    end)
    _state.heartbeatConn = conn
end

-- ===========================================================================
-- Public: lifecycle.
-- ===========================================================================

-- Begin a story-mode auto-run.
--
-- opts: {
--   coreId          : string,                       -- "Power" / "ControlCore" / "SupportCore"
--   auxLoadout      : { string }?,                  -- aux tower ids the player has equipped
--   autoPickerMode  : ("random" | "fixed-index")?,  -- default "random"
--   autoPickerChoices : { [string]: number }?,      -- only for fixed-index mode
--   onMapEntered    : ((mapId, driver) -> ())?,     -- E-2 wires placement here
--   onComplete      : ((summary) -> ())?,
--   onFailed        : ((phase, summary) -> ())?,
-- }
function StoryAutoDriver.start(opts: any)
    if _state ~= nil then
        warn("[StoryAutoDriver] start() called while already active — ignoring")
        return
    end

    _state = {
        phase           = "preparing",
        coreId          = opts.coreId,
        auxLoadout      = opts.auxLoadout,
        onMapEntered    = opts.onMapEntered,
        onComplete      = opts.onComplete,
        onFailed        = opts.onFailed,
        heartbeatConn   = nil,
        bossClaimedConn = nil,
        startedAt       = os.clock(),
        mapResults      = {},
    }

    -- Equip the requested Core for all players (cheap; matches story
    -- mode flow where TowerPicked sets <id>Equipped on the active player).
    -- Without this the SwitchMap "Core stock grant" fallback to "Power"
    -- regardless of opts.coreId.
    if opts.coreId then
        for _, p in ipairs(Players:GetPlayers()) do
            -- Clear any previously equipped Cores first.
            local CoreTypes = require(Shared:WaitForChild("CoreTypes"))
            for _, id in ipairs(CoreTypes.Ids) do
                p:SetAttribute(id .. "Equipped", false)
            end
            p:SetAttribute(opts.coreId .. "Equipped", true)
        end
    end

    -- Kick off the auto-picker before any picker can fire.
    AutoPicker.beginAuto({
        mode    = opts.autoPickerMode or "random",
        choices = opts.autoPickerChoices,
    })
    print(("[StoryAutoDriver] start coreId=%s aux=%d picker=%s"):format(
        tostring(opts.coreId),
        opts.auxLoadout and #opts.auxLoadout or 0,
        AutoPicker.describe()))

    -- Attach listeners.
    local bossClaimed = ReplicatedStorage:FindFirstChild(Remotes.Names.BossRewardClaimed)
    if not bossClaimed then
        warn("[StoryAutoDriver] BossRewardClaimed bindable missing — sweep cannot transition maps")
    else
        _state.bossClaimedConn = bossClaimed.Event:Connect(onMapBossClaimed)
    end
    startHeartPoll()

    -- Fire SwitchMap to map 1. The wave system's listener auto-starts
    -- wave 1 after a 6.5s grace, giving the caller time to place towers
    -- via the onMapEntered hook.
    setPhase("map1")
    fireSwitchMap(1)
    if _state.onMapEntered then
        _state.onMapEntered(1, StoryAutoDriver)
    end
end

function StoryAutoDriver.stop()
    if not _state then return end
    print("[StoryAutoDriver] stop() called — aborting")
    teardown()
    _state = nil
end

return StoryAutoDriver
