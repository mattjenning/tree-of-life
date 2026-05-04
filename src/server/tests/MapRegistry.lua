--[[
    MapRegistry.lua tests — pin the per-map metadata table down so adding
    map 4 (roadmap: Underground) without filling in all required fields
    is caught at server-boot, not at the next "playtest broke something"
    debug session.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tests = require(script.Parent)
local MapRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MapRegistry"))

------------------------------------------------------------
-- Required-field check on every entry
------------------------------------------------------------

Tests.test("MapRegistry — all entries have required fields", function()
    for id, entry in pairs(MapRegistry.maps) do
        local prefix = "mapId " .. tostring(id)
        Tests.assertType(entry.key,                 "string", prefix .. ".key")
        Tests.assertType(entry.displayName,         "string", prefix .. ".displayName")
        Tests.assertType(entry.bossType,            "string", prefix .. ".bossType")
        Tests.assertType(entry.playsRewardCutscene, "boolean", prefix .. ".playsRewardCutscene")
        Tests.assertType(entry.splitTargets,        "boolean", prefix .. ".splitTargets")
        Tests.assertType(entry.placeAllCenter,      "table",  prefix .. ".placeAllCenter")
        Tests.assertType(entry.placeAllCenter.col,  "number", prefix .. ".placeAllCenter.col")
        Tests.assertType(entry.placeAllCenter.row,  "number", prefix .. ".placeAllCenter.row")
        -- difficultySection is optional (nil for map 1).
    end
end)

------------------------------------------------------------
-- Lookup APIs
------------------------------------------------------------

Tests.test("MapRegistry.get — returns entry for known id", function()
    local entry = MapRegistry.get(1)
    Tests.assertNotNil(entry, "mapId 1 should exist")
    Tests.assertEq(entry.key, "map1", "map 1 key")
end)

Tests.test("MapRegistry.get — returns nil for unknown id", function()
    Tests.assertNil(MapRegistry.get(99), "mapId 99 should be nil")
    Tests.assertNil(MapRegistry.get(nil), "nil id should be nil")
    Tests.assertNil(MapRegistry.get("not-a-number"), "non-number id should be nil")
end)

Tests.test("MapRegistry.idFromKey — round-trips against .key", function()
    for id, entry in pairs(MapRegistry.maps) do
        Tests.assertEq(MapRegistry.idFromKey(entry.key), id,
            "key→id round trip for " .. entry.key)
    end
end)

Tests.test("MapRegistry.idFromKey — nil for unknown key", function()
    Tests.assertNil(MapRegistry.idFromKey("hub"), "hub is not a registered map")
    Tests.assertNil(MapRegistry.idFromKey(nil), "nil key")
end)

------------------------------------------------------------
-- Sanity: keys + display names are unique across maps
------------------------------------------------------------

Tests.test("MapRegistry — keys are unique", function()
    local seen = {}
    for id, entry in pairs(MapRegistry.maps) do
        Tests.assertNil(seen[entry.key],
            "duplicate key " .. entry.key .. " on mapId " .. tostring(id))
        seen[entry.key] = true
    end
end)

return nil
