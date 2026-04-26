--[[
    Targeting.lua tests — exercises findTarget mode logic by injecting a
    mock ctx with table-based mobs (no real Roblox Instances, no
    CollectionService traffic). One mob mock fits all five modes:

        First / Last        — sort by .progress
        Strongest / Weakest — sort by mob:GetAttribute("Health")
        Center              — sort by neighbor count within 8 studs

    Mock mobs are plain tables with:
      .Position : Vector3
      .Parent   : self (truthy non-nil so the mob is "alive")
      .Name     : string
      :GetAttribute(name) → table-backed lookup

    activeMobs maps the mock to a synthetic data table containing the
    waypointIndex Targeting reads to compute progress; if the mob isn't
    a path-walker we just leave it as 1 and the progress fraction
    derives from waypoint geometry.
]]

local Tests = require(script.Parent)
local Targeting = require(script.Parent.Parent:WaitForChild("systems"):WaitForChild("Targeting"))

------------------------------------------------------------
-- Mock helpers
------------------------------------------------------------

local function makeWaypoint(x, z)
    -- Real BasePart so the .Position lookup matches what live waypoints
    -- expose. Parented to nil so it doesn't pollute the real workspace.
    local p = Instance.new("Part")
    p.Anchored = true
    p.CanCollide = false
    p.Size = Vector3.new(1, 1, 1)
    p.CFrame = CFrame.new(x, 0, z)
    return p
end

local function makeMockMob(name, x, z, hp)
    local attrs = {
        Health = hp or 100,
        MaxHealth = hp or 100,
    }
    local mob
    mob = {
        Name = name,
        Position = Vector3.new(x, 0, z),
        -- Self-referential Parent: any non-nil value is truthy enough
        -- for the `mob.Parent` check inside findTarget. Real Roblox
        -- Instance.Parent would be the model, but findTarget just
        -- nil-tests it.
        Parent = nil,
        GetAttribute = function(_self, key)
            return attrs[key]
        end,
        _attrs = attrs,  -- expose for tests to mutate
    }
    mob.Parent = mob
    return mob
end

local function makeCtx(mobs, waypoints)
    -- activeMobs is a {mob -> data} table where data has waypointIndex.
    local activeMobs = {}
    for _, m in ipairs(mobs) do
        activeMobs[m] = {
            waypointIndex = m._wpIndex or 1,
            -- Targeting reads data._phoenixQueued; absent = false.
        }
    end
    return {
        activeMobs = activeMobs,
        getWaypoints = function() return waypoints end,
    }
end

------------------------------------------------------------
-- Tests
------------------------------------------------------------

Tests.test("Targeting.findTarget — empty activeMobs returns nil", function()
    local ctx = makeCtx({}, { makeWaypoint(0, 0), makeWaypoint(20, 0) })
    Targeting.setup(ctx)
    local got = ctx.findTarget(Vector3.new(0, 0, 0), 30, "First")
    Tests.assertNil(got, "no mobs → nil")
end)

Tests.test("Targeting.findTarget — out-of-range mob is excluded", function()
    local far = makeMockMob("far", 100, 0, 100)
    far._wpIndex = 1
    local ctx = makeCtx({ far }, { makeWaypoint(0, 0), makeWaypoint(200, 0) })
    Targeting.setup(ctx)
    local got = ctx.findTarget(Vector3.new(0, 0, 0), 30, "First")
    Tests.assertNil(got, "mob at dist 100 with range 30 → nil")
end)

Tests.test("Targeting.findTarget — First picks furthest along path", function()
    -- Two mobs along the same path; one closer to the heart.
    local back  = makeMockMob("back",  10, 0, 100)
    local front = makeMockMob("front", 50, 0, 100)
    back._wpIndex  = 1  -- still on leg 1
    front._wpIndex = 2  -- on leg 2 → further along
    local ctx = makeCtx({ back, front },
        { makeWaypoint(0, 0), makeWaypoint(30, 0), makeWaypoint(80, 0) })
    Targeting.setup(ctx)
    local got = ctx.findTarget(Vector3.new(40, 0, 0), 100, "First")
    Tests.assertEq(got, front, "First should prefer front-of-path mob")
end)

Tests.test("Targeting.findTarget — Last picks least-far along path", function()
    local back  = makeMockMob("back",  10, 0, 100)
    local front = makeMockMob("front", 50, 0, 100)
    back._wpIndex  = 1
    front._wpIndex = 2
    local ctx = makeCtx({ back, front },
        { makeWaypoint(0, 0), makeWaypoint(30, 0), makeWaypoint(80, 0) })
    Targeting.setup(ctx)
    local got = ctx.findTarget(Vector3.new(40, 0, 0), 100, "Last")
    Tests.assertEq(got, back, "Last should prefer back-of-path mob")
end)

Tests.test("Targeting.findTarget — Strongest picks highest HP", function()
    local low  = makeMockMob("low",  10, 0, 50)
    local high = makeMockMob("high", 12, 0, 500)
    local ctx = makeCtx({ low, high }, { makeWaypoint(0, 0), makeWaypoint(30, 0) })
    Targeting.setup(ctx)
    local got = ctx.findTarget(Vector3.new(0, 0, 0), 100, "Strongest")
    Tests.assertEq(got, high, "Strongest should prefer high-HP mob")
end)

Tests.test("Targeting.findTarget — Weakest picks lowest HP", function()
    local low  = makeMockMob("low",  10, 0, 50)
    local high = makeMockMob("high", 12, 0, 500)
    local ctx = makeCtx({ low, high }, { makeWaypoint(0, 0), makeWaypoint(30, 0) })
    Targeting.setup(ctx)
    local got = ctx.findTarget(Vector3.new(0, 0, 0), 100, "Weakest")
    Tests.assertEq(got, low, "Weakest should prefer low-HP mob")
end)

Tests.test("Targeting.findTarget — Center picks mob with most neighbors", function()
    -- One isolated mob; one mob clustered with 3 friends within 8 studs.
    local isolated = makeMockMob("isolated", 30, 0, 100)
    local cluster1 = makeMockMob("cluster1", 0, 0, 100)
    local cluster2 = makeMockMob("cluster2", 2, 0, 100)
    local cluster3 = makeMockMob("cluster3", 4, 0, 100)
    local cluster4 = makeMockMob("cluster4", 6, 0, 100)  -- the center
    local ctx = makeCtx({ isolated, cluster1, cluster2, cluster3, cluster4 },
        { makeWaypoint(0, 0), makeWaypoint(50, 0) })
    Targeting.setup(ctx)
    local got = ctx.findTarget(Vector3.new(3, 0, 0), 100, "Center")
    -- Cluster center has more neighbors than isolated; expect a cluster mob.
    Tests.assertNotNil(got, "Center should not return nil")
    Tests.assertNeq(got, isolated, "Center should not pick isolated mob")
end)

Tests.test("Targeting.findTarget — unknown mode falls back to First-like", function()
    -- Unknown modes shouldn't crash; behavior is "best-effort First"
    -- (any of the candidates is acceptable since the contract is
    -- "don't crash"). Just assert non-nil + valid mob from the input set.
    local m1 = makeMockMob("m1", 10, 0, 100)
    local m2 = makeMockMob("m2", 20, 0, 100)
    local ctx = makeCtx({ m1, m2 }, { makeWaypoint(0, 0), makeWaypoint(30, 0) })
    Targeting.setup(ctx)
    local got = ctx.findTarget(Vector3.new(0, 0, 0), 100, "BogusModeXYZ")
    Tests.assertTrue(got == m1 or got == m2,
        "unknown mode should still return one of the input mobs")
end)

return nil
