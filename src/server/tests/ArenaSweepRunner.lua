--[[
    ArenaSweepRunner.lua tests — regression replay coverage.

    Most of ArenaSweepRunner is integration code (spawns mobs, places
    towers, fires upgrade pickers, runs the live wave loop). The
    pure-math helpers + defensive resets are testable in isolation;
    the combat coroutine itself is best validated end-to-end via a
    real sweep.

    ea3-123: this file currently covers the dev-skip-to-MAP-BOSS leak
    fix (_resetSweepStageState). Future tier-2 entries from
    project_test_coverage_plan.md will land here too.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Tests = require(script.Parent)
local ArenaSweepRunner = require(ServerScriptService
    :WaitForChild("systems"):WaitForChild("ArenaSweepRunner"))

------------------------------------------------------------
-- _resetSweepStageState — replays the 2026-05-01 ea3-122 regression.
--
-- Bug: DEV skip-to-MAP-BOSS sets WaveCtxBridge.ctx.StageState.currentStage
-- = 3. MobFactory.makeMob reads that field at every spawn and applies
-- Stages[3].hpMult (3.4× for Map 1) + Stages[3].speedMult (1.3×). If
-- the player fired skip-to-MAP-BOSS then immediately clicked FAILURE
-- CURVE × 105, the FIRST sweep combo spawned mobs at 3.4× HP / 1.3×
-- speed and tower DPS couldn't keep up. Wave 1 lost 13,399 heart
-- (vs. expected ~3,000); state self-cleared a few combos in.
--
-- ea3-123 fix: setupFailureCurveCombo calls _resetSweepStageState
-- right after the phase set-up to defensively force currentStage = 1.
-- These tests pin that contract.
------------------------------------------------------------

Tests.test("_resetSweepStageState: resets currentStage from 3 to 1", function()
    -- Simulate the post-DEV-skip-to-MAP-BOSS state.
    local mockCtx = {
        StageState = {
            currentStage = 3,
            currentMapId = 4,
        },
    }
    ArenaSweepRunner._resetSweepStageState(mockCtx)
    Tests.assertEq(mockCtx.StageState.currentStage, 1,
        "currentStage should be reset to 1 (sweep baseline)")
    -- currentMapId unchanged — sweep only resets stage progression,
    -- not which map the player is on (always Map 4 during sweep).
    Tests.assertEq(mockCtx.StageState.currentMapId, 4,
        "currentMapId should be left alone")
end)

Tests.test("_resetSweepStageState: idempotent when already at stage 1", function()
    local mockCtx = {
        StageState = { currentStage = 1, currentMapId = 4 },
    }
    ArenaSweepRunner._resetSweepStageState(mockCtx)
    Tests.assertEq(mockCtx.StageState.currentStage, 1,
        "stage 1 stays stage 1 (no off-by-one)")
end)

Tests.test("_resetSweepStageState: resets from any leaked stage value", function()
    -- Three dev tools currently set currentStage = 3
    -- (TreeOfLife_WaveSystem.server.lua lines ~1537, 1831, 1879).
    -- Future dev tools or test fixtures might set 2, 4, or anything.
    -- The reset should normalize regardless of the leaked value.
    for _, leakedStage in ipairs({ 2, 3, 4, 5, 99 }) do
        local mockCtx = { StageState = { currentStage = leakedStage } }
        ArenaSweepRunner._resetSweepStageState(mockCtx)
        Tests.assertEq(mockCtx.StageState.currentStage, 1,
            ("stage %d should normalize to 1"):format(leakedStage))
    end
end)

Tests.test("_resetSweepStageState: nil-safe on missing ctx", function()
    -- Defensive: WaveCtxBridge.ctx may be nil during early boot
    -- (WaveSystem hasn't published its ctx yet). Test that the
    -- helper doesn't crash.
    local ok = pcall(function() ArenaSweepRunner._resetSweepStageState(nil) end)
    Tests.assertTrue(ok, "should not error on nil ctx")
end)

Tests.test("_resetSweepStageState: nil-safe on missing StageState", function()
    -- Defensive: ctx exists but StageState hasn't been populated yet
    -- (mid-script-reload edge case). Helper should no-op cleanly.
    local mockCtx = {}  -- no StageState field
    local ok = pcall(function() ArenaSweepRunner._resetSweepStageState(mockCtx) end)
    Tests.assertTrue(ok, "should not error when ctx.StageState is nil")
    Tests.assertNil(mockCtx.StageState, "should not synthesize a StageState that wasn't there")
end)

return nil
