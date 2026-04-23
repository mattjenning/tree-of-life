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

local MobUpdate = {}

function MobUpdate.setup(ctx)
    local function updateMobs(dt)
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
                if data.bbAnchor then
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

                local stunned = data.stunUntil and now < data.stunUntil
                -- Boss freezes during phase wind-up (the 1.2s stop-and-
                -- vibrate before the tap spots launch). Only applies to
                -- the final boss.
                local windingUp = (mob == ctx.FinalBossState.instance) and (now < ctx.FinalBossState.windupUntil)
                local targetIdx = data.waypointIndex
                local targetWp = waypoints[targetIdx]
                if targetWp then
                    local current = mob.Position
                    if not stunned and not knocking and not windingUp then
                        local target = targetWp.Position
                        target = Vector3.new(target.X, current.Y, target.Z)
                        local diff = target - current
                        local distance = diff.Magnitude
                        local stepDist = data.speed * dt
                        if stepDist >= distance then
                            mob.CFrame = CFrame.new(target)
                            data.waypointIndex = data.waypointIndex + 1
                            if data.waypointIndex > #waypoints then
                                if heart then
                                    local hp = heart:GetAttribute("Health") or 0
                                    local dmg = data.damage or data.maxHp
                                    local inGrace = os.clock() < ctx.PhoenixGrace.activeUntil

                                    if inGrace then
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
                                        heart:SetAttribute("Health", math.max(0, hp - dmg))
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
                    -- stunned/knocked).
                    if data.bbAnchor and mob.Parent then
                        data.bbAnchor.CFrame = mob.CFrame + Vector3.new(0, data.size * 0.9, 0)
                    end
                    -- Stun stars: 3 small yellow parts orbiting above
                    -- the mob's head.
                    if stunned then
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
