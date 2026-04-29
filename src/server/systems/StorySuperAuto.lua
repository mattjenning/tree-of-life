--[[
    StorySuperAuto.lua — Phase E-2 (2026-04-29 ea3-35).

    Replaces the broad-sweep behavior of SUPER AUTO with a story-
    progression-mirror sweep. Per memory project_core_upgrade_picker.md
    → "SUPER AUTO redesign":

        Each Core's sweep mirrors a full story run.
        For each Core: map 1 → map 2 → map 3 (+ optional +20% bonus).

    SHIPPED in E-2 (this commit):
      • Orchestration of the 3-Core sequence using StoryAutoDriver +
        AutoPicker. Per-Core start → onComplete / onFailed → next Core.
      • Per-Core result capture (final phase, elapsed seconds, which
        maps were cleared) into a `summary` table.
      • Server log breadcrumbs at every phase transition so a sweep
        leaves a clear audit trail.

    DEFERRED to E-2.5 (after Matthew validates orchestration):
      • Tower auto-placement. The driver fires onMapEntered(mapId) on
        each map switch; that hook is currently a no-op. Without it,
        the run dies on wave 1 of map 1 with no towers. Once the
        TowerPlacement.lua placeTowerForPlayer helper is exposed via
        ctx, this module can place a Core tower at a fixed cell per
        map. Aux placements layer on after.
      • The "+20% bonus" stress phase (map3plus). Driver state machine
        already has the `map3plus` enum entry; toggling
        Workspace.RunDifficultyMult = 1.2 + re-firing SwitchMap to
        map 3 is the implementation. Wired in E-2.5.
      • Real upgrade pick selection. Currently AutoPicker is in
        "random" mode — it picks any of N options uniformly. Phase
        E-3 (CORE AUTO) layers fixed-index mode for controlled tests.

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
    sweepStartedAt  : number,
}

local _state: SweepState? = nil

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

    StoryAutoDriver.start({
        coreId         = coreId,
        autoPickerMode = "random",
        -- onMapEntered: no-op for E-2. E-2.5 will place Core tower
        -- at a fixed cell per map here. Without placement, the
        -- driver's sweep dies on wave 1 with the heart at 0 HP,
        -- which routes through onFailed → recordCoreResult →
        -- startNextCore. The orchestration breadcrumbs (server log)
        -- will show the failure path firing for each Core in turn.
        onMapEntered   = nil,
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
-- onComplete : optional callback invoked with the aggregated summary
--              after all 3 Cores finish (success or failure each).
function StorySuperAuto.start(player: Player, onComplete: ((any) -> ())?)
    if _state ~= nil then
        warn("[StorySuperAuto] start() called while a sweep is already active — ignoring")
        return false
    end
    if not player or not player.Parent then
        warn("[StorySuperAuto] start() called with no valid player — ignoring")
        return false
    end

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
        onComplete     = onComplete,
        sweepStartedAt = os.clock(),
    }
    print(("[StorySuperAuto] start sweep — %d cores queued (%s)"):format(
        #queue, table.concat(queue, ", ")))

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
