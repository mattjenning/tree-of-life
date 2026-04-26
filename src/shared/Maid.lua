--!strict
--[[
    Maid.lua — Resource-tracking helper. Holds a bag of "things to clean up"
    (RBXScriptConnections, Instances, task threads, plain functions) and tears
    them down with a single Destroy() call.

    WHY THIS MODULE EXISTS:
    Long-lived systems (boss watchers, egg walkers, swoop loops, zone visuals,
    click detectors) accumulate resources that need symmetric teardown on
    boss-stop / RunReset / map switch / player-leave. Hand-rolling cleanup
    paths drifts: a new Connection added to startBirdBoss isn't disconnected
    in stopBirdBoss, the next run leaks a Heartbeat callback running flight
    math on a freed body Part, FPS tanks. A Maid you Give() each resource to
    when you create it makes the cleanup automatic and impossible to forget.

    USAGE:
        local Maid = require(ReplicatedStorage.Shared.Maid)
        local m = Maid.new()

        -- Track anything Roblox needs disconnect/Destroy on:
        m:give(part)                                    -- Instance → :Destroy()
        m:give(connection)                              -- RBXScriptConnection → :Disconnect()
        m:give(function() ... end)                      -- function → called
        m:give(thread)                                  -- task thread → task.cancel
        m:give(otherMaid)                               -- nested Maid → :destroy()

        -- Tear everything down (idempotent — calling twice is safe):
        m:destroy()

    PATTERN — boss/system module:
        local State = { maid = Maid.new(), active = false }
        function startBoss()
            State.maid:give(RunService.Heartbeat:Connect(...))
            State.maid:give(task.spawn(function() ... end))
            State.maid:give(buildBirdModel(...))   -- the entire model Instance
        end
        function stopBoss()
            State.maid:destroy()    -- one call wipes connections + threads + model
            State.maid = Maid.new() -- fresh maid for the next run
        end
]]

local Maid = {}
Maid.__index = Maid

export type Resource = RBXScriptConnection | Instance | () -> () | thread | Maid

export type Maid = typeof(setmetatable({} :: { _items: { Resource } }, Maid))

-- Construct an empty Maid. Callers typically attach this to a system's State
-- table so it's reachable from both the spawn-loop and the cleanup paths.
function Maid.new(): Maid
    return setmetatable({ _items = {} }, Maid) :: any
end

-- Add a resource to the cleanup bag. Returns the resource unchanged so
-- callsites can write `local conn = m:give(Heartbeat:Connect(...))`.
function Maid.give<T>(self: Maid, resource: T & Resource): T
    table.insert(self._items, resource :: any)
    return resource
end

-- Tear down all tracked resources in REVERSE order (LIFO — typically what you
-- want, so dependents are torn down before their dependencies). Each item is
-- destroyed independently inside a pcall so one failure doesn't leak the rest.
-- Idempotent: calling :destroy() a second time is a no-op since _items is
-- replaced with a fresh empty table on the first call.
function Maid.destroy(self: Maid)
    local items = self._items
    self._items = {}
    for i = #items, 1, -1 do
        local r = items[i]
        pcall(function()
            -- Connection? Instance? thread? function? nested Maid?
            -- Type-test in order of likelihood for our codebase: Connections
            -- and Instances are most common.
            if typeof(r) == "RBXScriptConnection" then
                (r :: RBXScriptConnection):Disconnect()
            elseif typeof(r) == "Instance" then
                (r :: Instance):Destroy()
            elseif type(r) == "function" then
                (r :: () -> ())()
            elseif type(r) == "thread" then
                task.cancel(r :: thread)
            elseif type(r) == "table" and (r :: any).destroy then
                -- Nested Maid (or anything Maid-like with a :destroy method).
                (r :: any):destroy(r)
            end
        end)
    end
end

return Maid
