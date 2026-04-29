--!strict
--[[
    CoreTypes.lua — Single source of truth for the 3 Core archetypes
    and their roles. Eliminates the `towerType == "Power"` hardcoded
    string-comparison anti-pattern that quietly skipped ControlCore
    and SupportCore in 4+ places (admin-panel tower-detail view,
    Infinite per-cycle damage upgrade, simulator role lookup,
    legacy hotbar visibility, hotbar tooltip lookup).

    WHY THIS MODULE EXISTS:
    Before this module, the canonical pattern for "is this a Core?"
    was inlined as:
        if id == "Power" or id == "ControlCore" or id == "SupportCore"
    in 5+ files, and the inverse (`if towerType == "Power" then ...`)
    silently treated the other two Cores as if they were Power. Build
    ea found one such bug (Infinite per-cycle damage upgrade was
    classifying ControlCore + SupportCore as Aux for the fx-fork);
    this module prevents the next one.

    USAGE:
        local CoreTypes = require(ReplicatedStorage.Shared.CoreTypes)
        if CoreTypes.isCore(towerType) then ... end
        local role = CoreTypes.roleFor(towerType)  -- "DPS"|"Control"|"Support"|nil
        for _, id in ipairs(CoreTypes.Ids) do ... end

    NAMING CONVENTION:
      - Ids: array of canonical Core ids in display order (Power
        first since Power is the legacy default).
      - Set: hash-table for O(1) `if Set[id] then ...` checks.
      - Role: "DPS" / "Control" / "Support" — matches the 3-axis
        tower role split documented in memory project_tower_categories.md.

    Any new Core archetype is a one-row append below.
]]

local CoreTypes = {}

CoreTypes.Ids = table.freeze({ "Power", "ControlCore", "SupportCore" })

CoreTypes.Set = table.freeze({
    Power       = true,
    ControlCore = true,
    SupportCore = true,
})

-- Role of each Core. Mirrors the 3-axis split used by TempTowers'
-- aux towers (see TempTowers.RoleByTowerId): DPS = direct damage,
-- Control = movement/environment debuff, Support = damage amplifier.
CoreTypes.Role = table.freeze({
    Power       = "DPS",
    ControlCore = "Control",
    SupportCore = "Support",
})

-- O(1) "is this id one of our Cores?" check. nil-safe.
function CoreTypes.isCore(id: any?): boolean
    return id ~= nil and CoreTypes.Set[id] == true
end

-- "What role is this Core's archetype?" Returns nil for non-Core
-- ids so callers can distinguish "not a Core" from "Core with
-- unknown role" if they care; most just `or "DPS"`.
function CoreTypes.roleFor(id: any?): string?
    if id == nil then return nil end
    return CoreTypes.Role[id]
end

table.freeze(CoreTypes)
return CoreTypes
