--[[
    StorySuperAuto.lua — Phase E-2 (2026-04-29 ea3-35).

    Replaces the broad-sweep behavior of SUPER AUTO with a story-
    progression-mirror sweep. Per memory project_core_upgrade_picker.md
    → "SUPER AUTO redesign":

        Each Core's sweep mirrors a full story run.
        For each Core: map 1 → map 2 → map 3 (+ optional +20% bonus).

    SHIPPED:
      • E-2 (ea3-35): orchestration of the 3-Core sequence using
        StoryAutoDriver + AutoPicker. Per-Core start → onComplete /
        onFailed → next Core. Per-Core result capture, server log
        breadcrumbs at every phase transition.
      • E-2.5 (ea3-36): tower auto-placement on map enter. Caller
        supplies `placeTower(player, towerType, anchorCol, anchorRow)`
        via opts (Infinite handler reads it from ctx). This module
        sets <coreId>Stock = 1 on map 1 (SwitchMap auto-grants for
        2/3) then iterates a candidate-cell list per map until a
        placement succeeds. Auxes still NOT placed — the temp-tower
        picker fires its own AutoPicker bypass and stamps owned/stock
        attrs, but with no aux placement they remain in the player's
        inventory rather than on the field.

    DEFERRED to a later phase:
      • Aux tower auto-placement. Once a temp-tower picker auto-
        resolves a card, the player has stock for that aux. The
        next iteration adds an aux placement loop in onMapEntered
        (or a separate post-pick hook).
      • The "+20% bonus" stress phase (map3plus). Driver state
        machine already has the `map3plus` enum entry; toggling
        Workspace.RunDifficultyMult = 1.2 + re-firing SwitchMap
        to map 3 is the implementation.
      • Real upgrade pick selection. Currently AutoPicker is in
        "random" mode. Phase E-3 (CORE AUTO) layers fixed-index
        mode for controlled tests.

    TYPICAL CALL FLOW:

        StorySuperAuto.start(player, function(summary)
            print("Sweep done")
            for _, perCore in ipairs(summary.perCore) do
                print(perCore.coreId, perCore.finalPhase, perCore.elapsedSeconds)
            end
        end)

    The progress / result remotes (autoRunProgressRemote etc.) used
    by the existing SUPER AUTO are NOT wired here yet — E-2.5 hooks
    the same UI plumbing once placement lands so the run looks like
    a normal sweep from the client's monitor.
]]

local CoreTypes = require(game:GetService("ReplicatedStorage")
    :WaitForChild("Shared")
    :WaitForChild("CoreTypes"))
local StoryAutoDriver = require(script.Parent:WaitForChild("StoryAutoDriver"))

local StorySuperAuto = {}

-- ===========================================================================
-- Module state.
-- ===========================================================================

type CoreResult = {
    coreId         : string,
    finalPhase     : string,
    failureReason  : string?,
    mapResults     : any,
    elapsedSeconds : number,
}

type PlaceTowerFn = (Player, string, number, number) -> ()
type FindCellFn   = (number, number, number) -> (number?, number?)

type SweepState = {
    player          : Player,
    coreQueue       : { string },  -- remaining Cores to run
    activeCoreIdx   : number,      -- 1-based pointer into the original sequence (for progress display)
    totalCores      : number,
    perCore         : { CoreResult },
    onComplete      : ((summary: any) -> ())?,
    placeTower      : PlaceTowerFn?,
    findOpenCell    : FindCellFn?,
    sweepStartedAt  : number,
}

local _state: SweepState? = nil

-- TempTowers.Templates is the canonical aux roster — placeAuxesOnMap
-- iterates this to find any aux the player has stock for. Required
-- here at module scope (rather than per-call) so the require()
-- happens once at boot, not on every map enter.
local TempTowers = require(game:GetService("ReplicatedStorage")
    :WaitForChild("Shared")
    :WaitForChild("TempTowers"))

-- ===========================================================================
-- Public introspection.
-- ===========================================================================

function StorySuperAuto.isActive(): boolean
    return _state ~= nil
end

function StorySuperAuto.describe(): string
    if not _state then return "(idle)" end
    return ("StorySuperAuto: core %d/%d (%s), %d done"):format(
        _state.activeCoreIdx,
        _state.totalCores,
        _state.coreQueue[1] or "?",
        #_state.perCore
    )
end

-- ===========================================================================
-- Internal: per-Core lifecycle.
-- ===========================================================================

local startNextCore  -- forward-decl

local function recordCoreResult(summary: any, failureReason: string?)
    if not _state then return end
    table.insert(_state.perCore, {
        coreId         = summary.coreId,
        finalPhase     = summary.finalPhase or "unknown",
        failureReason  = failureReason or summary.failureReason,
        mapResults     = summary.mapResults,
        elapsedSeconds = summary.elapsedSeconds or 0,
    })
    print(("[StorySuperAuto] Core done: %s → %s (%.1fs, reason=%s)"):format(
        tostring(summary.coreId),
        tostring(summary.finalPhase),
        summary.elapsedSeconds or 0,
        tostring(failureReason or summary.failureReason)
    ))
end

local function finishSweep()
    if not _state then return end
    local elapsed = os.clock() - _state.sweepStartedAt
    print(("[StorySuperAuto] sweep complete in %.1fs — %d cores done"):format(
        elapsed, #_state.perCore))
    local summary = {
        perCore        = _state.perCore,
        elapsedSeconds = elapsed,
    }
    local cb = _state.onComplete
    _state = nil
    if cb then cb(summary) end
end

-- Place a single tower (Core or aux) at the first open cell its
-- footprint fits in. Uses the placement-helper-supplied cell finder
-- (deterministic top-down, left-to-right scan within the map's
-- bounds — see TowerPlacement.lua). Returns true on success.
local function placeOneTower(
    player: Player,
    towerType: string,
    mapId: number,
    footprintW: number,
    footprintD: number,
    placeTower: PlaceTowerFn,
    findOpenCell: FindCellFn
): boolean
    local col, row = findOpenCell(mapId, footprintW, footprintD)
    if not col or not row then
        warn(("[StorySuperAuto] no open %dx%d cell on map %d for %s — skipping"):format(
            footprintW, footprintD, mapId, towerType))
        return false
    end
    local stockAttr = towerType .. "Stock"
    local stockBefore = player:GetAttribute(stockAttr) or 0
    placeTower(player, towerType, col, row)
    local stockAfter = player:GetAttribute(stockAttr) or 0
    if stockAfter < stockBefore then
        print(("[StorySuperAuto] placed %s for %s on map %d at (%d,%d)"):format(
            towerType, player.Name, mapId, col, row))
        return true
    end
    -- Placement helper rejected (no stock, etc). The placement
    -- handler's own warn() will detail the rejection reason.
    return false
end

-- Place the active Core for `player` on `mapId`. Map 1 doesn't
-- auto-grant Core stock on SwitchMap (that's the map where the
-- player NORMALLY picks via TowerPicked first); maps 2 and 3 have
-- their own SwitchMap auto-grant block. Set stock = 1 here as a
-- belt-and-suspenders so the first cell that fits consumes it.
local function placeCoreOnMap(
    player: Player,
    coreId: string,
    mapId: number,
    placeTower: PlaceTowerFn,
    findOpenCell: FindCellFn
): boolean
    local cur = player:GetAttribute(coreId .. "Stock") or 0
    if cur <= 0 then
        player:SetAttribute(coreId .. "Stock", 1)
    end

    -- Look up the Core's footprint via TempTowers.Templates fallback
    -- to TowerTypes (Cores aren't in TempTowers, but the placement
    -- helper accepts both). We hardcode 4×4 for the Core since all 3
    -- Cores currently use that footprint; if a future Core variant
    -- ships a different size, the placement helper will reject and
    -- we'll see "no open cell" in the log.
    local fw, fd = 4, 4
    local placed = placeOneTower(player, coreId, mapId, fw, fd, placeTower, findOpenCell)
    if not placed then
        warn(("[StorySuperAuto] failed to place Core %s on map %d — run will fail wave 1"):format(
            coreId, mapId))
    end
    return placed
end

-- Place every aux tower the player owns (stock > 0) at the next
-- open cell with a fitting footprint. Used by onMapEntered for
-- maps 2 and 3 (and map 1 if the player started with a stock-loaded
-- aux, which currently doesn't happen but is harmless to attempt).
--
-- Auxes accumulate across map bosses: map 1 boss → 1 aux, map 2
-- boss → 1 aux, etc. By the time the run reaches map 3, the player
-- typically owns 2 auxes. Each aux is placed ONCE; if stock > 1
-- (rare; only via dev re-pick), the extra stays in inventory.
local function placeOwnedAuxesOnMap(
    player: Player,
    mapId: number,
    placeTower: PlaceTowerFn,
    findOpenCell: FindCellFn
): number
    local placed = 0
    for towerId, tpl in pairs(TempTowers.Templates) do
        local stock = player:GetAttribute(towerId .. "Stock") or 0
        if stock > 0 then
            local fw = tpl.footprintWidth or 4
            local fd = tpl.footprintDepth or 4
            if placeOneTower(player, towerId, mapId, fw, fd, placeTower, findOpenCell) then
                placed = placed + 1
            end
        end
    end
    if placed > 0 then
        print(("[StorySuperAuto] placed %d aux towers on map %d for %s"):format(
            placed, mapId, player.Name))
    end
    return placed
end

startNextCore = function()
    if not _state then return end
    if #_state.coreQueue == 0 then
        finishSweep()
        return
    end

    local coreId = table.remove(_state.coreQueue, 1)
    _state.activeCoreIdx = _state.totalCores - #_state.coreQueue
    print(("[StorySuperAuto] starting Core %d/%d: %s"):format(
        _state.activeCoreIdx, _state.totalCores, coreId))

    -- Capture into upvalues for the onMapEntered closure (state
    -- can be cleared between map transitions if the run fails fast).
    local activePlayer  = _state.player
    local activeCoreId  = coreId
    local placeTower    = _state.placeTower
    local findOpenCell  = _state.findOpenCell

    StoryAutoDriver.start({
        coreId         = coreId,
        autoPickerMode = "random",
        -- 2026-04-29 ea3-36/37 Phase E-2.5: place towers on map enter.
        -- Order: Core first (anchors the map's defense), then any
        -- aux the player owns from prior boss-rewards. Run on a
        -- small task.delay so SwitchMap's grid reset (waveRunToken
        -- bump + clearAllMobs) finishes before the placement reads
        -- gridState. Without the delay, placement was racing the
        -- SwitchMap listener and intermittently landing on a stale
        -- grid.
        onMapEntered   = function(mapId: number)
            if not placeTower or not findOpenCell then
                warn("[StorySuperAuto] no placeTower / findOpenCell helpers — towers won't be placed")
                return
            end
            task.delay(0.5, function()
                if not _state or _state.player ~= activePlayer then return end
                placeCoreOnMap(activePlayer, activeCoreId, mapId, placeTower, findOpenCell)
                placeOwnedAuxesOnMap(activePlayer, mapId, placeTower, findOpenCell)
            end)
        end,
        onComplete     = function(summary)
            -- StoryAutoDriver fills summary.coreId from opts.coreId.
            recordCoreResult(summary, nil)
            -- Defer-next so we don't re-enter StoryAutoDriver.start
            -- inside its own onComplete invocation (which would
            -- briefly re-overlap the _state == nil check).
            task.defer(startNextCore)
        end,
        onFailed       = function(_diedInPhase, summary)
            recordCoreResult(summary, summary.failureReason)
            task.defer(startNextCore)
        end,
    })
end

-- ===========================================================================
-- Public: lifecycle.
-- ===========================================================================

-- Begin a 3-Core story-progression sweep.
--
-- player     : Player instance the sweep is running for. Used by the
--              broader Infinite/Studio plumbing for crash-recovery
--              checkpoints, monitor remote targeting, etc. (E-2.5
--              hooks; E-2 only stores it.)
-- opts       : {
--                 placeTower   : ((Player, towerType, anchorCol, anchorRow) -> ())?,
--                                -- ctx.placeTowerForPlayer from TowerPlacement.
--                                -- When nil, no towers are placed and every
--                                -- run dies on wave 1 (orchestration smoke-test
--                                -- mode).
--                 findOpenCell : ((mapId, footprintW, footprintD) -> (col?, row?))?,
--                                -- ctx.findOpenCellForMap from TowerPlacement.
--                                -- Used to find a fitting cell per tower —
--                                -- variable footprints (4×4 → 12×12) need
--                                -- per-tower cell discovery, not a hardcoded
--                                -- list.
--                 onComplete   : ((summary: any) -> ())?,
--                                -- Aggregate summary callback (3-Core sweep done).
--              }
function StorySuperAuto.start(player: Player, opts: any)
    if _state ~= nil then
        warn("[StorySuperAuto] start() called while a sweep is already active — ignoring")
        return false
    end
    if not player or not player.Parent then
        warn("[StorySuperAuto] start() called with no valid player — ignoring")
        return false
    end
    opts = opts or {}

    -- Clone CoreTypes.Ids into a mutable queue (table.remove pops below).
    local queue = {}
    for _, id in ipairs(CoreTypes.Ids) do
        table.insert(queue, id)
    end

    _state = {
        player         = player,
        coreQueue      = queue,
        activeCoreIdx  = 0,
        totalCores     = #queue,
        perCore        = {},
        onComplete     = opts.onComplete,
        placeTower     = opts.placeTower,
        findOpenCell   = opts.findOpenCell,
        sweepStartedAt = os.clock(),
    }
    print(("[StorySuperAuto] start sweep — %d cores queued (%s) placement=%s"):format(
        #queue, table.concat(queue, ", "),
        (opts.placeTower and opts.findOpenCell) and "wired" or "DEFERRED (orchestration only)"))

    startNextCore()
    return true
end

-- Force-stop the sweep mid-flight. Stops the active StoryAutoDriver
-- if it's still running (which calls AutoPicker.endAuto), drops the
-- queue, fires onComplete with a partial summary so the caller can
-- still display whatever Cores DID complete.
function StorySuperAuto.stop()
    if not _state then return end
    print("[StorySuperAuto] stop() — aborting sweep")
    StoryAutoDriver.stop()
    -- Don't fire onComplete here — partial summaries are misleading
    -- because the active Core's recordCoreResult never landed.
    _state = nil
end

return StorySuperAuto
