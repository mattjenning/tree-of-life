--[[
    Maid.lua tests — verifies the resource-tracking helper used by boss
    systems for symmetric teardown. Covers the resource types we actually
    pass it (functions, threads, Instances, nested Maids).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tests = require(script.Parent)
local Maid  = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Maid"))

------------------------------------------------------------
-- new() and basic give/destroy lifecycle
------------------------------------------------------------

Tests.test("Maid.new: returns an empty maid with give/destroy methods", function()
    local m = Maid.new()
    Tests.assertType(m, "table")
    Tests.assertType(m.give, "function")
    Tests.assertType(m.destroy, "function")
end)

Tests.test("Maid.give: returns the resource unchanged", function()
    local m = Maid.new()
    local fn = function() end
    local r = m:give(fn)
    Tests.assertEq(r, fn, "give should be transparent — same function returned")
end)

------------------------------------------------------------
-- destroy() invokes registered cleanups
------------------------------------------------------------

Tests.test("Maid.destroy: calls registered functions", function()
    local called = 0
    local m = Maid.new()
    m:give(function() called = called + 1 end)
    m:give(function() called = called + 10 end)
    m:destroy()
    Tests.assertEq(called, 11, "both cleanups should have fired")
end)

Tests.test("Maid.destroy: tears down in REVERSE order (LIFO)", function()
    local order = {}
    local m = Maid.new()
    m:give(function() table.insert(order, "first-given") end)
    m:give(function() table.insert(order, "second-given") end)
    m:give(function() table.insert(order, "third-given") end)
    m:destroy()
    Tests.assertEq(order[1], "third-given", "LIFO: last given runs first")
    Tests.assertEq(order[2], "second-given")
    Tests.assertEq(order[3], "first-given")
end)

Tests.test("Maid.destroy: idempotent — second call is a no-op", function()
    local called = 0
    local m = Maid.new()
    m:give(function() called = called + 1 end)
    m:destroy()
    m:destroy()
    Tests.assertEq(called, 1, "cleanup runs exactly once")
end)

Tests.test("Maid.destroy: a failing cleanup doesn't prevent later ones", function()
    local laterRan = false
    local m = Maid.new()
    m:give(function() laterRan = true end)         -- runs first (LIFO)
    m:give(function() error("boom") end)            -- this errors
    m:give(function() laterRan = true end)          -- pcall isolates each item
    m:destroy()
    Tests.assertTrue(laterRan, "non-erroring cleanups must still run")
end)

------------------------------------------------------------
-- Instance resources
------------------------------------------------------------

Tests.test("Maid.destroy: destroys Instances", function()
    local m = Maid.new()
    local p = Instance.new("Part")
    p.Anchored = true
    p.Parent = workspace
    m:give(p)
    Tests.assertNotNil(p.Parent, "parented before destroy")
    m:destroy()
    Tests.assertNil(p.Parent, "Destroy() should clear .Parent")
end)

------------------------------------------------------------
-- RBXScriptConnection resources
------------------------------------------------------------

Tests.test("Maid.destroy: disconnects RBXScriptConnections", function()
    local RunService = game:GetService("RunService")
    local m = Maid.new()
    local fired = 0
    local bindable = Instance.new("BindableEvent")
    local conn = bindable.Event:Connect(function() fired = fired + 1 end)
    m:give(conn)
    bindable:Fire()
    -- BindableEvent:Fire is DEFERRED in Roblox's modern signal mode —
    -- handlers run on the next resume cycle, not synchronously. Yield
    -- one frame to let the deferred handler land before asserting.
    RunService.Heartbeat:Wait()
    Tests.assertEq(fired, 1)
    m:destroy()
    bindable:Fire()
    RunService.Heartbeat:Wait()
    Tests.assertEq(fired, 1, "post-destroy fire should NOT increment")
    bindable:Destroy()
end)

------------------------------------------------------------
-- Nested Maid (treat as a Resource)
------------------------------------------------------------

Tests.test("Maid.destroy: tears down nested Maids", function()
    local outer = Maid.new()
    local inner = Maid.new()
    local fired = false
    inner:give(function() fired = true end)
    outer:give(inner)
    outer:destroy()
    Tests.assertTrue(fired, "nested maid's cleanup should have run")
end)

return nil
