--[[
    VfxPool.lua — Generic object-pool helper for short-lived VFX
    instances. Replaces the Instance.new + :Destroy churn pattern
    with acquire / release across damage popups, fire bolts, AOE
    bursts, and any future VFX that fires per-shot or per-hit.

    WHY THIS MODULE EXISTS:
    Per-frame VFX allocation in Effects.lua / Zones.lua / future
    VFX modules creates real Heap pressure. Damage popups in a
    busy run easily hit 200-500 spawns/sec (each = 3 instances:
    anchor + BillboardGui + TextLabel = 1500 instances/sec
    churned). Even at typical sweep loads the GC pauses are
    visible.

    The pool keeps N pre-built instances per kind, hands one out
    via acquire(), takes it back on release(). Each kind has its
    own free-list + builder. When the free-list runs dry we
    allocate fresh; when the player isn't pressuring the pool
    we keep them around (capped at MAX_PER_KIND so the pool
    can't grow unbounded across a long sweep).

    PUBLIC API:
      VfxPool.register(kind, builder, resetter)
        builder: () -> { root = Part, ... }   -- builds a fresh instance
        resetter: (entry) -> ()               -- restores defaults pre-acquire

      VfxPool.acquire(kind)        -> entry
      VfxPool.release(kind, entry) -> ()      -- return for reuse
      VfxPool.releaseAfter(kind, entry, seconds)
                                              -- task.delay-driven release;
                                              -- same as Debris:AddItem but
                                              -- pools instead of destroys

      VfxPool.shutdown()           -> ()      -- destroy all pooled instances
                                              -- (called at run-end / map switch)

    SAFETY:
    - Each entry is reparented OFF-SCREEN on release (Parent = nil)
      so it doesn't render between uses.
    - acquire() always re-parents to the caller's chosen target.
    - resetter() runs on every acquire (NOT release) so callers
      can rely on clean state.

    USAGE:
        VfxPool.register("damagePopup",
            buildDamagePopup,
            resetDamagePopup)
        local popup = VfxPool.acquire("damagePopup")
        popup.label.Text = "-15"
        popup.root.Parent = ctx.tdRoom
        VfxPool.releaseAfter("damagePopup", popup, 0.8)
]]

local VfxPool = {}

-- Per-kind free lists + bookkeeping.
local kinds: {[string]: any} = {}

-- Hard cap per kind so the pool can't grow unbounded across a long
-- sweep. 64 covers typical peak concurrency for damage popups; if a
-- kind needs more, register() can override the cap via the second
-- argument table.
local DEFAULT_MAX_PER_KIND = 64

------------------------------------------------------------
-- register — declare a pool kind. builder() makes a fresh instance;
-- resetter(entry) brings it to a known-good state before acquire
-- hands it out (so the caller doesn't need to know which fields the
-- previous user left dirty).
--
-- opts (optional): { maxPerKind = N }
------------------------------------------------------------
function VfxPool.register(kind: string, builder, resetter, opts: {[string]: any}?)
    if kinds[kind] then
        warn(("[VfxPool] kind '%s' already registered; overwriting"):format(kind))
    end
    kinds[kind] = {
        builder    = builder,
        resetter   = resetter,
        free       = {},      -- list of available entries
        live       = 0,       -- count currently checked out
        maxKept    = (opts and opts.maxPerKind) or DEFAULT_MAX_PER_KIND,
    }
end

------------------------------------------------------------
-- acquire — hand back a fresh-or-recycled entry. Resetter runs
-- on every acquire so caller gets clean state. Caller is
-- responsible for parenting / positioning / setting per-use
-- properties (text, color, transparency, etc.).
------------------------------------------------------------
function VfxPool.acquire(kind: string)
    local k = kinds[kind]
    if not k then
        error("[VfxPool] kind not registered: " .. tostring(kind))
    end
    local entry = table.remove(k.free)
    if not entry then
        entry = k.builder()
    end
    k.resetter(entry)
    k.live = k.live + 1
    return entry
end

------------------------------------------------------------
-- release — return an entry to the pool. Reparents off-screen
-- (Parent = nil) so it stops rendering. If the pool is at its
-- maxKept cap, destroys instead — keeps memory bounded over
-- long sweeps.
------------------------------------------------------------
function VfxPool.release(kind: string, entry)
    local k = kinds[kind]
    if not k or not entry then return end
    k.live = math.max(0, k.live - 1)
    -- Detach from the world so the entry stops rendering between
    -- uses. The root field is the convention: every kind's builder
    -- returns a table with a `root` Part the caller parents.
    if entry.root and entry.root.Parent ~= nil then
        entry.root.Parent = nil
    end
    if #k.free >= k.maxKept then
        -- Pool is full; destroy instead of growing unbounded.
        if entry.root then entry.root:Destroy() end
        return
    end
    table.insert(k.free, entry)
end

------------------------------------------------------------
-- releaseAfter — schedule the release on a delay. Replaces the
-- Debris:AddItem(part, t) pattern; safe to call from any thread.
------------------------------------------------------------
function VfxPool.releaseAfter(kind: string, entry, seconds: number)
    task.delay(seconds, function()
        VfxPool.release(kind, entry)
    end)
end

------------------------------------------------------------
-- shutdown — destroy all pooled instances. Called at run-end /
-- map-switch so the pool doesn't carry stale state into a fresh
-- run.
------------------------------------------------------------
function VfxPool.shutdown()
    for _, k in pairs(kinds) do
        for _, entry in ipairs(k.free) do
            if entry.root then entry.root:Destroy() end
        end
        k.free = {}
        k.live = 0
    end
end

------------------------------------------------------------
-- stats — debug helper. Returns { [kind] = { free = N, live = N } }.
-- Not used in hot paths; for F9 console inspection.
------------------------------------------------------------
function VfxPool.stats()
    local out = {}
    for kind, k in pairs(kinds) do
        out[kind] = { free = #k.free, live = k.live, maxKept = k.maxKept }
    end
    return out
end

return VfxPool
