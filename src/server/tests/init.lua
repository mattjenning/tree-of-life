--[[
    tests/init.lua — Tiny in-house test framework. Tests live as
    sibling ModuleScripts under this folder; each one requires
    `script.Parent` to get the framework and registers `t.test(name, fn)`
    cases. The orchestrator (src/server/RunTests.server.lua) requires
    each test child + invokes Tests.run().

    Why a custom framework instead of TestEZ:
      - One file, no external dependencies, no Studio plugin install.
      - Tests run automatically on every server start so a regression
        prints in the same console the rest of the server logs to —
        Matthew + Lily see "[Tests] 28 passed, 1 failed: ..." right
        next to the Rojo connection log.
      - Pure-Luau API; no `describe`/`it` BDD ceremony, just `t.test(...)`.

    USAGE (in each test file):
      local Tests = require(script.Parent)
      Tests.test("Rarity.ColorFor 'Common' returns gray", function()
          local Rarity = require(<path to module>)
          Tests.assertEq(Rarity.ColorFor("Common"), Rarity.Colors[1])
      end)

    Failures print as warnings (red in Studio output) so they stand out
    against passing prints.
]]

local Tests = {}

Tests.passed = 0
Tests.failed = 0
Tests.failures = {}

-- ---------------------------------------------------------------------
-- Assertions. All raise a Lua error on failure; the test() wrapper
-- pcalls each test fn and tallies passed/failed.
-- ---------------------------------------------------------------------

function Tests.assertEq(a, b, msg)
    if a == b then return end
    error(string.format("%s — expected %s, got %s",
        msg or "values not equal", tostring(b), tostring(a)), 2)
end

function Tests.assertNeq(a, b, msg)
    if a ~= b then return end
    error(string.format("%s — both were %s",
        msg or "values were equal", tostring(a)), 2)
end

function Tests.assertTrue(v, msg)
    if v then return end
    error(string.format("%s — got %s",
        msg or "expected truthy", tostring(v)), 2)
end

function Tests.assertFalse(v, msg)
    if not v then return end
    error(string.format("%s — got %s",
        msg or "expected falsy", tostring(v)), 2)
end

function Tests.assertNear(a, b, eps, msg)
    eps = eps or 0.001
    if type(a) ~= "number" or type(b) ~= "number" then
        error(string.format("%s — non-numeric (a=%s, b=%s)",
            msg or "assertNear", tostring(a), tostring(b)), 2)
    end
    if math.abs(a - b) <= eps then return end
    error(string.format("%s — expected %s ± %s, got %s",
        msg or "values not near", tostring(b), tostring(eps), tostring(a)), 2)
end

function Tests.assertNotNil(v, msg)
    if v ~= nil then return end
    error(msg or "expected non-nil", 2)
end

function Tests.assertNil(v, msg)
    if v == nil then return end
    error(string.format("%s — got %s", msg or "expected nil", tostring(v)), 2)
end

function Tests.assertType(v, expectedType, msg)
    local got = type(v)
    if got == expectedType then return end
    error(string.format("%s — expected type %s, got %s",
        msg or "type mismatch", expectedType, got), 2)
end

-- assertThrows — fn() should raise. Returns the error message for
-- further matching if the caller wants to assert specific text.
function Tests.assertThrows(fn, msg)
    local ok, err = pcall(fn)
    if ok then
        error(msg or "expected throw, got success", 2)
    end
    return tostring(err)
end

-- ---------------------------------------------------------------------
-- Test registration. Each call appends to the queue; run() executes them.
-- ---------------------------------------------------------------------

local queue = {}

function Tests.test(name, fn)
    table.insert(queue, { name = name, fn = fn })
end

function Tests.run()
    Tests.passed = 0
    Tests.failed = 0
    Tests.failures = {}
    for _, entry in ipairs(queue) do
        local ok, err = pcall(entry.fn)
        if ok then
            Tests.passed = Tests.passed + 1
        else
            Tests.failed = Tests.failed + 1
            table.insert(Tests.failures,
                string.format("%s: %s", entry.name, tostring(err)))
        end
    end
    Tests.report()
end

function Tests.report()
    if Tests.failed == 0 then
        print(string.format("[Tests] ✓ %d passed", Tests.passed))
    else
        warn(string.format("[Tests] ✗ %d passed, %d FAILED",
            Tests.passed, Tests.failed))
        for _, line in ipairs(Tests.failures) do
            warn("[Tests]   • " .. line)
        end
    end
end

return Tests
