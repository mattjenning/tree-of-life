--[[
    AutoPicker.lua — Server-side flag + helper for the SUPER AUTO
    story-progression sweep (Phase E). When the sweep is active, the
    4 player-facing pickers (TempTowerRewards / CoreUpgrades /
    UpgradeCards / PermanentTower) check AutoPicker.isActive() and
    bypass the client modal entirely — they auto-resolve a pick on
    the server side instead.

    Two modes:
      "random"      — pick a uniformly random index in [1, N].
                      Default for SUPER AUTO (we want the simulator
                      to mirror what the player would see on average,
                      not optimize).
      "fixed-index" — pick a fixed index per picker key. Drives
                      CORE AUTO ("always pick option 1 for Core
                      upgrades, random for everything else") so the
                      analyst can compare like-for-like across
                      different upgrade-path conditions.

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
local _state: {
    mode      : string,
    choices   : { [string]: number }?,  -- only used in "fixed-index" mode
}? = nil

-- Begin auto-pick mode. opts.mode = "random" | "fixed-index".
-- For "fixed-index", opts.choices is a table mapping picker key
-- (e.g. "coreUpgrade", "tempTower") to a 1-based index. Missing
-- keys fall through to random.
function AutoPicker.beginAuto(opts: { mode: string?, choices: { [string]: number }? }?)
    opts = opts or {}
    _state = {
        mode    = opts.mode or "random",
        choices = opts.choices,
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
    end
    return _state.mode
end

return AutoPicker
