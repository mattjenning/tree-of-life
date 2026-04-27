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
    --          Drives data.slowUntil / data.slowMult which MobUpdate reads.
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
        if slowPct > 0 and slowDuration > 0 then
            data.slowUntil = gameNow + slowDuration  -- game-seconds
            data.slowMult  = 1 - slowPct
            StatLedger.recordSlow(towerModel, 1 - slowPct, slowDuration)
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
    end

    local function updateTowers(towerList)
        -- Pause gate: when ctx.paused, towers hold fire. Matches MobUpdate's
        -- pause — mobs freeze, towers stop shooting, the whole combat layer
        -- is idle.
        if ctx.paused then return end
        local now = os.clock()
        for _, towerBase in ipairs(towerList) do
            local towerModel = towerBase.Parent
            if towerModel and towerModel.Parent then
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
                    local fireRate = towerModel:GetAttribute("FireRate") or 1
                    local aoeRadius = towerModel:GetAttribute("AoeRadius")
                    local lastFire = towerLastFire[towerModel] or 0
                    -- Effective fire rate scales with ctx.gameSpeed so towers
                    -- shoot in proportion to mob movement during 2x/3x/5x/10x.
                    local interval = 1 / (fireRate * ctx.gameSpeed)
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
                    if now - lastFire >= interval then
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
                                local landPos = target.Position
                                local data = ctx.activeMobs[target]
                                local wps = ctx.getWaypoints and ctx.getWaypoints()
                                if data and wps and #wps > 0 then
                                    local speed = data.speed or 0
                                    -- slowUntil is in ctx.gameTime units (game-seconds)
                                    -- after the 2026-04-27 timer-domain fix.
                                    local gameNow = ctx.gameTime or 0
                                    if data.slowUntil and gameNow < data.slowUntil and data.slowMult then
                                        speed = speed * data.slowMult
                                    end
                                    -- lobSeconds is wall-clock, but mob path advances by
                                    -- dt × gameSpeed. At game speed > 1, the mob covers
                                    -- MORE ground in the same wall time, so multiply by
                                    -- gameSpeed too.
                                    local initialLead = speed * lobSeconds * ctx.gameSpeed
                                    local leadStuds = initialLead
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
                                    landPos = cur
                                    -- If we ran out of waypoints while still
                                    -- having lead distance to consume, the mob
                                    -- would reach the heart before the lob
                                    -- lands. Shrink lobSeconds to match the
                                    -- distance we actually covered so the arc
                                    -- lands AT the heart instead of visually
                                    -- "past" it. Scale by actualCovered/initial
                                    -- — the shell arrives faster and the arc
                                    -- is flatter, but it still hits the heart
                                    -- spot.
                                    if leadStuds > 0 and initialLead > 0 then
                                        local covered = initialLead - leadStuds
                                        local scale = math.max(0.1, covered / initialLead)
                                        lobSeconds = lobSeconds * scale
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
                                        -- Aggressive homing: the lob STARTS aimed at the
                                        -- predicted landing spot but bends sharply toward
                                        -- the LIVE target each frame. Per Matthew
                                        -- 2026-04-27: "increase the homing ability of
                                        -- mushroom mortar even more." Bumped from
                                        -- blendBase 0.10 → 0.25 (2.5× stronger pull per
                                        -- frame) and the lateGate cutoff stretched
                                        -- 0.8 → 0.95 so homing stays alive nearly to
                                        -- impact instead of locking in the last 20%.
                                        local startT = os.clock()
                                        while os.clock() - startT < lobSeconds do
                                            local t = math.min(1, (os.clock() - startT) / lobSeconds)
                                            if lobTarget and lobTarget.Parent then
                                                local desired = lobTarget.Position
                                                local blendBase = 0.25
                                                local lateGate  = math.max(0, 1 - t / 0.95)
                                                local blend = blendBase * lateGate
                                                currentLand = currentLand:Lerp(desired, blend)
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
                                        -- Visuals off: skip the per-frame ball position
                                        -- + homing loop entirely. Just delay damage by
                                        -- lobSeconds wallclock so the lob's "flight time"
                                        -- still feels right gameplay-wise. No homing
                                        -- means the lob lands at the original predicted
                                        -- landPos — fine at math-only speeds where the
                                        -- per-frame homing was unreliable anyway.
                                        task.wait(lobSeconds)
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

                                towerLastFire[towerModel] = now
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
                                })
                            end

                            towerLastFire[towerModel] = now
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
