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

Tests.test("buildSelectAutoQueue with 3 locked + default slot rotates 1 aux", function()
    -- 2026-04-29 ea3-9: 3-locked is no longer rejected. With the
    -- default slider (= K+1 = 4), this rotates a single aux through
    -- the (n-3) remaining auxes → (n-3) entries.
    local n = countTestPool()
    local q = Infinite.buildSelectAutoQueue("Power",
        { "PepperCannon", "FrostMelon", "ThornVine" })
    Tests.assertEq(#q, n - 3,
        string.format("expected %d quads (default slider=4 rotates 1), got %d", n - 3, #q))
    for _, e in ipairs(q) do
        Tests.assertEq(#e.auxIds, 4, "quad size = 4")
        Tests.assertTrue(containsId(e.auxIds, "PepperCannon"))
        Tests.assertTrue(containsId(e.auxIds, "FrostMelon"))
        Tests.assertTrue(containsId(e.auxIds, "ThornVine"))
    end
end)

Tests.test("buildSelectAutoQueue with K > slider returns empty (defensive)", function()
    -- 2026-04-29 ea3-9: locked count exceeding slot count is the
    -- only rejection condition now. Client should never produce
    -- this (FIFO eviction at the picker), but the helper rejects
    -- defensively. ea3-26: warn moved out of the helper to the
    -- remote handler (where the security boundary lives), so the
    -- helper is silent on invalid input — tests can probe freely.
    local q = Infinite.buildSelectAutoQueue("Power",
        { "PepperCannon", "FrostMelon", "ThornVine" }, 2)
    Tests.assertEq(#q, 0, "K=3 > slider=2 rejected")
end)

Tests.test("buildSelectAutoQueue with K == slider produces single entry (locked-only)", function()
    -- Every slot locked → one queue entry that runs the locked
    -- loadout once. Useful for "run THIS exact loadout."
    local q = Infinite.buildSelectAutoQueue("Power",
        { "PepperCannon", "FrostMelon" }, 2)
    Tests.assertEq(#q, 1, "K==N → single entry")
    Tests.assertEq(#q[1].auxIds, 2, "entry size = K")
    Tests.assertTrue(containsId(q[1].auxIds, "PepperCannon"))
    Tests.assertTrue(containsId(q[1].auxIds, "FrostMelon"))
end)

Tests.test("buildSelectAutoQueue 1 locked + slider 3 = C(n-1, 2) duos", function()
    -- K=1, N=3 → rotate 2 auxes → C(n-1, 2) combinations.
    local n = countTestPool()
    local q = Infinite.buildSelectAutoQueue("Power", { "PepperCannon" }, 3)
    -- C(n-1, 2) = (n-1)(n-2)/2
    local expected = ((n - 1) * (n - 2)) / 2
    Tests.assertEq(#q, expected,
        string.format("expected C(%d,2)=%d trios, got %d", n - 1, expected, #q))
    for _, e in ipairs(q) do
        Tests.assertEq(#e.auxIds, 3, "trio size = 3")
        Tests.assertTrue(containsId(e.auxIds, "PepperCannon"),
            "locked PepperCannon missing")
    end
end)

Tests.test("buildSelectAutoQueue 4 locked + slot 5 = (n-4) entries", function()
    -- K=4, N=5 → rotate 1 aux through (n-4) remaining → (n-4) entries.
    -- Per Matthew 2026-04-29: "add a 5 difficulty, lets you select
    -- four towers, run those 4 + every aux combo."
    local n = countTestPool()
    local q = Infinite.buildSelectAutoQueue("Power",
        { "PepperCannon", "FrostMelon", "ThornVine", "AcornSniper" }, 5)
    Tests.assertEq(#q, n - 4,
        string.format("expected %d entries, got %d", n - 4, #q))
    for _, e in ipairs(q) do
        Tests.assertEq(#e.auxIds, 5, "entry size = 5")
    end
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

------------------------------------------------------------
-- buildTowerSuperQueue — TOWER SUPER zoom-in sweep, filters
-- buildFullAutoQueue to combos containing one focus aux.
-- Per Matthew 2026-04-29 (ea3-24).
------------------------------------------------------------

Tests.test("buildTowerSuperQueue filters to combos containing focus aux", function()
    local q = Infinite.buildTowerSuperQueue("Power", "BlinkBerry")
    Tests.assertTrue(#q > 0, "queue should have at least one combo")
    for _, e in ipairs(q) do
        Tests.assertTrue(containsId(e.auxIds, "BlinkBerry"),
            "every queue entry should include focus aux: " .. tostring(e.label))
    end
end)

Tests.test("buildTowerSuperQueue rejects nil / unknown focus aux", function()
    -- ea3-26: warn moved out of helper, helper is silent on invalid
    -- input. The remote handler does the warn for player-facing paths.
    Tests.assertEq(#Infinite.buildTowerSuperQueue("Power", nil), 0,
        "nil focusAuxId → empty queue")
    Tests.assertEq(#Infinite.buildTowerSuperQueue("Power", "NotARealTower"), 0,
        "unknown focusAuxId → empty queue")
end)

Tests.test("buildTowerSuperQueue rejects InfiniteStandard anchor as focus", function()
    -- The standardization anchor isn't a player-facing tower; it
    -- shouldn't be selectable as a focus aux.
    Tests.assertEq(#Infinite.buildTowerSuperQueue("Power", "InfiniteStandard"), 0,
        "anchor as focus should be rejected")
end)

------------------------------------------------------------
-- buildTopCombosQueue — used by the continuous-loop's sweep #2+
-- to focus on highest-finalWave loadouts in descending order.
------------------------------------------------------------

Tests.test("buildTopCombosQueue empty results returns empty queue", function()
    Tests.assertEq(#Infinite.buildTopCombosQueue("Power", {}, 10), 0,
        "empty results → empty queue")
    Tests.assertEq(#Infinite.buildTopCombosQueue("Power", nil, 10), 0,
        "nil results → empty queue")
end)

Tests.test("buildTopCombosQueue sorts loadouts by avgWave descending", function()
    local results = {
        { auxIds = { "PepperCannon" },         finalWave = 14.0 },
        { auxIds = { "MushroomMortar" },       finalWave = 17.0 },
        { auxIds = { "AcornSniper" },          finalWave = 11.0 },
        { auxIds = { "ThornVine" },            finalWave = 12.0 },
    }
    local q = Infinite.buildTopCombosQueue("Power", results, 10)
    Tests.assertEq(#q, 4, "4 unique loadouts → 4 entries")
    -- First entry should be the highest-finalWave loadout.
    Tests.assertEq(q[1].auxIds[1], "MushroomMortar",
        "highest avgWave first")
    Tests.assertEq(q[#q].auxIds[1], "AcornSniper",
        "lowest avgWave last")
end)

Tests.test("buildTopCombosQueue dedupes by aux signature + averages", function()
    -- Two runs with same aux set get aggregated.
    local results = {
        { auxIds = { "PepperCannon", "FrostMelon" }, finalWave = 12.0 },
        { auxIds = { "FrostMelon", "PepperCannon" }, finalWave = 14.0 },
        -- Same set, sorted differently.
        { auxIds = { "MushroomMortar" },             finalWave = 16.0 },
    }
    local q = Infinite.buildTopCombosQueue("Power", results, 10)
    -- Should be 2 unique loadouts (the duo merged + Mortar solo).
    Tests.assertEq(#q, 2, "merged duplicates by signature")
    -- Mortar (avg 16) ranks above merged duo (avg 13).
    Tests.assertEq(q[1].auxIds[1], "MushroomMortar")
end)

Tests.test("buildTopCombosQueue caps at topN", function()
    local results = {}
    for i = 1, 50 do
        table.insert(results, {
            auxIds = { "Tower" .. i },
            finalWave = i * 0.5,  -- monotonic so each is its own loadout
        })
    end
    local q = Infinite.buildTopCombosQueue("Power", results, 10)
    Tests.assertEq(#q, 10, "topN caps queue size")
end)

Tests.test("buildTopCombosQueue label uses provided coreId", function()
    local results = {
        { auxIds = { "PepperCannon" }, finalWave = 14.0 },
    }
    local q = Infinite.buildTopCombosQueue("ControlCore", results, 5)
    Tests.assertTrue(string.sub(q[1].label, 1, #"ControlCore") == "ControlCore",
        "label prefixed with coreId: " .. tostring(q[1].label))
end)

Tests.test("buildTopCombosQueue skips empty-aux entries", function()
    -- Power-Core-only runs (auxIds = {}) don't represent unique
    -- loadouts to re-test; should be filtered out.
    local results = {
        { auxIds = {},                  finalWave = 18.0 },  -- skip
        { auxIds = { "PepperCannon" },  finalWave = 12.0 },
    }
    local q = Infinite.buildTopCombosQueue("Power", results, 10)
    Tests.assertEq(#q, 1, "empty-aux filtered")
    Tests.assertEq(q[1].auxIds[1], "PepperCannon")
end)

return nil
