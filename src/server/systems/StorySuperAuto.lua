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

type SweepState = {
    player          : Player,
    coreQueue       : { string },  -- remaining Cores to run
    activeCoreIdx   : number,      -- 1-based pointer into the original sequence (for progress display)
    totalCores      : number,
    perCore         : { CoreResult },
    onComplete      : ((summary: any) -> ())?,
    placeTower      : ((Player, string, number, number) -> ())?,
    sweepStartedAt  : number,
}

local _state: SweepState? = nil

-- ===========================================================================
-- Placement candidate cells per map. The placement helper validates
-- each cell against the live grid state (path / heart / occupied) and
-- skips any that fail; the first cell whose footprint fits is used.
-- These are deliberately corner-ish to dodge the central path corridor;
-- if a future map adjustment moves the path into the corner, append a
-- new cell at the end of the list rather than reordering — sweep runs
-- saved with the old cell layout will keep landing where they used to.
--
-- Format: { {anchorCol, anchorRow}, ... }, tried in order.
--
-- Map 1: cols 0-59, rows 0-43, path runs across the middle.
-- Map 2: cols 60-134 (offset 60), rows 0-54.
-- Map 3: cols 135-224 (offset 135), rows 0-65.
local STORY_PLACE_CELLS: { [number]: { { number } } } = {
    [1] = { { 5,  5 }, { 5,  35 }, { 50, 5 }, { 50, 35 } },
    [2] = { { 65, 5 }, { 65, 45 }, { 125, 5 }, { 125, 45 } },
    [3] = { { 140, 5 }, { 140, 55 }, { 215, 5 }, { 215, 55 } },
}

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

-- Place the active Core for `player` on `mapId`. Walks the
-- STORY_PLACE_CELLS list for that map, calls the supplied
-- placeTower helper, and trusts the helper's internal validation
-- to reject cells that don't fit (path / heart / occupied / out
-- of bounds). Returns true if any cell succeeded — false means
-- the run will fail on wave 1 (no defender) and the sweep
-- advances to the next Core via the driver's heart-poll path.
local function placeCoreOnMap(player: Player, coreId: string, mapId: number, placeTower: (Player, string, number, number) -> ())
    local cells = STORY_PLACE_CELLS[mapId]
    if not cells then
        warn(("[StorySuperAuto] no candidate cells for mapId=%d — Core not placed"):format(mapId))
        return false
    end

    -- Map 1 doesn't auto-grant Core stock on SwitchMap (that's the
    -- map where the player NORMALLY picks via TowerPicked first).
    -- Maps 2 and 3 have their own SwitchMap auto-grant block. Set
    -- stock = 1 so the first valid cell consumes it cleanly.
    -- Equipped is already set in StoryAutoDriver.start.
    if mapId == 1 then
        local cur = player:GetAttribute(coreId .. "Stock") or 0
        if cur <= 0 then
            player:SetAttribute(coreId .. "Stock", 1)
        end
    end

    -- Try each candidate cell. The placement helper checks
    -- canPlaceAt internally — first cell that fits wins; rest
    -- skip silently (its rejection prints will appear in the log,
    -- but they're informational not fatal).
    for _, cell in ipairs(cells) do
        local stockBefore = player:GetAttribute(coreId .. "Stock") or 0
        if stockBefore <= 0 then
            -- Edge case: a previous map's Core may have been
            -- placed, leaving this map at 0 stock. Re-grant.
            player:SetAttribute(coreId .. "Stock", 1)
            stockBefore = 1
        end
        placeTower(player, coreId, cell[1], cell[2])
        local stockAfter = player:GetAttribute(coreId .. "Stock") or 0
        if stockAfter < stockBefore then
            -- Stock decremented = placement succeeded. We're done.
            print(("[StorySuperAuto] placed %s for %s on map %d at (%d,%d)"):format(
                coreId, player.Name, mapId, cell[1], cell[2]))
            return true
        end
    end
    warn(("[StorySuperAuto] all candidate cells rejected on map %d for %s — run will fail wave 1"):format(
        mapId, coreId))
    return false
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
    local activePlayer = _state.player
    local activeCoreId = coreId
    local placeTower   = _state.placeTower

    StoryAutoDriver.start({
        coreId         = coreId,
        autoPickerMode = "random",
        -- 2026-04-29 ea3-36 Phase E-2.5: place the Core tower on
        -- map enter. Run on a small task.delay so SwitchMap's grid
        -- reset (waveRunToken bump + clearAllMobs) finishes before
        -- our placement reads gridState. Without the delay, the
        -- placement was racing the SwitchMap listener and
        -- intermittently landing on a stale grid.
        onMapEntered   = function(mapId: number)
            if not placeTower then
                warn("[StorySuperAuto] no placeTower helper supplied — Core won't be placed")
                return
            end
            task.delay(0.5, function()
                if not _state or _state.player ~= activePlayer then return end
                placeCoreOnMap(activePlayer, activeCoreId, mapId, placeTower)
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
--                 placeTower : ((Player, towerType, anchorCol, anchorRow) -> ())?,
--                              -- E-2.5 wiring: Hub's ctx.placeTowerForPlayer
--                              -- (TowerPlacement.lua's exported helper). When
--                              -- nil, no Cores are placed and every run dies
--                              -- on wave 1 (orchestration smoke-test mode).
--                 onComplete : ((summary: any) -> ())?,
--                              -- Aggregate summary callback (3-Core sweep done).
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
        sweepStartedAt = os.clock(),
    }
    print(("[StorySuperAuto] start sweep — %d cores queued (%s) placement=%s"):format(
        #queue, table.concat(queue, ", "),
        opts.placeTower and "wired" or "DEFERRED (orchestration only)"))

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
