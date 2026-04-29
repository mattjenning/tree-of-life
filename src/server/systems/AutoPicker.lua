--[[
    AutoPicker.lua — Server-side flag + helper for the SUPER AUTO
    story-progression sweep (Phase E). When the sweep is active, the
    4 player-facing pickers (TempTowerRewards / CoreUpgrades /
    UpgradeCards / PermanentTower) check AutoPicker.isActive() and
    bypass the client modal entirely — they auto-resolve a pick on
    the server side instead.

    Three modes:
      "random"         — pick a uniformly random index in [1, N].
                         Default for SUPER AUTO (we want the simulator
                         to mirror what the player would see on average,
                         not optimize).
      "fixed-index"    — pick a fixed index per picker key. Drives
                         CORE AUTO conditions 1-3 ("always pick option
                         N for Core upgrades, random for everything
                         else").
      "fixed-sequence" — walk a per-key SEQUENCE on each call (cursor
                         per pickerKey). Drives CORE AUTO condition 4
                         ("one of each option" — sequence {1, 2, 3}
                         picks #1 for the first map-boss upgrade, #2
                         for the second, #3 for the third). Wraps if
                         called more than #seq times. Per Matthew
                         design dump 2026-04-29 → CORE AUTO section.

    Per Matthew design dump 2026-04-29 (memory:
    project_core_upgrade_picker.md). Phase E ships incrementally —
    this module is E-prep, no callers yet wire to it. Pickers are
    updated in this same commit; SUPER AUTO redesign in E-2 turns
    AutoPicker on at sweep start.

    USAGE:
        local AutoPicker = require(script.Parent.AutoPicker)
        AutoPicker.beginAuto({ mode = "random" })
        -- ... run story-progression sweep; pickers auto-resolve ...
        AutoPicker.endAuto()
]]

local AutoPicker = {}

-- Module-level state. Single-active assumption: only ONE auto sweep
-- per server at a time. Concurrent sweeps would race the picker
-- handlers and produce nonsense; SUPER AUTO is server-wide singleton
-- already, so this is safe.
--
-- ea3-42: choices field now accepts EITHER a number (fixed-index)
-- OR a list of numbers (fixed-sequence). Cursor tracks per-key
-- progress through the sequence; stays at end on subsequent calls
-- via wrap-around in pickIndex.
local _state: {
    mode      : string,
    choices   : { [string]: any }?,  -- number for fixed-index, {number} for fixed-sequence
    cursor    : { [string]: number }?,  -- per-pickerKey position in fixed-sequence list
}? = nil

-- Begin auto-pick mode.
--   opts.mode = "random" | "fixed-index" | "fixed-sequence"
--   opts.choices = {
--     -- fixed-index:    [pickerKey] = number (1-based)
--     -- fixed-sequence: [pickerKey] = { number, number, ... }
--   }
-- Missing keys fall through to random per pickIndex call.
function AutoPicker.beginAuto(opts: { mode: string?, choices: { [string]: any }? }?)
    opts = opts or {}
    _state = {
        mode    = opts.mode or "random",
        choices = opts.choices,
        cursor  = {},  -- fixed-sequence walks this per pickerKey
    }
end

function AutoPicker.endAuto()
    _state = nil
end

function AutoPicker.isActive(): boolean
    return _state ~= nil
end

-- pickIndex(numOptions, pickerKey?) — returns a 1-based index in
-- [1, numOptions]. pickerKey identifies which picker is asking
-- (used by "fixed-index" mode to look up the player's controlled
-- choice). Defaults to random if mode unset, fixed-index has no
-- entry for the key, or numOptions <= 0.
function AutoPicker.pickIndex(numOptions: number, pickerKey: string?): number
    if numOptions <= 0 then return 1 end  -- defensive
    if not _state then
        -- Inactive — shouldn't be called, but defensive: random.
        return math.random(1, numOptions)
    end
    if _state.mode == "fixed-index" and _state.choices and pickerKey then
        local idx = _state.choices[pickerKey]
        if type(idx) == "number" and idx >= 1 and idx <= numOptions then
            return idx
        end
    elseif _state.mode == "fixed-sequence" and _state.choices and pickerKey then
        local seq = _state.choices[pickerKey]
        if type(seq) == "table" and #seq > 0 then
            -- Advance the per-key cursor; wrap when exhausted so a
            -- caller that fires more times than #seq still gets a
            -- valid index instead of a nil-index crash. Cursor lives
            -- on _state, so a stop()/start() cycle resets it.
            local cur = _state.cursor or {}
            local next_i = (cur[pickerKey] or 0) + 1
            if next_i > #seq then next_i = 1 end
            cur[pickerKey] = next_i
            _state.cursor = cur
            local idx = seq[next_i]
            if type(idx) == "number" and idx >= 1 and idx <= numOptions then
                return idx
            end
        end
    end
    return math.random(1, numOptions)
end

-- Read-only snapshot for diagnostic logs.
function AutoPicker.describe(): string
    if not _state then return "(inactive)" end
    if _state.mode == "fixed-index" then
        local parts = {}
        for k, v in pairs(_state.choices or {}) do
            table.insert(parts, k .. "=" .. tostring(v))
        end
        table.sort(parts)
        return ("fixed-index[%s]"):format(table.concat(parts, ", "))
    elseif _state.mode == "fixed-sequence" then
        local parts = {}
        for k, v in pairs(_state.choices or {}) do
            if type(v) == "table" then
                local nums = {}
                for _, n in ipairs(v) do table.insert(nums, tostring(n)) end
                table.insert(parts, k .. "=" .. table.concat(nums, "→"))
            end
        end
        table.sort(parts)
        return ("fixed-sequence[%s]"):format(table.concat(parts, ", "))
    end
    return _state.mode
end

return AutoPicker
