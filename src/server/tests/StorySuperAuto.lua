--[[
    StorySuperAuto.lua tests — Phase E-2 smoke coverage. Like
    StoryAutoDriver tests, the real behaviour is end-to-end and
    only observable via a live sweep + server log breadcrumbs.
    These tests pin the API surface so a future refactor can't
    silently rename / remove the public functions other consumers
    rely on (CORE AUTO's `if StorySuperAuto.isActive()` guard +
    CoreAutoRunner's reserved-for-future-extraction require).
    The InfiniteStorySuperRun entry-point handler was removed
    2026-05-01 ea3-142; module survives for the consumers above.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Tests = require(script.Parent)
local StorySuperAuto = require(ServerScriptService
    :WaitForChild("systems")
    :WaitForChild("StorySuperAuto"))

------------------------------------------------------------
-- Idle-state defaults
------------------------------------------------------------

Tests.test("StorySuperAuto.isActive() is false before start", function()
    Tests.assertFalse(StorySuperAuto.isActive(),
        "freshly-required module should not be active")
end)

Tests.test("StorySuperAuto.describe() readable while idle", function()
    local s = StorySuperAuto.describe()
    Tests.assertType(s, "string")
    Tests.assertTrue(#s > 0)
end)

------------------------------------------------------------
-- Public API surface
------------------------------------------------------------

Tests.test("StorySuperAuto exposes start/stop/isActive/describe", function()
    Tests.assertType(StorySuperAuto.start, "function")
    Tests.assertType(StorySuperAuto.stop, "function")
    Tests.assertType(StorySuperAuto.isActive, "function")
    Tests.assertType(StorySuperAuto.describe, "function")
end)

------------------------------------------------------------
-- Validation: invalid args don't crash
------------------------------------------------------------

Tests.test("StorySuperAuto.start(nil, ...) returns false (no crash)", function()
    local ok = StorySuperAuto.start(nil, nil)
    Tests.assertFalse(ok or false, "expected false return for nil player")
    Tests.assertFalse(StorySuperAuto.isActive(),
        "module should remain idle after rejected start")
end)

Tests.test("StorySuperAuto.stop() is a no-op when idle", function()
    -- Should not throw.
    StorySuperAuto.stop()
    Tests.assertFalse(StorySuperAuto.isActive())
end)

return nil
