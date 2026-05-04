--[[
    CoreAutoRunner.lua — Phase E-3 (2026-04-29 ea3-42).

    Tests how each Core upgrade option affects survival, with all other
    variables held constant. Per memory project_core_upgrade_picker.md
    → "CORE AUTO" section.

    Per Core, 4 conditions:
      #1 → always pick option 1 of the Core's 3 upgrades
      #2 → always pick option 2
      #3 → always pick option 3
      #4 → pick one of each option (1, 2, 3 across the 3 map bosses)

    Across 3 Cores = 12 conditions × N reps each. Output: per-condition
    average final phase + death position + DPS share so the analyst
    can see which upgrade option compounds best for a given Core.

    USES:
      • AutoPicker fixed-index mode (conditions 1-3) and fixed-sequence
        mode (condition 4 — sequence {1, 2, 3}) — both shipped in
        ea3-42 alongside this module.
      • StoryAutoDriver for the per-condition story playthrough.
      • StorySuperAuto's tower placement helpers (passed through
        opts.placeTower / opts.findOpenCell from the Infinite handler).

    NOT YET WIRED in this commit:
      • Aux loadout determinism. Auxes come from the post-boss temp-
        tower picker, which auto-resolves at random index even though
        the player's saved loadout biases the rolls. So aux roster
        varies between conditions, smearing the upgrade signal. v2
        could lock auxes via fixed-index temp-tower picks.
      • Condition repetition (N reps per condition). v1 ships N=1
        for fast iteration; bumping to 3+ when the analyst wants
        noise-tolerant signal.
]]

local CoreTypes = require(game:GetService("ReplicatedStorage")
    :WaitForChild("Shared")
    :WaitForChild("CoreTypes"))
local CoreUpgrades = require(game:GetService("ReplicatedStorage")
    :WaitForChild("Shared")
    :WaitForChild("CoreUpgrades"))
local StoryAutoDriver = require(script.Parent:WaitForChild("StoryAutoDriver"))

local CoreAutoRunner = {}

-- ===========================================================================
-- Condition definitions — drives the inner loop.
-- ===========================================================================

-- A condition pairs a coreId with an AutoPicker config that determines
-- which Core upgrade option gets picked at each map boss.
type Condition = {
    label   : string,                          -- "Power+option1", "ControlCore+mix", etc.
    coreId  : string,
    pickerMode    : string,                    -- "fixed-index" | "fixed-sequence"
    pickerChoices : { [string]: any },         -- { coreUpgrade = N } or { coreUpgrade = {N1,N2,N3} }
}

-- Build the 12-condition list from CoreTypes.Ids and the per-Core
-- option count (always 3 — guarded by CoreUpgrades.Options shape +
-- the test in tests/CoreUpgrades.lua).
local function buildConditions(): { Condition }
    local conds = {}
    for _, coreId in ipairs(CoreTypes.Ids) do
        for n = 1, 3 do
            table.insert(conds, {
                label   = ("%s+#%d"):format(coreId, n),
                coreId  = coreId,
                pickerMode    = "fixed-index",
                pickerChoices = { coreUpgrade = n },
            })
        end
        -- "Mix" condition — one of each option across the 3 map bosses.
        table.insert(conds, {
            label   = ("%s+mix"):format(coreId),
            coreId  = coreId,
            pickerMode    = "fixed-sequence",
            pickerChoices = { coreUpgrade = { 1, 2, 3 } },
        })
    end
    return conds
end

-- ===========================================================================
-- Module state.
-- ===========================================================================

type ConditionResult = {
    label          : string,
    coreId         : string,
    upgradeOptionLabel : string,  -- friendlier name like "PowerBaseDamage"
    finalPhase     : string,
    failureReason  : string?,
    deathPosition  : any?,
    statSnapshot   : any,
    elapsedSeconds : number,
}

type RunnerState = {
    player          : Player,
    queue           : { Condition },
    activeIdx       : number,
    totalConditions : number,
    perCondition    : { ConditionResult },
    onComplete      : ((summary: any) -> ())?,
    placeTower      : any?,
    findOpenCell    : any?,
    sweepStartedAt  : number,
}

local _state: RunnerState? = nil

-- ===========================================================================
-- Public introspection.
-- ===========================================================================

function CoreAutoRunner.isActive(): boolean
    return _state ~= nil
end

function CoreAutoRunner.describe(): string
    if not _state then return "(idle)" end
    return ("CoreAuto: %d/%d (%s)"):format(
        _state.activeIdx,
        _state.totalConditions,
        (_state.queue[1] and _state.queue[1].label) or "?")
end

-- ===========================================================================
-- Internal: condition execution loop.
-- ===========================================================================

local startNextCondition  -- forward decl

-- Resolve a friendly name for the picked upgrade option. Helps the
-- summary read "Power+#1 (PowerBaseDamage)" instead of just "Power+#1".
local function describeOptionLabel(coreId: string, pickerMode: string, choices: any): string
    local options = CoreUpgrades.optionsFor(coreId)
    if not options then return "(no options)" end
    if pickerMode == "fixed-index" then
        local idx = choices and choices.coreUpgrade
        if type(idx) == "number" and options[idx] then
            return options[idx].id
        end
    elseif pickerMode == "fixed-sequence" then
        return "mix"
    end
    return "?"
end

local function recordResult(cond: Condition, summary: any, failureReason: string?)
    if not _state then return end
    table.insert(_state.perCondition, {
        label          = cond.label,
        coreId         = cond.coreId,
        upgradeOptionLabel = describeOptionLabel(cond.coreId, cond.pickerMode, cond.pickerChoices),
        finalPhase     = summary.finalPhase or "unknown",
        failureReason  = failureReason or summary.failureReason,
        deathPosition  = summary.deathPosition,
        statSnapshot   = summary.statSnapshot,
        elapsedSeconds = summary.elapsedSeconds or 0,
    })
    print(("[CoreAutoRunner] %s done → %s (%.1fs)"):format(
        cond.label, tostring(summary.finalPhase), summary.elapsedSeconds or 0))
end

local function formatDeathPos(pos: any): string
    if type(pos) ~= "table" then return "?" end
    return ("m%d s%d w%d"):format(pos.mapId or 0, pos.stage or 0, pos.wave or 0)
end

local function finishSweep()
    if not _state then return end
    local elapsed = os.clock() - _state.sweepStartedAt
    print(("[CoreAutoRunner] CORE AUTO complete in %.1fs — %d conditions"):format(
        elapsed, #_state.perCondition))
    print("[CoreAutoRunner] -------- E-3 CORE AUTO summary --------")
    for _, r in ipairs(_state.perCondition) do
        print(("  %-22s (%s) phase=%s, died=%s, %.1fs"):format(
            r.label, r.upgradeOptionLabel, r.finalPhase,
            formatDeathPos(r.deathPosition), r.elapsedSeconds))
    end
    print("[CoreAutoRunner] -------- end E-3 summary --------")
    local summary = {
        perCondition   = _state.perCondition,
        elapsedSeconds = elapsed,
    }
    local cb = _state.onComplete
    _state = nil
    if cb then cb(summary) end
end

startNextCondition = function()
    if not _state then return end
    if #_state.queue == 0 then
        finishSweep()
        return
    end

    local cond = table.remove(_state.queue, 1)
    _state.activeIdx = _state.totalConditions - #_state.queue
    print(("[CoreAutoRunner] starting condition %d/%d: %s"):format(
        _state.activeIdx, _state.totalConditions, cond.label))

    -- Capture into closure upvalues for the onMapEntered hook + the
    -- driver callbacks (state may be torn down between transitions).
    local activePlayer  = _state.player
    local activeCoreId  = cond.coreId
    local placeTower    = _state.placeTower
    local findOpenCell  = _state.findOpenCell

    -- Reuse StorySuperAuto's onMapEntered placement logic by importing
    -- the helpers it builds. We can't directly call StorySuperAuto.start
    -- because that's the 3-Core sweep; we want one Core, controlled
    -- picks. So re-implement the onMapEntered closure in-line here,
    -- mirroring StorySuperAuto's placeCoreOnMap + placeOwnedAuxesOnMap.
    -- (Future cleanup: extract those helpers into a shared module.)
    local StorySuperAuto = require(script.Parent:WaitForChild("StorySuperAuto"))
    local _ = StorySuperAuto  -- intentionally unused; reserved for future helper-extraction

    StoryAutoDriver.start({
        coreId             = activeCoreId,
        autoPickerMode     = cond.pickerMode,
        autoPickerChoices  = cond.pickerChoices,
        onMapEntered       = function(mapId)
            if not placeTower or not findOpenCell then return end
            task.delay(0.5, function()
                if not _state or _state.player ~= activePlayer then return end
                -- Inline Core placement: same pattern as StorySuperAuto.placeCoreOnMap.
                local cur = activePlayer:GetAttribute(activeCoreId .. "Stock") or 0
                if cur <= 0 then
                    activePlayer:SetAttribute(activeCoreId .. "Stock", 1)
                end
                local col, row = findOpenCell(mapId, 4, 4)
                if col and row then
                    placeTower(activePlayer, activeCoreId, col, row)
                end
                -- Inline aux placement: same pattern as
                -- StorySuperAuto.placeOwnedAuxesOnMap. Iterate
                -- TempTowers.Templates, place any aux with stock > 0.
                local TempTowers = require(game:GetService("ReplicatedStorage")
                    :WaitForChild("Shared")
                    :WaitForChild("TempTowers"))
                for towerId, tpl in pairs(TempTowers.Templates) do
                    local stock = activePlayer:GetAttribute(towerId .. "Stock") or 0
                    if stock > 0 then
                        local fw = tpl.footprintWidth or 4
                        local fd = tpl.footprintDepth or 4
                        local c2, r2 = findOpenCell(mapId, fw, fd)
                        if c2 and r2 then
                            placeTower(activePlayer, towerId, c2, r2)
                        end
                    end
                end
            end)
        end,
        onComplete         = function(summary)
            recordResult(cond, summary, nil)
            task.defer(startNextCondition)
        end,
        onFailed           = function(_diedInPhase, summary)
            recordResult(cond, summary, summary.failureReason)
            task.defer(startNextCondition)
        end,
    })
end

-- ===========================================================================
-- Public: lifecycle.
-- ===========================================================================

-- Begin a CORE AUTO sweep.
--
-- player : Player running the sweep.
-- opts   : {
--   placeTower   : ctx.placeTowerForPlayer
--   findOpenCell : ctx.findOpenCellForMap
--   onComplete   : optional summary callback
-- }
function CoreAutoRunner.start(player: Player, opts: any)
    if _state ~= nil then
        warn("[CoreAutoRunner] start() called while a sweep is already active — ignoring")
        return false
    end
    if not player or not player.Parent then
        warn("[CoreAutoRunner] start() called with no valid player — ignoring")
        return false
    end
    opts = opts or {}

    local conditions = buildConditions()
    _state = {
        player          = player,
        queue           = conditions,
        activeIdx       = 0,
        totalConditions = #conditions,
        perCondition    = {},
        onComplete      = opts.onComplete,
        placeTower      = opts.placeTower,
        findOpenCell    = opts.findOpenCell,
        sweepStartedAt  = os.clock(),
    }
    print(("[CoreAutoRunner] start CORE AUTO — %d conditions queued"):format(#conditions))
    startNextCondition()
    return true
end

function CoreAutoRunner.stop()
    if not _state then return end
    print("[CoreAutoRunner] stop() — aborting sweep")
    StoryAutoDriver.stop()
    _state = nil
end

return CoreAutoRunner
