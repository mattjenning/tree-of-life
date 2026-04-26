--[[
    StatLedger.lua — per-run tower stat capture for the future Infinite
    Arena balance/benchmark sandbox (roadmap: project_infinite_arena.md).

    Records per-tower stats during a run so the Infinite mode can compute
    DPS, total damage, stun-value, slow-value, knockback-value, and
    tower-combo distributions across many runs to drive a tier list +
    balance recommendations.

    PHASE 1 INFRASTRUCTURE (this file): records the data, exposes a
    snapshot API, prints a summary on run end. The Infinite mode UI +
    scenario runner that EATS this data is future work.

    API:
        StatLedger.recordDamage(tower, amount, hitType: "direct"/"chain"/"dot"/"splash")
        StatLedger.recordStun(tower, gameSeconds)
        StatLedger.recordSlow(tower, slowMult, durationSec)   -- (1-slowMult) × dur
        StatLedger.recordKnockback(tower, studDistance)
        StatLedger.recordPlacement(towerType: string, rarity: string?)
        StatLedger.recordTick()                                -- bump run time clock
        StatLedger.snapshot()                                  -- shallow copy
        StatLedger.summary()  → string                          -- human-readable
        StatLedger.reset()                                     -- new run

    Per-tower entry shape (looked up by tower MODEL, not type — so two
    Power towers placed in the same run track separately):
        {
            type        = "Power" / "ThornVine" / etc.,
            damage      = { direct=N, splash=N, chain=N, dot=N, total=N },
            stunSec     = N,
            slowValue   = N,    -- sum of (1-slowMult)*durationSec
            kbStuds     = N,
            hits        = N,
        }

    Tower-type loadout (separate from per-tower stats — one entry per
    distinct (type, rarity) pairing the player placed):
        loadout = { ["Power[Common]"] = 1, ["ThornVine[Rare]"] = 2, ... }

    Lifecycle hooks:
        - TowerPlacement.lua calls recordPlacement on successful place.
        - Damage.lua calls recordDamage.
        - Effects.lua / Towers.lua call recordStun / recordSlow / recordKnockback.
        - WaveSystem reset path calls reset() at run-start.
        - Boss-defeat / game-over fires summary().
]]

local StatLedger = {}

-- Recording master switch. When false, every recordX function early-
-- returns and snapshot()/summary() reports an empty ledger. Set to
-- true only when the Balance Studio UI + persistent run-history are
-- ready to consume the data — until then we don't want partial
-- captures polluting future tier-list runs.
-- Per Matthew (2026-04-27): "do not record any stats for now (make
-- this change first), we need to get it working first."
-- Flip via StatLedger.setRecordingEnabled(true) when ready.
local recordingEnabled = false

-- Per-tower stats keyed by Roblox Model. Tower destruction (smash) doesn't
-- clear the entry — its stats stay so the run summary still shows what
-- that tower did before it was destroyed.
local towerStats: {[Instance]: any} = {}
-- Loadout keyed by "TowerType[Rarity]" string for cheap collation.
local loadout: {[string]: number} = {}
-- Run wall-clock + game-time at start, updated on snapshot.
local runStartClock = os.clock()

function StatLedger.setRecordingEnabled(enabled: boolean)
    recordingEnabled = enabled and true or false
end

function StatLedger.isRecordingEnabled(): boolean
    return recordingEnabled
end

local function ensureEntry(tower: Instance)
    local entry = towerStats[tower]
    if entry then return entry end
    entry = {
        type      = tower:GetAttribute("TowerType") or tower.Name,
        damage    = { direct=0, splash=0, chain=0, dot=0, total=0 },
        stunSec   = 0,
        slowValue = 0,
        kbStuds   = 0,
        hits      = 0,
    }
    towerStats[tower] = entry
    return entry
end

function StatLedger.recordDamage(tower: Instance?, amount: number, hitType: string?)
    if not recordingEnabled then return end
    if not tower or type(amount) ~= "number" or amount <= 0 then return end
    local e = ensureEntry(tower)
    local kind = (hitType == "splash" or hitType == "chain"
                  or hitType == "dot") and hitType or "direct"
    e.damage[kind] = (e.damage[kind] or 0) + amount
    e.damage.total = e.damage.total + amount
    e.hits = e.hits + 1
end

function StatLedger.recordStun(tower: Instance?, gameSeconds: number)
    if not recordingEnabled then return end
    if not tower or type(gameSeconds) ~= "number" or gameSeconds <= 0 then return end
    local e = ensureEntry(tower)
    e.stunSec = e.stunSec + gameSeconds
end

function StatLedger.recordSlow(tower: Instance?, slowMult: number, durationSec: number)
    if not recordingEnabled then return end
    if not tower or type(slowMult) ~= "number" or type(durationSec) ~= "number" then return end
    if slowMult >= 1 or durationSec <= 0 then return end
    local e = ensureEntry(tower)
    -- Slow-value = (1 - slowMult) × duration. A 50% slow for 2s = 1.0
    -- slow-stud-seconds; a 25% slow for 4s also = 1.0. Comparable across
    -- towers regardless of slow strength × duration tradeoff.
    e.slowValue = e.slowValue + (1 - slowMult) * durationSec
end

function StatLedger.recordKnockback(tower: Instance?, studDistance: number)
    if not recordingEnabled then return end
    if not tower or type(studDistance) ~= "number" or studDistance <= 0 then return end
    local e = ensureEntry(tower)
    e.kbStuds = e.kbStuds + studDistance
end

function StatLedger.recordPlacement(towerType: string?, rarity: string?)
    if not recordingEnabled then return end
    if type(towerType) ~= "string" then return end
    local key = rarity and (towerType .. "[" .. rarity .. "]") or towerType
    loadout[key] = (loadout[key] or 0) + 1
end

function StatLedger.snapshot(): {[string]: any}
    -- Shallow copy of per-tower stats keyed by tower Name@instanceId.
    -- Caller can serialize / iterate without worrying about future writes.
    local out = { towers = {}, loadout = {}, runWallSec = os.clock() - runStartClock }
    for tower, entry in pairs(towerStats) do
        local id = (tower.Parent and tower:GetFullName()) or tower.Name
        -- Deep-copy the damage subtable; everything else is scalar.
        out.towers[id] = {
            type      = entry.type,
            damage    = table.clone(entry.damage),
            stunSec   = entry.stunSec,
            slowValue = entry.slowValue,
            kbStuds   = entry.kbStuds,
            hits      = entry.hits,
            dps       = (out.runWallSec > 0)
                        and (entry.damage.total / out.runWallSec)
                        or 0,
        }
    end
    for key, count in pairs(loadout) do
        out.loadout[key] = count
    end
    return out
end

function StatLedger.summary(): string
    local snap = StatLedger.snapshot()
    local lines = {}
    table.insert(lines, string.format(
        "[StatLedger] run summary — %.1fs wall", snap.runWallSec))
    table.insert(lines, "  Loadout:")
    for key, count in pairs(snap.loadout) do
        table.insert(lines, string.format("    %s × %d", key, count))
    end
    -- Sort towers by total damage desc for readability.
    local sortable = {}
    for id, entry in pairs(snap.towers) do
        table.insert(sortable, { id = id, entry = entry })
    end
    table.sort(sortable, function(a, b)
        return a.entry.damage.total > b.entry.damage.total
    end)
    table.insert(lines, "  Towers:")
    for _, row in ipairs(sortable) do
        local e = row.entry
        table.insert(lines, string.format(
            "    %s  dmg=%d (D=%d/S=%d/C=%d/dot=%d) hits=%d dps=%.1f stun=%.1fs slow=%.1f kb=%.0f",
            e.type,
            e.damage.total, e.damage.direct, e.damage.splash, e.damage.chain, e.damage.dot,
            e.hits, e.dps, e.stunSec, e.slowValue, e.kbStuds))
    end
    return table.concat(lines, "\n")
end

function StatLedger.reset()
    towerStats = {}
    loadout = {}
    runStartClock = os.clock()
end

return StatLedger
