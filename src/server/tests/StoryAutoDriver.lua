--[[
    StoryAutoDriver.lua tests — Phase E-1 smoke coverage. The driver
    can't be fully unit-tested in isolation because it fires real
    BindableEvents (SwitchMap) and listens to others (BossRewardClaimed),
    so these tests cover the API surface + idle-state contract. Real
    end-to-end behaviour will be observable via the SUPER AUTO sweep
    in E-2 (server log breadcrumbs from setPhase / fireSwitchMap).
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Tests = require(script.Parent)
local StoryAutoDriver = require(ServerScriptService
    :WaitForChild("systems")
    :WaitForChild("StoryAutoDriver"))

------------------------------------------------------------
-- Idle-state defaults
------------------------------------------------------------

Tests.test("StoryAutoDriver.isActive() is false before start", function()
    Tests.assertFalse(StoryAutoDriver.isActive(),
        "freshly-required driver should not be active")
end)

Tests.test("StoryAutoDriver.phase() reports 'idle' before start", function()
    Tests.assertEq(StoryAutoDriver.phase(), "idle")
end)

Tests.test("StoryAutoDriver.describe() readable while idle", function()
    local s = StoryAutoDriver.describe()
    Tests.assertType(s, "string")
    Tests.assertTrue(#s > 0, "describe should return non-empty string")
end)

------------------------------------------------------------
-- Public API surface
------------------------------------------------------------

Tests.test("StoryAutoDriver exposes start/stop lifecycle functions", function()
    Tests.assertType(StoryAutoDriver.start, "function")
    Tests.assertType(StoryAutoDriver.stop,  "function")
    Tests.assertType(StoryAutoDriver.isActive, "function")
    Tests.assertType(StoryAutoDriver.phase, "function")
    Tests.assertType(StoryAutoDriver.describe, "function")
end)

Tests.test("StoryAutoDriver.stop() is a no-op when idle", function()
    -- Should not throw, should leave driver in idle state.
    StoryAutoDriver.stop()
    Tests.assertEq(StoryAutoDriver.phase(), "idle")
    Tests.assertFalse(StoryAutoDriver.isActive())
end)

return nil
