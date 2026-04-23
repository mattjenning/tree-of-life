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

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tags = require(Shared:WaitForChild("Tags"))

local Towers = {}

function Towers.setup(ctx)
    local towerLastFire   = {}  -- [tower model] = os.clock() of last shot
    local towerOwnerCache = {}  -- [tower model] = Player (cached per tower)

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
    local function applyTempTowerDebuffs(towerModel, target, now, isAoeSecondary)
        local data = ctx.activeMobs[target]
        if not data then return end

        local slowPct      = towerModel:GetAttribute("SlowPct") or 0
        local slowDuration = towerModel:GetAttribute("SlowDuration") or 0
        if slowPct > 0 and slowDuration > 0 then
            data.slowUntil = now + (slowDuration / ctx.gameSpeed)
            data.slowMult  = 1 - slowPct
        end

        if not isAoeSecondary then
            local pStunDur = towerModel:GetAttribute("PeriodicStunDuration") or 0
            local pStunCd  = towerModel:GetAttribute("PeriodicStunCooldown") or 0
            if pStunDur > 0 and pStunCd > 0 then
                local lastStun = towerModel:GetAttribute("LastPeriodicStun") or 0
                if now - lastStun >= pStunCd then
                    data.stunUntil = now + (pStunDur / ctx.gameSpeed)
                    towerModel:SetAttribute("LastPeriodicStun", now)
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
                -- Temp towers have NoAmmo=true: they don't consume Shots so
                -- they fire forever. Dev cheat overrides consumption too.
                local noAmmo = towerModel:GetAttribute("NoAmmo") == true
                local unlimited = noAmmo
                    or (owner and owner:GetAttribute("DevUnlimitedAmmo") == true)
                -- Canopy Spider web: if the tower is webbed, skip firing
                -- until WebbedUntil passes. The client overlays a sticky-web
                -- visual based on this attribute.
                local webbedUntil = towerModel:GetAttribute("WebbedUntil") or 0
                local isWebbed = now < webbedUntil
                if (shots > 0 or unlimited) and not isWebbed then
                    local baseDamage = towerModel:GetAttribute("Damage") or 10
                    -- Per-player bonus damage (final boss minigame).
                    local damage = baseDamage
                    if owner then
                        local until_ = owner:GetAttribute("BonusDamageUntil") or 0
                        if now < until_ then
                            damage = baseDamage * ctx.WaveConfig.finalBossBonusMultiplier
                        end
                    end
                    local range    = towerModel:GetAttribute("Range")    or 25
                    local fireRate = towerModel:GetAttribute("FireRate") or 1
                    local aoeRadius = towerModel:GetAttribute("AoeRadius")
                    local lastFire = towerLastFire[towerModel] or 0
                    -- Effective fire rate scales with ctx.gameSpeed so towers
                    -- shoot in proportion to mob movement during 2x/3x/5x/10x.
                    local interval = 1 / (fireRate * ctx.gameSpeed)
                    if now - lastFire >= interval then
                        local tp = towerBase.Position
                        local mode = towerModel:GetAttribute("TargetMode") or "First"
                        local target = ctx.findTarget(tp, range, mode)
                        if target then
                            -- Lob branch (MushroomMortar): arcing shot with delayed
                            -- AOE at snapshotted landing position. Replaces normal
                            -- instant-hit path because "damage on landing" is the
                            -- whole point of the mechanic.
                            local lobSeconds = towerModel:GetAttribute("LobSeconds")
                            if lobSeconds and lobSeconds > 0 then
                                local blastRadius = towerModel:GetAttribute("BlastRadius") or 8
                                local landPos = target.Position
                                local lobColor = towerModel:GetAttribute("ProjectileColor")
                                    or Color3.fromRGB(180, 140, 90)

                                local ball = Instance.new("Part")
                                ball.Shape = Enum.PartType.Ball
                                ball.Size = Vector3.new(2.5, 2.5, 2.5)
                                ball.Anchored = true
                                ball.CanCollide = false
                                ball.CastShadow = false
                                ball.Color = lobColor
                                ball.Material = Enum.Material.Neon
                                ball.Parent = workspace

                                local fromPos = tp + Vector3.new(0, 18, 0)
                                -- Bezier control point above midpoint for the arc.
                                local mid = fromPos:Lerp(landPos, 0.5) + Vector3.new(0, 40, 0)
                                local landedDamage = damage   -- snapshot here; tower
                                                               -- attributes may change before lob
                                                               -- lands (upgrades, etc.)
                                local landedTower = towerModel
                                task.spawn(function()
                                    local startT = os.clock()
                                    while os.clock() - startT < lobSeconds do
                                        local t = math.min(1, (os.clock() - startT) / lobSeconds)
                                        local p = (1 - t)^2 * fromPos
                                                + 2 * (1 - t) * t * mid
                                                + t^2 * landPos
                                        ball.Position = p
                                        task.wait()
                                    end
                                    ball:Destroy()
                                    ctx.spawnAoeBurst(landPos, blastRadius)
                                    local hitNow = os.clock()
                                    for mob, _ in pairs(ctx.activeMobs) do
                                        if mob.Parent
                                           and (mob.Position - landPos).Magnitude <= blastRadius then
                                            ctx.damageMob(mob, landedDamage, landedTower)
                                            applyTempTowerDebuffs(landedTower, mob, hitNow, false)
                                        end
                                    end
                                end)

                                towerLastFire[towerModel] = now
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
                            ctx.fireBolt(tp + Vector3.new(0, 10, 0), target.Position, boltColor)

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
                            local patchRadius = towerModel:GetAttribute("PatchRadius")
                            if patchRadius and patchRadius > 0 and ctx.spawnZone then
                                ctx.spawnZone({
                                    position     = target.Position,
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
                                ctx.spawnZone({
                                    position    = target.Position,
                                    radius      = cloudRadius,
                                    lifetime    = towerModel:GetAttribute("CloudSeconds") or 3,
                                    tickDmg     = towerModel:GetAttribute("CloudTickDmg") or 3,
                                    tickPerSec  = towerModel:GetAttribute("CloudTickPerSec") or 4,
                                    color       = Color3.fromRGB(140, 230, 140),
                                    sourceTower = towerModel,
                                })
                            end

                            towerLastFire[towerModel] = now
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
