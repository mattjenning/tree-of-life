--!strict
--[[
    MapRegistry.lua — single source of truth for per-map metadata.

    Replaces the 6+ `if mapId == 1 elseif mapId == 2 elseif mapId == 3`
    chains scattered across server + client code with a registry table
    keyed by mapId. Adding the underground map (roadmap: mapId 4) is now
    a one-row append — no more searching for dispatch sites.

    Fields:
        key                  — short string id used by DevTeleport remote
                               ("map1", "map2", "map3"). Hub uses "hub"
                               and is NOT in this registry.
        displayName          — human-readable label for dev / UI text.
        bossType             — mob type to spawn for the named MAP boss
                               (the standalone post-stage-3 boss). Map 1
                               historically uses "finalboss" (Mold King /
                               Pickle Lord depending on era), map 2 uses
                               "spider", map 3 uses "finalboss" (the
                               Canopy Bird via Map3BirdBoss self-managed).
        playsRewardCutscene  — whether picking the temp-tower reward
                               plays the walk-to-Core cinematic before
                               firing BossRewardClaimed. Map 1 + 2 do;
                               map 3 doesn't (Pickle Lord runs separately).
        splitTargets         — whether upgrade cards split between Core
                               and Aux. Map 1 is Core-only ("warm up
                               your Core tower" phase); map 2+ split.
        placeAllCenter       — {col, row} for the client's dev
                               "placeAllTowers" spiral start. Pure
                               client-side dev tool data.
        difficultySection    — name of the Config sub-section that holds
                               this map's Difficulty table (or nil if
                               the map uses baseline difficulty). Read
                               via Config[difficultySection].Difficulty.

    Usage:
        local MapRegistry = require(ReplicatedStorage.Shared.MapRegistry)
        local entry = MapRegistry.get(mapId)  -- nil for unknown ids
        if entry and entry.splitTargets then ... end

    Adding map 4:
        MapRegistry.maps[4] = {
            key                 = "map4",
            displayName         = "Underground",
            bossType            = "finalboss",
            playsRewardCutscene = true,
            splitTargets        = true,
            placeAllCenter      = { col = X, row = Y },
            difficultySection   = "Map4",
        }
]]

export type MapEntry = {
    key: string,
    displayName: string,
    bossType: string,
    playsRewardCutscene: boolean,
    splitTargets: boolean,
    placeAllCenter: { col: number, row: number },
    difficultySection: string?,
}

local MapRegistry = {}

MapRegistry.maps = {
    [1] = {
        key                 = "map1",
        displayName         = "Crook of the Tree",
        bossType            = "finalboss",
        playsRewardCutscene = true,
        splitTargets        = false,
        placeAllCenter      = { col = 30, row = 22 },
        difficultySection   = nil,  -- baseline (no Map1.Difficulty section)
    },
    [2] = {
        key                 = "map2",
        displayName         = "Climbing the Tree",
        bossType            = "spider",
        playsRewardCutscene = true,
        splitTargets        = true,
        placeAllCenter      = { col = 97, row = 27 },
        difficultySection   = "Map2",
    },
    [3] = {
        key                 = "map3",
        displayName         = "Canopy Nest",
        bossType            = "finalboss",
        playsRewardCutscene = false,
        splitTargets        = true,
        placeAllCenter      = { col = 180, row = 33 },
        difficultySection   = "Map3",
    },
    [4] = {
        -- Pickle Swamp — Infinite Arena (Phase 1 balance sandbox).
        -- Lives outside the main run loop; reached via the hub's
        -- swirling green portal, not via SwitchMap from a prior
        -- map. Tower placement + mob walking + StatLedger all
        -- reuse the standard mapId pipeline; the wave system gets
        -- a custom infinite spawner instead of WAVES[4].
        key                 = "map4",
        displayName         = "Pickle Swamp",
        bossType            = "finalboss",  -- unused; no map boss in infinite mode
        playsRewardCutscene = false,
        splitTargets        = true,
        placeAllCenter      = { col = 270, row = 33 },
        difficultySection   = "Map4",
    },
}

-- Lookup by mapId. Returns nil for unknown ids — callers should
-- defensively handle nil so adding map 4 (or any future map) without
-- updating every consumer doesn't crash; the consumer just falls
-- back to its no-op / default branch.
function MapRegistry.get(mapId: number?): MapEntry?
    if type(mapId) ~= "number" then return nil end
    return MapRegistry.maps[mapId]
end

-- Reverse lookup: given a teleport key ("map1" / "map2" / "map3"),
-- return the mapId. Used by Portal.lua's DevTeleport handler.
function MapRegistry.idFromKey(key: string?): number?
    if type(key) ~= "string" then return nil end
    for id, entry in pairs(MapRegistry.maps) do
        if entry.key == key then return id end
    end
    return nil
end

return MapRegistry
