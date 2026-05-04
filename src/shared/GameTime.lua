--!strict
--[[
    GameTime.lua — Single source of truth for "game time" semantics.

    WHY THIS MODULE EXISTS:
    Multiple ad-hoc patterns existed for "wait N game-seconds":
        task.wait(seconds / gameSpeed)        -- floors at one frame at high gs
        task.wait(seconds * gameSpeed)        -- WRONG direction
        os.clock() + seconds / gameSpeed       -- snapshot ignores mid-wait changes
        Heartbeat:Wait() loop with dt × gs    -- correct, but rewritten everywhere
    Each variant was wrong in a different scenario (boss-phase lock holding gs at
    1×, player changing speed mid-wait, frame-time floor at 10×). One canonical
    helper closes that whole class of bug.

    USAGE:
        local GameTime = require(ReplicatedStorage.Shared.GameTime)

        -- Wait N game-seconds, polling per frame (correct under speed changes
        -- AND boss-phase locks). Optional predicate aborts early — return false
        -- to break out of the wait (e.g. mob died, boss stopped).
        GameTime.adaptiveWait(20)                     -- 20 game-seconds
        GameTime.adaptiveWait(3, function() return State.active end)

        -- Per-frame game-time delta inside a Heartbeat connection.
        local gameDt = GameTime.scaled(dt)            -- dt × gameSpeed

        -- Read current game speed (defensive: nil/0/negative → 1).
        local gs = GameTime.speed()

        -- Lock speed to 1× for a boss-phase tap window, with auto-release
        -- safety. Returns a release function — calling it pops the lock.
        -- Use this over raw bindable fires so you can't leak a lock.
        local release = GameTime.lockSpeed()
        ...do tap window...
        release()

        -- Or scope it: lock for the duration of fn, releases even if fn errors.
        GameTime.withSpeedLock(function()
            ...
        end)

    DEPENDENCIES:
    Reads `Workspace.GameSpeed` (broadcast by the wave system on every speed
    change). Fires `BossPhaseSpeedLock` BindableEvent (handled in the wave
    system, which manages the lock count + actual gs flip). Both are part of
    the existing run-system contract — this module is a wrapper, not a
    redefinition.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))

local GameTime = {}

-- Current game speed as a positive number. Defensive coercion: nil, 0, or
-- negative values all coerce to 1 so callers don't have to repeat the guard.
function GameTime.speed(): number
    local gs = Workspace:GetAttribute("GameSpeed")
    if type(gs) ~= "number" or gs <= 0 then
        return 1
    end
    return gs
end

-- True when the game is in pause state (Workspace.GamePaused set by the
-- wave system's pause path). Distinct from speed=0: the speed multiplier
-- is preserved across pause so unpause resumes at the same multiplier,
-- and several systems still divide by ctx.gameSpeed which mustn't go
-- to 0. Use this in time-based loops to actually pause progression.
function GameTime.isPaused(): boolean
    return Workspace:GetAttribute("GamePaused") == true
end

-- Wallclock seconds since program start. Thin alias so callsites read as
-- "GameTime.now()" alongside game-time helpers — easier to scan for accidental
-- wallclock arithmetic in code that should be game-time scaled.
function GameTime.now(): number
    return os.clock()
end

-- dt scaled by the current game speed. Use inside Heartbeat connections that
-- want to advance by GAME-time per frame (mob walkers, daze countdowns,
-- boss flight loops). Returns 0 while paused so per-frame time loops
-- naturally freeze without each callsite needing its own pause guard.
function GameTime.scaled(dt: number): number
    if GameTime.isPaused() then return 0 end
    return dt * GameTime.speed()
end

-- Wait `gameSeconds` of GAME time (i.e. `gameSeconds / gameSpeed` wallclock
-- on average, but resilient to mid-wait speed changes and boss-phase locks).
-- Polls Workspace.GameSpeed each Heartbeat and accumulates dt × gs until the
-- target is reached.
--
-- Optional `predicate` is called each tick before the dt is added; returning
-- false aborts the wait early (yields a partial-elapsed value back to caller).
-- Useful for "wait 30 game-seconds OR until boss dies".
--
-- Returns the actual game-seconds elapsed (always <= gameSeconds).
function GameTime.adaptiveWait(gameSeconds: number, predicate: (() -> boolean)?): number
    if gameSeconds <= 0 then return 0 end
    local elapsed = 0
    while elapsed < gameSeconds do
        if predicate and not predicate() then return elapsed end
        local dt = RunService.Heartbeat:Wait()
        -- Skip elapsed-time accumulation while paused. We still yield
        -- on Heartbeat so the caller's coroutine doesn't busy-spin,
        -- but the wait will resume from where it left off when the
        -- pause clears. Without this guard, Pickle Lord's smash /
        -- decay / mini loops kept ticking right through pause because
        -- Workspace.GameSpeed isn't zeroed on pause (preserved so
        -- unpause resumes at the prior multiplier).
        if not GameTime.isPaused() then
            local gs = GameTime.speed()
            elapsed = elapsed + dt * gs
        end
    end
    return elapsed
end

-- Internal: fetch the BossPhaseSpeedLock bindable lazily. The wave system
-- creates it; if this module is required before then, FindFirstChild returns
-- nil. We re-resolve on each call so the first lockSpeed() AFTER the wave
-- system boots picks it up cleanly.
local function lockBindable(): BindableEvent?
    local b = ReplicatedStorage:FindFirstChild(Remotes.Names.BossPhaseSpeedLock)
    if b and b:IsA("BindableEvent") then return b end
    return nil
end

-- Push a 1× speed lock. Returns a release function that pops the lock exactly
-- once (idempotent — calling it twice is a no-op). Callers that hold a lock
-- across an async boundary (task.delay, animation) should keep this closure
-- in scope and call it on cleanup, NOT fire the bindable directly.
function GameTime.lockSpeed(): () -> ()
    local b = lockBindable()
    if not b then
        -- No bindable yet (wave system hasn't booted). Return a no-op release
        -- so callers don't have to nil-check.
        return function() end
    end
    b:Fire({ action = "lock" })
    local released = false
    return function()
        if released then return end
        released = true
        local b2 = lockBindable()
        if b2 then b2:Fire({ action = "unlock" }) end
    end
end

-- Run `fn` with a 1× speed lock held for its duration. The lock pops even if
-- `fn` errors — guards against the "lock count drift" bug class where a holder
-- crashes before releasing and the count never returns to 0. Use for tap
-- windows, cutscenes, and anything else that should be 1× regardless of player
-- speed selection.
function GameTime.withSpeedLock<T>(fn: () -> T): T
    local release = GameTime.lockSpeed()
    local ok, result = pcall(fn)
    release()
    if not ok then error(result, 0) end
    return result :: T
end

-- Format a duration in seconds as `H:MM:SS`. Always three components,
-- so 3 minutes reads "0:03:00" and a 105-loadout sweep ETA reads
-- "1:44:59" instead of the old "104m 59s". Used by every player-facing
-- time status bar (run-time HUD, sweep ETA, etc.) so the formatting
-- is consistent across the UI. Negative or NaN inputs clamp to 0.
function GameTime.formatHMS(seconds: number): string
    local s = math.max(0, math.floor(seconds))
    local h = s // 3600
    local m = (s % 3600) // 60
    local sec = s % 60
    return string.format("%d:%02d:%02d", h, m, sec)
end

return GameTime
