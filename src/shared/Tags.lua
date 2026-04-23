--!strict
--[[
    Tags.lua — Single source of truth for every CollectionService tag.

    WHY THIS MODULE EXISTS:
    We use CollectionService:GetTagged() in many places to iterate over
    mobs, towers, ammo piles, etc. If you typo a tag as "EnemyEndpoint"
    instead of "EnemyEndPoint", GetTagged returns an empty list and the
    bug is silent. Centralizing tag names in a frozen table makes typos
    a parse-time error under `--!strict`.

    USAGE:
        local Tags = require(ReplicatedStorage.Shared.Tags)
        for _, heart in ipairs(CollectionService:GetTagged(Tags.EnemyEndPoint)) do
            ...
        end

        CollectionService:AddTag(tower.TowerBase, Tags.Tower)

    NAMING: Tags are PascalCase, matching their historical string form
    so we don't have to rename anything physical in Workspace.
]]

local Tags = table.freeze({
    -- ── GAMEPLAY ENTITIES ──
    Mob           = "Mob",           -- Any enemy spawned by the wave system
    Tower         = "Tower",         -- Player-placed tower (TowerBase Part)
    FinalBoss     = "FinalBoss",     -- Final-fight boss mob (subset of Mob)
    EnemyEndPoint = "EnemyEndPoint", -- The heart mob targets (has MapId attr)
    EnemySpawn    = "EnemySpawn",    -- The first waypoint of an enemy path
    EnemyWaypoint = "EnemyWaypoint", -- Individual waypoints along a path
    AmmoPile      = "AmmoPile",      -- Pickup-able ammo crate in TD room
    SpiderWeb     = "SpiderWeb",     -- Canopy Weaver web projectile (tappable)

    -- ── WORLD STRUCTURE ──
    -- NOTE: Canopy's physical tag in Workspace is "ToL_Canopy" (legacy prefix
    -- from an earlier project name). Keeping the prefixed string here avoids
    -- having to retag every canopy part in the tree.
    Canopy        = "ToL_Canopy",    -- Hub tree canopy foliage (for animation/lighting)
    TDFloor       = "TDFloor",       -- Main TD room floor (for shadow casting)
})

return Tags
