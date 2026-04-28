--[[
    Towers.lua — Tower firing loop.

    Called every Heartbeat from the main loop with the current list of
    tagged tower parts. For each tower:
      1. Check if it has shots (or the owner has DevUnlimitedAmmo).
      2. Respect the per-tower fire-rate cooldown.
      3. Pick a target via ctx.findTarget (Targeting.lua).
      4. Apply stun/knockback effects via ctx.applyHitEffects; each proc
         grants one extra damage hit.
      5. Deal damage via ctx.damageMob.
      6. Spawn firing bolt + AOE burst VFX.
      7. Decrement Shots (unless unlimited).

    Per-tower state:
      - towerLastFire[towerModel]  : os.clock of last shot (cooldown)
      - towerOwnerCache[towerModel]: cached Player reference (saved per-frame
                                     Players:GetPlayerByUserId calls)

    Both tables are module-local but published on ctx so Phoenix and
    DevRemotes can access / clear them. A GetInstanceRemovedSignal(Tower)
    handler drops cache entries when a tower is destroyed so DevReset
    and normal tower-destroy flows don't leak memory across runs.

    setup(ctx) reads (late-resolved at call time):
      ctx.activeMobs, ctx.WaveConfig, ctx.gameSpeed
      ctx.findTarget                  (Targeting.lua)
      ctx.applyHitEffects, fireBolt, spawnAoeBurst  (Effects.lua)
      ctx.damageMob                   (orchestrator until commit 9)
      ctx.phoenixDisplayCd, ctx.phoenixDisplayGrace
                                      (for tag-removed cache cleanup)

    And publishes:
      ctx.updateTowers(towerList)  -- called from Heartbeat
      ctx.towerLastFire            -- for Phoenix / dev reset to read/clear
      ctx.towerOwnerCache          -- for Phoenix / dev reset to read/clear
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tags = require(Shared:WaitForChild("Tags"))
local MobUtil = require(Shared:WaitForChild("MobUtil"))
local StatLedger = require(script.Parent:WaitForChild("StatLedger"))

local Towers = {}

function Towers.setup(ctx)
    -- Throttle table for the "what is each tower firing at" diagnostic.
    local towerLastFire   = {}  -- [tower model] = os.clock() of last shot
    local towerOwnerCache = {}  -- [tower model] = Player (cached per tower)
    local towerLastTarget = {}  -- [tower model] = mob it last fired at

    -- Publish caches so Phoenix + DevReset can read/clear them.
    ctx.towerLastFire   = towerLastFire
    ctx.towerOwnerCache = towerOwnerCache

    -- The owner of a tower never changes after placement, so we resolve it once
    -- via getTowerOwner and cache. Saves a per-frame Players:GetPlayerByUserId
    -- call per tower.
    local function getTowerOwner(towerModel)
        local cached = towerOwnerCache[towerModel]
        if cached and cached.Parent then return cached end
        local ownerId = towerModel:GetAttribute("Owner")
        if not ownerId then return nil end
        local p = Players:GetPlayerByUserId(ownerId)
        if p then towerOwnerCache[towerModel] = p end
        return p
    end

    -- Clean per-tower cache entries when a tower is removed. Without this,
    -- DevReset destroys towers but the table entries linger across runs —
    -- a slow leak. The tag is removed when the tower model is destroyed,
    -- which fires GetInstanceRemovedSignal.
    CollectionService:GetInstanceRemovedSignal(Tags.Tower):Connect(function(taggedPart)
        -- The tagged instance is the tower's BasePart, not the model. Walk
        -- both to be safe — caches might key on either depending on insertion site.
        local model = taggedPart.Parent
        if model then
            towerLastFire[model]   = nil
            towerOwnerCache[model] = nil
            if ctx.phoenixDisplayCd    then ctx.phoenixDisplayCd[model]    = nil end
            if ctx.phoenixDisplayGrace then ctx.phoenixDisplayGrace[model] = nil end
        end
        towerLastFire[taggedPart]   = nil
        towerOwnerCache[taggedPart] = nil
        if ctx.phoenixDisplayCd    then ctx.phoenixDisplayCd[taggedPart]    = nil end
        if ctx.phoenixDisplayGrace then ctx.phoenixDisplayGrace[taggedPart] = nil end
    end)

    -- Per-tower-type debuffs applied after damage+procs. Kept inline (not
    -- in applyHitEffects) because these are GUARANTEED effects driven by
    -- tower attributes, not probabilistic rolls.
    --   Slow:  SlowPct (0..1) + SlowDuration (seconds). Applies every hit.
    --          Drives data.slows[sourceTower] = {endsAt, mult} via
    --          MobUtil.applySlow — per-source map, strongest active
    --          source wins (see MobUtil for the per-source semantic).
    --   Periodic stun: PeriodicStunDuration + PeriodicStunCooldown (seconds).
    --          Tracks per-tower LastPeriodicStun; when now - last >= cooldown,
    --          the hit also stuns and the timer resets. Only the PRIMARY
    --          target gets stunned (AOE secondaries don't) — keeps the effect
    --          a precise crowd-control hit, not a blanket AOE hard-CC.
    local function applyTempTowerDebuffs(towerModel, target, _now, isAoeSecondary)
        local data = ctx.activeMobs[target]
        if not data then return end

        -- Switched stun/slow + LastPeriodicStun to ctx.gameTime
        -- (game-seconds clock) per Matthew 2026-04-27 Option B
        -- audit. The wallclock-based timer was collapsing across
        -- the substep batch at 200×/400×: all 10-20 substeps
        -- inside a Heartbeat saw "stunned/slowed" because os.clock()
        -- barely advanced between them, inflating effective debuff
        -- duration 10-20× in game time. ctx.gameTime advances by
        -- subDt × gameSpeed each substep so timers expire at the
        -- right simulated moment regardless of speed multiplier.
        local gameNow = ctx.gameTime or 0

        local slowPct      = towerModel:GetAttribute("SlowPct") or 0
        local slowDuration = towerModel:GetAttribute("SlowDuration") or 0
        local slowStackPct = towerModel:GetAttribute("SlowStackPct") or 0
        if slowStackPct > 0 and slowDuration > 0 then
            -- STACKING SLOW (FrostMelon, 2026-04-27 rework). Each hit
            -- adds slowStackPct; cap at slowStackCap. Stack timer
            -- refreshes per hit; if the stack expires before the
            -- next hit, count resets to 1 (mob "thaws").
            --
            -- data.slowStacks[towerModel] = { count, expiresAt }
            -- separate from data.slows because the slow MULT here is
            -- DERIVED (count × stackPct) per-hit, not stamped at
            -- placement. Each hit overwrites data.slows[tower] with
            -- the fresh derived mult so MobUtil.activeSlow picks up
            -- the latest.
            local stackCap = towerModel:GetAttribute("SlowStackCap") or 0.20
            data.slowStacks = data.slowStacks or {}
            local entry = data.slowStacks[towerModel]
            local count
            if entry and entry.expiresAt > gameNow then
                count = entry.count + 1
            else
                count = 1
            end
            -- Cap at slowStackCap / slowStackPct stacks. Float math
            -- safe-rounded so 0.20 cap with 0.01 step caps at 20.
            local maxStacks = math.floor(stackCap / slowStackPct + 0.5)
            if count > maxStacks then count = maxStacks end
            local effectivePct = count * slowStackPct
            if effectivePct > stackCap then effectivePct = stackCap end
            data.slowStacks[towerModel] = {
                count     = count,
                expiresAt = gameNow + slowDuration,
            }
            MobUtil.applySlow(data, towerModel, effectivePct, slowDuration, gameNow)
            StatLedger.recordSlow(towerModel, 1 - effectivePct, slowDuration)
            MobUtil.refreshSlowVisual(target, data, gameNow)
        elseif slowPct > 0 and slowDuration > 0 then
            -- Per-source slow: each source tower gets its own timer
            -- entry on data.slows. Strongest active source wins for
            -- movement; visual recolors when the dominant source
            -- changes. See MobUtil for full mechanic.
            MobUtil.applySlow(data, towerModel, slowPct, slowDuration, gameNow)
            StatLedger.recordSlow(towerModel, 1 - slowPct, slowDuration)
            MobUtil.refreshSlowVisual(target, data, gameNow)
        end

        if not isAoeSecondary then
            local pStunDur = towerModel:GetAttribute("PeriodicStunDuration") or 0
            local pStunCd  = towerModel:GetAttribute("PeriodicStunCooldown") or 0
            if pStunDur > 0 and pStunCd > 0 then
                local lastStun = towerModel:GetAttribute("LastPeriodicStun") or 0
                if gameNow - lastStun >= pStunCd then
                    data.stunUntil = gameNow + pStunDur  -- game-seconds
                    StatLedger.recordStun(towerModel, pStunDur)
                    towerModel:SetAttribute("LastPeriodicStun", gameNow)
                end
            end
        end

        -- ContolCore stacking-DOT proc (Stage 2 — Matthew 2026-04-27).
        -- When a tower has StackDotTickDmg > 0, each direct hit
        -- adds/refreshes a stack on the mob. Stacks tick damage
        -- per-frame in MobUpdate (see ctx.tickControlStacks call).
        --
        -- data.controlStacks[towerModel] = {
        --     count, expiresAt, tickDmg, tickPerSec, maxStacks, lastTickAt
        -- }
        if not isAoeSecondary then
            local stackTickDmg = towerModel:GetAttribute("StackDotTickDmg") or 0
            if stackTickDmg > 0 then
                data.controlStacks = data.controlStacks or {}
                local entry = data.controlStacks[towerModel]
                local maxStacks = towerModel:GetAttribute("MaxStacks") or 8
                local stackSec  = towerModel:GetAttribute("StackDotSeconds") or 4
                if entry then
                    entry.count = math.min(maxStacks, entry.count + 1)
                    entry.expiresAt = gameNow + stackSec
                else
                    data.controlStacks[towerModel] = {
                        count       = 1,
                        expiresAt   = gameNow + stackSec,
                        tickDmg     = stackTickDmg,
                        tickPerSec  = towerModel:GetAttribute("StackDotTickPerSec") or 2,
                        maxStacks   = maxStacks,
                        lastTickAt  = gameNow,
                    }
                end
            end
        end
    end

    -- advanceLastFire — bookkeeping helper for the post-fire timer reset.
    --
    -- 2026-04-27 v2: switched from wallclock-time (os.clock) to game-time
    -- (ctx.gameTime) semantics. Caller now passes `gameNow` (game-sec
    -- monotonic) and `interval` in game-seconds. At 1× speed gameNow
    -- advances at the same rate as os.clock so behavior is identical;
    -- at >1× game speed gameNow advances PROPORTIONALLY to gameSpeed,
    -- which means at substep-active speeds (>20×) towers correctly
    -- get extra fire opportunities per Heartbeat as ctx.gameTime
    -- advances per substep.
    --
    -- v1 (wallclock): "lastFire = now" reset threw away the accumulated
    -- overshoot (now - lastFire > interval) every fire, costing ~dt/2
    -- wallclock-sec per shot. v2 keeps the same fix (advance by exactly
    -- one `interval` instead of resetting to `gameNow`) so fractional
    -- overshoot stays banked toward the next shot's gate.
    --
    -- The clamp guards against catch-up bursts: if a tower's been idle
    -- (webbed, no targets in range, just placed) for many intervals,
    -- `lastFire + interval` could still be far in the past, and the next
    -- frame would fire AGAIN. Capping at `gameNow - interval` ensures
    -- the next eligible fire is at most one interval away — no rubber-
    -- band bursts on web-break or target-acquisition.
    local function advanceLastFire(gameNow: number, lastFire: number, interval: number): number
        local v = lastFire + interval
        if gameNow - v > interval then
            v = gameNow - interval
        end
        return v
    end

    -- Aura cache (2026-04-28 perf pass). The aura pre-pass below
    -- USED to run an O(towers × aura-sources) distance loop on every
    -- Heartbeat, recomputing identical assignments because nothing
    -- ever moved. Towers don't reposition; aura attributes are
    -- frozen at placement; the only thing that invalidates the
    -- assignment is a tower add/remove event.
    --
    -- Cache: { [towerBase] = {dmg, fr, rng} }. Stamped on each tower
    -- in one shot when invalid; on subsequent ticks we just rewrite
    -- the same attributes (cheap GetAttribute / SetAttribute, no
    -- distance math). Aura cache invalidation fires from the Tags.Tower
    -- add/remove signals below.
    local auraCache = nil
    local function invalidateAuraCache()
        auraCache = nil
    end
    do
        local CollectionService = game:GetService("CollectionService")
        local Tags = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Tags"))
        CollectionService:GetInstanceAddedSignal(Tags.Tower):Connect(invalidateAuraCache)
        CollectionService:GetInstanceRemovedSignal(Tags.Tower):Connect(invalidateAuraCache)
    end

    local function updateTowers(towerList)
        -- Pause gate: when ctx.paused, towers hold fire. Matches MobUpdate's
        -- pause — mobs freeze, towers stop shooting, the whole combat layer
        -- is idle.
        if ctx.paused then return end
        local now = os.clock()
        -- gameNow drives ALL fire-cadence timing (per 2026-04-27 v2
        -- refactor). os.clock-based `now` is kept only for visual
        -- animation hooks (lob homing loop) and the WebbedUntil
        -- check (CanopySpiderBoss writes WebbedUntil = os.clock + N).
        local gameNow = ctx.gameTime or 0

        -- Aura pre-pass — picks up any tower with auraRadius>0
        -- (covers SupportCore + the 3 aux Support buff towers
        -- PaceFlower / PowerSeed / SpyglassRoot). Stamps
        -- AuraDamageBoost / AuraFireRateBoost / AuraRangeBoost
        -- percentage attributes on each tower; the fire path below
        -- reads them and multiplies effective stats.
        --
        -- Strongest-wins per axis (max over aura sources in range),
        -- NOT additive — keeps aura math clean and prevents trivially
        -- stacking multiple buff towers into runaway compounding.
        -- A buff tower never buffs itself.
        --
        -- 2026-04-28 perf pass: result memoized in auraCache; only
        -- recomputed when the tower set changes (CollectionService
        -- add / remove signals invalidate). Stamps the cached
        -- per-tower triple every Heartbeat so newly-stamped
        -- attributes propagate to the fire path immediately, but
        -- the O(n²) distance math runs at most once per
        -- placement / destruction.
        if not auraCache then
            local supportCores = {}
            for _, towerBase in ipairs(towerList) do
                local towerModel = towerBase.Parent
                if towerModel and towerModel.Parent then
                    local auraR = towerModel:GetAttribute("AuraRadius")
                    if auraR and auraR > 0 then
                        table.insert(supportCores, {
                            base    = towerBase,
                            radius  = auraR,
                            dmgPct  = towerModel:GetAttribute("AuraDamageBonusPct") or 0,
                            frPct   = towerModel:GetAttribute("AuraFireRateBonusPct") or 0,
                            rngPct  = towerModel:GetAttribute("AuraRangeBonusPct") or 0,
                        })
                    end
                end
            end
            auraCache = {}
            for _, towerBase in ipairs(towerList) do
                local towerModel = towerBase.Parent
                if towerModel and towerModel.Parent then
                    local bestDmg, bestFr, bestRng = 0, 0, 0
                    if #supportCores > 0 then
                        local pos = towerBase.Position
                        for _, sc in ipairs(supportCores) do
                            if sc.base ~= towerBase then
                                local d = (pos - sc.base.Position).Magnitude
                                if d <= sc.radius then
                                    if sc.dmgPct > bestDmg then bestDmg = sc.dmgPct end
                                    if sc.frPct  > bestFr  then bestFr  = sc.frPct  end
                                    if sc.rngPct > bestRng then bestRng = sc.rngPct end
                                end
                            end
                        end
                    end
                    auraCache[towerBase] = { bestDmg, bestFr, bestRng }
                end
            end
        end
        for _, towerBase in ipairs(towerList) do
            local towerModel = towerBase.Parent
            if towerModel and towerModel.Parent then
                local cached = auraCache[towerBase]
                if cached then
                    towerModel:SetAttribute("AuraDamageBoost",   cached[1])
                    towerModel:SetAttribute("AuraFireRateBoost", cached[2])
                    towerModel:SetAttribute("AuraRangeBoost",    cached[3])
                end
            end
        end

        -- Live-mob snapshot — flat array of { mob, data } entries
        -- with mob.Parent already verified. Hoisted at top of
        -- updateTowers (2026-04-28 perf pass) so per-tower
        -- iterations stop walking the activeMobs hashtable + doing
        -- mob.Parent reads inside their inner loops. Each
        -- pairs(ctx.activeMobs) at 30-50 mobs costs a hash-iter
        -- + Instance Parent read; at 6 inner loops × 30 towers ×
        -- 60Hz this was 9k+ Instance reads/sec.
        --
        -- Currently consumed by:
        --   • BloodlinkVine link-membership refresh (below)
        --   • BlinkBerry blink-AOE pre-pass (below)
        -- The 4 remaining inner loops (per-fire splash / AOE /
        -- pierce / chain) keep their pairs() pattern for now; they
        -- have target-exclusion and perpendicular semantics that
        -- need careful per-callsite refactor. Pattern is
        -- documented; future commit can adopt as needed.
        local liveMobs = {}
        local liveMobsCount = 0
        for mob, data in pairs(ctx.activeMobs) do
            if mob.Parent then
                liveMobsCount = liveMobsCount + 1
                liveMobs[liveMobsCount] = { mob = mob, data = data }
            end
        end

        -- BloodlinkVine pre-pass (2026-04-28): build the link map
        -- so when ctx.damageMob lands on a linked mob, the link
        -- broadcast helper knows the cluster. Refreshes per
        -- updateTowers tick — mobs entering / leaving range
        -- naturally pick up / drop link membership.
        --
        -- Storage: data.linkClusters = { [towerModel] = { mob, ... } }
        -- read by ctx.broadcastLinkedDamage (in MobUpdate or similar
        -- — wired below).
        local linkSources = {}  -- list of { base, radius, towerModel, echoFrac }
        for _, towerBase in ipairs(towerList) do
            local tm = towerBase.Parent
            if tm and tm.Parent then
                local linkR = tm:GetAttribute("LinkRadius")
                if linkR and linkR > 0 then
                    table.insert(linkSources, {
                        base       = towerBase,
                        radius     = linkR,
                        towerModel = tm,
                        echoFrac   = tm:GetAttribute("LinkEchoFrac") or 0.5,
                    })
                end
            end
        end
        -- Refresh per-mob link membership. Iterates the hoisted
        -- liveMobs snapshot (skips the pairs() hash-walk +
        -- mob.Parent check that the snapshot already filtered).
        -- Cheap O(mobs × linkSources); typical run has <30 mobs
        -- and <2 BloodlinkVines.
        if #linkSources > 0 then
            for i = 1, liveMobsCount do
                local entry = liveMobs[i]
                local mob, data = entry.mob, entry.data
                local prev = data.linkedTo
                data.linkedTo = nil
                for _, src in ipairs(linkSources) do
                    local d = (mob.Position - src.base.Position).Magnitude
                    if d <= src.radius then
                        data.linkedTo = data.linkedTo or {}
                        data.linkedTo[src.towerModel] = src.echoFrac
                    end
                end
                -- (prev) — could compare for diagnostics; skipping.
                _ = prev
            end
        end

        for _, towerBase in ipairs(towerList) do
            local towerModel = towerBase.Parent
            if towerModel and towerModel.Parent then
                -- BlinkBerry — periodic AOE teleport (Control role,
                -- 2026-04-28). Has BlinkInterval > 0 → run blink
                -- branch and CONTINUE (skip the firing path; this
                -- tower doesn't shoot). Per-tower last-blink time
                -- stored in towerLastFire (reused — same Heartbeat-
                -- gated cadence semantics).
                local blinkInterval = towerModel:GetAttribute("BlinkInterval") or 0
                if blinkInterval > 0 then
                    -- Blink timer is tracked SEPARATELY from the shot
                    -- fire timer (towerLastFire). Sharing them broke
                    -- once BlinkBerry got a fire rate (2026-04-28):
                    -- every shot bumped towerLastFire, so the blink
                    -- check kept seeing "we blinked recently" and
                    -- never re-fired. Per-model attribute avoids the
                    -- conflict; persists across hot-reload too.
                    local lastBlink = towerModel:GetAttribute("LastBlinkAt") or -math.huge
                    if gameNow - lastBlink >= blinkInterval then
                        towerModel:SetAttribute("LastBlinkAt", gameNow)
                        local blinkDist = towerModel:GetAttribute("BlinkDistance") or 20
                        local blinkRange = towerModel:GetAttribute("Range") or 25
                        local tp = towerBase.Position
                        local wps = ctx.getWaypoints and ctx.getWaypoints()
                        if wps and #wps > 0 then
                            -- Iterate the hoisted liveMobs snapshot
                            -- (mob.Parent already verified). 2026-04-28:
                            -- per-mob blink cap removed per Matthew —
                            -- loop prevention now relies on stat tuning
                            -- (range 15 + interval 8 + distance 8 ⇒
                            -- mob covers more ground between blinks
                            -- than the setback). If a hang re-emerges
                            -- the next pass is per-tower-per-mob
                            -- recency throttle, not a hard cap.
                            for i = 1, liveMobsCount do
                                local mobEntry = liveMobs[i]
                                local mob, data = mobEntry.mob, mobEntry.data
                                if data then
                                    local d = (mob.Position - tp).Magnitude
                                    if d <= blinkRange then
                                        -- Walk the mob backward `blinkDist` studs
                                        -- along the waypoint chain. Floor at
                                        -- waypointIndex 2 — past that the mob
                                        -- snaps to wps[1] (spawn) and stops.
                                        local pos = mob.Position
                                        local curIdx = data.waypointIndex or 1
                                        local remaining = blinkDist
                                        while remaining > 0 and curIdx >= 2 do
                                            local prevWp = wps[curIdx - 1]
                                            local prevPos = Vector3.new(prevWp.Position.X, pos.Y, prevWp.Position.Z)
                                            local toPrev = prevPos - pos
                                            local segDist = toPrev.Magnitude
                                            if segDist <= 1e-3 then
                                                curIdx = curIdx - 1
                                            elseif remaining < segDist then
                                                pos = pos + toPrev.Unit * remaining
                                                remaining = 0
                                            else
                                                pos = prevPos
                                                remaining = remaining - segDist
                                                curIdx = curIdx - 1
                                            end
                                        end
                                        -- Apply new position + waypointIndex.
                                        data.waypointIndex = math.max(1, curIdx)
                                        if mob:IsA("BasePart") then
                                            mob.CFrame = CFrame.new(pos.X, mob.Position.Y, pos.Z)
                                        elseif mob.PivotTo then
                                            mob:PivotTo(CFrame.new(pos.X, mob.Position.Y, pos.Z))
                                        end
                                    end
                                end
                            end
                        end
                    end
                    -- BlinkBerry now ALSO fires regular shots (Matthew
                    -- 2026-04-28: "give blink berry a fire rate"). Fall
                    -- through to the standard fire path below instead
                    -- of `continue`, so BlinkBerry's damage/fireRate
                    -- attributes drive direct DPS while the blink
                    -- mechanic stays intact.
                end

                local shots = towerModel:GetAttribute("Shots") or 0
                local owner = getTowerOwner(towerModel)
                -- Ammo system retired: `unlimited = true` always. The
                -- ammo-consumption / ammo-pile / CarryingAmmo code below
                -- is now dead; leaving the structure in place so a future
                -- "ammo returns" pass can re-enable via `unlimited = ...`
                -- without re-plumbing the fire/decrement path. Attributes
                -- Shots/MaxShots still get set at placement but never
                -- decrement — effectively cosmetic.
                local unlimited = true
                -- Canopy Spider web: if the tower is webbed, skip firing
                -- until WebbedUntil passes. The client overlays a sticky-web
                -- visual based on this attribute.
                local webbedUntil = towerModel:GetAttribute("WebbedUntil") or 0
                local isWebbed = now < webbedUntil
                if (shots > 0 or unlimited) and not isWebbed then
                    local baseDamage = towerModel:GetAttribute("Damage") or 10
                    -- Per-player bonus damage from the final-boss minigame.
                    -- Each successful tap pushes an entry on the player's
                    -- rolling bonus stack; multiplier = finalBossBonus
                    -- Multiplier + sum(active extraPcts) while ≥1 entry
                    -- is live, else 1.0. FinalBoss.lua owns the stack +
                    -- prune logic; we just ask it. See FinalBoss.lua's
                    -- module header for the rolling-stack semantics.
                    local damage = baseDamage
                    if owner then
                        local mult, hasBonus = ctx.bonusDamageMult(owner)
                        if hasBonus then
                            damage = baseDamage * mult
                        end
                    end
                    -- SupportCore aura damage bonus (Stage 2 — Matthew
                    -- 2026-04-27). Computed by the aura pre-pass above
                    -- and stamped on the tower as AuraDamageBoost (% pts).
                    local auraDmgBoost = towerModel:GetAttribute("AuraDamageBoost") or 0
                    if auraDmgBoost > 0 then
                        damage = damage * (1 + auraDmgBoost / 100)
                    end
                    local range    = towerModel:GetAttribute("Range")    or 25
                    -- Pickle Lord's range-decay attack. The encounter ticks
                    -- the player's RangeDecayMultiplier × 0.9 every 30
                    -- game-seconds; here we apply it to the effective
                    -- range. No floor — drives toward 0 so the player
                    -- has a hard timer to kill Pickle Lord. Cleared back
                    -- to nil on RunReset / SwitchMap / PickleLordDefeated
                    -- (PickleLordBoss.stopPickleLord handles the kill /
                    -- abort cases; RunReset clears via DevRemotes).
                    if owner then
                        local decay = owner:GetAttribute("RangeDecayMultiplier")
                        if decay and decay ~= 1 then
                            range = range * decay
                        end
                    end
                    -- Aura range bonus (SpyglassRoot, 2026-04-28).
                    local auraRngBoost = towerModel:GetAttribute("AuraRangeBoost") or 0
                    if auraRngBoost > 0 then
                        range = range * (1 + auraRngBoost / 100)
                    end
                    local fireRate = towerModel:GetAttribute("FireRate") or 1
                    -- SupportCore aura fireRate bonus (Stage 2 — Matthew
                    -- 2026-04-27). Multiplies effective shots-per-second
                    -- by (1 + AuraFireRateBoost/100). Shorter cooldown
                    -- between shots while the tower is in a Support
                    -- core's aura.
                    local auraFrBoost = towerModel:GetAttribute("AuraFireRateBoost") or 0
                    if auraFrBoost > 0 then
                        fireRate = fireRate * (1 + auraFrBoost / 100)
                    end
                    local aoeRadius = towerModel:GetAttribute("AoeRadius")
                    local lastFire = towerLastFire[towerModel] or 0
                    -- Game-time fire interval (2026-04-27 v2 refactor).
                    -- Old: `1 / (fireRate × gameSpeed)` in WALLCLOCK-sec.
                    -- New: `1 / fireRate` in GAME-sec — gameNow already
                    -- advances at gameSpeed × wallclock per Heartbeat /
                    -- substep, so the per-game-sec fire rate stays
                    -- exactly fireRate at every game speed. At >20×
                    -- (substep-active), gameNow advances per substep
                    -- so towers can fire multiple times per Heartbeat.
                    local interval = 1 / fireRate
                    -- Pre-resolve the target every frame so we can fire IMMEDIATELY
                    -- on a target switch (especially manual targets — when the bird
                    -- becomes hittable, the Core that's locked on it should fire on
                    -- this frame, not wait for the next interval). If the target
                    -- changed since last fire, reset the interval gate.
                    local tp = towerBase.Position
                    local mode = towerModel:GetAttribute("TargetMode") or "First"
                    local resolvedTarget = ctx.findTarget(tp, range, mode, towerModel)
                    if resolvedTarget and resolvedTarget ~= towerLastTarget[towerModel] then
                        lastFire = 0  -- bypass interval; fire on this frame
                    end
                    if gameNow - lastFire >= interval then
                        local target = resolvedTarget
                        if target then
                            -- Lob branch (MushroomMortar): arcing shot with delayed
                            -- AOE at snapshotted landing position. Replaces normal
                            -- instant-hit path because "damage on landing" is the
                            -- whole point of the mechanic.
                            local lobSeconds = towerModel:GetAttribute("LobSeconds")
                            if lobSeconds and lobSeconds > 0 then
                                local blastRadius = towerModel:GetAttribute("BlastRadius") or 8
                                -- Aim AHEAD: predict where the target will be by the
                                -- time the lob lands. Walk the mob forward along the
                                -- waypoint path by (speed × lobSeconds × gameSpeed
                                -- factor), including any slow debuff, so the
                                -- blast lands where the mob is ABOUT to be.
                                --
                                -- predictLead(seconds): walks the mob forward along its
                                -- waypoint chain by the time-equivalent stud count and
                                -- returns the predicted world position. Used twice —
                                -- once for the initial aim point, then re-evaluated
                                -- each frame inside the homing loop so the lob always
                                -- chases the FUTURE position (not the current one).
                                -- Per Matthew 2026-04-27: "mushroom aiming needs to
                                -- be more anticipatory." The previous homing branch
                                -- lerped toward target.Position (the LIVE / current
                                -- spot) which actively erased the lead the longer
                                -- the lob flew, so shells consistently landed in the
                                -- mob's wake on fast or accelerating waves.
                                local landPos = target.Position
                                local data = ctx.activeMobs[target]
                                local wps = ctx.getWaypoints and ctx.getWaypoints()
                                local function predictLead(seconds: number): Vector3
                                    if not data or not wps or #wps == 0 then
                                        return target.Position
                                    end
                                    local speed = data.speed or 0
                                    -- Per-source slow (2026-04-27): use strongest
                                    -- currently-active source's mult for lob target-
                                    -- lead prediction. Falls through to no slow if
                                    -- nothing active.
                                    local gameNow = ctx.gameTime or 0
                                    local activeMult = MobUtil.activeSlow(data, gameNow)
                                    if activeMult then
                                        speed = speed * activeMult
                                    end
                                    -- 2026-04-28 lob-time refactor: `seconds` is
                                    -- now GAME-seconds (was wall-clock). The lob
                                    -- waits `lobSeconds / gameSpeed` wallclock
                                    -- below, which equates to `lobSeconds`
                                    -- game-seconds at any game-speed. Mob travels
                                    -- speed × seconds studs in that time —
                                    -- gameSpeed factor no longer needed in the
                                    -- prediction. Fixes Mushroom -3.20 wave drop
                                    -- at 20× (lob was taking 33 game-seconds to
                                    -- land — wave was over before damage hit).
                                    local leadStuds = speed * seconds
                                    local wpIdx = data.waypointIndex or 1
                                    local cur = target.Position
                                    while leadStuds > 0 and wpIdx <= #wps do
                                        local wp = wps[wpIdx]
                                        local wpPos = Vector3.new(wp.Position.X, cur.Y, wp.Position.Z)
                                        local seg = wpPos - cur
                                        local segLen = seg.Magnitude
                                        if leadStuds < segLen then
                                            cur = cur + seg.Unit * leadStuds
                                            leadStuds = 0
                                        else
                                            cur = wpPos
                                            leadStuds = leadStuds - segLen
                                            wpIdx = wpIdx + 1
                                        end
                                    end
                                    return cur
                                end

                                if data and wps and #wps > 0 then
                                    -- Initial prediction at firing time.
                                    landPos = predictLead(lobSeconds)
                                    -- If we ran out of waypoints while still
                                    -- having lead distance to consume, the mob
                                    -- would reach the heart before the lob
                                    -- lands. Shrink lobSeconds so the arc
                                    -- lands AT the heart instead of visually
                                    -- "past" it. Compute coverage by walking
                                    -- the path manually here (predictLead
                                    -- already returns the clamped point).
                                    do
                                        local speed = data.speed or 0
                                        local gameNow = ctx.gameTime or 0
                                        local activeMult = MobUtil.activeSlow(data, gameNow)
                                        if activeMult then speed = speed * activeMult end
                                        -- Match predictLead's new game-time
                                        -- semantics — drop the gameSpeed factor.
                                        local initialLead = speed * lobSeconds
                                        local actualLead = (landPos - target.Position).Magnitude
                                        if initialLead > 0 and actualLead < initialLead - 0.5 then
                                            local scale = math.max(0.1, actualLead / initialLead)
                                            lobSeconds = lobSeconds * scale
                                        end
                                    end
                                end
                                -- TargetAimOffsetY lift: bosses with a buried
                                -- body part (Pickle Lord) stamp this attribute
                                -- so projectiles aim ABOVE the geometric
                                -- center instead of the underground origin.
                                -- Without this, the mortar's landPos sits at
                                -- target.Position (Y deep underground) and
                                -- the arc plows through the world floor.
                                local aimY = target:GetAttribute("TargetAimOffsetY")
                                if type(aimY) == "number" and aimY ~= 0 then
                                    landPos = Vector3.new(landPos.X,
                                                          landPos.Y + aimY,
                                                          landPos.Z)
                                end
                                local lobColor = towerModel:GetAttribute("ProjectileColor")
                                    or Color3.fromRGB(180, 140, 90)

                                -- Skip the lob ball when math-only mode is on
                                -- OR when VISUALS toggle is off. Per Matthew
                                -- 2026-04-27: "you can see mushroom mortar
                                -- fire at 100x." MushroomMortar's arcing
                                -- projectile bypasses the standard fireBolt
                                -- gate; needed its own check. Damage still
                                -- applies via the deferred landedDamage path
                                -- below (independent of the ball Part).
                                local visualsOn = ctx.mathOnlyMode ~= true
                                    and Workspace:GetAttribute("InfiniteVisuals") == true
                                local ball
                                if visualsOn then
                                    ball = Instance.new("Part")
                                    ball.Shape = Enum.PartType.Ball
                                    ball.Size = Vector3.new(2.5, 2.5, 2.5)
                                    ball.Anchored = true
                                    ball.CanCollide = false
                                    ball.CastShadow = false
                                    ball.Color = lobColor
                                    ball.Material = Enum.Material.Neon
                                    ball.Parent = workspace
                                end

                                -- Fire origin scales with the tower's visual size
                                -- (TowerPlacement applies Model:ScaleTo(0.5) at
                                -- placement; the magic-number Y offset must
                                -- track that scale or the lob originates above
                                -- empty air over a half-size tower).
                                local towerScale = (towerModel.GetScale and towerModel:GetScale()) or 1
                                local fromPos = tp + Vector3.new(0, 18 * towerScale, 0)
                                local landedDamage = damage   -- snapshot here; tower
                                                               -- attributes may change before lob
                                                               -- lands (upgrades, etc.)
                                local landedTower = towerModel
                                local lobTarget   = target    -- captured for homing re-eval
                                task.spawn(function()
                                    local currentLand = landPos
                                    if ball then
                                        -- Anticipatory homing: each frame we re-predict
                                        -- where the mob WILL be when the remaining
                                        -- flight time elapses, and lerp toward THAT.
                                        -- Previously the homing pulled toward
                                        -- target.Position (the LIVE spot), which
                                        -- erased the initial lead — shells landed in
                                        -- the mob's wake on fast or accelerating
                                        -- waves. Per Matthew 2026-04-27: "mushroom
                                        -- aiming needs to be more anticipatory."
                                        --
                                        -- Math: at frame t∈[0,1], remaining flight =
                                        -- (1-t) × lobSeconds. predictLead walks the
                                        -- mob's waypoint chain by that many seconds
                                        -- and returns the future world position. The
                                        -- lerp blend is a small correction toward
                                        -- that future point.
                                        --
                                        -- blendBase 0.18 → 0.10 → 0.07 (2026-04-27) —
                                        -- Matthew: "lower mushroom homing ability, it's
                                        -- overtuned now." Then "nerf mushroom homing
                                        -- a little more." Halving and then trimming
                                        -- another 30% off the per-frame correction
                                        -- toward the future point. The INITIAL
                                        -- prediction is still accurate; the homing now
                                        -- follows mob path-changes (corner turns, slow
                                        -- debuff lift) loosely so shells can miss
                                        -- when the path shifts mid-flight. Keeps
                                        -- Mushroom strong on straight-path engagements
                                        -- but punishes lobs at corners.
                                        -- 2026-04-28: lob duration scales with
                                        -- gameSpeed so it lands in `lobSeconds`
                                        -- GAME-seconds at any speed. Wallclock
                                        -- duration at 1× = lobSeconds; at 20× =
                                        -- lobSeconds/20 (much faster visually).
                                        -- Clamped at 1 minimum so a future
                                        -- gameSpeed=0 / pause doesn't divide by 0.
                                        local lobWallDur = lobSeconds / math.max(1, ctx.gameSpeed)
                                        local startT = os.clock()
                                        while os.clock() - startT < lobWallDur do
                                            local t = math.min(1, (os.clock() - startT) / lobWallDur)
                                            if lobTarget and lobTarget.Parent then
                                                -- `remaining` in GAME-seconds for
                                                -- predictLead's new semantics.
                                                local remaining = math.max(0, (1 - t) * lobSeconds)
                                                local futurePos = predictLead(remaining)
                                                local blendBase = 0.07
                                                -- Late-flight lock so the last few
                                                -- frames freeze the aim point —
                                                -- prevents jitter on the final lerp
                                                -- when the mob is ~0 studs from
                                                -- impact. Cutoff at t=0.92 so the
                                                -- last 8% of flight is committed.
                                                local lateGate = math.max(0, 1 - t / 0.92)
                                                local blend = blendBase * lateGate
                                                currentLand = currentLand:Lerp(futurePos, blend)
                                            end
                                            local mid = fromPos:Lerp(currentLand, 0.5) + Vector3.new(0, 40, 0)
                                            local p = (1 - t)^2 * fromPos
                                                    + 2 * (1 - t) * t * mid
                                                    + t^2 * currentLand
                                            ball.Position = p
                                            task.wait()
                                        end
                                        ball:Destroy()
                                    else
                                        -- Visuals off: skip the per-frame ball
                                        -- position + homing loop entirely. Just
                                        -- delay damage by `lobSeconds` GAME-
                                        -- seconds. Wallclock = lobSeconds /
                                        -- gameSpeed so high-speed sweeps don't
                                        -- have the lob arriving after the wave
                                        -- ends. 2026-04-28 lob-time refactor.
                                        task.wait(lobSeconds / math.max(1, ctx.gameSpeed))
                                    end
                                    ctx.spawnAoeBurst(currentLand, blastRadius)
                                    local hitNow = os.clock()
                                    for mob, _ in pairs(ctx.activeMobs) do
                                        if mob.Parent
                                           and (mob.Position - currentLand).Magnitude <= blastRadius then
                                            ctx.damageMob(mob, landedDamage, landedTower)
                                            applyTempTowerDebuffs(landedTower, mob, hitNow, false)
                                        end
                                    end
                                end)

                                towerLastFire[towerModel] = advanceLastFire(gameNow, lastFire, interval)
                                towerLastTarget[towerModel] = target
                                if not unlimited then
                                    towerModel:SetAttribute("Shots", shots - 1)
                                end
                                continue  -- skip normal fire path entirely
                            end
                            -- Apply secondary effects (stun/knockback) BEFORE the
                            -- damage hit. If the damage kills the target, the mob
                            -- gets removed from activeMobs and applyHitEffects
                            -- becomes a no-op. Doing it first preserves the roll.
                            -- Each proc returns a count; for every proc we deal
                            -- an EXTRA hit of normal damage (so a stun-and-
                            -- knockback double-proc = 3 total damage hits).
                            local procs = ctx.applyHitEffects(towerModel, target)
                            ctx.damageMob(target, damage, towerModel)
                            for _ = 1, procs do
                                ctx.damageMob(target, damage, towerModel)
                            end
                            -- Per-tower-type guaranteed debuffs (slow, periodic stun).
                            applyTempTowerDebuffs(towerModel, target, now, false)

                            -- Projectile VFX color — per-tower via ProjectileColor
                            -- attribute so temp towers (ice shards, thorns, etc.)
                            -- read distinctly. Default is the Power-tower orange.
                            local boltColor = towerModel:GetAttribute("ProjectileColor")
                                or Color3.fromRGB(255, 120, 80)
                            -- Fire origin tracks the tower's visual scale; see
                                                            -- the lob branch above for the same reason.
                            local boltScale = (towerModel.GetScale and towerModel:GetScale()) or 1
                            local boltOrigin = tp + Vector3.new(0, 10 * boltScale, 0)
                            -- Tall-boss bolt aim: target.Position.Y + the
                            -- per-mob TargetAimOffsetY attribute lifts the
                            -- effective aim from a buried body center to
                            -- roughly player-head height (Pickle Lord:
                            -- ~127 stud above body center). Falls back to
                            -- the barrel's own Y when TargetXZOnly is set
                            -- but no offset — bolt fires horizontally
                            -- instead of angling down through the floor.
                            local boltAim
                            local aimY = target:GetAttribute("TargetAimOffsetY")
                            if aimY then
                                boltAim = Vector3.new(target.Position.X,
                                                       target.Position.Y + aimY,
                                                       target.Position.Z)
                            elseif target:GetAttribute("TargetXZOnly") then
                                boltAim = Vector3.new(target.Position.X,
                                                       boltOrigin.Y,
                                                       target.Position.Z)
                            else
                                boltAim = target.Position
                            end
                            ctx.fireBolt(boltOrigin, boltAim, boltColor)

                            if aoeRadius and aoeRadius > 0 then
                                local targetPos = target.Position
                                ctx.spawnAoeBurst(targetPos, aoeRadius)
                                for mob, _ in pairs(ctx.activeMobs) do
                                    if mob ~= target and mob.Parent then
                                        if (mob.Position - targetPos).Magnitude <= aoeRadius then
                                            local mobProcs = ctx.applyHitEffects(towerModel, mob)
                                            ctx.damageMob(mob, damage, towerModel)
                                            for _ = 1, mobProcs do
                                                ctx.damageMob(mob, damage, towerModel)
                                            end
                                            -- AOE secondaries: slow applies, periodic
                                            -- stun does not (keeps CC precise).
                                            applyTempTowerDebuffs(towerModel, mob, now, true)
                                        end
                                    end
                                end
                            end

                            -- Pierce: ThornVine. Find up to PierceCount mobs
                            -- "further down the line" — projectile continues through
                            -- the primary target and damages nearby mobs past it.
                            -- Simplified as "nearest mobs within perpendicular distance
                            -- of the tower→target line, sorted by distance from target."
                            local pierceCount = towerModel:GetAttribute("PierceCount")
                            if pierceCount and pierceCount > 0 then
                                local dir = (target.Position - tp)
                                if dir.Magnitude > 0.01 then
                                    dir = dir.Unit
                                    local lineWidth = 3.5  -- studs of perpendicular tolerance
                                    -- Collect candidates + their along-line distance PAST
                                    -- the primary target (we only pierce further, not backward).
                                    local candidates = {}
                                    for mob, _ in pairs(ctx.activeMobs) do
                                        if mob ~= target and mob.Parent then
                                            local toMob = mob.Position - tp
                                            local along = toMob:Dot(dir)
                                            local targetAlong = (target.Position - tp):Dot(dir)
                                            if along > targetAlong then
                                                local perp = (toMob - dir * along).Magnitude
                                                if perp <= lineWidth and along <= range * 1.2 then
                                                    table.insert(candidates,
                                                        { mob = mob, along = along })
                                                end
                                            end
                                        end
                                    end
                                    table.sort(candidates, function(a, b) return a.along < b.along end)
                                    for i = 1, math.min(pierceCount, #candidates) do
                                        local mob = candidates[i].mob
                                        ctx.damageMob(mob, damage, towerModel)
                                        applyTempTowerDebuffs(towerModel, mob, now, true)
                                    end
                                end
                            end

                            -- Chain: LightningRadish. Hop to N successive mobs,
                            -- each within ChainRange of the previous hop, damage
                            -- decays by ChainFalloff per hop.
                            local chainJumps = towerModel:GetAttribute("ChainJumps")
                            if chainJumps and chainJumps > 0 then
                                local chainRange   = towerModel:GetAttribute("ChainRange")   or 14
                                local chainFalloff = towerModel:GetAttribute("ChainFalloff") or 0.6
                                local last = target
                                local curDamage = damage
                                local hitSet = { [target] = true }
                                for _ = 1, chainJumps do
                                    curDamage = curDamage * chainFalloff
                                    local nearest, nearestDist = nil, chainRange + 0.01
                                    for mob, _ in pairs(ctx.activeMobs) do
                                        if not hitSet[mob] and mob.Parent then
                                            local d = (mob.Position - last.Position).Magnitude
                                            if d < nearestDist then
                                                nearest, nearestDist = mob, d
                                            end
                                        end
                                    end
                                    if not nearest then break end
                                    ctx.fireBolt(last.Position + Vector3.new(0, 2, 0),
                                        nearest.Position, boltColor)
                                    ctx.damageMob(nearest, curDamage, towerModel)
                                    applyTempTowerDebuffs(towerModel, nearest, now, true)
                                    hitSet[nearest] = true
                                    last = nearest
                                end
                            end

                            -- Zone spawn: HoneyHive patch + SporePuffball cloud.
                            -- Patch has tick damage + slow; cloud has tick damage only.
                            -- Both use the shared Zones system.
                            -- Project the zone DOWN to the tower's Y (floor level)
                            -- regardless of how high the target is. The bird boss
                            -- hovers/dives at altitude; without this, spore clouds
                            -- and honey patches floated mid-air alongside the bird
                            -- and missed every ground mob below them. Tower Y is a
                            -- reliable floor proxy since towers can only be placed
                            -- on the path/room floor.
                            local zoneGroundPos = Vector3.new(
                                target.Position.X, tp.Y, target.Position.Z)
                            local patchRadius = towerModel:GetAttribute("PatchRadius")
                            if patchRadius and patchRadius > 0 and ctx.spawnZone then
                                ctx.spawnZone({
                                    position     = zoneGroundPos,
                                    radius       = patchRadius,
                                    lifetime     = towerModel:GetAttribute("PatchSeconds") or 3,
                                    tickDmg      = towerModel:GetAttribute("PatchTickDmg") or 2,
                                    tickPerSec   = towerModel:GetAttribute("PatchTickPerSec") or 2,
                                    slowPct      = towerModel:GetAttribute("PatchSlowPct") or 0,
                                    slowDuration = 0.8,
                                    color        = Color3.fromRGB(255, 205, 80),
                                    sourceTower  = towerModel,
                                })
                            end
                            local cloudRadius = towerModel:GetAttribute("CloudRadius")
                            if cloudRadius and cloudRadius > 0 and ctx.spawnZone then
                                -- Tick damage scales with upgrade bonus: base + flat/12.
                                -- The /12 spreads one picked +flat bump across the cloud's
                                -- 12 total ticks (4 ticks/sec × 3s lifetime), so a Damage
                                -- card gives Spore Puffball the same TOTAL bonus damage
                                -- per cloud it'd give a single-shot tower per hit.
                                local baseTick = towerModel:GetAttribute("CloudTickDmg") or 3
                                local damageFlat = towerModel:GetAttribute("DamageFlat") or 0
                                ctx.spawnZone({
                                    position    = zoneGroundPos,
                                    radius      = cloudRadius,
                                    lifetime    = towerModel:GetAttribute("CloudSeconds") or 3,
                                    tickDmg     = baseTick + damageFlat / 12,
                                    tickPerSec  = towerModel:GetAttribute("CloudTickPerSec") or 4,
                                    color       = Color3.fromRGB(140, 230, 140),
                                    sourceTower = towerModel,
                                    -- 2026-04-27: opt in to overlap-heat
                                    -- mechanic. Spore clouds dropped within
                                    -- ~10 studs of each other gain mutual
                                    -- heat → brighter visual + 1.4×/1.8×/
                                    -- 2.2× damage multiplier (cap at 4).
                                    -- Honey doesn't pass this so its slow-
                                    -- and-tick mechanic stays linear.
                                    enableHeat  = true,
                                })
                            end

                            towerLastFire[towerModel] = advanceLastFire(gameNow, lastFire, interval)
                            towerLastTarget[towerModel] = target
                            if not unlimited then
                                towerModel:SetAttribute("Shots", shots - 1)
                            end
                        end
                    end
                end
            end
        end
    end

    ctx.updateTowers = updateTowers
    ctx.getTowerOwner = getTowerOwner
end

return Towers
