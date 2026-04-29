--[[
    MobUpdate.lua — Per-frame mob update loop.

    Owns the function called once per Heartbeat from the orchestrator's
    main loop: walks ctx.activeMobs, advances each mob along its waypoint
    path (unless stunned / knocked / winding-up / Phoenix-burning / -queued),
    damages the heart when one reaches the end, and renders stun-star
    orbit visuals.

    Does NOT own:
      - dtscaling decision (game-speed) → uses ctx.gameSpeed
      - Phoenix capture / consume / limbo → delegates to Phoenix.lua
      - Boss phase windup → delegates to FinalBoss.lua (tickPhaseWindup
        still called here for convenience since it's once-per-frame)
      - Phoenix queue release → ctx.processPhoenixQueue

    setup(ctx) reads (late-resolved at call time):
      ctx.gameSpeed, ctx.getHeart, ctx.getWaypoints, ctx.activeMobs,
      ctx.tdRoom, ctx.tickPhaseWindup, ctx.processPhoenixQueue,
      ctx.PhoenixGrace, ctx.capturePhoenixAOEMobs, ctx.capturePhoenixMob,
      ctx.tryConsumePhoenix, ctx.moveToPhoenixLimbo, ctx.FinalBossState

    And publishes:
      ctx.updateMobs(dt)
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared  = ReplicatedStorage:WaitForChild("Shared")
local MobUtil = require(Shared:WaitForChild("MobUtil"))
local Tags    = require(Shared:WaitForChild("Tags"))

local MobUpdate = {}

function MobUpdate.setup(ctx)
    local function updateMobs(dt)
        -- Pause gate: when ctx.paused, skip the entire mob-update frame.
        -- Mobs freeze in place, knockback/phase-windup/phoenix-queue all
        -- halt. Stun/slow timestamps tick in wallclock (minor inconsistency
        -- — acceptable for MVP pause).
        if ctx.paused then return end
        -- Apply game-speed multiplier to time delta. All path movement
        -- (mob speeds along waypoints) uses dt — multiplying here scales
        -- the whole mob movement layer. Knockback below uses wall-clock
        -- so it visually stays the same brief slide regardless of game
        -- speed.
        dt = dt * ctx.gameSpeed
        local heart = ctx.getHeart()
        local waypoints = ctx.getWaypoints()
        local now = os.clock()

        -- Boss windup → phase-fire transition. Delegated to FinalBoss.lua
        -- which fires BossPhase to all clients once the windup elapses.
        ctx.tickPhaseWindup()

        -- Phoenix queue: if the queue has mobs waiting to be released,
        -- process their timed spawn. See comment on PhoenixQueue in
        -- systems/Phoenix.lua.
        ctx.processPhoenixQueue(now)

        -- Phoenix grace sweep: while grace is active, any mob that enters
        -- the AOE (and isn't already queued) gets captured into the
        -- respawn queue.
        if now < ctx.PhoenixGrace.activeUntil and heart and #waypoints > 0 then
            ctx.capturePhoenixAOEMobs(now, heart, waypoints)
        end

        for mob, data in pairs(ctx.activeMobs) do
            if not mob.Parent then
                ctx.activeMobs[mob] = nil
            elseif data._phoenixQueued then
                -- In Phoenix limbo: hidden offscreen, waiting to be
                -- released from the queue. Skip all update logic
                -- (movement, HP bar, etc.). The queue scheduler moves
                -- the mob back into play when due.
            elseif data._phoenixBurning then
                -- Phoenix burn-in-place phase: mob catches fire and
                -- freezes for 0.5s so players see the effect register,
                -- towers can get shots in, and then it transitions to
                -- limbo (queue). Still targetable and damageable during
                -- this window (tower-targeting check uses _phoenixQueued,
                -- not _phoenixBurning).
                -- Skip the HP-bar anchor sync in math-only mode
                -- (visual only; doesn't affect targeting / damage).
                if data.bbAnchor and not ctx.mathOnlyMode then
                    data.bbAnchor.CFrame = mob.CFrame + Vector3.new(0, data.size * 0.9, 0)
                end
                if now >= (data._phoenixBurnUntil or 0) then
                    ctx.moveToPhoenixLimbo(mob, data)
                end
            else
                -- Knockback slide (active while data.knockback set):
                -- overrides path.
                local knocking = false
                if data.knockback then
                    local kb = data.knockback
                    local t = (now - kb.startTime) / kb.duration
                    if t >= 1 then
                        -- Slide done: snap to final, clear state
                        mob.CFrame = CFrame.new(kb.toPos)
                        data.knockback = nil
                    else
                        -- Interpolate: ease-out (1 - (1-t)^2)
                        local ease = 1 - (1 - t) * (1 - t)
                        local pos = kb.fromPos:Lerp(kb.toPos, ease)
                        mob.CFrame = CFrame.new(pos)
                        knocking = true
                    end
                end

                -- stunUntil is in ctx.gameTime (game-seconds) after the
                -- 2026-04-27 timer-domain fix; check against game-clock,
                -- not wallclock os.clock(). Substep batches at high speed
                -- were inflating stun duration 10-20× game-time before.
                local gameNow = ctx.gameTime or 0

                -- ControlCore stacking-DOT tick (Stage 2 — Matthew
                -- 2026-04-27). Walks data.controlStacks, applies
                -- count × tickDmg damage per (1/tickPerSec) game-sec
                -- elapsed since lastTickAt. Prunes expired entries.
                -- Damage routed through ctx.damageMob so kill credit
                -- + StatLedger book-keeping flow normally.
                if data.controlStacks then
                    local toRemove
                    for sourceTower, entry in pairs(data.controlStacks) do
                        if not sourceTower or not sourceTower.Parent
                           or gameNow > (entry.expiresAt or 0) then
                            toRemove = toRemove or {}
                            table.insert(toRemove, sourceTower)
                        else
                            local interval = 1 / math.max(0.001, entry.tickPerSec or 2)
                            if gameNow - (entry.lastTickAt or 0) >= interval then
                                local dmg = (entry.count or 0) * (entry.tickDmg or 0)
                                if dmg > 0 and ctx.damageMob then
                                    ctx.damageMob(mob, dmg, sourceTower, true)  -- isChainDamage=true to skip TotalDamageDone double-count
                                end
                                entry.lastTickAt = gameNow
                            end
                        end
                    end
                    if toRemove then
                        for _, k in ipairs(toRemove) do
                            data.controlStacks[k] = nil
                        end
                    end
                end

                local stunned = data.stunUntil and gameNow < data.stunUntil
                -- Boss freezes during phase wind-up (the 1.2s stop-and-
                -- vibrate before the tap spots launch). Only applies to
                -- the final boss.
                local windingUp = (mob == ctx.FinalBossState.instance) and (now < ctx.FinalBossState.windupUntil)
                -- Web Weaver (map 2 boss) freezes for the web-attack
                -- duration. Attribute-based so the CanopySpiderBoss
                -- system can set it directly on the mob without touching
                -- MobUpdate internals.
                local webbingUntil = mob:GetAttribute("BossWebbing") or 0
                if now < webbingUntil then
                    windingUp = true  -- reuse the same "halt" gate
                end
                local targetIdx = data.waypointIndex
                local targetWp = waypoints[targetIdx]
                if targetWp then
                    local current = mob.Position
                    if not stunned and not knocking and not windingUp then
                        local target = targetWp.Position
                        target = Vector3.new(target.X, current.Y, target.Z)
                        local diff = target - current
                        local distance = diff.Magnitude
                        -- Per-source slow (Matthew 2026-04-27): each
                        -- slow source has its own timer entry on
                        -- data.slows. activeSlow returns the strongest
                        -- currently-active source's mult and prunes
                        -- expired entries. When the dominant source
                        -- expires, the next-strongest takes over
                        -- automatically.
                        local slowMult = 1.0
                        local effectiveMult = MobUtil.activeSlow(data, gameNow)
                        if effectiveMult then
                            slowMult = effectiveMult
                        end
                        -- 2026-04-29 ea3-29 (Phase C-2): ControlAddSlow
                        -- Core upgrade — multiplicative bonus slow on
                        -- top of the per-source strongest. 5% per
                        -- stack, persists 2s after each player-tower
                        -- hit (Towers.lua applyTempTowerDebuffs sets
                        -- data.controlBonusSlowMult + Expiry).
                        if (data.controlBonusSlowExpiry or 0) > gameNow then
                            slowMult = slowMult * (data.controlBonusSlowMult or 1)
                        end
                        -- Refresh the slow-visual highlight to match
                        -- the active source's color (or clear if no
                        -- source is active). Cheap per-frame.
                        MobUtil.refreshSlowVisual(mob, data, gameNow)
                        local stepDist = data.speed * slowMult * dt
                        if stepDist >= distance then
                            mob.CFrame = CFrame.new(target)
                            data.waypointIndex = data.waypointIndex + 1
                            if data.waypointIndex > #waypoints then
                                if heart then
                                    -- Damage = mob's REMAINING HP (not MaxHp). A
                                    -- mob with 100 max but 30 remaining deals 30.
                                    -- Lets the player whittle a tank mid-path so
                                    -- the punishment for letting it through is
                                    -- proportional to how undamaged it was when
                                    -- it landed. data.hp is mirrored onto the
                                    -- mob's Health attribute on every hit (see
                                    -- Damage.lua), so this stays in sync.
                                    local dmg = math.max(0, data.hp or 0)
                                    -- MAP-BOSS hard rule: if a tagged map boss
                                    -- (Mold King / Web Weaver / Canopy Bird) makes
                                    -- it to the heart, the run is OVER. Phoenix
                                    -- doesn't save you — the boss is the climactic
                                    -- threat per stage and reaching the heart is
                                    -- the lose condition by design. Set heart HP
                                    -- to 0 directly, skipping every phoenix branch.
                                    -- Tags.FinalBoss is only on the boss itself
                                    -- (escorts/spiderlings don't get it — see
                                    -- MobFactory's isEscort gate), so this won't
                                    -- false-trigger on web-weaver minions.
                                    local isMapBoss = CollectionService:HasTag(mob, Tags.FinalBoss)
                                    local inGrace = os.clock() < ctx.PhoenixGrace.activeUntil

                                    if isMapBoss then
                                        heart:SetAttribute("Health", 0)
                                        ctx.activeMobs[mob] = nil
                                        mob:Destroy()
                                    elseif inGrace then
                                        -- Active Phoenix grace window:
                                        -- the per-frame AOE sweep
                                        -- normally catches mobs before
                                        -- they reach the heart; but if
                                        -- one slips through (frame-skip,
                                        -- boss knockback), we queue it
                                        -- here with its current HP so it
                                        -- also goes through the phoenix
                                        -- staggered respawn.
                                        ctx.capturePhoenixMob(mob, data, waypoints)
                                    elseif ctx.tryConsumePhoenix() then
                                        -- Phoenix fired: this mob has
                                        -- been queued by
                                        -- capturePhoenixAOEMobs inside
                                        -- tryConsumePhoenix. Do nothing
                                        -- else.
                                    else
                                        -- Shared heart-damage helper: same canonical
                                        -- math the egg path uses (Map3BirdBoss). One
                                        -- call site for the actual SetAttribute keeps
                                        -- both flows from drifting.
                                        --
                                        -- OVERKILL CAPTURE (Infinite Arena partial-
                                        -- wave-clear formula): read heart HP BEFORE
                                        -- the damage call so we can compute how much
                                        -- of the mob's hit was wasted past 0. A 20k
                                        -- boss vs 10k heart = 10k overkill = 10k
                                        -- "extra threat" the wave brought that the
                                        -- run never had to absorb. Fed to Infinite
                                        -- via ctx.onHeartOverkill so exit()'s
                                        -- fractionalWave can grow the denominator
                                        -- and shrink the partial-clear score for
                                        -- runs that died to a wildly over-tuned
                                        -- mob (vs. dying to one that JUST nicked
                                        -- the heart for the killing blow).
                                        local heartHpBefore = (heart :: any):GetAttribute("Health") or 0
                                        if type(heartHpBefore) ~= "number" then heartHpBefore = 0 end
                                        MobUtil.damageHeart(heart, dmg)
                                        -- Fire onHeartOverkill ONLY when the mob
                                        -- actually killed the heart (dmg >=
                                        -- heartHpBefore). Earlier code fired
                                        -- on every heart-hit which broke wave-
                                        -- attribution: a wave-1 basic that just
                                        -- chipped the heart fired the callback
                                        -- and got captured as "the killing mob"
                                        -- via first-write-wins, so all later
                                        -- runs scored as wave 1.X.
                                        if ctx.onHeartOverkill and dmg >= heartHpBefore then
                                            local overkill = math.max(0, dmg - heartHpBefore)
                                            ctx.onHeartOverkill(overkill, dmg, heartHpBefore, mob)
                                        end
                                        ctx.activeMobs[mob] = nil
                                        mob:Destroy()
                                    end
                                else
                                    ctx.activeMobs[mob] = nil
                                    mob:Destroy()
                                end
                            end
                        else
                            local dir = diff.Unit
                            mob.CFrame = CFrame.new(current + dir * stepDist)
                        end
                    end
                    -- Always update HP bar anchor (so it tracks even when
                    -- stunned/knocked). Skipped in math-only mode —
                    -- visual only; doesn't affect targeting/damage.
                    if data.bbAnchor and mob.Parent and not ctx.mathOnlyMode then
                        data.bbAnchor.CFrame = mob.CFrame + Vector3.new(0, data.size * 0.9, 0)
                    end
                    -- Stun stars: 3 small yellow parts orbiting above
                    -- the mob's head. Skipped in math-only mode
                    -- (purely cosmetic; doesn't affect stun timing
                    -- or damage). At 100× speed with many stunned
                    -- mobs the orbit math + Instance.new spam was
                    -- ~10% of the per-frame budget.
                    if stunned and not ctx.mathOnlyMode then
                        if not data.stunStars then
                            local stars = {}
                            for i = 1, 3 do
                                local star = Instance.new("Part")
                                star.Name = "StunStar"
                                star.Shape = Enum.PartType.Ball
                                star.Size = Vector3.new(0.45, 0.45, 0.45)
                                star.Anchored = true
                                star.CanCollide = false
                                star.CastShadow = false
                                star.Material = Enum.Material.Neon
                                star.Color = Color3.fromRGB(255, 230, 60)
                                star.Parent = ctx.tdRoom
                                stars[i] = star
                            end
                            data.stunStars = stars
                        end
                        -- Orbit them around a point just above the mob's
                        -- head.
                        local ox = mob.Position.X
                        local oz = mob.Position.Z
                        local oy = mob.Position.Y + data.size * 0.9 + 0.3
                        local radius = data.size * 0.45
                        local angleBase = now * 4  -- orbit speed
                        for i, star in ipairs(data.stunStars) do
                            local a = angleBase + (i - 1) * (2 * math.pi / 3)
                            star.CFrame = CFrame.new(ox + math.cos(a) * radius, oy, oz + math.sin(a) * radius)
                        end
                    else
                        if data.stunStars then
                            for _, star in ipairs(data.stunStars) do star:Destroy() end
                            data.stunStars = nil
                        end
                    end
                else
                    -- Out of waypoints — clean up any attached visuals.
                    if data.stunStars then
                        for _, star in ipairs(data.stunStars) do star:Destroy() end
                        data.stunStars = nil
                    end
                    ctx.activeMobs[mob] = nil
                    mob:Destroy()
                end
            end
        end
    end

    ctx.updateMobs = updateMobs
end

return MobUpdate
