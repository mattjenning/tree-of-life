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
require(script.Parent:WaitForChild("tests"):WaitForChild("CoreTypes"))
require(script.Parent:WaitForChild("tests"):WaitForChild("CoreUpgrades"))
require(script.Parent:WaitForChild("tests"):WaitForChild("Config"))
require(script.Parent:WaitForChild("tests"):WaitForChild("TempTowers"))
require(script.Parent:WaitForChild("tests"):WaitForChild("GameTime"))
require(script.Parent:WaitForChild("tests"):WaitForChild("Maid"))
require(script.Parent:WaitForChild("tests"):WaitForChild("MobUtil"))
require(script.Parent:WaitForChild("tests"):WaitForChild("Grid"))
require(script.Parent:WaitForChild("tests"):WaitForChild("Targeting"))
require(script.Parent:WaitForChild("tests"):WaitForChild("MapRegistry"))
require(script.Parent:WaitForChild("tests"):WaitForChild("StatLedger"))
require(script.Parent:WaitForChild("tests"):WaitForChild("Infinite"))
require(script.Parent:WaitForChild("tests"):WaitForChild("InfiniteSimulator"))
require(script.Parent:WaitForChild("tests"):WaitForChild("InfiniteRunHistoryStore"))
require(script.Parent:WaitForChild("tests"):WaitForChild("InfiniteValidator"))
require(script.Parent:WaitForChild("tests"):WaitForChild("InfinitePathGeometry"))
require(script.Parent:WaitForChild("tests"):WaitForChild("InfiniteQueues"))
require(script.Parent:WaitForChild("tests"):WaitForChild("FailureCurveSweep"))
require(script.Parent:WaitForChild("tests"):WaitForChild("StoryAutoDriver"))
require(script.Parent:WaitForChild("tests"):WaitForChild("StorySuperAuto"))
require(script.Parent:WaitForChild("tests"):WaitForChild("AutoPicker"))
require(script.Parent:WaitForChild("tests"):WaitForChild("ArenaSweepRunner"))
require(script.Parent:WaitForChild("tests"):WaitForChild("AutoPlaceStrategy"))

Tests.run()

-- ea3-43: defensive AutoPicker reset post-tests. If any AutoPicker
-- test throws before its cleanup endAuto() runs, the module-level
-- state stays active — and EVERY picker bypass branch (TempTowerRewards
-- cutscene, CoreUpgrades modal, UpgradeCards between-wave) fires
-- silently in subsequent story play, bypassing the player's clicks.
-- Each test now also calls endAuto() at start as a safety net, but
-- this post-Tests.run() reset closes the gap if both safeties miss.
local AutoPicker = require(script.Parent:WaitForChild("systems"):WaitForChild("AutoPicker"))
AutoPicker.endAuto()
