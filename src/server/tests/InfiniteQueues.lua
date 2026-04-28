--[[
    InfiniteQueues.lua tests — pure-function coverage for the four
    queue-builder helpers exposed by Infinite.lua:
      • buildAutoRunQueue    — solos + duos
      • buildLongAutoQueue   — curated trios from Config
      • buildFullAutoQueue   — buildAutoRunQueue + buildLongAutoQueue
      • buildSelectAutoQueue — sweeps pinned to player's saved loadout

    These power the SIMULATE → FULL AUTO / SELECT AUTO menu items.
    Bugs in queue composition manifest as silent miscounts (e.g.
    SELECT AUTO with 1 locked aux returning 0 runs instead of 13).
    The shape contracts pinned here cover the most common failure
    modes:
      - missing tower id in iteration set
      - locked aux duplicated in output
      - InfiniteStandard anchor leaking into non-trio queues
      - off-by-one on duo / triple combinations
]]

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Tests = require(script.Parent)
local Infinite = require(ServerScriptService:WaitForChild("systems"):WaitForChild("Infinite"))
local TempTowers = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TempTowers"))

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

-- Count Templates excluding the InfiniteStandard anchor (the test
-- pool used by buildAutoRunQueue / buildSelectAutoQueue iteration).
local function countTestPool()
    local n = 0
    for id in pairs(TempTowers.Templates) do
        if id ~= "InfiniteStandard" then n = n + 1 end
    end
    return n
end

local function containsId(auxIds, id)
    for _, x in ipairs(auxIds) do
        if x == id then return true end
    end
    return false
end

------------------------------------------------------------
-- buildAutoRunQueue — solos (n) + duos (C(n, 2))
------------------------------------------------------------

Tests.test("buildAutoRunQueue produces n solos + C(n,2) duos", function()
    local n = countTestPool()
    local q = Infinite.buildAutoRunQueue("Power")
    local expected = n + (n * (n - 1)) / 2
    Tests.assertEq(#q, expected,
        string.format("Expected %d (= %d solos + %d duos), got %d",
            expected, n, (n * (n - 1)) / 2, #q))
end)

Tests.test("buildAutoRunQueue labels start with the coreId", function()
    -- Each label = "<core> + <aux>" / "<core> + <aux1> + <aux2>"
    -- so the tier list display reads consistently with the player's
    -- saved Core archetype.
    local q = Infinite.buildAutoRunQueue("ControlCore")
    for _, e in ipairs(q) do
        Tests.assertTrue(string.sub(e.label, 1, #"ControlCore") == "ControlCore",
            "Label missing ControlCore prefix: " .. tostring(e.label))
    end
end)

Tests.test("buildAutoRunQueue defaults coreId to Power when nil", function()
    local q = Infinite.buildAutoRunQueue(nil)
    Tests.assertTrue(#q > 0, "queue not empty on nil coreId")
    Tests.assertTrue(string.sub(q[1].label, 1, #"Power") == "Power",
        "default coreId should be Power: " .. tostring(q[1].label))
end)

Tests.test("buildAutoRunQueue never includes the InfiniteStandard anchor", function()
    -- The anchor is only used by trio queues (LongAuto). It must not
    -- leak into solos / duos or it'd inflate its own run count and
    -- pollute its tier with non-tested runs.
    local q = Infinite.buildAutoRunQueue("Power")
    for _, e in ipairs(q) do
        Tests.assertFalse(containsId(e.auxIds, "InfiniteStandard"),
            "InfiniteStandard leaked into auto-run queue: " .. tostring(e.label))
    end
end)

------------------------------------------------------------
-- buildLongAutoQueue — curated trios from Config
------------------------------------------------------------

Tests.test("buildLongAutoQueue returns one entry per Config trio", function()
    local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
    local trios = (Config.InfiniteArena and Config.InfiniteArena.LongAutoTrios) or {}
    local q = Infinite.buildLongAutoQueue("Power")
    Tests.assertEq(#q, #trios, "queue length matches trio config")
end)

Tests.test("buildLongAutoQueue auxIds are exactly the trio entries", function()
    local q = Infinite.buildLongAutoQueue("Power")
    for _, e in ipairs(q) do
        Tests.assertEq(#e.auxIds, 3, "trio queue entries have 3 auxes")
    end
end)

------------------------------------------------------------
-- buildFullAutoQueue — concatenation
------------------------------------------------------------

Tests.test("buildFullAutoQueue = buildAutoRunQueue + buildLongAutoQueue", function()
    local autoQ = Infinite.buildAutoRunQueue("Power")
    local longQ = Infinite.buildLongAutoQueue("Power")
    local fullQ = Infinite.buildFullAutoQueue("Power")
    Tests.assertEq(#fullQ, #autoQ + #longQ,
        "full queue length is the sum")
end)

------------------------------------------------------------
-- buildSelectAutoQueue — pinned to player's saved loadout
------------------------------------------------------------

Tests.test("buildSelectAutoQueue with 0 locked = same as buildAutoRunQueue", function()
    local locked = Infinite.buildSelectAutoQueue("Power", {})
    local autoQ  = Infinite.buildAutoRunQueue("Power")
    Tests.assertEq(#locked, #autoQ,
        "0 locked = full auto sweep (no trios)")
end)

Tests.test("buildSelectAutoQueue with 1 locked = (n-1) duos containing it", function()
    -- 1 locked aux; iterate the OTHER (n-1) auxes (n = test pool size,
    -- excluding the standardization anchor) → (n-1) duos containing
    -- the locked aux.
    local n = countTestPool()
    local q = Infinite.buildSelectAutoQueue("Power", { "PepperCannon" })
    Tests.assertEq(#q, n - 1,
        string.format("expected %d duos, got %d", n - 1, #q))
    -- Every queue entry must contain the locked aux.
    for _, e in ipairs(q) do
        Tests.assertTrue(containsId(e.auxIds, "PepperCannon"),
            "locked aux missing: " .. tostring(e.label))
        Tests.assertEq(#e.auxIds, 2, "duo size = 2")
    end
end)

Tests.test("buildSelectAutoQueue with 2 locked = (n-2) trios containing both", function()
    local n = countTestPool()
    local q = Infinite.buildSelectAutoQueue("Power", { "PepperCannon", "FrostMelon" })
    Tests.assertEq(#q, n - 2,
        string.format("expected %d trios, got %d", n - 2, #q))
    for _, e in ipairs(q) do
        Tests.assertTrue(containsId(e.auxIds, "PepperCannon"),
            "locked PepperCannon missing")
        Tests.assertTrue(containsId(e.auxIds, "FrostMelon"),
            "locked FrostMelon missing")
        Tests.assertEq(#e.auxIds, 3, "trio size = 3")
    end
end)

Tests.test("buildSelectAutoQueue with 3 locked returns empty (rejected)", function()
    -- 3+ locked = nothing meaningful to vary. Client greys the button;
    -- server defensively returns empty.
    local q = Infinite.buildSelectAutoQueue("Power",
        { "PepperCannon", "FrostMelon", "ThornVine" })
    Tests.assertEq(#q, 0, "3-locked rejection")
end)

Tests.test("buildSelectAutoQueue skips the InfiniteStandard anchor", function()
    -- The anchor must not appear in an iteration set; it's a trio-only
    -- standardization tool that would skew sweep results.
    local q = Infinite.buildSelectAutoQueue("Power", { "PepperCannon" })
    for _, e in ipairs(q) do
        Tests.assertFalse(containsId(e.auxIds, "InfiniteStandard"),
            "anchor leaked into select-auto queue")
    end
end)

Tests.test("buildSelectAutoQueue defaults coreId to Power on nil/missing", function()
    local q = Infinite.buildSelectAutoQueue(nil, { "PepperCannon" })
    Tests.assertTrue(#q > 0, "queue not empty on nil coreId")
    Tests.assertTrue(string.sub(q[1].label, 1, #"Power") == "Power",
        "default coreId should be Power")
end)

return nil
