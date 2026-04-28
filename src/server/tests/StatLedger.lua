--[[
    StatLedger.lua tests — verify the per-run stat ledger accumulates
    damage / stun / slow / knockback per tower correctly, supports a
    snapshot API, and resets cleanly between runs.
]]

local Tests = require(script.Parent)
local StatLedger = require(script.Parent.Parent:WaitForChild("systems"):WaitForChild("StatLedger"))

------------------------------------------------------------
-- Mock tower (same approach as the Targeting tests — table-based
-- with a self-referential Parent and a stub GetAttribute).
------------------------------------------------------------

local function makeMockTower(name, towerType)
    local attrs = { TowerType = towerType or name }
    local tower
    tower = {
        Name = name,
        GetAttribute = function(_self, k) return attrs[k] end,
        GetFullName = function(_self) return "Workspace." .. name end,
    }
    tower.Parent = tower
    return tower
end

------------------------------------------------------------
-- Tests. Recording is gated off by default (Matthew 2026-04-27:
-- "do not record any stats for now"); the tests flip it on before
-- exercising the API, then leave it as they found it.
------------------------------------------------------------

local function withRecording(fn)
    return function()
        local prior = StatLedger.isRecordingEnabled()
        StatLedger.setRecordingEnabled(true)
        local ok, err = pcall(fn)
        StatLedger.setRecordingEnabled(prior)
        if not ok then error(err, 0) end
    end
end

Tests.test("StatLedger.setRecordingEnabled — toggle round-trips", function()
    local prior = StatLedger.isRecordingEnabled()
    StatLedger.setRecordingEnabled(false)
    Tests.assertFalse(StatLedger.isRecordingEnabled(), "after false")
    StatLedger.setRecordingEnabled(true)
    Tests.assertTrue(StatLedger.isRecordingEnabled(), "after true")
    StatLedger.setRecordingEnabled(prior)
end)

Tests.test("StatLedger.recordDamage — drops calls when recording disabled", function()
    local prior = StatLedger.isRecordingEnabled()
    StatLedger.setRecordingEnabled(false)
    StatLedger.reset()
    local t = makeMockTower("X", "Power")
    StatLedger.recordDamage(t, 100, "direct")
    local snap = StatLedger.snapshot()
    local empty = true
    for _ in pairs(snap.towers) do empty = false end
    Tests.assertTrue(empty, "no entries when disabled")
    StatLedger.setRecordingEnabled(prior)
end)

Tests.test("StatLedger.recordDamage — accumulates per-tower per-type", withRecording(function()
    StatLedger.reset()
    local t = makeMockTower("PowerTower", "Power")
    StatLedger.recordDamage(t, 50, "direct")
    StatLedger.recordDamage(t, 20, "splash")
    StatLedger.recordDamage(t, 30, "chain")
    StatLedger.recordDamage(t, 10, "dot")
    local snap = StatLedger.snapshot()
    -- Find the entry — keyed by GetFullName.
    local entry = nil
    for _, e in pairs(snap.towers) do entry = e; break end
    Tests.assertNotNil(entry, "tower entry should exist")
    Tests.assertEq(entry.damage.direct, 50, "direct damage")
    Tests.assertEq(entry.damage.splash, 20, "splash damage")
    Tests.assertEq(entry.damage.chain, 30, "chain damage")
    Tests.assertEq(entry.damage.dot, 10, "dot damage")
    Tests.assertEq(entry.damage.total, 110, "total damage")
    Tests.assertEq(entry.hits, 4, "hit count")
end))

Tests.test("StatLedger.recordDamage — buckets damage by mob.MobType", withRecording(function()
    StatLedger.reset()
    local t = makeMockTower("Mortar", "MushroomMortar")
    -- Mock mobs with MobType attribute.
    local function mockMob(mobType)
        local m = Instance.new("Part")
        m:SetAttribute("MobType", mobType)
        return m
    end
    StatLedger.recordDamage(t, 100, "direct", mockMob("basic"))
    StatLedger.recordDamage(t, 50,  "direct", mockMob("basic"))
    StatLedger.recordDamage(t, 200, "direct", mockMob("tank"))
    StatLedger.recordDamage(t, 30,  "splash", mockMob("fast"))
    -- Damage WITHOUT mob param should still record total but skip
    -- mob-type bucket (no nil-key explosion).
    StatLedger.recordDamage(t, 25, "direct")
    local snap = StatLedger.snapshot()
    local entry
    for _, e in pairs(snap.towers) do entry = e; break end
    Tests.assertNotNil(entry, "tower entry exists")
    Tests.assertEq(entry.damageByMobType.basic, 150, "basic damage bucket")
    Tests.assertEq(entry.damageByMobType.tank,  200, "tank damage bucket")
    Tests.assertEq(entry.damageByMobType.fast,  30,  "fast damage bucket")
    Tests.assertEq(entry.damage.total, 405, "total includes no-mob hits")
end))

Tests.test("StatLedger.recordDamage — unknown hitType counts as direct", withRecording(function()
    StatLedger.reset()
    local t = makeMockTower("Tower", "Power")
    StatLedger.recordDamage(t, 100, "garbage_kind")
    local snap = StatLedger.snapshot()
    local entry
    for _, e in pairs(snap.towers) do entry = e end
    Tests.assertEq(entry.damage.direct, 100, "fallback to direct")
end))

Tests.test("StatLedger.recordDamage — ignores nil tower or non-positive amount", withRecording(function()
    StatLedger.reset()
    StatLedger.recordDamage(nil, 50, "direct")
    StatLedger.recordDamage(makeMockTower("X"), 0, "direct")
    StatLedger.recordDamage(makeMockTower("X"), -5, "direct")
    local snap = StatLedger.snapshot()
    local empty = true
    for _ in pairs(snap.towers) do empty = false end
    Tests.assertTrue(empty, "no entries should have been created")
end))

Tests.test("StatLedger.recordSlow — slow-value = (1-mult) * duration", withRecording(function()
    StatLedger.reset()
    local t = makeMockTower("Slower", "Slower")
    StatLedger.recordSlow(t, 0.5, 2)   -- 50% slow × 2s = 1.0
    StatLedger.recordSlow(t, 0.75, 4)  -- 25% slow × 4s = 1.0
    local snap = StatLedger.snapshot()
    local entry
    for _, e in pairs(snap.towers) do entry = e end
    Tests.assertNear(entry.slowValue, 2.0, 0.001, "1.0 + 1.0")
end))

Tests.test("StatLedger.recordPlacement — counts (type, rarity) pairs", withRecording(function()
    StatLedger.reset()
    StatLedger.recordPlacement("Power", "Common")
    StatLedger.recordPlacement("Power", "Common")
    StatLedger.recordPlacement("ThornVine", "Rare")
    local snap = StatLedger.snapshot()
    Tests.assertEq(snap.loadout["Power[Common]"], 2)
    Tests.assertEq(snap.loadout["ThornVine[Rare]"], 1)
end))

Tests.test("StatLedger.reset — clears all state", withRecording(function()
    StatLedger.reset()
    StatLedger.recordDamage(makeMockTower("X", "Power"), 100, "direct")
    StatLedger.recordPlacement("Power", "Rare")
    StatLedger.reset()
    local snap = StatLedger.snapshot()
    local empty = true
    for _ in pairs(snap.towers) do empty = false end
    Tests.assertTrue(empty, "towers should be empty after reset")
    local emptyLoad = true
    for _ in pairs(snap.loadout) do emptyLoad = false end
    Tests.assertTrue(emptyLoad, "loadout should be empty after reset")
end))

return nil
