--[[
    Infinite.lua — Phase 1 of the Infinite Arena (balance/benchmark
    sandbox per project_infinite_arena.md).

    OWNS:
    - Hub-portal entry handler (called from HubWorld.Touched): teleports
      into Map4, fires SwitchMap (noAutoWaves=true) so the wave system
      knows we're on map 4 without kicking off WAVES[1], grants the
      default tower stock, starts the spawner.
    - Return-portal lazy build inside Map4 (touch → exit + summary).
    - 3-wave loop spawner: every run cycles AOE / Combined / Solo by
      wave % 3, with RunDifficultyMult ramping geometrically per wave.
    - Heart-death listener: on Health <= 0, prints
        "failed at wave N (testType)" + StatLedger.summary(),
      then auto-returns the player to the hub.
    - AUTO RUN orchestrator: builds a 73-loadout queue (9 solos + 36
      pairs + 28 triples-with-anchor), runs each until heart-death or
      wave-30 cap, captures finalWave per loadout, assembles a per-role
      S/A/B/C/D/F tier list at the end. Fired from the admin panel's
      AUTO RUN button; result tier list prints to the server log.

    NOT YET:
    - Full UI for tweaking ramp constants live (today: read from
      Config.Map4.Difficulty)
    - Per-scenario damage / status separators in StatLedger summary
    - Multi-player Infinite (today assumes one player at a time)
    - Persistent run-history DataStore (AUTO RUN tier list lives in
      memory only — re-running the sweep starts from zero)

    setup(ctx) reads from HUB-ctx:
      ctx.MAP4_PLAYER_SPAWN_CF / ctx.HUB_SPAWN_CF
      ctx.map4Heart, ctx.map4Room

    Reads via WaveCtxBridge.ctx (cross-script, late-resolved):
      makeMob, getWaypoints, clearAllMobs   (MobFactory in WaveSystem)

    Reads via direct require:
      shared/Remotes, shared/Config, shared/GameTime, systems/StatLedger

    Publishes:
      ctx.enterInfinite(player, scenarioName)
      ctx.exitInfinite(player)
]]

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local Players             = game:GetService("Players")
local Workspace           = game:GetService("Workspace")
local CollectionService   = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared      = ReplicatedStorage:WaitForChild("Shared")
local Remotes     = require(Shared:WaitForChild("Remotes"))
local Config      = require(Shared:WaitForChild("Config"))
local GameTime    = require(Shared:WaitForChild("GameTime"))
local Tags        = require(Shared:WaitForChild("Tags"))
local TempTowers  = require(Shared:WaitForChild("TempTowers"))

-- Cross-script bridge: WaveSystem-ctx (in a separate Server script)
-- publishes itself to WaveCtxBridge.ctx after its setup completes.
-- Infinite lives in Hub's ecosystem but needs WaveSystem-side
-- functions (makeMob, getWaypoints, activeMobs, clearAllMobs) and
-- the StatLedger reference. Read via waveCtx() at call time so we
-- get the freshest reference if WaveSystem reboots.
local WaveCtxBridge = require(ServerScriptService:WaitForChild("WaveCtxBridge"))
local function waveCtx()
    return WaveCtxBridge.ctx
end
local StatLedger = require(script.Parent:WaitForChild("StatLedger"))
local InfiniteRunHistoryStore = require(ServerScriptService:WaitForChild("InfiniteRunHistoryStore"))
local InfiniteSimulator = require(script.Parent:WaitForChild("InfiniteSimulator"))
local InfiniteValidator = require(script.Parent:WaitForChild("InfiniteValidator"))

local Infinite = {}

-- Cinematic timing
local ENTRY_FADE_OUT_SEC = 0.8
local EXIT_FADE_OUT_SEC  = 0.6

-- Lazy-wired return portal
local returnPortalSetup = false

------------------------------------------------------------
-- Run state. Single-player at a time; multi-player Infinite is
-- a future expansion (would require per-player StageState).
------------------------------------------------------------
local State = {
    active        = false,
    activePlayer  = nil :: Player?,
    -- Wave counter: ramps continuously across the 3-test loop. Wave 1
    -- is AOE-easy; by wave 30 we're in late-stage SoloTarget hell.
    -- Last reached + last test type land in the run-end summary
    -- ("failed at wave 12 (AOE)").
    wave          = 0,
    spawnerToken  = 0,    -- bumped on stop() so live coroutines can detect abort
    heartConn     = nil :: RBXScriptConnection?,
    -- Set by client clicking the countdown overlay; spawner loop's
    -- pre-wave countdown predicate aborts on this and wave 1 starts
    -- immediately. Reset to false on each enter().
    skipCountdown = false,
}

------------------------------------------------------------
-- AUTO RUN orchestrator state. When .active, exit() captures the
-- finalWave + dequeues the next loadout instead of returning to
-- hub. Builds a tier list from finalWave averages once the queue
-- drains. See buildAutoRunQueue / assembleTiers below.
------------------------------------------------------------
local autoRun = {
    active     = false,
    queue      = nil,    -- list of pending { auxIds, label } loadouts
    current    = nil,    -- the loadout currently running
    results    = nil,    -- list of completed { auxIds, label, finalWave, testType }
    total      = 0,      -- queue size at start (for "12/73" progress display)
    continuous = false,  -- when true, finalize() rebuilds the queue + restarts
                         -- a fresh sweep instead of going idle. Per Matthew
                         -- 2026-04-27: "run autorun continuously." Cleared by
                         -- InfiniteStopRun remote / TOTAL RESET / player exit.
    sweepNum   = 0,      -- count of sweeps completed since AUTO RUN started
                         -- (just for the log line / monitor display).
}

-- All sweep tuning lives in Config.InfiniteArena (single source of
-- truth shared with InfiniteSimulator.lua). Module-locals below are
-- aliases so the rest of this file reads naturally; any tuning
-- change goes in Config.lua and BOTH the live spawner and the
-- closed-form sim see it. Per Matthew 2026-04-27: keep these in
-- lockstep so validation deltas reflect actual model gaps, not
-- forgotten tuning copy-paste.
local _IA = Config.InfiniteArena
local MAX_AUTO_RUN_WAVE       = _IA.MaxAutoRunWave
local COMMON_DAMAGE_FLAT      = _IA.Upgrade.DamageFlat
local COMMON_FIRERATE_DELTA   = _IA.Upgrade.FireRateMult
local COMMON_RANGE_DELTA      = _IA.Upgrade.RangeMult
local RANGE_CAP_MULT          = _IA.Upgrade.RangeCapMult
local POST_CAP_EFFECT_BOOST   = _IA.Upgrade.PostCapBoost
local CYCLE_STEP              = _IA.CycleStep
local AUTO_RUN_ANCHOR         = _IA.AutoRunAnchor

------------------------------------------------------------
-- In-session cache. Persistent DataStore-backed history is a
-- future step (project_infinite_arena.md step 3); until then the
-- admin panel reads this cache to re-display the most recent
-- sweep without scrolling the server log.
--
-- Survives until the server restarts. Per Matthew (2026-04-26):
-- "just in session store now, same for tower statistics, no data
-- store yet."
--
-- Shape:
--   lastSweep = {
--     tiers          = { DPS = {...}, Control = {...}, Support = {...} },
--     results        = { { auxIds, label, finalWave, testType, statSummary }, ... },
--     completedAt    = os.time(),
--     total          = number,    -- queue size at start
--   }
--   lastRunStats = string         -- last StatLedger.summary() text
------------------------------------------------------------
local lastSweep = nil :: { any }?
local lastRunStats: string = ""

-- Separate cache for SIMULATE results (pure-math closed-form).
-- Kept distinct from `lastSweep` and `cumulativeResults` per Matthew
-- 2026-04-27: "keep this data separate until I can validate it."
-- Same shape as lastSweep so the admin panel could opt in to
-- displaying it later.
local simulatedSweep = nil :: { any }?

-- Cumulative results pool — every run from every sweep since the
-- last BALANCE RESET appends here. Default tier-list view (admin
-- panel + LastSweepData channel) shows cumulative aggregate across
-- all sweeps so multi-sweep tuning doesn't lose statistical power.
-- Wiped by the InfiniteBalanceReset remote. Per Matthew 2026-04-26:
-- "the run stats + tier lists should be across every run unless
-- balance reset is hit."
--
-- DataStore-backed via InfiniteRunHistoryStore.loadCumulative /
-- saveCumulative — survives server restarts so the cumulative tier
-- list builds up across multiple Studio sessions. Per Matthew
-- 2026-04-26: "hook up the data store so we can save autorun data."
-- Hydrated in setup() (lazy DataStore load) so the file's top-level
-- still initializes to {} for the no-DataStore case.
local cumulativeResults: { any } = {}

-- Monotonic balance-era counter. Hydrated from DataStore on setup;
-- bumped each time BALANCE RESET fires. Stamped onto every sweep
-- + cumulative result so LOAD RUNS can group sweeps by balance
-- era. Per Matthew 2026-04-27: "every time balance reset is used
-- increase the balance version # and start a new row."
local currentBalanceVersion: number = 1

------------------------------------------------------------
-- buildAutoRunQueue — generate every loadout the AUTO RUN sweep
-- runs through. Three sweep types per Matthew's spec
-- (2026-04-26):
--
--   1. Solo:    Power + 1 aux              → 9 runs   (one per aux)
--   2. Pair:    Power + 2 aux              → C(9,2) = 36 runs
--   3. Triple:  Power + 2 aux + anchor     → C(9,2) = 36 runs
--
-- Total = 9 + 36 + 36 = 81 runs.
--
-- Test pool = all 9 regular aux towers (excludes InfiniteStandard,
-- which is the anchor-only standardization tool). Each tower
-- appears in 1 solo + 8 duos + 8 trios = 17 stat runs.
--
-- ── ORDERING ──
-- Per Matthew 2026-04-27: "for solo, duo, and triple, within
-- those buckets, can you randomize tower selection so if I have
-- to stop during a partial run multiple times, eventually each
-- tower gets tested the same amount, or close?"
--
-- Each bucket gets a fresh Fisher-Yates shuffle PER queue build.
-- Three guarantees:
--   1. Bucket order is preserved (all solos before any duo, all
--      duos before any trio) — STOP RUN with N completed gives a
--      well-defined "at least N/3 of each category" lower bound.
--   2. Within a bucket, order is uniform random. Over many
--      partial sweeps, every tower's expected appearance count
--      converges (LLN — sample mean → true mean).
--   3. The shuffle uses a fresh Random per call (no module-level
--      seeded state) so consecutive sweeps produce different
--      orders even within the same server session.
--
-- InfiniteStandard appears in all 36 trios as the anchor; its
-- own tier stats EXCLUDE those (anchor-only role, see
-- assembleTiers below).
------------------------------------------------------------
local function buildAutoRunQueue(): { { auxIds: { string }, label: string } }
    -- Test pool: every TempTower except the anchor. The anchor
    -- (InfiniteStandard) appears only in the trio loop below.
    local testPool = {}
    for id in pairs(TempTowers.Templates) do
        if id ~= AUTO_RUN_ANCHOR then
            table.insert(testPool, id)
        end
    end
    table.sort(testPool)  -- deterministic base order; shuffle below

    -- Fresh Random per call so consecutive sweeps differ. os.time()
    -- + tick() seed gives sub-second resolution for back-to-back
    -- continuous sweeps.
    local rng = Random.new(os.time() * 1000 + math.floor(os.clock() * 1000) % 1000)

    -- Fisher-Yates shuffle in place.
    local function shuffle(list)
        for i = #list, 2, -1 do
            local j = rng:NextInteger(1, i)
            list[i], list[j] = list[j], list[i]
        end
    end

    -- 1. Solos (9 — one per test-pool tower).
    local solos = {}
    for _, id in ipairs(testPool) do
        table.insert(solos, {
            auxIds = { id },
            label  = ("Power + %s"):format(id),
        })
    end
    shuffle(solos)

    -- 2. Duos (C(9, 2) = 36 — all unordered pairs of test-pool
    -- towers; AcornSniper is in 8 of these like every other tower).
    local duos = {}
    for i = 1, #testPool do
        for j = i + 1, #testPool do
            local a, b = testPool[i], testPool[j]
            table.insert(duos, {
                auxIds = { a, b },
                label  = ("Power + %s + %s"):format(a, b),
            })
        end
    end
    shuffle(duos)

    -- 3. Trios with InfiniteStandard baseline (C(9, 2) = 36).
    -- AcornSniper participates as a regular non-anchor here too
    -- (paired with each of the 8 other test-pool towers).
    local trios = {}
    for i = 1, #testPool do
        for j = i + 1, #testPool do
            local a, b = testPool[i], testPool[j]
            table.insert(trios, {
                auxIds = { a, b, AUTO_RUN_ANCHOR },
                label  = ("Power + %s + %s + %s"):format(a, b, AUTO_RUN_ANCHOR),
            })
        end
    end
    shuffle(trios)

    -- Concat: solos → duos → trios. Bucket boundaries are
    -- preserved so STOP RUN N runs in always covers at least
    -- floor(N/3) of each category.
    local queue = {}
    for _, e in ipairs(solos) do table.insert(queue, e) end
    for _, e in ipairs(duos)  do table.insert(queue, e) end
    for _, e in ipairs(trios) do table.insert(queue, e) end

    return queue
end

------------------------------------------------------------
-- assembleTiers — bucket every aux tower into S/A/B/C/D/F per
-- role based on the average wave reached across runs the tower
-- participated in.
--
-- Algorithm:
--   1. For each tower id, sum every finalWave from runs whose
--      auxIds includes it. avgWave = totalWaves / runCount.
--   2. Group towers by role (DPS / Control / Support).
--   3. Sort each role group by avgWave descending.
--   4. Slice each sorted group into 6 buckets (S=top, F=bottom).
--      With 5 DPS / 4 Control / 0 Support, ranks become:
--        DPS:     S A B C D     (rank 1..5 → top..bottom)
--        Control: S A B C       (rank 1..4 → top..bottom)
--      Buckets sit unevenly until we have ≥6 towers per role —
--      good enough for a first read; revisit when more aux land.
--
-- Returns: { DPS = {...}, Control = {...}, Support = {...} }
-- where each entry = { towerId, avgWave, runs, role, tier }
------------------------------------------------------------
local function assembleTiers(results: { any }): { [string]: { any } }
    local perTower = {}
    for _, r in ipairs(results) do
        local isTrio = (#r.auxIds) >= 3
        for _, id in ipairs(r.auxIds) do
            -- The trio anchor (InfiniteStandard) is in every
            -- trio just to standardize the third-aux slot.
            -- Counting those toward its own avgWave would inflate
            -- its run count and pollute its tier with runs that
            -- aren't testing it. Skip the bump when the anchor
            -- appears in a trio. Other towers count normally.
            if id == AUTO_RUN_ANCHOR and isTrio then
                continue
            end
            if not perTower[id] then
                perTower[id] = { runs = 0, totalWaves = 0 }
            end
            perTower[id].runs = perTower[id].runs + 1
            perTower[id].totalWaves = perTower[id].totalWaves + r.finalWave
        end
    end

    local byRole = { DPS = {}, Control = {}, Support = {} }
    for id, agg in pairs(perTower) do
        local role = TempTowers.RoleByTowerId[id] or "DPS"
        table.insert(byRole[role], {
            towerId = id,
            avgWave = agg.totalWaves / math.max(1, agg.runs),
            runs    = agg.runs,
            role    = role,
        })
    end

    local TIER_NAMES = { "S", "A", "B", "C", "D", "F" }
    for _, list in pairs(byRole) do
        table.sort(list, function(a, b) return a.avgWave > b.avgWave end)
        local n = #list
        for i, e in ipairs(list) do
            -- Top performer → S, bottom → F, middle distributed
            -- across A..D. Per Matthew 2026-04-27 "add S tier" —
            -- the previous proportional formula (ceil(i*6/n))
            -- never assigned S when n < 6, so the top DPS / Control
            -- tower always landed in A. New rule guarantees the
            -- best-of-slate gets the top tier (S) regardless of
            -- slate size.
            if i == 1 then
                e.tier = "S"
            elseif n >= 2 and i == n then
                e.tier = "F"
            else
                -- Middle ranks (i = 2..n-1) → tiers A..D (indices 2..5).
                -- For n < 4 the middle has 0 or 1 entry; map to C.
                local middleN = n - 2
                if middleN <= 0 then
                    e.tier = "C"
                else
                    local pos = i - 2  -- 0-indexed position in middle
                    local tierIdx = 2 + math.floor(pos * 4 / middleN)
                    e.tier = TIER_NAMES[math.min(5, tierIdx)]
                end
            end
        end
    end

    return byRole
end

------------------------------------------------------------
-- printTierList — server-log readable dump of the tier list.
-- Emitted at AUTO RUN finish; persistent run history lands later,
-- so for now the server log IS the tier-list display surface.
------------------------------------------------------------
local function printTierList(byRole: { [string]: { any } })
    print("[Infinite] -------- AUTO RUN tier list --------")
    for _, role in ipairs({"DPS", "Control", "Support"}) do
        local list = byRole[role] or {}
        if #list == 0 then
            print(("[Infinite]   %s: (no towers)"):format(role))
        else
            print(("[Infinite]   %s:"):format(role))
            for _, e in ipairs(list) do
                print(("[Infinite]     %s  %-18s  avg wave %5.2f over %d run(s)"):format(
                    e.tier, e.towerId, e.avgWave, e.runs))
            end
        end
    end
    print("[Infinite] -------- end tier list --------")
end

------------------------------------------------------------
-- 3-wave loop. Every run cycles through these test types in order;
-- the wave counter ramps continuously so wave 1 is AOE-easy and wave
-- 30 is Solo-target-very-hard.
--
--   waveIndex % 3 == 1 → AOE      — many basic mobs in tight clumps.
--                                    Exercises splash, Detonator
--                                    chains, knockback.
--   waveIndex % 3 == 2 → Combined — basic + fast + tank mixed.
--                                    Exercises target-priority +
--                                    overall DPS.
--   waveIndex % 3 == 0 → Solo     — one big tank-type mob, HP-scaled
--                                    by RunDifficultyMult. Exercises
--                                    sustained DPS + stun value.
--
-- Each test function returns a list of {mobType, count} pairs.
------------------------------------------------------------
-- Cycle-1 baseline pools come from Config.InfiniteArena.Pools_C1
-- (single source of truth — InfiniteSimulator reads the same).
-- Pool ratios:
--   AOE      — N basic mobs sharing the pool
--   Combined — basic:fast:tank = 4:3:10 ratio, counts 2:2:1
--                                (24x = pool → x = pool/24)
--   Solo     — 1 tank with the full pool
-- All other waves scale via cycleMult (= 1 + (cycle-1) × CycleStep,
-- applied per-Heartbeat in startSpawnerLoop) and loadoutMult
-- (Config.InfiniteArena.LoadoutMult).
--
-- hpMult values back-derive from base mob HPs in WaveData.MOB_TYPES:
--   basic baseHp = 30, fast baseHp = 18, tank baseHp = 90
local TEST_TYPES = {
    AOE = function(_wave)
        local pool = _IA.Pools_C1.AOE
        local count = 6
        return {
            { mobType = "basic", count = count, hpMult = pool / (count * 30) },
        }
    end,

    Combined = function(_wave)
        -- Pool split 4:3:10 across basic:fast:tank, counts 2:2:1.
        -- Per-mob HP = pool × (ratio / 24): basic 4/24, fast 3/24,
        -- tank 10/24. Each per-mob HP / baseHp = the hpMult.
        local pool = _IA.Pools_C1.Combined
        local basicHp = pool * (4 / 24)
        local fastHp  = pool * (3 / 24)
        local tankHp  = pool * (10 / 24)
        return {
            { mobType = "basic", count = 2, hpMult = basicHp / 30 },
            { mobType = "fast",  count = 2, hpMult = fastHp  / 18 },
            { mobType = "tank",  count = 1, hpMult = tankHp  / 90 },
        }
    end,

    Solo = function(_wave)
        local pool = _IA.Pools_C1.Solo
        return {
            { mobType = "tank", count = 1, hpMult = pool / 90 },
        }
    end,
}

-- Wave-mod → test-type name, as a frozen lookup so the spawner is
-- a single dispatch and the heart-death summary can name the test
-- the player failed on (e.g. "failed at wave 12 (AOE)").
local TEST_BY_MOD = { [1] = "AOE", [2] = "Combined", [0] = "Solo" }
local function testTypeForWave(wave: number): string
    return TEST_BY_MOD[wave % 3] or "Combined"
end

------------------------------------------------------------
-- Default tower loadout when no payload is provided (dev quick-
-- entry / fallback). When the loadout panel commits, granLoadout
-- is called with `auxIds` instead and ONLY those towers receive
-- stock. Power Core is always granted regardless.
------------------------------------------------------------
local function grantLoadout(player: Player, auxIds: { string }?)
    -- Build a set of which aux IDs are picked for this run so we can
    -- set Equipped + stock in lockstep below.
    local picked: { [string]: boolean } = {}
    if auxIds then
        for _, towerId in ipairs(auxIds) do
            picked[towerId] = true
        end
    end
    local grantAll = (auxIds == nil)  -- dev shortcut: nil → equip all

    -- Aux towers: stock + Equipped flag together. Picked = template
    -- stock + Equipped=true. Un-picked = stock 0 + Equipped=false.
    -- The Equipped attribute drives hotbar visibility now (see
    -- init.client.lua's buildHotbar revision 2026-04-26): once set,
    -- the slot stays visible even after the tower is placed (stock
    -- → 0). When the loadout changes (re-pick / AUTO RUN round),
    -- Equipped flips and the hotbar rebuilds.
    for towerId, tpl in pairs(TempTowers.Templates) do
        local isEquipped = grantAll or picked[towerId] == true
        if isEquipped then
            player:SetAttribute(towerId .. "Stock", tpl.stock)
            player:SetAttribute(towerId .. "Equipped", true)
        else
            player:SetAttribute(towerId .. "Stock", 0)
            player:SetAttribute(towerId .. "Equipped", false)
        end
    end
    -- Power Core: always granted (1 Core per run is the canonical
    -- ownership rule). Equipped=true so it stays on the hotbar
    -- post-placement.
    player:SetAttribute("PowerStock", 1)
    player:SetAttribute("PowerEquipped", true)

    -- Power Core gets starting Special, Stun, and AOE upgrade
    -- cards on Infinite-mode entry per Matthew 2026-04-26:
    -- "give the core tower the starting special, stun, and aoe
    -- cards on autorun start." These player-attributes get
    -- stamped onto the Core at placement time (see
    -- TowerPlacement / TowerBuilders Power path). Base values
    -- match SPECIAL_EFFECTS in UpgradeCards.lua so a Core with
    -- these starting cards behaves identically to one that
    -- picked the cards organically on Map 1.
    player:SetAttribute("CoreAoeRadius",       4)
    player:SetAttribute("CoreStunDuration",    0.5)
    player:SetAttribute("CoreStunChance",      0.05)
    player:SetAttribute("CoreKnockback",       3)
    player:SetAttribute("CoreKnockbackChance", 0.05)

    player:SetAttribute("DoTStock", 0)
    player:SetAttribute("CCStock", 0)
    player:SetAttribute("CarryingAmmo", 0)
    player:SetAttribute("RerollTokens", 5)
    -- Mark "stock granted" so the client unhides the hotbar via the
    -- standard plumbing (TreeOfLife_Hub watches HasBeenGrantedStock).
    player:SetAttribute("HasBeenGrantedStock", true)
end

------------------------------------------------------------
-- Return portal (built lazily on first entry).
------------------------------------------------------------
local function setupReturnPortal(map4Room: Model, spawnCF: CFrame, exitCallback: (Player) -> ())
    if returnPortalSetup then return end
    returnPortalSetup = true
    local pos = spawnCF.Position + Vector3.new(6, -3, 0)
    local outerRing = Instance.new("Part")
    outerRing.Name = "ReturnPortalOuterRing"
    outerRing.Shape = Enum.PartType.Cylinder
    outerRing.Anchored = true
    outerRing.CanCollide = false
    outerRing.Size = Vector3.new(0.3, 14, 14)
    outerRing.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
    outerRing.Material = Enum.Material.Neon
    outerRing.Color = Color3.fromRGB(80, 220, 100)
    outerRing.Transparency = 0.35
    outerRing.Parent = map4Room

    local disc = Instance.new("Part")
    disc.Name = "ReturnPortalDisc"
    disc.Shape = Enum.PartType.Cylinder
    disc.Anchored = true
    disc.CanCollide = false
    disc.Size = Vector3.new(0.4, 10, 10)
    disc.CFrame = CFrame.new(pos + Vector3.new(0, 0.1, 0))
              * CFrame.Angles(0, 0, math.rad(90))
    disc.Material = Enum.Material.Neon
    disc.Color = Color3.fromRGB(60, 255, 110)
    disc.Transparency = 0.15
    disc.Parent = map4Room

    local labelAnchor = Instance.new("Part")
    labelAnchor.Name = "ReturnLabelAnchor"
    labelAnchor.Anchored = true
    labelAnchor.CanCollide = false
    labelAnchor.Size = Vector3.new(0.2, 0.2, 0.2)
    labelAnchor.Transparency = 1
    labelAnchor.CFrame = CFrame.new(pos + Vector3.new(0, 6, 0))
    labelAnchor.Parent = map4Room
    local billboard = Instance.new("BillboardGui")
    billboard.Size = UDim2.fromOffset(220, 50)
    billboard.LightInfluence = 0
    billboard.AlwaysOnTop = true
    billboard.MaxDistance = 200
    billboard.Parent = labelAnchor
    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Text = "RETURN TO HUB"
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 28
    label.TextColor3 = Color3.fromRGB(220, 255, 230)
    label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    label.TextStrokeTransparency = 0.4
    label.Parent = billboard

    local lastExitAt = {}
    disc.Touched:Connect(function(other)
        if not other or not other.Parent then return end
        if other.Name ~= "HumanoidRootPart" then return end
        local player = Players:GetPlayerFromCharacter(other.Parent)
        if not player then return end
        local now = os.clock()
        if now - (lastExitAt[player.UserId] or 0) < 1.0 then return end
        lastExitAt[player.UserId] = now
        exitCallback(player)
    end)
    print("[Infinite] return portal wired in pickle dimension")
end

function Infinite.setup(ctx)
    -- Hydrate cumulative pool from DataStore on server boot.
    -- Lazy-loaded; falls back to an empty list if DataStore is
    -- unavailable (Studio without API access). Per Matthew
    -- 2026-04-26: "hook up the data store so we can save autorun
    -- data."
    do
        local loaded = InfiniteRunHistoryStore.loadCumulative()
        if loaded and #loaded > 0 then
            cumulativeResults = loaded
            print(("[Infinite] cumulative pool hydrated from DataStore — %d run(s)"):format(
                #cumulativeResults))
        end
        currentBalanceVersion = InfiniteRunHistoryStore.getBalanceVersion()
        print(("[Infinite] active balance version = %d"):format(currentBalanceVersion))
    end

    local function getHubSpawnCF(): CFrame
        return ctx.HUB_SPAWN_CF or CFrame.new(0, 5, 5)
    end
    local function getMap4SpawnCF(): CFrame
        return ctx.MAP4_PLAYER_SPAWN_CF or CFrame.new(8000, 105, 0)
    end

    local enterRemote = Remotes.getOrCreate(Remotes.Names.EnterInfinite, "RemoteEvent")
    local exitRemote  = Remotes.getOrCreate(Remotes.Names.ExitInfinite, "RemoteEvent")
    local pickRemote  = Remotes.getOrCreate(Remotes.Names.PickInfiniteScenario, "RemoteEvent")
    local roundRemote = Remotes.getOrCreate(Remotes.Names.InfiniteRoundUpdate, "RemoteEvent")
    local autoPlaceRemote = Remotes.getOrCreate(Remotes.Names.InfiniteAutoPlace, "RemoteEvent")
    local countdownRemote = Remotes.getOrCreate(Remotes.Names.InfiniteCountdown, "RemoteEvent")
    local skipRemote      = Remotes.getOrCreate(Remotes.Names.InfiniteSkipCountdown, "RemoteEvent")
    local forceExitRemote = Remotes.getOrCreate(Remotes.Names.InfiniteForceExit, "RemoteEvent")
    local totalResetRemote = Remotes.getOrCreate(Remotes.Names.InfiniteTotalReset, "RemoteEvent")
    local autoRunRemote        = Remotes.getOrCreate(Remotes.Names.InfiniteAutoRun, "RemoteEvent")
    local autoRunProgressRemote = Remotes.getOrCreate(Remotes.Names.InfiniteAutoRunProgress, "RemoteEvent")
    local autoRunDoneRemote    = Remotes.getOrCreate(Remotes.Names.InfiniteAutoRunDone, "RemoteEvent")
    local runCompletedRemote   = Remotes.getOrCreate(Remotes.Names.InfiniteRunCompleted, "RemoteEvent")
    local lastSweepReqRemote   = Remotes.getOrCreate(Remotes.Names.InfiniteRequestLastSweep, "RemoteEvent")
    local lastSweepDataRemote  = Remotes.getOrCreate(Remotes.Names.InfiniteLastSweepData, "RemoteEvent")
    local sweepHistoryReqRemote  = Remotes.getOrCreate(Remotes.Names.InfiniteRequestSweepHistory, "RemoteEvent")
    local sweepHistoryDataRemote = Remotes.getOrCreate(Remotes.Names.InfiniteSweepHistoryData, "RemoteEvent")
    local loadSweepByIdxRemote   = Remotes.getOrCreate(Remotes.Names.InfiniteLoadSweepByIndex, "RemoteEvent")
    local loadByVersionRemote    = Remotes.getOrCreate(Remotes.Names.InfiniteLoadByBalanceVersion, "RemoteEvent")
    local balanceResetRemote     = Remotes.getOrCreate(Remotes.Names.InfiniteBalanceReset, "RemoteEvent")
    local visualsToggleRemote    = Remotes.getOrCreate(Remotes.Names.InfiniteVisualsToggle, "RemoteEvent")
    local simulateRemote         = Remotes.getOrCreate(Remotes.Names.InfiniteSimulate, "RemoteEvent")
    local simulateDataRemote     = Remotes.getOrCreate(Remotes.Names.InfiniteSimulateData, "RemoteEvent")
    local stopRunRemote          = Remotes.getOrCreate(Remotes.Names.InfiniteStopRun, "RemoteEvent")
    local exportDataRemote       = Remotes.getOrCreate(Remotes.Names.InfiniteExportData, "RemoteEvent")
    local exportDataReadyRemote  = Remotes.getOrCreate(Remotes.Names.InfiniteExportDataReady, "RemoteEvent")

    -- Forward-decl: STOP RUN / forceExit handlers below need to call
    -- exit() (the canonical run-teardown path), but its assignment
    -- lives ~900 lines later because it depends on enter / enterIdle
    -- / startSpawnerLoop. Hoisted here per CLAUDE.md "Lua resolves
    -- free variables at function-DEFINITION time" — without this
    -- hoist the STOP RUN handler captured the global `exit` (nil)
    -- and crashed at click time: 02:45:13 [Infinite] line 779:
    -- attempt to call a nil value. Re-declared at the original
    -- site below as a `do nothing` to keep the existing assignment
    -- pattern; this hoisted forward-decl is the canonical local.
    local enter, exit, enterIdle

    -- EXPORT DATA: assembles the cumulative pool + per-tower
    -- aggregates + per-pair stats + last sweep tiers into a single
    -- JSON string for offline analysis. Per Matthew 2026-04-27.
    -- Computed server-side because cumulativeResults lives here;
    -- client receives the encoded string via InfiniteExportDataReady
    -- and dumps it to F9 + a copyable modal.
    exportDataRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        local HttpService = game:GetService("HttpService")

        -- Per-tower aggregate over cumulativeResults.
        local towerAgg = {}
        for _, r in ipairs(cumulativeResults) do
            local n = (r.auxIds and #r.auxIds) or 0
            local isTrio = n >= 3
            for _, id in ipairs(r.auxIds or {}) do
                if not (id == AUTO_RUN_ANCHOR and isTrio) then
                    towerAgg[id] = towerAgg[id] or { runs = 0, totalWave = 0, byCategory = { Solo = 0, Duo = 0, Trio = 0 } }
                    towerAgg[id].runs = towerAgg[id].runs + 1
                    towerAgg[id].totalWave = towerAgg[id].totalWave + (r.finalWave or 0)
                    if n == 1 then towerAgg[id].byCategory.Solo = towerAgg[id].byCategory.Solo + 1
                    elseif n == 2 then towerAgg[id].byCategory.Duo = towerAgg[id].byCategory.Duo + 1
                    elseif n >= 3 then towerAgg[id].byCategory.Trio = towerAgg[id].byCategory.Trio + 1
                    end
                end
            end
        end
        for _, agg in pairs(towerAgg) do
            agg.avgWave = agg.totalWave / math.max(1, agg.runs)
        end

        -- Per-unordered-pair (combo) aggregate over duo/trio results.
        local pairAgg = {}
        local function pairKey(a, b)
            if a > b then a, b = b, a end
            return a .. "+" .. b
        end
        for _, r in ipairs(cumulativeResults) do
            local aux = r.auxIds or {}
            local n = #aux
            if n >= 2 then
                local realAux = {}
                for _, id in ipairs(aux) do
                    if not (id == AUTO_RUN_ANCHOR and n >= 3) then
                        table.insert(realAux, id)
                    end
                end
                for i = 1, #realAux do
                    for j = i + 1, #realAux do
                        local key = pairKey(realAux[i], realAux[j])
                        pairAgg[key] = pairAgg[key] or { runs = 0, totalWave = 0 }
                        pairAgg[key].runs = pairAgg[key].runs + 1
                        pairAgg[key].totalWave = pairAgg[key].totalWave + (r.finalWave or 0)
                    end
                end
            end
        end
        for _, agg in pairs(pairAgg) do
            agg.avgWave = agg.totalWave / math.max(1, agg.runs)
        end

        local config = {
            cycleStep       = CYCLE_STEP,
            loadoutMults    = {
                ["1"] = _IA.LoadoutMult[1],
                ["2"] = _IA.LoadoutMult[2],
                ["3"] = _IA.LoadoutMult[3],
            },
            anchor          = AUTO_RUN_ANCHOR,
            pools_C1        = _IA.Pools_C1,
            heartHp         = (Config.Map4 and Config.Map4.HeartMaxHp) or 50000,
            maxAutoRunWave  = MAX_AUTO_RUN_WAVE,
        }

        -- Full payload — printed to F9 (no length cap there). Includes
        -- the bulky cumulativeResults pool which can run 200k+ chars
        -- once you've accumulated 1k+ runs.
        local fullPayload = {
            schemaVersion = 1,
            exportedAt    = os.time(),
            config = config,
            cumulativeCount = #cumulativeResults,
            cumulativeResults = cumulativeResults,
            towerAggregate  = towerAgg,
            pairAggregate   = pairAgg,
            lastSweep       = lastSweep,
            simulatedSweep  = simulatedSweep,
            lastRunStats    = lastRunStats,
        }

        -- Summary payload — small enough to fit in the Roblox TextBox
        -- 200k-char limit (tower + pair aggregates only; no per-run
        -- pool). Per Matthew 2026-04-27 bug report: the modal crashed
        -- on 234k-char strings because Roblox capped at 200k. F9 keeps
        -- the full JSON; modal copy-friendly view shows the summary.
        local summaryPayload = {
            schemaVersion = 1,
            exportedAt    = os.time(),
            config = config,
            cumulativeCount = #cumulativeResults,
            -- cumulativeResults intentionally OMITTED — see F9 for full
            towerAggregate  = towerAgg,
            pairAggregate   = pairAgg,
            lastSweep       = lastSweep and {
                tiers       = lastSweep.tiers,
                completedAt = lastSweep.completedAt,
                total       = lastSweep.total,
                aborted     = lastSweep.aborted,
                -- results omitted (also large)
            } or nil,
            lastRunStats    = lastRunStats,
        }

        local okFull, fullJson = pcall(HttpService.JSONEncode, HttpService, fullPayload)
        if not okFull then
            warn(("[Infinite] EXPORT DATA encode failed: %s"):format(tostring(fullJson)))
            return
        end
        local okSum, summaryJson = pcall(HttpService.JSONEncode, HttpService, summaryPayload)
        if not okSum then
            warn(("[Infinite] EXPORT DATA summary encode failed: %s"):format(tostring(summaryJson)))
            summaryJson = nil
        end

        print(("[Infinite] EXPORT DATA — %d cumulative runs, %d towers, %d pairs, full %d chars, summary %d chars"):format(
            #cumulativeResults,
            (function() local n = 0; for _ in pairs(towerAgg) do n = n + 1 end; return n end)(),
            (function() local n = 0; for _ in pairs(pairAgg) do n = n + 1 end; return n end)(),
            #fullJson, summaryJson and #summaryJson or 0))
        exportDataReadyRemote:FireClient(player, {
            json    = fullJson,      -- F9 dump; can be huge
            summary = summaryJson,    -- modal display; <200k
        })
    end)

    -- STOP RUN: clear the continuous-sweep flag so the current
    -- sweep is the last one, then immediately abort the in-flight
    -- run via the same path RUN RESET / forceExit uses. Per
    -- Matthew 2026-04-27.
    stopRunRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        if not autoRun.active then return end
        autoRun.continuous = false  -- finalize() will go idle now
        print(("[Infinite] %s requested STOP RUN — aborting after %d sweep(s) + %d run(s) of current sweep")
            :format(player.Name, autoRun.sweepNum or 0, #(autoRun.results or {})))
        -- Mirror forceExit's abort-current-sweep path so we don't
        -- have to wait for the heart to die naturally.
        if State.activePlayer == player then
            if autoRun.results and #autoRun.results > 0 then
                local tiers = assembleTiers(autoRun.results)
                printTierList(tiers)
                lastSweep = {
                    tiers          = tiers,
                    results        = autoRun.results,
                    completedAt    = os.time(),
                    total          = autoRun.total,
                    aborted        = true,
                    balanceVersion = currentBalanceVersion,
                }
                for _, r in ipairs(autoRun.results) do
                    table.insert(cumulativeResults, r)
                end
                InfiniteRunHistoryStore.saveCumulative(cumulativeResults)
                InfiniteRunHistoryStore.append(lastSweep)
            end
            autoRun.active   = false
            autoRun.queue    = nil
            autoRun.current  = nil
            autoRun.results  = nil
            autoRun.total    = 0
            autoRun.sweepNum = 0
            StatLedger.setRecordingEnabled(false)
            -- Use exit() to tear down the active loadout (returns
            -- to swamp idle, NOT hub).
            exit(player)
        end
    end)

    -- SIMULATE: pure-math closed-form sweep over the AUTO RUN
    -- queue. Results stored in `simulatedSweep` (parallel cache,
    -- DOES NOT touch cumulativeResults / lastSweep). Per Matthew
    -- 2026-04-27: "keep this data separate until I can validate
    -- it." Server prints the sim tier list to the log + fires
    -- the data back to the client for optional display.
    --
    -- Phase 1 of project_simulator_improvement.md: extended to
    -- compare each sim result against the matching real-sweep
    -- entries in cumulativeResults via InfiniteValidator. The F9
    -- log now shows BOTH the sim tier list AND the sim-vs-real
    -- delta breakdown by category / role-mix / carries-tower so
    -- every later phase has a measurable success metric (did the
    -- median |delta| shrink?). The full per-loadout table + buckets
    -- ride along on the simulateDataRemote payload so the admin
    -- panel's VALIDATE section can render them.
    simulateRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        local startWall = os.clock()
        local queue = buildAutoRunQueue()
        local results = InfiniteSimulator.runSweep(queue)
        local elapsed = os.clock() - startWall

        local tiers = assembleTiers(results)
        print(("[Infinite] SIMULATE complete in %.3f s — %d loadouts evaluated"):format(
            elapsed, #results))
        print("[Infinite] -------- SIMULATED tier list (closed-form math; not validated) --------")
        printTierList(tiers)
        print("[Infinite] -------- end SIMULATED tier list --------")

        -- Sim-vs-real delta report (only meaningful if the player
        -- has accumulated some real sweeps; if cumulativeResults
        -- is empty every loadout is "untracked").
        local validationReport = InfiniteValidator.compare({
            sim           = results,
            real          = cumulativeResults,
            roleByTowerId = TempTowers.RoleByTowerId,
        })
        InfiniteValidator.printReport(validationReport)

        simulatedSweep = {
            tiers       = tiers,
            results     = results,
            completedAt = os.time(),
            total       = #results,
            simulated   = true,
            validation  = validationReport,
        }
        simulateDataRemote:FireClient(player, simulatedSweep)
    end)

    -- VISUALS toggle: flips Workspace.InfiniteVisuals on each
    -- client fire. Default off. Per Matthew 2026-04-27.
    if Workspace:GetAttribute("InfiniteVisuals") == nil then
        Workspace:SetAttribute("InfiniteVisuals", false)
    end
    visualsToggleRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        local cur = Workspace:GetAttribute("InfiniteVisuals") == true
        Workspace:SetAttribute("InfiniteVisuals", not cur)
        print(("[Infinite] %s toggled VISUALS → %s"):format(
            player.Name, (not cur) and "ON" or "OFF"))
    end)

    -- Apply the VISUALS attribute to all currently-spawned mobs
    -- whenever it changes. Without this, toggling the button only
    -- affects FUTURE mobs (MobFactory.makeMob reads the attribute
    -- at spawn time) — existing mobs would keep their original
    -- transparency.
    Workspace:GetAttributeChangedSignal("InfiniteVisuals"):Connect(function()
        local visible = Workspace:GetAttribute("InfiniteVisuals") == true
        local Tags = require(Shared:WaitForChild("Tags"))
        for _, mob in ipairs(CollectionService:GetTagged(Tags.Mob)) do
            if mob:IsA("BasePart") then
                mob.Transparency = visible and 0 or 1
            end
        end
    end)

    -- Auto-toggle VISUALS based on game speed per Matthew
    -- 2026-04-27: "turn visuals on at 20x and lower, turn them
    -- off at 50x and higher automatically." Speeds in the ladder
    -- are {1, 2, 3, 5, 10, 20, 50, 100, 200, 400}; the threshold
    -- between low-speed-visible and high-speed-hidden sits at the
    -- 20→50 jump. Manual button still works as a one-off override
    -- but a subsequent speed change re-applies the rule.
    local function applyVisualsForSpeed()
        local speed = Workspace:GetAttribute("GameSpeed") or 1
        local shouldShow = speed <= 20
        if Workspace:GetAttribute("InfiniteVisuals") ~= shouldShow then
            Workspace:SetAttribute("InfiniteVisuals", shouldShow)
        end
    end
    Workspace:GetAttributeChangedSignal("GameSpeed"):Connect(applyVisualsForSpeed)
    -- Apply current state on boot so a player entering Map 4 at
    -- 1× starts with VISUALS = true without needing to bump speed.
    applyVisualsForSpeed()
    skipRemote.OnServerEvent:Connect(function(player)
        if State.activePlayer ~= player then return end
        State.skipCountdown = true
    end)
    -- Pre-create the picker remote so HubWorld can FireClient on it.
    Remotes.getOrCreate(Remotes.Names.ShowInfiniteScenarioPicker, "RemoteEvent")

    local function teleportTo(player: Player, cf: CFrame)
        local character = player.Character
        if not character then return end
        local hrp = character:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        hrp.CFrame = cf
    end

    -- Forward decls so functions defined earlier can reference
    -- functions defined later. Lua's local-binding rule is: the
    -- reference must point to a local declared BEFORE the closure,
    -- otherwise it falls through to globals (and becomes nil).
    -- (enter / exit / enterIdle are forward-declared near the top
    -- of setup() so the STOP RUN / forceExit / EXPORT DATA remote
    -- handlers above can call exit() — they're defined in this
    -- order:
    --   - startSpawnerLoop references `exit` (AUTO RUN wave cap)
    --   - exit references `enter` (AUTO RUN dequeue → restart)
    --   - enter references `enterIdle` (auto-route if not in arena)
    -- Re-declaring here would shadow the hoisted local, so the
    -- assignments below land on the SAME upvalues the handlers
    -- already captured. Per CLAUDE.md "Lua resolves free variables
    -- at function-DEFINITION time".)

    ------------------------------------------------------------
    -- applyWaveCycleUpgrades — fired after every Boss wave (wave %
    -- 3 == 0). Walks every Map 4 tower owned by `player` and stamps
    -- a common-mean upgrade onto its Damage / FireRate / Range
    -- attributes.
    --
    -- State (per-run; reset on enter()):
    --   State.auxRangeMult / State.coreRangeMult — cumulative
    --     range multipliers. Cards stop applying range once these
    --     hit RANGE_CAP_MULT (2.0).
    --   State.auxRangeCapped / State.coreRangeCapped — once these
    --     flip true, damage + firerate cards apply at 1.5× effect.
    ------------------------------------------------------------
    local function applyWaveCycleUpgrades(player: Player)
        if not player or not player.Parent then return end
        local map4ColOffset = ctx.MAP4_COL_OFFSET or 225

        -- Compute current effects per category. If range is capped,
        -- damage + firerate get the 1.5× boost.
        local function effectsFor(capped: boolean)
            local boost = capped and POST_CAP_EFFECT_BOOST or 1.0
            return {
                damageDelta   = COMMON_DAMAGE_FLAT * boost,
                fireRateDelta = COMMON_FIRERATE_DELTA * boost,
                rangeDelta    = (not capped) and COMMON_RANGE_DELTA or 0,
            }
        end
        local auxFx  = effectsFor(State.auxRangeCapped == true)
        local coreFx = effectsFor(State.coreRangeCapped == true)

        local touched = 0
        for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local model = base.Parent
            if model and model:IsA("Model") then
                local owner = model:GetAttribute("Owner")
                local anchorCol = model:GetAttribute("AnchorCol") or -1
                if owner == player.UserId and anchorCol >= map4ColOffset then
                    local towerType = model:GetAttribute("TowerType")
                    local fx = (towerType == "Power") and coreFx or auxFx
                    -- Damage: flat add. FireRate: % bump. Range: %
                    -- bump unless this category is range-capped.
                    local d = model:GetAttribute("Damage")
                    if type(d) == "number" then
                        model:SetAttribute("Damage", d + fx.damageDelta)
                    end
                    local fr = model:GetAttribute("FireRate")
                    if type(fr) == "number" then
                        model:SetAttribute("FireRate", fr * (1 + fx.fireRateDelta))
                    end
                    if fx.rangeDelta > 0 then
                        local rg = model:GetAttribute("Range")
                        if type(rg) == "number" then
                            model:SetAttribute("Range", rg * (1 + fx.rangeDelta))
                        end
                    end
                    touched = touched + 1
                end
            end
        end

        -- Bump cumulative range multipliers (only if not yet capped).
        -- Once they cross RANGE_CAP_MULT, flip the capped flag so
        -- next cycle's effectsFor() returns boosted damage/firerate.
        if not State.auxRangeCapped then
            State.auxRangeMult = (State.auxRangeMult or 1.0) * (1 + COMMON_RANGE_DELTA)
            if State.auxRangeMult >= RANGE_CAP_MULT then
                State.auxRangeCapped = true
            end
        end
        if not State.coreRangeCapped then
            State.coreRangeMult = (State.coreRangeMult or 1.0) * (1 + COMMON_RANGE_DELTA)
            if State.coreRangeMult >= RANGE_CAP_MULT then
                State.coreRangeCapped = true
            end
        end

        -- (silenced wave-cycle upgrade trace — was 10× per run × 81 runs of log spam)
        local _ = touched
    end

    ------------------------------------------------------------
    -- Spawner loop. Cycles through the 3 test types every 3 waves,
    -- ramping RunDifficultyMult each wave. Stops when State.active
    -- flips false (heart death / manual exit).
    ------------------------------------------------------------
    local function spawnWave(testType: string, wave: number)
        local fn = TEST_TYPES[testType]
        if not fn then return end
        local wctx = waveCtx()
        if not wctx then
            warn("[Infinite] WaveCtxBridge.ctx is nil — wave system not ready?")
            return
        end
        local groups = fn(wave)
        local waypoints = wctx.getWaypoints()
        if not waypoints or #waypoints == 0 then
            warn("[Infinite] no waypoints — map 4 not active?")
            return
        end
        -- Track the SET of mobs spawned this wave so we can compute
        -- mob-kill ratio at heart-death time. Stored in State so
        -- exit() can read it.
        State.waveMobs = {}
        for _, group in ipairs(groups) do
            local hpMult = group.hpMult or 1.0
            for _ = 1, group.count do
                if not State.active then return end
                local mob = wctx.makeMob(group.mobType, waypoints, hpMult)
                if mob then
                    mob:SetAttribute("MapId", 4)
                    State.mobsSpawnedThisWave = (State.mobsSpawnedThisWave or 0) + 1
                    -- Capture starting HP per mob so exit() can
                    -- compute damage-done / hp-pool ratio. Mob's
                    -- Health attribute = max at spawn (MobFactory
                    -- sets both Health + MaxHealth to the same
                    -- value pre-stamp).
                    State.waveMobs[mob] = mob:GetAttribute("Health") or 1
                end
                -- Tiny stagger between mobs in a group so they don't
                -- spawn in the exact same frame. SCALED BY gameSpeed
                -- per Matthew 2026-04-27: at 400× the wallclock 0.08 s
                -- gap was 32 game-seconds between spawns, giving
                -- towers a huge per-mob clear window — loadouts
                -- inflated to wave 23 vs the expected ~13. Now the
                -- gap stays at 0.08 game-seconds regardless of speed,
                -- so spawn cadence matches what real-time players
                -- would experience.
                local speed = math.max(1, Workspace:GetAttribute("GameSpeed") or 1)
                task.wait(0.08 / speed)
            end
        end
    end

    local function startSpawnerLoop(myToken: number)
        task.spawn(function()
            local diff = (Config.Map4 and Config.Map4.Difficulty) or {}
            local intervalSec = diff.IntervalSec or 8
            -- AUTO RUN: skip the 5s pre-wave countdown so the sweep
            -- doesn't spend ~6 minutes on countdowns alone (5s × 73
            -- runs). Setting skipCountdown=true makes the loop below
            -- break immediately on first iteration.
            if autoRun.active then
                State.skipCountdown = true
            end
            -- AUTO RUN placement-detect: poll the Map 4 tower count
            -- until it stops increasing (placement burst settled),
            -- then proceed. Per Matthew 2026-04-26: "lower the time
            -- between auto run sections... just wait until all
            -- towers are placed then start." Replaces the prior
            -- wall-clock pause that scaled with speed.
            --
            -- Stable-for window = 0.3s (auto-place fires PlaceTower
            -- in tight burst client-side; once count stops climbing
            -- for 300ms the burst is done). Hard cap = 4s in case
            -- something blocks placement, so the sweep doesn't hang.
            if autoRun.active then
                local map4ColOffset = ctx.MAP4_COL_OFFSET or 225
                local function countMap4Towers()
                    local n = 0
                    for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                        local model = base.Parent
                        if model and (model:GetAttribute("AnchorCol") or -1) >= map4ColOffset then
                            n = n + 1
                        end
                    end
                    return n
                end
                local lastCount, stableSince = 0, os.clock()
                local hardCap = os.clock() + 4
                while State.active and State.spawnerToken == myToken do
                    if os.clock() > hardCap then break end
                    local n = countMap4Towers()
                    if n > lastCount then
                        lastCount = n
                        stableSince = os.clock()
                    elseif n > 0 and (os.clock() - stableSince) > 0.3 then
                        break  -- placements stable; proceed
                    end
                    task.wait(0.1)
                end
                if not State.active or State.spawnerToken ~= myToken then return end
            end
            -- 5-second pre-wave countdown so the player has time to read
            -- the auto-place layout + pause if they want to inspect a
            -- tower before mobs start hitting. Click the countdown
            -- overlay to skip (sets State.skipCountdown via remote).
            for n = 5, 1, -1 do
                if not State.active or State.spawnerToken ~= myToken then return end
                if State.skipCountdown then break end
                if State.activePlayer then
                    countdownRemote:FireClient(State.activePlayer, { countdown = n })
                end
                GameTime.adaptiveWait(1, function()
                    return State.active and State.spawnerToken == myToken
                       and not State.skipCountdown
                end)
            end
            -- Fire 0 to clear the countdown overlay client-side just before wave 1.
            if State.activePlayer then
                countdownRemote:FireClient(State.activePlayer, { countdown = 0 })
            end
            while State.active and State.spawnerToken == myToken do
                -- Capture the just-cleared wave's HP-pool + damage
                -- numbers BEFORE the wave counter ticks forward and
                -- spawnWave clears State.waveMobs. Pushed onto a
                -- rolling history capped at the last 2 entries so
                -- exit()'s fractional calculation can sum 3 waves
                -- (current + last 2) per Matthew 2026-04-26: "when
                -- calculating partial wave cleared, include the
                -- total damage done over the last 3 waves divided
                -- by the total hp pool for those 3 waves." Skip on
                -- the first iteration when waveMobs is still the
                -- pre-run empty table.
                if State.waveMobs and next(State.waveMobs) then
                    local prevStart, prevDamage = 0, 0
                    for mob, startHp in pairs(State.waveMobs) do
                        prevStart = prevStart + startHp
                        if mob.Parent then
                            local hp = mob:GetAttribute("Health") or 0
                            prevDamage = prevDamage + math.max(0, startHp - hp)
                        else
                            prevDamage = prevDamage + startHp
                        end
                    end
                    if prevStart > 0 then
                        State.recentWaves = State.recentWaves or {}
                        table.insert(State.recentWaves,
                            { start = prevStart, damage = prevDamage })
                        while #State.recentWaves > 2 do
                            table.remove(State.recentWaves, 1)
                        end
                    end
                end

                State.wave = State.wave + 1
                State.waveStartedAt = os.clock()
                State.mobsSpawnedThisWave = 0
                -- AUTO RUN cap: if a loadout survives MAX_AUTO_RUN_WAVE
                -- waves it's strong enough to S-tier; cap the result
                -- and let exit() advance the queue. Without this, a
                -- broken combo could stall the sweep indefinitely.
                if autoRun.active and State.wave > MAX_AUTO_RUN_WAVE then
                    print(("[Infinite] AUTO RUN: loadout exceeded wave %d cap — capping + advancing")
                        :format(MAX_AUTO_RUN_WAVE))
                    State.wave = MAX_AUTO_RUN_WAVE
                    if State.activePlayer then
                        -- exit() runs in this coroutine's context; it
                        -- bumps spawnerToken so this while loop ends
                        -- naturally on the next predicate check.
                        task.spawn(function()
                            local p = State.activePlayer
                            if p then exit(p) end
                        end)
                    end
                    return
                end
                local testType = testTypeForWave(State.wave)
                -- Set the run-difficulty multiplier BEFORE spawning so
                -- MobFactory.makeMob picks it up (mob HP ramps per wave).
                -- Compounds:
                --   1. slider's starting difficulty
                --   2. per-wave geometric ramp (hpPerRound)
                --   3. per-sequence step bonus — every completed
                --      AOE/Mixed/Boss trio adds a SEQUENCE_HP_BONUS
                --      multiplier on top, so sequence transitions
                --      feel like meaningful difficulty steps. Per
                --      Matthew 2026-04-26: "increase hp ramp in
                --      between the sequences for mobs."
                -- Cycle-based scaling. Step softened from 0.4 → 0.2
                -- per Matthew 2026-04-26: "the hp numbers are way
                -- too high." At step 0.4 a strong solo loadout
                -- reached W19-20 with mob HPs ≈ 2,267-7,083, which
                -- read as trio-tier numbers visually. Step 0.2
                -- halves the ramp:
                --   C1 (W1-3)   = 1.0
                --   C2 (W4-6)   = 1.2
                --   C3 (W7-9)   = 1.4
                --   C4 (W10-12) = 1.6
                --   C5 (W13-15) = 1.8
                --   C6 (W16-18) = 2.0
                --   C7 (W19-21) = 2.2
                --
                -- loadoutMult bakes solo/duo/trio difficulty into a
                -- flat multiplier on top:
                --   solo (1 aux)  = 1.00
                --   duo  (2 aux)  = 1.25
                --   trio (3 aux)  = 1.60
                -- (Set in enter() as State.startingDifficulty.)
                --
                -- Final HP per mob = baseHp × hpMult × cycleMult ×
                --   loadoutMult.
                local cycle = math.ceil(State.wave / 3)
                local cycleMult   = 1 + (cycle - 1) * CYCLE_STEP
                local loadoutMult = State.startingDifficulty or 1.0
                Workspace:SetAttribute("RunDifficultyMult", cycleMult * loadoutMult)
                if State.activePlayer then
                    roundRemote:FireClient(State.activePlayer, {
                        wave     = State.wave,
                        testType = testType,
                    })
                end
                -- (silenced per-wave trace — was 30 × 81 = 2400+ lines per sweep)
                spawnWave(testType, State.wave)
                if not State.active or State.spawnerToken ~= myToken then break end
                -- Smart inter-wave wait. Default cap = intervalSec, but
                -- BOSS waves (wave % 3 == 0 = Solo single tank) get an
                -- effectively unbounded wait — the next wave is AOE,
                -- and the user doesn't want a fresh AOE swarm spawning
                -- while the boss is still alive. Per Matthew 2026-04-26:
                -- "when auto running, do not start the next aoe wave
                -- until the boss wave is cleared." 600s is a sentinel
                -- for "wait until they're all dead" — if a boss takes
                -- 10 minutes the run is broken anyway and the heart-
                -- death listener / wave cap will end it cleanly.
                --
                -- For non-boss waves we keep the intervalSec cap so a
                -- weak loadout doesn't get an unfair grace period; the
                -- cap matches the original cadence used for AOE→Combined
                -- and Combined→Boss transitions.
                local isBossWave = (State.wave % 3 == 0)
                local waitCap = isBossWave and 600 or intervalSec
                local waveEndMin = os.clock() + 1
                GameTime.adaptiveWait(waitCap, function()
                    if not State.active or State.spawnerToken ~= myToken then
                        return false  -- abort
                    end
                    if os.clock() < waveEndMin then return true end  -- below min gap, keep waiting
                    local wctx = waveCtx()
                    if not wctx or not wctx.activeMobs then return true end
                    -- If activeMobs has any entry, keep waiting; once
                    -- it's empty, abort the wait and proceed to next wave.
                    for _ in pairs(wctx.activeMobs) do
                        return true  -- at least one mob alive
                    end
                    return false  -- all dead, advance
                end)
                -- Auto-upgrade after every Boss wave (wave % 3 == 0).
                -- The 3-wave sequence ran cleanly (mobs cleared above);
                -- now stamp 6 common-mean cards onto every tower
                -- (damage / firerate / range × aux + core). Range
                -- caps at 2× base, then damage + firerate get a 1.5×
                -- effect boost. See applyWaveCycleUpgrades for the
                -- exact math.
                if State.active and State.spawnerToken == myToken
                   and State.wave % 3 == 0 and State.activePlayer then
                    applyWaveCycleUpgrades(State.activePlayer)
                end
            end
        end)
    end

    -- Tear down every tower the player placed on Map 4. Identified by
    -- AnchorCol >= MAP4_COL_OFFSET (everything map-4-side; Map4 cols
    -- start at 225 = ctx.MAP4_COL_OFFSET). Without this, exiting and
    -- re-entering the dimension stacks towers from prior runs on top
    -- of the auto-place pattern, which is bad for stat capture and
    -- visual sanity.
    local function destroyMap4Towers(player: Player)
        local map4ColOffset = ctx.MAP4_COL_OFFSET or 225
        local gridState = ctx.gridState
        local destroyed = 0
        for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local model = base.Parent
            if model and model:IsA("Model") then
                local owner = model:GetAttribute("Owner")
                local anchorCol = model:GetAttribute("AnchorCol") or -1
                if owner == player.UserId and anchorCol >= map4ColOffset then
                    -- Free the grid cells this tower occupied BEFORE
                    -- destroying the model. Without this, gridState
                    -- stays marked "occupied" and the next round's
                    -- auto-place can't reuse the cells (root cause
                    -- of "AUTO RUN auto-place stops working after
                    -- round 1" — Matthew 2026-04-26 playtest). Same
                    -- pattern as the SellTower path in
                    -- TowerPlacement.lua.
                    if gridState then
                        local anchorRow = model:GetAttribute("AnchorRow") or 0
                        local fw = model:GetAttribute("FootprintW") or 0
                        local fd = model:GetAttribute("FootprintD") or 0
                        for dc = 0, fw - 1 do
                            for dr = 0, fd - 1 do
                                local c, r = anchorCol + dc, anchorRow + dr
                                if gridState[c] and gridState[c][r] == "occupied" then
                                    gridState[c][r] = "open"
                                end
                            end
                        end
                    end
                    model:Destroy()
                    destroyed = destroyed + 1
                end
            end
        end
        -- Broadcast the freshly-cleared grid so the client's localGrid
        -- matches server reality before the next auto-place fits()
        -- check runs (otherwise client sees old "occupied" state and
        -- auto-place's fits() returns false).
        if destroyed > 0 and ctx.broadcastGrid then
            ctx.broadcastGrid()
        end
        -- (silenced destroyMap4Towers trace — fires per-loadout
        -- transition during AUTO RUN, log spam.)
        local _ = destroyed
    end

    local function stopSpawner()
        State.active = false
        State.spawnerToken = State.spawnerToken + 1
        if State.heartConn then
            State.heartConn:Disconnect()
            State.heartConn = nil
        end
        Workspace:SetAttribute("RunDifficultyMult", 1.0)
        local wctx = waveCtx()
        if wctx and wctx.clearAllMobs then wctx.clearAllMobs() end
    end

    -- exit() is the canonical run-end path. Called from:
    --   - heart-death listener (hookHeartDeath)
    --   - return portal Touched
    --   - admin RUN RESET (forceExitRemote)
    --   - PlayerRemoving (only does the teardown half)
    --   - AUTO RUN wave cap (when a loadout exceeds MAX_AUTO_RUN_WAVE)
    --
    -- AUTO RUN flow: when autoRun.active, this captures the run's
    -- finalWave instead of returning to hub, then either dequeues
    -- the next loadout (recursive enter()) or finalizes the sweep.
    -- Assigned to the forward-declared local `exit` so other
    -- functions defined earlier (startSpawnerLoop) can reference it.
    exit = function(player: Player)
        if not player or not player.Parent then return end

        -- Capture this run's outcome BEFORE teardown. AUTO RUN path
        -- stores the finalWave + label + per-tower stat summary so
        -- assembleTiers can rank towers afterward AND the admin
        -- panel's per-run drilldown has data. Standard runs print
        -- the StatLedger summary to the server log.
        --
        -- finalWave is FRACTIONAL: integer wave + (time alive past
        -- wave spawn) / expected wave duration. Capped at 0.99 so
        -- a heart that dies right as wave N+1 spawns reads as N.99
        -- not N+1.0. Per Matthew 2026-04-26: "add fractional round
        -- completion depending on time alive past wave spawn."
        local statSummary = StatLedger.summary()
        lastRunStats = statSummary  -- in-session cache for admin panel
        -- Fractional finalWave = State.wave + (damage dealt this
        -- wave / total HP pool of this wave's mobs). Higher
        -- fidelity than mob-kill ratio — partial damage on a tank
        -- counts proportionally instead of being lost when the
        -- tank survives. Per Matthew 2026-04-26: "calculate
        -- fractional clear based on damage done / hp pool for
        -- better fidelity."
        -- Fractional finalWave per Matthew 2026-04-26 spec:
        --   finalWave = State.wave + (damage over last 3 waves)
        --                          / (HP pool of those 3 waves)
        -- "If they die on wave 3 the clear is 3 + (damage on 1,2,3)
        --  / (hp pool of 1,2,3)." Edge cases:
        --   • Die on wave 1 → 1 + damage(W1) / pool(W1)
        --   • Die on wave 2 → 2 + damage(W1+W2) / pool(W1+W2)
        --   • Die on wave 3+ → wave + damage(last 3) / pool(last 3)
        -- State.recentWaves holds the previous 2 cleared waves (cap
        -- 2); current wave's stats come from State.waveMobs. Sum
        -- yields up to 3 waves of context — smooths the fractional
        -- score so a tower that handled W4-5 cleanly but stalled on
        -- W6 reads higher than one that struggled all three.
        local fractionalWave = State.wave
        if State.wave > 0 then
            local totalStart, totalDamage = 0, 0
            -- Past waves (last 2 from history).
            if State.recentWaves then
                for _, w in ipairs(State.recentWaves) do
                    totalStart  = totalStart  + w.start
                    totalDamage = totalDamage + w.damage
                end
            end
            -- Current wave from waveMobs.
            if State.waveMobs then
                for mob, startHp in pairs(State.waveMobs) do
                    totalStart = totalStart + startHp
                    if mob.Parent then
                        local currentHp = mob:GetAttribute("Health") or 0
                        totalDamage = totalDamage + math.max(0, startHp - currentHp)
                    else
                        totalDamage = totalDamage + startHp
                    end
                end
            end
            if totalStart > 0 then
                fractionalWave = State.wave + math.max(0, totalDamage / totalStart)
            end
        end
        if autoRun.active and autoRun.current then
            local result = {
                auxIds         = autoRun.current.auxIds,
                label          = autoRun.current.label,
                finalWave      = fractionalWave,
                testType       = testTypeForWave(State.wave),
                statSummary    = statSummary,
                -- Stamp the active balance era so LOAD RUNS can
                -- group sweeps + cumulative results by version.
                balanceVersion = currentBalanceVersion,
            }
            table.insert(autoRun.results, result)
            print(("[Infinite] AUTO RUN  %d/%d  %s  →  failed at wave %.2f (%s)"):format(
                #autoRun.results, autoRun.total,
                autoRun.current.label, fractionalWave, testTypeForWave(State.wave)))
            -- Fire per-run completion to the client so the Monitor
            -- window can update live tower stats + prospective tier
            -- placement after each loadout finishes (rather than
            -- only at sweep end).
            runCompletedRemote:FireClient(player, {
                idx       = #autoRun.results,
                auxIds    = result.auxIds,
                label     = result.label,
                finalWave = result.finalWave,
                testType  = result.testType,
            })
        else
            if State.wave > 0 then
                print(("[Infinite] -------- run summary -------- failed at wave %.2f (%s)"):format(
                    fractionalWave, testTypeForWave(State.wave)))
            else
                print("[Infinite] -------- run summary -------- (no waves run)")
            end
            print(statSummary)
        end
        StatLedger.reset()
        stopSpawner()
        destroyMap4Towers(player)
        State.activePlayer = nil
        State.wave = 0

        -- AUTO RUN dequeue path: pop next loadout, fire progress to
        -- client HUD, restart in-place WITHOUT the hub teleport.
        -- Player stays in Map 4; spawner gets a fresh spawnerToken
        -- via enter() → State.spawnerToken += 1.
        if autoRun.active and autoRun.queue and #autoRun.queue > 0 then
            local nextLoadout = table.remove(autoRun.queue, 1)
            autoRun.current = nextLoadout
            local progIdx = #autoRun.results + 1
            autoRunProgressRemote:FireClient(player, {
                current = progIdx,
                total   = autoRun.total,
                label   = nextLoadout.label,
            })
            -- Brief gap so the heart-death log + progress message
            -- land before the next run starts; also gives the auto-
            -- place pattern's prior-run state a frame or two to
            -- finish unwinding.
            -- Inter-round delay removed (Matthew 2026-04-26: "lower
            -- the time between auto run sections... just wait until
            -- all towers are placed then start"). The placement
            -- pause inside enter() (1-3s scaled by speed) already
            -- gives towers time to land before wave 1 spawns; the
            -- prior 1.0s was just a "let prior log lines flush"
            -- buffer that adds 73s of dead time per sweep.
            task.spawn(function()
                if not player.Parent then return end
                -- Slider tracks aux count — same lockstep as the
                -- loadout picker (more towers = more difficulty).
                -- 1 aux → 1.25×, 2 aux → 1.5×, 3 aux → 1.75×.
                enter(player, {
                    auxIds = nextLoadout.auxIds,
                    slider = #nextLoadout.auxIds,
                })
            end)
            return
        end

        -- AUTO RUN finalize: queue empty → assemble + emit tier list,
        -- stash the in-session cache, then STAY IN ARENA so the
        -- player can review the live MONITOR window + open the
        -- admin panel for tier-list details. They return to hub
        -- explicitly via the return portal or admin RUN RESET.
        -- Per Matthew 2026-04-26: "it teleported me out at the end
        -- of the auto run. are the stats gone?" — stats are kept
        -- in lastSweep + the autoRunDone payload, but the surprise
        -- teleport meant the player had to walk back to see them.
        if autoRun.active then
            autoRun.active = false
            local tiers = assembleTiers(autoRun.results or {})
            printTierList(tiers)
            -- In-session cache for the admin panel's RUN STATS
            -- section. Survives until server restart (no DataStore
            -- yet — see project_infinite_arena.md step 3 for the
            -- planned persistent layer).
            lastSweep = {
                tiers          = tiers,
                results        = autoRun.results,
                completedAt    = os.time(),
                total          = autoRun.total,
                balanceVersion = currentBalanceVersion,
            }
            -- Append every result to the cumulative pool so the
            -- default admin-panel tier list spans all sweeps since
            -- the last BALANCE RESET. Per Matthew 2026-04-26: "the
            -- run stats + tier lists should be across every run
            -- unless balance reset is hit."
            for _, r in ipairs(autoRun.results) do
                table.insert(cumulativeResults, r)
            end
            -- Persist cumulative pool to DataStore so the tier list
            -- survives server restarts. SaveCumulative trims heavy
            -- statSummary text + caps at MAX_CUMULATIVE_RESULTS.
            InfiniteRunHistoryStore.saveCumulative(cumulativeResults)
            -- Persist this individual sweep to history so LOAD RUN
            -- can pull it back across server restarts. (Trims
            -- statSummary text + caps at MAX_SWEEPS internally.)
            InfiniteRunHistoryStore.append(lastSweep)
            autoRunDoneRemote:FireClient(player, {
                results     = autoRun.results,
                tiers       = tiers,
                completedAt = lastSweep.completedAt,
                total       = autoRun.total,
            })
            -- Continuous-sweep loop: if STOP RUN hasn't been hit,
            -- rebuild the queue and kick off another sweep right
            -- away. Stat recording stays on; cumulative pool keeps
            -- growing. Per Matthew 2026-04-27: "run autorun
            -- continuously."
            if autoRun.continuous then
                autoRun.sweepNum = (autoRun.sweepNum or 0) + 1
                local newQueue = buildAutoRunQueue()
                autoRun.active  = true
                autoRun.queue   = newQueue
                autoRun.results = {}
                autoRun.total   = #newQueue
                local firstLoadout = table.remove(newQueue, 1)
                autoRun.current = firstLoadout
                autoRunProgressRemote:FireClient(player, {
                    current  = 1,
                    total    = autoRun.total,
                    label    = firstLoadout.label,
                    sweepNum = autoRun.sweepNum,
                })
                print(("[Infinite] AUTO RUN sweep #%d → starting next continuous sweep (%d loadouts)")
                    :format(autoRun.sweepNum, autoRun.total))
                task.spawn(function()
                    if not player.Parent then return end
                    enter(player, {
                        auxIds = firstLoadout.auxIds,
                        slider = #firstLoadout.auxIds,
                    })
                end)
                return
            end

            StatLedger.setRecordingEnabled(false)
            autoRun.queue      = nil
            autoRun.current    = nil
            autoRun.results    = nil
            autoRun.total      = 0
            autoRun.continuous = false
            autoRun.sweepNum   = 0
            print(("[Infinite] AUTO RUN sweep complete — %s remains in swamp idle to review stats"):format(player.Name))
            return  -- skip hub-return; player stays in arena idle
        end

        -- Restore StageState to map 1 (hub default) so the wave system's
        -- getHeart / getWaypoints stop resolving to Map4. Fire SwitchMap
        -- with noAutoWaves so we don't kick off a wave on map 1 either.
        local switchMapBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
        if switchMapBindable then
            switchMapBindable:Fire({
                mapId = 1,
                mapName = "Crook of the Tree",
                noAutoWaves = true,
            })
        end
        exitRemote:FireClient(player, {
            fadeOutSec = EXIT_FADE_OUT_SEC,
            holdSec    = 0.3,
            fadeInSec  = 0.6,
        })
        task.delay(EXIT_FADE_OUT_SEC * 0.6, function()
            teleportTo(player, getHubSpawnCF())
            player:SetAttribute("InfiniteInArena", false)
            -- Clear Equipped flags on hub return so the regular
            -- Map 1-3 hotbar logic takes over (legacy fallback in
            -- buildHotbar). Without this, every aux tower would
            -- stay marked Equipped=false and stay hidden during
            -- regular runs even after a boss-reward grant.
            for towerId in pairs(TempTowers.Templates) do
                player:SetAttribute(towerId .. "Equipped", nil)
            end
            player:SetAttribute("PowerEquipped", nil)
        end)
        print(("[Infinite] %s returned to hub"):format(player.Name))
    end

    local function hookHeartDeath()
        if State.heartConn then State.heartConn:Disconnect() end
        local heart = ctx.map4Heart
        if not heart then return end
        State.heartConn = heart:GetAttributeChangedSignal("Health"):Connect(function()
            if not State.active then return end
            local hp = heart:GetAttribute("Health") or 0
            if hp <= 0 and State.activePlayer then
                exit(State.activePlayer)
            end
        end)
    end

    -- enterIdle — drop the player into Map 4 with NO countdown / NO
    -- spawner / NO loadout grant. Used by the hub portal Touched +
    -- ProximityPrompt + dev-teleport "infinite" target. Player
    -- arrives in the swamp and can roam freely; the LOADOUT or AUTO
    -- RUN buttons trigger the actual run. Per Matthew 2026-04-26:
    -- "don't start the countdown until a loadout is selected or
    -- autorun is started".
    enterIdle = function(player: Player)
        if not player or not player.Parent then return end
        -- Position-check: if the InfiniteInArena attribute claims
        -- the player is in the swamp BUT they're actually back in
        -- the hub (DevReset respawned them, character died and
        -- respawned at SpawnLocation, etc.), the attribute is stale.
        -- Force the teleport instead of no-op'ing. Without this,
        -- post-reset portal touches were silent — see Matthew
        -- 2026-04-26: "after reset port to swamp is broken".
        if player:GetAttribute("InfiniteInArena") == true then
            local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            local mapCenterX = (ctx.MAP4_CENTER and ctx.MAP4_CENTER.X) or 8000
            if hrp and math.abs(hrp.Position.X - mapCenterX) < 200 then
                -- Truly in the arena — no-op so re-touching the
                -- disc doesn't replay the cinematic over an
                -- existing presence.
                return
            end
            -- Stale attribute; clear and fall through to re-entry.
            print(("[Infinite] %s has stale InfiniteInArena flag — clearing + re-entering"):format(player.Name))
            player:SetAttribute("InfiniteInArena", false)
        end

        -- Switch wave system to Map 4 stage state (no auto waves).
        local switchMapBindable = ReplicatedStorage:FindFirstChild(Remotes.Names.SwitchMap)
        if switchMapBindable then
            switchMapBindable:Fire({
                mapId = 4,
                mapName = "Pickle Swamp",
                noAutoWaves = true,
            })
        else
            warn("[Infinite] SwitchMap bindable missing — wave system not booted yet?")
        end

        -- Heart full HP (prior runs may have damaged it).
        if ctx.map4Heart then
            local maxHp = ctx.map4Heart:GetAttribute("MaxHealth") or Config.Map4.HeartMaxHp
            ctx.map4Heart:SetAttribute("Health", maxHp)
        end

        -- Lazy-build the return portal (first entry only).
        if ctx.map4Room then
            setupReturnPortal(ctx.map4Room, getMap4SpawnCF(), exit)
        end

        enterRemote:FireClient(player, {
            fadeOutSec = ENTRY_FADE_OUT_SEC,
            holdSec    = 0.4,
            fadeInSec  = 0.8,
        })
        task.delay(ENTRY_FADE_OUT_SEC * 0.6, function()
            teleportTo(player, getMap4SpawnCF())
            player:SetAttribute("InfiniteInArena", true)
            -- Idle state: zero stocks AND mark every tower
            -- Equipped=false so the hotbar is empty until a loadout
            -- is selected. The wave system's SwitchMap handler
            -- grants PowerStock=1 on map switch (carry-over logic
            -- meant for Map 1→2/3); the Equipped=false override
            -- keeps Power off the hotbar until the player explicitly
            -- picks a loadout via the LOADOUT button or AUTO RUN.
            for towerId in pairs(TempTowers.Templates) do
                player:SetAttribute(towerId .. "Stock", 0)
                player:SetAttribute(towerId .. "Equipped", false)
            end
            player:SetAttribute("PowerStock", 0)
            player:SetAttribute("PowerEquipped", false)
        end)
        print(("[Infinite] %s entered the pickle dimension (idle — pick LOADOUT or AUTO RUN to start)")
            :format(player.Name))
    end

    -- enter — assigned to the forward-declared local `enter` so
    -- exit() can recurse into the next AUTO RUN loadout. Assumes
    -- the player is already in Map 4 (via enterIdle); this just
    -- starts the run state + spawner. If somehow called when the
    -- player isn't in the arena, auto-routes through enterIdle
    -- and waits a beat for the cinematic to settle.
    enter = function(player: Player, opts: { auxIds: { string }?, slider: number? }?)
        -- opts comes from the loadout panel's PickInfiniteScenario
        -- payload OR is nil for dev-quick-entry / fallback paths.
        --   auxIds = list of TempTowers IDs to grant stock for; nil
        --            means "grant ALL aux at template stock counts"
        --            (dev shortcut so the auto-place pattern fills
        --            every role slot for visual debugging).
        --   slider = 0..4, sets RunDifficultyMult start value via
        --            (1.0 + slider × 0.25) so slider 0 = 1.0×,
        --            slider 4 = 2.0×. Spawner ramp compounds on top.
        if not player or not player.Parent then return end

        -- Auto-route through enterIdle if not yet in the arena.
        -- Then wait for the cinematic teleport to settle so the
        -- run-start grant + spawner doesn't race the fade.
        if player:GetAttribute("InfiniteInArena") ~= true then
            enterIdle(player)
            task.wait(ENTRY_FADE_OUT_SEC * 0.6 + 0.2)
            if not player.Parent then return end
        end

        if State.active then
            -- Mid-run re-pick (loadout button → START while a run is
            -- active): stop the current spawner + clear towers/mobs
            -- in-place, then fall through to start a fresh run with
            -- the new loadout. Player stays in Map4 — no cinematic.
            if State.activePlayer == player then
                print(("[Infinite] %s re-picked loadout mid-run — restarting"):format(player.Name))
                stopSpawner()
                destroyMap4Towers(player)
                State.activePlayer = nil
                State.wave = 0
            else
                warn(("[Infinite] %s tried to enter while another run was active"):format(player.Name))
                return
            end
        end
        opts = opts or {}
        local auxIds = opts.auxIds  -- may be nil
        local sliderValue = math.clamp(opts.slider or 3, 0, 4)
        -- Slider → starting-difficulty (loadoutMult). Pulls from
        -- Config.InfiniteArena.LoadoutMult[N]; out-of-range slider
        -- values fall through to the linear-extrapolation formula
        -- (1.0 + slider × 0.25) that the dev-only sliders 0/4 use.
        local startingDifficulty = _IA.LoadoutMult[sliderValue]
        if not startingDifficulty then
            startingDifficulty = 1.0 + sliderValue * 0.25
        end

        State.active        = true
        State.activePlayer  = player
        State.wave          = 0
        State.spawnerToken  = State.spawnerToken + 1
        State.skipCountdown = false
        -- Clear the rolling 3-wave HP/damage window so the new
        -- run's fractional calculation starts from zero. (Carried
        -- across the AUTO RUN loop's mid-sweep restart and stale
        -- entries would polluted the next loadout's score.)
        State.recentWaves   = {}
        -- auxCount drives the spawner's solo +1 wave-shift (so solo
        -- skips wave 1's softball HP and starts on what would be
        -- duo/trio's wave 2). Was unset before — the spawner read
        -- State.auxCount and got nil, so the shift never fired and
        -- solo loadouts were dying around wave 6-7. Per Matthew
        -- 2026-04-26: "remove wave 1 from solo" (i.e. start solo
        -- on what is currently wave 2's HP). Trio always = 3 (anchor
        -- counted), duo = 2, solo = 1, dev (auxIds=nil) = #templates
        -- which is plenty.
        if auxIds then
            State.auxCount = #auxIds
        else
            -- Dev shortcut path (grant-all): not "solo" by any
            -- meaningful definition, leave at 0 so the shift skips.
            State.auxCount = 0
        end
        -- Reset cumulative upgrade trackers per run. Each Solo wave
        -- triggers applyWaveCycleUpgrades which bumps these; once
        -- they hit RANGE_CAP_MULT (2×), the capped flag flips and
        -- subsequent cycles boost damage + firerate by 1.5× instead
        -- of applying range.
        State.auxRangeMult   = 1.0
        State.coreRangeMult  = 1.0
        State.auxRangeCapped = false
        State.coreRangeCapped = false
        local myToken = State.spawnerToken

        -- Reset the stat ledger so this run's stats start clean.
        StatLedger.reset()

        -- Heart full HP at run start (covers AUTO RUN loop case
        -- where heart was killed in the previous loadout's run).
        if ctx.map4Heart then
            local maxHp = ctx.map4Heart:GetAttribute("MaxHealth") or Config.Map4.HeartMaxHp
            ctx.map4Heart:SetAttribute("Health", maxHp)
        end

        -- Stash the slider's starting difficulty on State so the
        -- spawner loop's per-wave RunDifficultyMult ramp compounds
        -- on top of it (`starting × hpPerRound^(wave-1)`).
        State.startingDifficulty = startingDifficulty

        -- No teleport / no cinematic — player is already in arena.
        -- Grant loadout immediately, then auto-place after a delay
        -- so the gridUpdate paint has settled. Extended from 0.5s
        -- → 1.0s after Matthew 2026-04-26 reported "auto run place
        -- towers seems to not be working" — the shorter delay was
        -- racing the gridUpdate broadcast, especially during AUTO
        -- RUN looping where exit() destroys + re-broadcasts the
        -- grid back-to-back.
        grantLoadout(player, auxIds)
        hookHeartDeath()
        task.delay(1.0, function()
            if State.active and State.spawnerToken == myToken then
                autoPlaceRemote:FireClient(player)
            end
        end)
        startSpawnerLoop(myToken)
        -- (silenced run-start / auto-place / autoPlaceRemote-fired
        -- traces — used to fire 3 lines per loadout × 81 loadouts.)
    end

    -- Loadout-panel handler. Payload from the client picker:
    --   { auxIds = {string,...}, slider = number 0..4 }
    -- auxIds may be a sparse list (only the towers the player picked);
    -- slider sets the starting RunDifficultyMult. Sanitize both before
    -- handing to enter().
    pickRemote.OnServerEvent:Connect(function(player, payload)
        if type(payload) ~= "table" then return end
        if Workspace:GetAttribute("InfiniteUnlocked") ~= true then
            warn(("[Infinite] %s submitted loadout but Infinite is locked"):format(player.Name))
            return
        end
        local opts = {}
        if type(payload.auxIds) == "table" then
            local clean = {}
            for _, id in ipairs(payload.auxIds) do
                if type(id) == "string" and TempTowers.Templates[id] then
                    table.insert(clean, id)
                end
            end
            opts.auxIds = clean
        end
        if type(payload.slider) == "number" then
            opts.slider = payload.slider
        end
        enter(player, opts)
    end)

    -- Admin "RUN RESET" — same path as exit() (return to hub, stop
    -- spawner, clear towers). If an AUTO RUN sweep is in progress
    -- this also aborts the queue + prints partial tier list so the
    -- player can bail out mid-sweep.
    forceExitRemote.OnServerEvent:Connect(function(player)
        if State.activePlayer == player then
            if autoRun.active then
                print(("[Infinite] AUTO RUN aborted by %s after %d/%d run(s)"):format(
                    player.Name, #(autoRun.results or {}), autoRun.total))
                if autoRun.results and #autoRun.results > 0 then
                    local tiers = assembleTiers(autoRun.results)
                    printTierList(tiers)
                    -- Cache the partial tier list — incomplete sweep
                    -- is still useful for spot-checks. Clearer than
                    -- losing all data when the user bails early.
                    lastSweep = {
                        tiers          = tiers,
                        results        = autoRun.results,
                        completedAt    = os.time(),
                        total          = autoRun.total,
                        aborted        = true,
                        balanceVersion = currentBalanceVersion,
                    }
                    -- Aborted partials still feed cumulative — every
                    -- finished run is a real datapoint regardless of
                    -- whether the SWEEP completed.
                    for _, r in ipairs(autoRun.results) do
                        table.insert(cumulativeResults, r)
                    end
                    -- Persist cumulative + the aborted sweep itself.
                    InfiniteRunHistoryStore.saveCumulative(cumulativeResults)
                    InfiniteRunHistoryStore.append(lastSweep)
                end
                autoRun.active  = false
                autoRun.queue   = nil
                autoRun.current = nil
                autoRun.results = nil
                autoRun.total   = 0
                StatLedger.setRecordingEnabled(false)
            end
            print(("[Infinite] %s forced exit via admin RUN RESET"):format(player.Name))
            exit(player)
        end
    end)

    -- Admin "TOTAL RESET" — placeholder until persistent run history
    -- lands. Once that's in, this clears the DataStore-backed history
    -- the tier-rating algorithm reads from.
    totalResetRemote.OnServerEvent:Connect(function(player)
        if not player then return end
        -- TOTAL RESET = "Erase ALL Balance Studio stats from
        -- inception." Clears the in-session cumulative pool, the
        -- persisted cumulative DataStore key, AND the DataStore
        -- sweep history (so LOAD RUN starts fresh too). Per the
        -- admin panel's confirm-modal copy: "Wipes BOTH the
        -- in-session cumulative pool AND every saved sweep."
        local cleared = #cumulativeResults
        cumulativeResults = {}
        InfiniteRunHistoryStore.clearCumulative()
        InfiniteRunHistoryStore.clear()
        print(("[Infinite] %s TOTAL RESET — cleared %d cumulative run(s) + DataStore history (persisted)")
            :format(player.Name, cleared))
        lastSweepDataRemote:FireClient(player, {
            empty        = true,
            cumulative   = true,
            lastRunStats = "",
        })
    end)

    -- Admin "AUTO RUN" — kick off the full benchmark sweep. Builds
    -- the queue (9 solos + 36 pairs + 28 triples-with-anchor = 73
    -- runs), turns on stat recording, fires the first loadout via
    -- enter(). exit() handles the dequeue + finalize after each run.
    -- Refuses if a run is already active (player must RUN RESET
    -- first) — protects against accidentally clobbering a manual run.
    autoRunRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        if Workspace:GetAttribute("InfiniteUnlocked") ~= true then
            warn(("[Infinite] %s requested AUTO RUN but Infinite is locked"):format(player.Name))
            return
        end
        if autoRun.active then
            warn(("[Infinite] %s requested AUTO RUN but a sweep is already in progress (%d/%d)")
                :format(player.Name, #(autoRun.results or {}), autoRun.total))
            return
        end
        if State.active and State.activePlayer ~= player then
            warn(("[Infinite] %s requested AUTO RUN but another player is in a run"):format(player.Name))
            return
        end

        local queue = buildAutoRunQueue()
        autoRun.active     = true
        autoRun.queue      = queue
        autoRun.results    = {}
        autoRun.total      = #queue
        autoRun.continuous = true   -- loop sweeps until STOP RUN
        autoRun.sweepNum   = 1

        -- Stat recording is disabled by default ("get it working
        -- first" decision). AUTO RUN is the first place we WANT
        -- per-tower DPS / stun-sec / slow-value capture, since
        -- the tier list will eventually weight by these too. Flip
        -- on for the duration of the sweep; exit() flips off when
        -- the queue drains (or RUN RESET aborts).
        StatLedger.setRecordingEnabled(true)
        StatLedger.reset()

        -- Pop the first loadout + start. If a manual run is already
        -- active for THIS player, enter()'s mid-run-restart branch
        -- handles the cleanup; otherwise it's a fresh entry.
        local firstLoadout = table.remove(queue, 1)
        autoRun.current = firstLoadout

        autoRunProgressRemote:FireClient(player, {
            current = 1,
            total   = autoRun.total,
            label   = firstLoadout.label,
        })
        print(("[Infinite] AUTO RUN starting — %d loadouts queued (anchor=%s, cap=wave %d)")
            :format(autoRun.total, AUTO_RUN_ANCHOR, MAX_AUTO_RUN_WAVE))
        -- Slider tracks aux count — same lockstep as the loadout
        -- picker (more towers = more difficulty). 1 aux → 1.25×,
        -- 2 aux → 1.5×, 3 aux → 1.75×.
        enter(player, {
            auxIds = firstLoadout.auxIds,
            slider = #firstLoadout.auxIds,
        })
    end)

    -- Admin panel default view: ALL RUNS cumulative aggregate
    -- across every sweep since BALANCE RESET. Per Matthew
    -- 2026-04-26: "the run stats + tier lists should be across
    -- every run unless balance reset is hit." Falls back to a
    -- single most-recent sweep if cumulative is empty (covers the
    -- fresh-server case where no sweep has run yet but lastSweep
    -- might have something the client wants to see).
    --
    -- Empty-state payload is { empty = true } so the client knows
    -- to show "no sweep yet" instead of "loading...".
    lastSweepReqRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        if #cumulativeResults > 0 then
            local tiers = assembleTiers(cumulativeResults)
            lastSweepDataRemote:FireClient(player, {
                tiers        = tiers,
                results      = cumulativeResults,
                completedAt  = lastSweep and lastSweep.completedAt or os.time(),
                total        = #cumulativeResults,
                cumulative   = true,
                lastRunStats = lastRunStats,
            })
        elseif lastSweep then
            lastSweepDataRemote:FireClient(player, {
                tiers        = lastSweep.tiers,
                results      = lastSweep.results,
                completedAt  = lastSweep.completedAt,
                total        = lastSweep.total,
                aborted      = lastSweep.aborted,
                lastRunStats = lastRunStats,
            })
        else
            lastSweepDataRemote:FireClient(player, {
                empty        = true,
                lastRunStats = lastRunStats,  -- might still have manual-run stats
            })
        end
    end)

    -- BALANCE RESET: wipe the cumulative aggregate so the next
    -- sweep starts the tier list from zero. Doesn't touch the
    -- DataStore-backed sweep history (LOAD RUNS can still pull
    -- older sweeps individually). Persists the wipe so it sticks
    -- across server restarts. Bumps the balance-version counter
    -- so subsequent sweeps form a NEW era — past sweeps stay
    -- grouped under their old version in the LOAD RUNS picker.
    -- Per Matthew 2026-04-27: "every time balance reset is used
    -- increase the balance version # and start a new row."
    balanceResetRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        local cleared = #cumulativeResults
        cumulativeResults = {}
        InfiniteRunHistoryStore.clearCumulative()
        currentBalanceVersion = InfiniteRunHistoryStore.bumpBalanceVersion()
        print(("[Infinite] %s wiped cumulative balance stats (%d run(s) cleared, persisted) — new balance version = %d"):format(
            player.Name, cleared, currentBalanceVersion))
        lastSweepDataRemote:FireClient(player, {
            empty        = true,
            cumulative   = true,
            lastRunStats = lastRunStats,
        })
    end)

    -- Admin panel "LOAD RUNS" section: list past balance ERAS
    -- (one row per balanceVersion, regardless of how many sweeps
    -- ran in that era) from the DataStore-backed history. Per
    -- Matthew 2026-04-27: "change LOAD RUN to LOAD RUNS and have
    -- it load all runs from a given balance change. every time
    -- balance reset is used increase the balance version # and
    -- start a new row." Returns version-grouped metadata; full
    -- aggregated payload comes via InfiniteLoadByBalanceVersion
    -- when the user picks an era. Per-sweep `sweeps` field kept
    -- for legacy LOAD-by-idx callers (currently unused but the
    -- remote handler below still works).
    sweepHistoryReqRemote.OnServerEvent:Connect(function(player)
        if not player or not player.Parent then return end
        local versionGroups = InfiniteRunHistoryStore.listByBalanceVersion()
        local sweeps        = InfiniteRunHistoryStore.list()
        sweepHistoryDataRemote:FireClient(player, {
            versionGroups         = versionGroups,
            currentBalanceVersion = currentBalanceVersion,
            -- Legacy compat — old client builds still read this.
            sweeps                = sweeps,
        })
    end)

    -- Legacy single-sweep loader (kept so older client builds
    -- don't break mid-rollout). New LOAD RUNS UI uses the
    -- balance-version path below.
    loadSweepByIdxRemote.OnServerEvent:Connect(function(player, payload)
        if not player or not player.Parent then return end
        if type(payload) ~= "table" or type(payload.idx) ~= "number" then return end
        local sweep = InfiniteRunHistoryStore.get(payload.idx)
        if not sweep then
            warn(("[Infinite] LOAD RUN: idx %d not found"):format(payload.idx))
            lastSweepDataRemote:FireClient(player, { empty = true })
            return
        end
        lastSweepDataRemote:FireClient(player, {
            tiers          = sweep.tiers,
            results        = sweep.results,
            completedAt    = sweep.completedAt,
            total          = sweep.total,
            aborted        = sweep.aborted,
            balanceVersion = sweep.balanceVersion,
            lastRunStats   = "(loaded from past sweep — StatLedger snapshot wasn't persisted)",
        })
        print(("[Infinite] LOAD RUN: %s loaded sweep idx %d (%d run(s))"):format(
            player.Name, payload.idx, (sweep.results and #sweep.results) or 0))
    end)

    -- LOAD RUNS pick: hydrate every sweep belonging to a single
    -- balance era into the existing tier-list display via the
    -- InfiniteLastSweepData channel. Server merges the era's
    -- sweeps (results concat, completedAt = newest) and runs
    -- assembleTiers over the combined result pool — that's what
    -- the picker row's count corresponds to.
    loadByVersionRemote.OnServerEvent:Connect(function(player, payload)
        if not player or not player.Parent then return end
        if type(payload) ~= "table" or type(payload.balanceVersion) ~= "number" then return end
        local merged = InfiniteRunHistoryStore.getByBalanceVersion(payload.balanceVersion)
        if not merged then
            warn(("[Infinite] LOAD RUNS: balance v%d has no sweeps"):format(payload.balanceVersion))
            lastSweepDataRemote:FireClient(player, { empty = true })
            return
        end
        local tiers = assembleTiers(merged.results)
        lastSweepDataRemote:FireClient(player, {
            tiers          = tiers,
            results        = merged.results,
            completedAt    = merged.completedAt,
            total          = #merged.results,
            aborted        = merged.aborted,
            balanceVersion = merged.balanceVersion,
            sweepCount     = merged.sweepCount,
            -- Reuse `cumulative=true` so the client's renderSweep
            -- treats this as an aggregate (drives the "ALL RUNS"
            -- morph + the prefix label).
            cumulative     = true,
            lastRunStats   = ("(loaded balance v%d — %d sweep(s), %d run(s) — StatLedger snapshot not persisted)")
                :format(merged.balanceVersion, merged.sweepCount, #merged.results),
        })
        print(("[Infinite] LOAD RUNS: %s loaded balance v%d (%d sweep(s), %d run(s))"):format(
            player.Name, merged.balanceVersion, merged.sweepCount, #merged.results))
    end)

    -- Player leaving mid-run cleanup: stop the spawner, clear mobs,
    -- print summary. Otherwise the spawner keeps spawning into an
    -- empty map4 with no audience until the heart eventually dies.
    -- If an AUTO RUN sweep is in progress, also abort the queue +
    -- print partial tier list so the run isn't wasted entirely.
    Players.PlayerRemoving:Connect(function(player)
        if State.activePlayer == player then
            print(("[Infinite] %s left mid-run — tearing down"):format(player.Name))
            if autoRun.active then
                print(("[Infinite] AUTO RUN aborted (player left) after %d/%d run(s)"):format(
                    #(autoRun.results or {}), autoRun.total))
                if autoRun.results and #autoRun.results > 0 then
                    local tiers = assembleTiers(autoRun.results)
                    printTierList(tiers)
                    lastSweep = {
                        tiers          = tiers,
                        results        = autoRun.results,
                        completedAt    = os.time(),
                        total          = autoRun.total,
                        aborted        = true,
                        balanceVersion = currentBalanceVersion,
                    }
                end
                autoRun.active  = false
                autoRun.queue   = nil
                autoRun.current = nil
                autoRun.results = nil
                autoRun.total   = 0
                StatLedger.setRecordingEnabled(false)
            elseif State.wave > 0 then
                print(("[Infinite] -------- run summary -------- "
                    .. "(player left at wave %d / %s)"):format(
                    State.wave, testTypeForWave(State.wave)))
                print(StatLedger.summary())
                StatLedger.reset()
            end
            stopSpawner()
            destroyMap4Towers(player)
            State.activePlayer = nil
            State.wave = 0
        end
    end)

    -- Idle entry is the canonical hub-portal target — dropping the
    -- player into Map 4 with no countdown / no spawner. The actual
    -- run starts via the in-arena LOADOUT button or AUTO RUN.
    -- ctx.enterInfinite is kept as an alias for back-compat with
    -- the dev ProximityPrompt path; it now points at idle entry.
    ctx.enterIdleInfinite = enterIdle
    ctx.enterInfinite     = enterIdle
    ctx.exitInfinite      = exit

    -- Character respawn → clear InfiniteInArena. DevReset, death,
    -- or any generic respawn fires CharacterAdded; the new character
    -- spawns at SpawnLocation in the hub, NOT inside Map 4. Without
    -- this hook the attribute would stay true and the next portal
    -- touch would no-op. Also stop any in-flight spawner so it
    -- doesn't keep spawning into an empty arena. (Matthew
    -- 2026-04-26: "after reset port to swamp is broken".)
    Players.PlayerAdded:Connect(function(player)
        player.CharacterAdded:Connect(function()
            if player:GetAttribute("InfiniteInArena") then
                player:SetAttribute("InfiniteInArena", false)
                if State.activePlayer == player then
                    print(("[Infinite] %s respawned mid-run — tearing down"):format(player.Name))
                    if autoRun.active then
                        autoRun.active  = false
                        autoRun.queue   = nil
                        autoRun.current = nil
                        autoRun.results = nil
                        autoRun.total   = 0
                    end
                    stopSpawner()
                    State.activePlayer = nil
                    State.wave = 0
                end
            end
        end)
    end)
    -- Also cover players already in-game when this script reloads
    -- (Studio sync-on-save reuses existing Player objects).
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character then
            -- If they already have a character and the attribute is
            -- somehow set, treat as "respawned" to clear cleanly.
            if player:GetAttribute("InfiniteInArena") then
                player:SetAttribute("InfiniteInArena", false)
            end
        end
        player.CharacterAdded:Connect(function()
            if player:GetAttribute("InfiniteInArena") then
                player:SetAttribute("InfiniteInArena", false)
            end
        end)
    end

    print("[Infinite] system online (Workspace.InfiniteUnlocked = "
        .. tostring(Workspace:GetAttribute("InfiniteUnlocked")) .. ")")
end

return Infinite
