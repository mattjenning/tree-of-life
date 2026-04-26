--[[
    RunTests.server.lua — Auto-runs the in-house test suite at server
    boot. Tests live as ModuleScripts under server/tests/. Each test
    file requires `script.Parent` (the framework) and registers
    `Tests.test(name, fn)` cases at require time. We require each test
    file here, then call Tests.run() to execute the queue.

    Why at server boot:
      - Catches structural regressions (frozen-table contracts, math
        scaling drift, palette desync) before any player joins. Server
        log shows "[Tests] ✓ N passed" right next to the Rojo connect
        line — same console, no extra workflow step.
      - 30 tests run in a few ms; production cost is negligible.
      - If the server is broken on boot it'll never serve requests
        anyway, so test-on-boot doesn't waste production cycles.

    Adding a new test file: drop a Lua file under server/tests/ and add
    one require() line below. Order doesn't matter — tests run in
    registration order globally.
]]

local Tests = require(script.Parent:WaitForChild("tests"))

-- Each require triggers the test file's `Tests.test(name, fn)` calls;
-- they queue up in the framework, then Tests.run() executes the queue.
require(script.Parent:WaitForChild("tests"):WaitForChild("Rarity"))
require(script.Parent:WaitForChild("tests"):WaitForChild("Config"))
require(script.Parent:WaitForChild("tests"):WaitForChild("TempTowers"))
require(script.Parent:WaitForChild("tests"):WaitForChild("GameTime"))
require(script.Parent:WaitForChild("tests"):WaitForChild("Maid"))
require(script.Parent:WaitForChild("tests"):WaitForChild("MobUtil"))
require(script.Parent:WaitForChild("tests"):WaitForChild("Grid"))
require(script.Parent:WaitForChild("tests"):WaitForChild("Targeting"))
require(script.Parent:WaitForChild("tests"):WaitForChild("MapRegistry"))
require(script.Parent:WaitForChild("tests"):WaitForChild("StatLedger"))

Tests.run()
