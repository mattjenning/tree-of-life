--[[
    PickleLordBoss.lua — The RUN BOSS encounter on map 3.

    Triggered AFTER the player claims their map-3 temp-tower reward (i.e.
    on BossRewardClaimed mapId=3, NOT on BossDefeated mapId=3 — the spec
    explicitly chains through the temp picker first). On HP=0 the chain
    fires PickleLordDefeated, which PermanentTowers.lua picks up to show
    the permanent-tower picker; on permanent claim, RunVictory plays and
    the player returns to the hub.

    Original spec: docs/pickle-lord-spec.md. Everything tunable lives in
    Config.Map3.PickleLord. The build has diverged from the original spec
    in a few places per playtest iteration — see the per-section notes.

    GEOMETRY:
      Single tall green Block (BodyWidth × BodyTotalHeight × BodyDepth)
      positioned BodyOffsetFromCenter studs behind MAP3_CENTER. Only the
      top BodyVisibleHeight studs poke above the platform — body bulk
      extends down into the void below the back edge. Painted face on
      the +Z side: two NEON eye balls with black pupil balls, two angled
      eyebrows, a frown mouth. A green SpotLight sits 4 studs below the
      feet, aimed UP, lighting the boss from underneath in pickle-shard
      green (UnderlightBrightness / UnderlightRange).

    ENTRANCE:
      Slow rise — model spawns at its final pivot, then immediately
      pivots DOWN by RiseDistance. A spawned task tweens the pivot back
      up over RiseSec wallclock seconds (ease-out cubic) so the boss
      visually emerges from below. PlayPickleLordEntrance fires to all
      clients at spawn time, triggering a moonlit-blue + foggy lighting
      tween. NO environment destruction (per 2026-04-25 — original spec
      had branches/leaves/flowers blowing apart, this was reverted).

    SMASH:
      Every SmashIntervalGameSec (game-time) the boss picks a random
      player and runs:
        1. WINDUP — eye glow ramps over EyeGlowRampSec (PointLight 0→3,
           Material switches to Neon), body slowly rotates to face the
           target at SmashRotationRadPerSec (~20°/s). Beams + smash
           circle DON'T appear until rotation completes; if the body's
           already facing the target the windup is rotation-free and
           beams come out immediately.
        2. LOCK-ON — a SmashRadiusStuds-radius Cylinder spawns on the
           floor at the target's current XZ; two thin Neon Block beams
           project from each eye to the smash zone. Both fade from
           outline-transparent to solid over SmashTotalSec wallclock.
           Game speed locked at 1× for the whole windup + lock-on.
        3. RESOLVE — every owned tower whose XZ distance to the circle
           center ≤ radius gets a green-flame consumption VFX (Fire
           instance + dark-tween + transparency fade) and is destroyed
           after a 0.55s burn; player's stock is restored immediately.
           Player damage currently DISABLED for playtest — re-enable by
           uncommenting the loop in performSmash.

      Range decay every RangeDecayIntervalGameSec (game-time) — multiplies
      each player's RangeDecayMultiplier attribute by RangeDecayMultiplier
      (0.9 per tick, no floor). Towers.lua reads it in findTarget.

    ATTRIBUTES set on the player:
      RangeDecayMultiplier  (number, 0..1) — Towers.lua reads this in findTarget.
                                              Cleared on RunReset / SwitchMap /
                                              PickleLordDefeated.

    setup(ctx) reads:
      ctx.MAP3_CENTER  — arena geometry (also drives smash-circle Y math)
      ctx.makePart     — shared part factory

    Publishes:
      ctx.startPickleLord()      — begin the encounter
      ctx.stopPickleLord(killed) — abort early (dev / cleanup); pass
                                   true if HP=0 path so the reward chain
                                   fires.
]]

local CollectionService = game:GetService("CollectionService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

local ServerScriptService = game:GetService("ServerScriptService")

local Shared   = ReplicatedStorage:WaitForChild("Shared")
local Config   = require(Shared:WaitForChild("Config"))
local GameTime = require(Shared:WaitForChild("GameTime"))
local Maid     = require(Shared:WaitForChild("Maid"))
local MobUtil  = require(Shared:WaitForChild("MobUtil"))
local Remotes  = require(Shared:WaitForChild("Remotes"))
local Tags     = require(Shared:WaitForChild("Tags"))

-- PermanentTowerStore exposes a tiny per-player prefs table (the same
-- one used for hasSeenFirstDeathFairy, etc). We piggyback on it for
-- the cinematic skip-hint flag instead of standing up a new
-- DataStore — the prefs API already persists across sessions.
local PermanentTowerStore =
    require(ServerScriptService:WaitForChild("PermanentTowerStore"))

local PickleLordBoss = {}

function PickleLordBoss.setup(ctx)
    local PL          = Config.Map3.PickleLord
    local MAP3_CENTER = ctx.MAP3_CENTER
    local makePart    = ctx.makePart

    -- Per-encounter state. cleared on stopPickleLord; the maid drops
    -- every spawned thread / part / connection in one call. State.active
    -- gates the loops so a re-trigger (post-defeat) isn't possible
    -- mid-fight.
    local State = {
        active             = false,
        body               = nil,    -- BasePart for the visible boss
        eyes               = nil,    -- {leftEye, rightEye} BaseParts; smash beams project from these
        model              = nil,    -- container Model (cleanup root)
        startedAt          = 0,      -- os.clock() at start; pacing loops anchor here
        smashLockReleases  = {},     -- in-flight speed-lock releases; smash safety can pop
        riseComplete       = false,  -- true once the entrance rise tween finishes; smash loop waits on this
        maid               = nil,
    }

    local pickleLordBindable = Remotes.getOrCreate(Remotes.Names.PickleLordDefeated, "BindableEvent")
    local playEntranceRemote = Remotes.getOrCreate(Remotes.Names.PlayPickleLordEntrance, "RemoteEvent")
    local playSmashRemote    = Remotes.getOrCreate(Remotes.Names.PlayPickleLordSmash,   "RemoteEvent")
    local cinematicEndedRemote = Remotes.getOrCreate(Remotes.Names.PickleLordCinematicEnded, "RemoteEvent")

    -- Fast-forward the entrance rise on cinematic-skip. Client fires
    -- this when their cinematic ends (skip OR natural). The rise
    -- task picks up State.cinematicSkipped on its next tick and
    -- snaps to the landing pivot, flagging riseComplete=true so the
    -- smash loop + tower targetability flip on immediately. If the
    -- rise has already completed naturally (timing match), this is
    -- a noop. Server-trusted: any client can fire this safely
    -- because all it does is shorten the boss's grace period.
    cinematicEndedRemote.OnServerEvent:Connect(function(_player)
        if State.active and not State.riseComplete then
            State.cinematicSkipped = true
        end
    end)

    -- Build the boss model: a giant green Block positioned off the platform
    -- edge so only the top reads. The body's local origin is at GEOMETRIC
    -- center; we shift it down by (TotalHeight/2 - VisibleHeight) so the
    -- top edge sits ~VisibleHeight above the platform. CollectionService
    -- tag FinalBoss makes broadcastWaveState pick him up for the HUD HP
    -- bar exactly like the bird / spider / mold king.
    local function buildModel(originPos)
        local model = Instance.new("Model")
        model.Name = "PickleLord"
        model.Parent = Workspace

        -- Base position calculation: top of body should sit BodyVisibleHeight
        -- above the platform (i.e. above originPos.Y). Body center then sits
        -- at originPos.Y + BodyVisibleHeight - BodyTotalHeight/2.
        local centerY = originPos.Y + PL.BodyVisibleHeight - PL.BodyTotalHeight * 0.5
        local bodyPos = Vector3.new(originPos.X, centerY, originPos.Z)

        -- Body is a default Block Part with a SpecialMesh (MeshType.Sphere)
        -- child that overrides rendering to a stretched ellipsoid. Tried
        -- Shape=Ball first but Roblox renders that as a sphere using the
        -- smallest dimension — the body became tiny + invisible at our
        -- (62, 440, 52) Size. SpecialMesh actually stretches the sphere
        -- to fill the Part's bounding box, giving the pickle silhouette.
        --
        -- Collision/positioning math still uses the bounding-box dimensions
        -- (BodyWidth × BodyTotalHeight × BodyDepth). Face features below
        -- are placed on the actual ellipsoid surface using
        -- ellipsoidSurfaceZ() to avoid floating outside the visible mesh.
        local body = makePart({
            Name         = "PickleLordBody",
            Size         = Vector3.new(PL.BodyWidth, PL.BodyTotalHeight, PL.BodyDepth),
            CFrame       = CFrame.new(bodyPos),
            Material     = Enum.Material.Slate,
            Color        = PL.BodyColor,
            CanCollide   = true,
            Parent       = model,
        })
        do
            local mesh = Instance.new("SpecialMesh")
            mesh.MeshType = Enum.MeshType.Sphere
            mesh.Parent = body
        end
        body:SetAttribute("MaxHealth", PL.Hp)
        body:SetAttribute("Health",    PL.Hp)
        body:SetAttribute("DisplayName", "The Pickle Lord")
        -- Targeting helpers (read by Targeting.lua's tag-fallback). The
        -- body is 62×52 stud and 440 stud tall with center 125 stud
        -- below the platform; without these, towers compute 3D distance
        -- to a buried centroid and can never reach it.
        --   TargetXZOnly: collapse distance to horizontal — boss is so
        --     tall the Y component never matters in practice.
        --   TargetRadius: half body width (31 stud) — towers shooting
        --     within this many studs of the body silhouette count as
        --     in-range, matching "outer edge of model" intuition.
        body:SetAttribute("TargetXZOnly", true)
        body:SetAttribute("TargetRadius", math.max(PL.BodyWidth, PL.BodyDepth) * 0.5)
        -- TargetAimOffsetY: lifts the EFFECTIVE aim point from the
        -- (buried) body center to roughly platform Y + 2 stud
        -- (player head height). Read by Towers.lua's bolt-aim path
        -- + by the client manual-target indicator. Without it
        -- bolts visually fly toward the body's geometric center
        -- which sits below the floor, and the bullseye / TARGET
        -- bracket adornment lands underground too.
        --   body.Y = origin.Y - (BodyTotalHeight/2 - BodyVisibleHeight)
        --          = origin.Y - 125  (with H=440, visible=95)
        --   head Y ≈ origin.Y + 2
        --   offset = (origin.Y + 2) - body.Y = 127
        body:SetAttribute("TargetAimOffsetY",
            (PL.BodyTotalHeight * 0.5) - PL.BodyVisibleHeight + 2)
        -- Untargetable until the rise/cinematic finishes. Cleared in
        -- the rise-complete branch below. Without this, towers start
        -- firing bolts at the still-rising boss the moment he's
        -- workspace-parented — visible during the cinematic and
        -- looks weird.
        body:SetAttribute("Untargetable", true)
        CollectionService:AddTag(body, Tags.FinalBoss)
        -- Tags.Mob is what Targeting.lua's tag-fallback iterator uses for
        -- standalone targets that live outside ctx.activeMobs (the bird
        -- body uses the same pattern). Without this, towers ignore the
        -- Pickle Lord and the player can't damage him. Damage.lua's
        -- standalone-mob branch handles HP via the Health attribute the
        -- HP=0 listener below picks up.
        CollectionService:AddTag(body, Tags.Mob)

        -- Pre-compute face Y anchors. With the body now an ellipsoid
        -- (Shape = Ball), the face features need to sit on the ACTUAL
        -- ellipsoid surface rather than on the bounding-box +Z plane —
        -- otherwise they float in space outside the visible silhouette.
        -- Y values pulled DOWN from the original (-8 / -18 from top)
        -- because at extreme Y/half-height ratios (>0.95) the ellipsoid
        -- narrows so much in X-Z that the eyes / brows wouldn't fit on
        -- the surface at their X = ±4.5 offset.
        local topY      = originPos.Y + PL.BodyVisibleHeight
        -- Y offsets sized for BodyVisibleHeight = 80. Proportions same
        -- as the prior 140-tall layout — eyes ~26% from apex, brows
        -- just above eyes, mouth ~64% down (the "red line" from
        -- playtest). With visible body shorter the face peeks above
        -- the canopy as a head-and-shoulders silhouette.
        local eyeY      = topY - 21
        local browY     = eyeY + 4
        local mouthY    = topY - 51

        -- Ellipsoid surface helper: returns the +Z surface point for a
        -- given (xOffset, yAboveCenter), using the body's semi-axes
        -- (a, b, c) = (BodyWidth/2, BodyTotalHeight/2, BodyDepth/2).
        -- If the (x, y) is outside the ellipsoid, returns 0 (face
        -- feature ends up at body center Z, which is invisible behind
        -- the body — safer than sticking out wrong).
        local function ellipsoidSurfaceZ(xOff, yAbove)
            local a = PL.BodyWidth * 0.5
            local b = PL.BodyTotalHeight * 0.5
            local c = PL.BodyDepth * 0.5
            local term = 1 - (xOff / a) ^ 2 - (yAbove / b) ^ 2
            if term <= 0 then return 0 end
            return c * math.sqrt(term)
        end

        -- Underlight: green SpotLight at the BASE of the visible body,
        -- placed just barely outside the body's front face plane,
        -- aimed straight UP. Narrow cone designed so the cone's top
        -- edge lands right at the top of the head — a tight pillar of
        -- light traveling up the body, brightest at the base, tapering
        -- as it reaches the face. Classic horror-movie uplight without
        -- the wide-flood look.
        --
        -- Geometry:
        --   • Y = MAP3_CENTER.Y (even with platform Y per playtest)
        --     so the cone has the entire upper body to climb.
        --   • Z = front face + 0.3 stud — "just barely away from the
        --     body" per playtest, basically grazing the surface so the
        --     light hits the face plane head-on without being inside
        --     the body itself.
        --   • Angle 22°: half-angle 11° at 70 stud above gives a cone
        --     radius of ~13.5 stud at the head — exactly enough to
        --     cover the BodyWidth/2 = 13 footprint with a hair of
        --     margin. Tighter cone keeps the eye-stripe lit while the
        --     edge falls off above the head (no flood spillover).
        --
        -- Shadows DISABLED so the canopy foliage between the platform
        -- and the boss doesn't break the cone.
        local underlightAnchor = makePart({
            Name         = "PickleLordUnderlight",
            Size         = Vector3.new(1, 1, 1),
            CFrame       = CFrame.new(
                bodyPos.X,
                MAP3_CENTER.Y,
                bodyPos.Z + PL.BodyDepth * 0.5 + 0.3),
            Transparency = 1,
            CanCollide   = false,
            Parent       = model,
        })
        local underlight = Instance.new("SpotLight")
        underlight.Color      = PL.ShardColor
        underlight.Brightness = PL.UnderlightBrightness or 25
        underlight.Range      = PL.UnderlightRange or 90
        -- 28° cone — at the doubled body height (140 visible), tan(14°)
        -- = 0.249 → cone radius at the head ≈ 35 stud, just covering
        -- BodyWidth/2 = 31. Tight pillar of light up the body ending
        -- at the head, same idea as before scaled to the bigger body.
        underlight.Angle      = 28
        underlight.Face       = Enum.NormalId.Top  -- points up at the boss's face
        underlight.Shadows    = false        -- canopy leaves don't block the cone
        underlight.Parent     = underlightAnchor

        -- Painted face on the body's +Z hemisphere (the side that faces
        -- the arena center / player vantage — boss is at MAP3_CENTER +
        -- (0, 0, -BodyOffsetFromCenter), so +Z = toward the player).
        -- Two eyes with black pupils, two angry-angled eyebrows, and a
        -- frown mouth. Each part's Z is computed by ellipsoidSurfaceZ
        -- from its (x, y) so the feature sits ON the ellipsoid surface
        -- rather than the bounding-box face.
        local eyeXOffset = 9
        local SURFACE_PEEK = 0.08  -- tiny push so the face peeks slightly proud of the surface
        local bodyCenterY  = bodyPos.Y
        local function makeFacePart(name, size, x, y, z, mat, color, rot)
            return makePart({
                Name       = name,
                Size       = size,
                CFrame     = CFrame.new(x, y, z) * (rot or CFrame.new()),
                Material   = mat,
                Color      = color,
                CanCollide = false,
                Parent     = model,
            })
        end
        -- Eyes: white sclera ball + black pupil ball. SpecialMesh sphere
        -- keeps each feature circular regardless of the parent Part's
        -- own Shape rendering.
        --
        -- Eyes use SmoothPlastic at IDLE — dull white sclera that does
        -- NOT glow. Each carries a PointLight with Brightness=0 so the
        -- smash routine can light it up by toggling Brightness +
        -- swapping to Neon material when the cones project. Per Matthew
        -- (2026-04-25): "eyes only glow when charging the smash."
        -- Saved to State.eyes so performSmash can find both for the
        -- charge effect + for projecting the cones from each one.
        local eyes = {}
        for _, sign in ipairs({-1, 1}) do
            local eyeZ = bodyPos.Z
                + ellipsoidSurfaceZ(eyeXOffset, eyeY - bodyCenterY)
                + SURFACE_PEEK
            local eye = makeFacePart("PickleLordEye",
                Vector3.new(5.2, 5.2, 1.2),
                bodyPos.X + sign * eyeXOffset, eyeY, eyeZ,
                Enum.Material.SmoothPlastic,
                Color3.fromRGB(245, 245, 235))
            local mesh = Instance.new("SpecialMesh")
            mesh.MeshType = Enum.MeshType.Sphere
            mesh.Parent = eye
            local eyeLight = Instance.new("PointLight")
            eyeLight.Color = Color3.fromRGB(255, 250, 220)
            eyeLight.Brightness = 0  -- idle off; performSmash sets to ~3 during charge
            eyeLight.Range = 8
            eyeLight.Parent = eye
            local pupil = makeFacePart("PickleLordPupil",
                Vector3.new(2.2, 2.2, 0.8),
                bodyPos.X + sign * eyeXOffset, eyeY, eyeZ + 1.0,
                Enum.Material.SmoothPlastic,
                Color3.fromRGB(15, 12, 10))
            local pmesh = Instance.new("SpecialMesh")
            pmesh.MeshType = Enum.MeshType.Sphere
            pmesh.Parent = pupil
            table.insert(eyes, eye)
        end
        State.eyes = eyes
        -- Eyebrows: thin tilted Parts angled inward toward the nose.
        -- Sign×rot pattern mirrors them so both slant down toward center.
        for _, sign in ipairs({-1, 1}) do
            local browZ = bodyPos.Z
                + ellipsoidSurfaceZ(eyeXOffset, browY - bodyCenterY)
                + SURFACE_PEEK
            makeFacePart("PickleLordBrow",
                Vector3.new(7.2, 1.4, 1.0),
                bodyPos.X + sign * eyeXOffset, browY, browZ,
                Enum.Material.SmoothPlastic,
                Color3.fromRGB(25, 35, 18),
                CFrame.Angles(0, 0, math.rad(sign * -22)))
        end
        -- Frown mouth: a single curved-feeling Part. Slight downward
        -- tilt at the ends would require multiple segments; for v1 a
        -- straight wide bar reads "stern" + scales cheaply.
        local mouthZ = bodyPos.Z
            + ellipsoidSurfaceZ(0, mouthY - bodyCenterY)
            + SURFACE_PEEK
        makeFacePart("PickleLordMouth",
            Vector3.new(14, 1.6, 1.0),
            bodyPos.X, mouthY, mouthZ,
            Enum.Material.SmoothPlastic,
            Color3.fromRGB(25, 35, 18))

        -- Bumps: ~50 small green spheres scattered on the upper portion
        -- of the ellipsoid surface — gives the boss the warty texture
        -- of a real pickle. Each bump is sampled by spherical coords
        -- (theta, phi) on a unit sphere with the polar component
        -- biased to the UPPER hemisphere (uy ≥ 0.3) so we don't waste
        -- bumps on the hidden lower portion of the body.
        do
            -- Bump count bumped per playtest 2026-04-26 to match
            -- the pickle reference photo's denser warty surface.
            local NUM_BUMPS = 140
            local bumpColor = Color3.fromRGB(85, 140, 65)
            local a = PL.BodyWidth * 0.5
            local b = PL.BodyTotalHeight * 0.5
            local c = PL.BodyDepth * 0.5
            for _ = 1, NUM_BUMPS do
                -- uy biased toward the middle band of the visible body
                -- (per pickle reference photo — bumps cluster around
                -- the equator, fewer at the very tips). Triangle
                -- distribution: average two uniform samples in [0.35,
                -- 0.85], peak around 0.6.
                local uy = ((0.35 + math.random() * 0.5)
                          + (0.35 + math.random() * 0.5)) * 0.5
                local theta = math.random() * 2 * math.pi
                local sinPhi = math.sqrt(math.max(0, 1 - uy * uy))
                local ux = math.cos(theta) * sinPhi
                local uz = math.sin(theta) * sinPhi
                -- Surface position on the ellipsoid.
                local sx = bodyPos.X + a * ux
                local sy = bodyPos.Y + b * uy
                local sz = bodyPos.Z + c * uz
                -- Bump diameter — varied so the texture reads as
                -- organic instead of a uniform grid of dots.
                local bumpSize = 2.5 + math.random() * 4.0
                local bump = makePart({
                    Name         = "PickleLordBump",
                    Size         = Vector3.new(bumpSize, bumpSize, bumpSize),
                    CFrame       = CFrame.new(sx, sy, sz),
                    Material     = Enum.Material.SmoothPlastic,
                    Color        = bumpColor,
                    CanCollide   = false,
                    Parent       = model,
                })
                -- SpecialMesh sphere keeps the bump round at any size
                -- (vs Shape=Ball pitfall — see body comment above).
                local bMesh = Instance.new("SpecialMesh")
                bMesh.MeshType = Enum.MeshType.Sphere
                bMesh.Parent = bump
            end
        end

        -- Set body as PrimaryPart so Model:PivotTo() rotates the whole
        -- model (face features + bumps + underlight included) when the
        -- boss turns to face a smash target.
        model.PrimaryPart = body

        -- Forward tilt for the pickle banana-curve. Top leans toward
        -- +Z (toward the player / arena center) by 8° around the X
        -- axis. PivotTo applied AFTER all parts are built so they
        -- rotate around body's center together. The underlight tilts
        -- with the body (its cone tilts forward 8°), but the cone is
        -- still wide enough to cover the face from below — verified
        -- the offset stays inside the cone with the new dimensions.
        model:PivotTo(CFrame.new(bodyPos) * CFrame.Angles(math.rad(8), 0, 0))

        State.body  = body
        State.model = model
        return body
    end

    ----------------------------------------------------------------
    -- SMASH ATTACK
    ----------------------------------------------------------------
    -- Pick the smash target. If multiple players, pick a random one;
    -- single-player runs always target the same player. Returns the
    -- player AND their HumanoidRootPart position (XZ used; Y normalized
    -- to platform level for the floor circle).
    local function pickSmashTarget()
        local players = Players:GetPlayers()
        if #players == 0 then return nil, nil end
        local pick = players[math.random(1, #players)]
        local char = pick.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return pick, nil end
        return pick, hrp.Position
    end

    -- One smash cycle: telegraph → 3s wallclock at 1× → resolve.
    -- Resolve walks Tags.Tower for tower-in-circle (destroys + restores
    -- stock), and the player Character for player-in-circle (kills).
    local function performSmash()
        if not State.active then return end
        if not State.riseComplete then return end  -- boss still rising; smash later
        local _, targetPos = pickSmashTarget()
        if not targetPos then return end

        -- Project to platform level. Map3's floor TOP sits at
        -- MAP3_CENTER.Y + 1 (the 2-stud floor centered on MAP3_CENTER.Y).
        -- Disc center sits 0.2 stud above floor top so the disc top is
        -- only ~0.4 stud proud of the floor surface — visible as a flat
        -- glow but doesn't cover the player's feet/legs.
        local floorTopY = MAP3_CENTER.Y + 1
        local platformY = floorTopY + 0.2
        local circleCenter = Vector3.new(targetPos.X, platformY, targetPos.Z)

        -- ============================================================
        -- WINDUP — eye glow ramps over EyeGlowRampSec while the body
        -- slowly rotates to face the smash target. Beams + smash circle
        -- DON'T appear until the body finishes rotating; if rotation is
        -- short (small angle), beams come out early. Both eye-ramp and
        -- rotation run during the speed-locked phase so wallclock and
        -- game-time agree.
        -- ============================================================
        local release = GameTime.lockSpeed()
        table.insert(State.smashLockReleases, release)
        local TweenService = game:GetService("TweenService")

        -- Eye glow ramp: PointLight Brightness 0 → 3 over EyeGlowRampSec
        -- (independent task, runs in parallel with rotation). Material
        -- can't be tweened so it flips to Neon up front; the ramp is
        -- carried entirely by Brightness easing in. Eyes finish glowing
        -- before / during / after beam-spawn depending on rotation
        -- duration; that's the intended "eyes still flaring up as the
        -- cones fire" beat for tight-angle smashes.
        for _, eye in ipairs(State.eyes or {}) do
            if eye and eye.Parent then
                eye.Material = Enum.Material.Neon
                local lt = eye:FindFirstChildOfClass("PointLight")
                if lt then
                    lt.Brightness = 0
                    TweenService:Create(lt,
                        TweenInfo.new(PL.EyeGlowRampSec or 3,
                            Enum.EasingStyle.Quad,
                            Enum.EasingDirection.Out),
                        { Brightness = 3 }
                    ):Play()
                end
            end
        end

        -- Slow rotation toward target. Compute current/target yaw,
        -- normalize the delta to [-π, π] for shortest-path rotation,
        -- then drive the model's pivot per-frame at SmashRotationRadPerSec
        -- until alignment. If the body is already facing the target,
        -- this loop exits immediately (delta ≈ 0) and beams spawn
        -- without delay.
        if State.body and State.body.Parent then
            local bp = State.body.Position
            local dx = circleCenter.X - bp.X
            local dz = circleCenter.Z - bp.Z
            local targetYaw = math.atan2(dx, dz)
            local _, currentYaw, _ = State.body.CFrame:ToEulerAnglesYXZ()
            local angleDiff = targetYaw - currentYaw
            -- Wrap to shortest path
            while angleDiff > math.pi do angleDiff = angleDiff - 2 * math.pi end
            while angleDiff < -math.pi do angleDiff = angleDiff + 2 * math.pi end
            local rotSpeed = PL.SmashRotationRadPerSec or 0.35
            local rotDuration = math.abs(angleDiff) / rotSpeed
            if rotDuration > 0.01 then
                local rotStarted = os.clock()
                while State.active do
                    local rotElapsed = os.clock() - rotStarted
                    local t = math.clamp(rotElapsed / rotDuration, 0, 1)
                    local newYaw = currentYaw + angleDiff * t
                    local stillBp = State.body.Position
                    -- IMPORTANT: re-apply the 8° forward pitch from
                    -- spawn (line 402 above). Without this, the yaw-
                    -- only PivotTo clobbers the tilt — the body
                    -- visibly straightens up the moment smash
                    -- targeting starts, which read as a "jump back"
                    -- in playtest. Yaw THEN pitch keeps the lean
                    -- pointing in the body's current facing dir.
                    State.model:PivotTo(CFrame.new(stillBp)
                        * CFrame.Angles(0, newYaw, 0)
                        * CFrame.Angles(math.rad(8), 0, 0))
                    if t >= 1 then break end
                    task.wait()
                end
                if not State.active then
                    -- Boss died mid-rotation — release lock and bail.
                    for i, r in ipairs(State.smashLockReleases) do
                        if r == release then
                            table.remove(State.smashLockReleases, i)
                            break
                        end
                    end
                    release()
                    return
                end
            end
        end

        -- ============================================================
        -- LOCK-ON — beams + smash circle now appear. Standard
        -- SmashTotalSec resolve clock starts here. Outline-to-solid
        -- tween on both: cylinder Transparency 0.95 → 0.35; each beam
        -- 0.95 → 0.25 over the same window.
        -- ============================================================
        local circle = makePart({
            Name         = "PickleLordSmashCircle",
            Shape        = Enum.PartType.Cylinder,
            Size         = Vector3.new(0.4, PL.SmashRadiusStuds * 2, PL.SmashRadiusStuds * 2),
            CFrame       = CFrame.new(circleCenter) * CFrame.Angles(0, 0, math.rad(90)),
            Material     = Enum.Material.Neon,
            Color        = PL.SmashCircleColor,
            Transparency = 0.95,
            CanCollide   = false,
            Parent       = Workspace,
        })
        TweenService:Create(circle,
            TweenInfo.new(PL.SmashTotalSec, Enum.EasingStyle.Linear),
            { Transparency = 0.35 }
        ):Play()

        -- SOLID OUTLINE RING — 48 short tangential segments arranged
        -- around the smash perimeter so the radius reads from any
        -- camera angle, not just from above. The translucent disc
        -- alone is hard to gauge edge from a low angle; the ring
        -- gives a hard "you must be outside this line" cue. Fully
        -- opaque Neon, ~0.5 stud thick, sits 0.5 stud above the
        -- platform so it doesn't z-fight with the floor.
        local outlineParts = {}
        local SEGMENTS = 48
        local segLen = (2 * math.pi * PL.SmashRadiusStuds) / SEGMENTS + 0.1
        for i = 0, SEGMENTS - 1 do
            local angle = (i / SEGMENTS) * 2 * math.pi
            local cosA = math.cos(angle)
            local sinA = math.sin(angle)
            local px = circleCenter.X + cosA * PL.SmashRadiusStuds
            local pz = circleCenter.Z + sinA * PL.SmashRadiusStuds
            -- Orient the segment along the local TANGENT (perpendicular
            -- to the radius). LookAt pointing at (pos + tangent) puts
            -- the part's -Z along the tangent, which makes Size.Z =
            -- segLen extend along the perimeter.
            local segPart = makePart({
                Name         = "PickleLordSmashOutline",
                Size         = Vector3.new(0.5, 0.5, segLen),
                CFrame       = CFrame.lookAt(
                    Vector3.new(px, circleCenter.Y + 0.5, pz),
                    Vector3.new(px - sinA, circleCenter.Y + 0.5, pz + cosA)),
                Material     = Enum.Material.Neon,
                Color        = PL.SmashCircleColor,
                Transparency = 0,
                CanCollide   = false,
                Parent       = Workspace,
            })
            table.insert(outlineParts, segPart)
        end

        -- Eye cones: thin green Neon beams from each eye to the smash
        -- zone, oriented via CFrame.lookAt (-Z faces target). Parented
        -- to the model so the maid sweeps them on stop.
        local beams = {}
        for _, eye in ipairs(State.eyes or {}) do
            if eye and eye.Parent then
                local origin = eye.Position
                local diff = circleCenter - origin
                local distance = diff.Magnitude
                if distance > 0.5 then
                    local mid = (origin + circleCenter) / 2
                    local beam = makePart({
                        Name         = "PickleLordEyeCone",
                        Size         = Vector3.new(0.6, 0.6, distance),
                        CFrame       = CFrame.lookAt(mid, circleCenter),
                        Material     = Enum.Material.Neon,
                        Color        = PL.ShardColor,
                        Transparency = 0.95,
                        CanCollide   = false,
                        Parent       = State.model,
                    })
                    table.insert(beams, beam)
                    TweenService:Create(beam,
                        TweenInfo.new(PL.SmashTotalSec, Enum.EasingStyle.Linear),
                        { Transparency = 0.25 }
                    ):Play()
                end
            end
        end

        -- Telegraph remote: clients can layer extra effects (camera
        -- shake, SFX, etc.) on top of the replicated Part.
        playSmashRemote:FireAllClients({
            position    = circleCenter,
            radius      = PL.SmashRadiusStuds,
            totalSec    = PL.SmashTotalSec,
            reactionSec = PL.SmashReactionSec,
            color       = PL.SmashCircleColor,
        })

        -- Sleep wallclock — speed is locked at 1× so SmashTotalSec is
        -- the actual perceived duration regardless of the player's
        -- selected game speed.
        task.wait(PL.SmashTotalSec)
        -- Destroy the visible zone + outline ring + beams before
        -- the resolution pass.
        if circle and circle.Parent then circle:Destroy() end
        for _, seg in ipairs(outlineParts) do
            if seg and seg.Parent then seg:Destroy() end
        end
        for _, beam in ipairs(beams) do
            if beam and beam.Parent then beam:Destroy() end
        end

        -- AURORA BURST — vertical pillars at each former-outline
        -- position rise UP on the smash hit, then fall BACK DOWN.
        -- Heights are sine-wave-modulated around the ring (4 cycles
        -- around the 48-segment perimeter, ±40% amplitude) so the
        -- wall has the wavy "northern lights" silhouette. Per
        -- playtest the palette is now pickle GREEN ONLY — three
        -- shades of green cycle per segment for variation without
        -- breaking the boss's color theme. Two-stage tween:
        -- grow up over 0.18s, then collapse back down over 0.45s
        -- (size.Y → 0.5, base position back to ground). No fade —
        -- the bars just sink back into the platform.
        do
            local AURORA_BASE_H    = 26
            local AURORA_AMP_RATIO = 0.4    -- ±40% height variation
            local AURORA_FREQ      = 4      -- wave cycles around the ring
            local AURORA_RISE_SEC  = 0.225  -- 25% slower (was 0.18)
            local AURORA_FALL_SEC  = 0.5625 -- 25% slower (was 0.45)
            local AURORA_COLORS    = {
                Color3.fromRGB(120, 230, 80),   -- bright pickle green
                Color3.fromRGB(70, 180, 60),    -- mid green
                Color3.fromRGB(160, 250, 120),  -- pale lime
            }
            local pillarParts = {}
            for i = 1, SEGMENTS do
                local angle = (i - 1) / SEGMENTS * 2 * math.pi
                local cosA = math.cos(angle)
                local sinA = math.sin(angle)
                local px = circleCenter.X + cosA * PL.SmashRadiusStuds
                local pz = circleCenter.Z + sinA * PL.SmashRadiusStuds
                -- Sine wave around the perimeter for that wavy look.
                local wave = math.sin((i - 1) / SEGMENTS
                    * 2 * math.pi * AURORA_FREQ)
                local height = AURORA_BASE_H * (1 + wave * AURORA_AMP_RATIO)
                -- Cycle through the three green shades so adjacent
                -- pillars contrast and the wall doesn't read as a
                -- monochrome green wall.
                local color = AURORA_COLORS[((i - 1) % #AURORA_COLORS) + 1]
                local pillar = makePart({
                    Name         = "PickleLordSmashAurora",
                    Size         = Vector3.new(1.0, 0.5, 1.0),  -- starts short, grows
                    CFrame       = CFrame.new(px,
                                              circleCenter.Y + 0.5 + 0.25,
                                              pz),
                    Material     = Enum.Material.Neon,
                    Color        = color,
                    Transparency = 0.2,
                    CanCollide   = false,
                    Parent       = Workspace,
                })
                pillarParts[i] = pillar
                -- Phase 1 — RISE: Size.Y -> height, position rises so
                -- the BASE stays at platform level.
                TweenService:Create(pillar,
                    TweenInfo.new(AURORA_RISE_SEC, Enum.EasingStyle.Quad,
                                  Enum.EasingDirection.Out),
                    {
                        Size   = Vector3.new(1.0, height, 1.0),
                        CFrame = CFrame.new(px,
                                            circleCenter.Y + 0.5 + height * 0.5,
                                            pz),
                    }
                ):Play()
                -- Phase 2 — FALL: after the rise lands, collapse back
                -- down. Size.Y → 0.5 (matching original), base CFrame
                -- back at ground level. Per-segment stagger (i % 6 *
                -- 0.04s) so the wall ripples down rather than falling
                -- as one block.
                local fallDelay = AURORA_RISE_SEC + (i % 6) * 0.04
                task.delay(fallDelay, function()
                    if pillar and pillar.Parent then
                        TweenService:Create(pillar,
                            TweenInfo.new(AURORA_FALL_SEC, Enum.EasingStyle.Quad,
                                          Enum.EasingDirection.In),
                            {
                                Size   = Vector3.new(1.0, 0.5, 1.0),
                                CFrame = CFrame.new(px,
                                                    circleCenter.Y + 0.5 + 0.25,
                                                    pz),
                            }
                        ):Play()
                    end
                end)
            end
            -- Cleanup: destroy all pillars after the longest possible
            -- lifetime (rise + max stagger + fall).
            local totalLifetime = AURORA_RISE_SEC
                                 + (5 * 0.04)   -- max stagger offset
                                 + AURORA_FALL_SEC
                                 + 0.1          -- grace
            task.delay(totalLifetime, function()
                for _, p in ipairs(pillarParts) do
                    if p and p.Parent then p:Destroy() end
                end
            end)
        end
        -- Eye glow OFF — back to dull SmoothPlastic baseline.
        for _, eye in ipairs(State.eyes or {}) do
            if eye and eye.Parent then
                eye.Material = Enum.Material.SmoothPlastic
                local lt = eye:FindFirstChildOfClass("PointLight")
                if lt then lt.Brightness = 0 end
            end
        end

        -- Release speed lock first (idempotent — closure no-ops on second
        -- call, but we also drop the table entry so smash safety doesn't
        -- double-pop).
        for i, r in ipairs(State.smashLockReleases) do
            if r == release then
                table.remove(State.smashLockReleases, i)
                break
            end
        end
        release()

        if not State.active then return end  -- boss died mid-smash, abort

        -- Resolve: walk every tower tagged Tags.Tower; check XZ distance
        -- to the circle center against SmashRadiusStuds. We use TowerBase
        -- positions where present (more accurate floor projection) and
        -- fall back to the model's PrimaryPart/first BasePart.
        local radiusSq = PL.SmashRadiusStuds * PL.SmashRadiusStuds
        local destroyed = 0
        local taggedTowers = CollectionService:GetTagged(Tags.Tower)
        print(("[PickleLord] resolve START — checking %d tagged towers, radius=%d, center=(%.1f, %.1f, %.1f)"):format(
            #taggedTowers, PL.SmashRadiusStuds,
            circleCenter.X, circleCenter.Y, circleCenter.Z))
        for _, base in ipairs(taggedTowers) do
            local towerModel = base.Parent
            if towerModel and towerModel.Parent then
                local pos
                local baseSlab = towerModel:FindFirstChild("TowerBase")
                if baseSlab and baseSlab:IsA("BasePart") then
                    pos = baseSlab.Position
                elseif towerModel.PrimaryPart then
                    pos = towerModel.PrimaryPart.Position
                else
                    -- Fallback: use the tagged part itself. Aux
                    -- towers (RootSprout / LightningRadish / etc.)
                    -- don't always have a "TowerBase" child or a
                    -- set PrimaryPart, so without this fallback
                    -- they were silently skipped — only Power
                    -- showed up in the smash diagnostic, the rest
                    -- never got distance-checked.
                    pos = base.Position
                end
                if pos then
                    local dx = pos.X - circleCenter.X
                    local dz = pos.Z - circleCenter.Z
                    local d2 = dx*dx + dz*dz
                    print(("[PickleLord]   tower %s at (%.1f, %.1f, %.1f) dist=%.1f in_range=%s"):format(
                        towerModel.Name, pos.X, pos.Y, pos.Z,
                        math.sqrt(d2), tostring(d2 <= radiusSq)))
                    if d2 <= radiusSq then
                        -- Tower invuln gate (Config flag). When true, skip
                        -- the entire stock-restore + VFX + destroy block
                        -- below. Diagnostic still prints so playtest sees
                        -- "would have destroyed N towers" without losing
                        -- the fight.
                        if PL.TowerInvulnerableToSmash then
                            print(("[PickleLord]   (invuln) %s would be destroyed"):format(towerModel.Name))
                            destroyed = destroyed + 1
                            continue
                        end
                        -- Restore stock so the player can rebuild the tower.
                        local ownerId = towerModel:GetAttribute("Owner")
                        local towerType = towerModel:GetAttribute("TowerType")
                        if ownerId and towerType then
                            local ownerPlayer = Players:GetPlayerByUserId(ownerId)
                            if ownerPlayer then
                                local stockKey = towerType .. "Stock"
                                local cur = ownerPlayer:GetAttribute(stockKey) or 0
                                ownerPlayer:SetAttribute(stockKey, cur + 1)
                            end
                        end
                        -- Green-flame consumption VFX. Walk every BasePart
                        -- in the tower, attach a Fire instance with the
                        -- pickle-green palette, and tween the part to
                        -- dark + transparent so it visually withers in
                        -- place. Untag immediately so the rest of the
                        -- world (target picker, ammo HUD, range circles)
                        -- treats the tower as already gone; the model
                        -- itself sticks around briefly for the burn
                        -- animation. Destroyed after BURN_SEC wallclock.
                        local BURN_SEC = 0.05  -- effectively instant; wither + destroy land within one frame
                        do
                            local TweenService = game:GetService("TweenService")
                            local burnInfo = TweenInfo.new(BURN_SEC, Enum.EasingStyle.Linear)
                            local towerDescParts = {}
                            for _, desc in ipairs(towerModel:GetDescendants()) do
                                if desc:IsA("BasePart") then
                                    table.insert(towerDescParts, desc)
                                    -- Fire instance — Roblox-built particle
                                    -- system. Color = bright shard green,
                                    -- SecondaryColor = dark smoke green.
                                    -- Size scales with the part's volume
                                    -- so a tiny pellet-sized part doesn't
                                    -- get a huge flame.
                                    local fire = Instance.new("Fire")
                                    fire.Color = Color3.fromRGB(120, 230, 80)
                                    fire.SecondaryColor = Color3.fromRGB(35, 70, 25)
                                    fire.Size = math.clamp(desc.Size.Magnitude * 0.45, 2, 9)
                                    fire.Heat = 8
                                    fire.Parent = desc
                                    -- Wither the part: dark green + fade
                                    -- to FULLY transparent so the tower
                                    -- is visually gone even if the model
                                    -- destroy below somehow gets blocked.
                                    TweenService:Create(desc, burnInfo, {
                                        Color = Color3.fromRGB(20, 25, 15),
                                        Transparency = 1,
                                    }):Play()
                                end
                            end
                            -- Spur of green VFX fire — a one-shot
                            -- particle burst at the tower's footprint
                            -- center. The per-part Fire instances above
                            -- give a brief flicker; this gives a
                            -- punchier vertical SPURT of green sparks
                            -- the moment the tower dies. Anchored to
                            -- a tiny invisible Part at `pos` (which is
                            -- the tower's TowerBase / PrimaryPart /
                            -- tagged-part position) so the emitter
                            -- doesn't ride the withering parts down.
                            do
                                local burstAnchor = Instance.new("Part")
                                burstAnchor.Anchored = true
                                burstAnchor.CanCollide = false
                                burstAnchor.CanQuery = false
                                burstAnchor.Transparency = 1
                                burstAnchor.Size = Vector3.new(0.1, 0.1, 0.1)
                                burstAnchor.CFrame = CFrame.new(pos + Vector3.new(0, 1, 0))
                                burstAnchor.Parent = Workspace
                                local emitter = Instance.new("ParticleEmitter")
                                emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
                                emitter.Color = ColorSequence.new({
                                    ColorSequenceKeypoint.new(0,
                                        Color3.fromRGB(170, 250, 110)),
                                    ColorSequenceKeypoint.new(0.5,
                                        Color3.fromRGB(120, 230, 80)),
                                    ColorSequenceKeypoint.new(1,
                                        Color3.fromRGB(35, 90, 25)),
                                })
                                emitter.Size = NumberSequence.new({
                                    NumberSequenceKeypoint.new(0, 2.4),
                                    NumberSequenceKeypoint.new(1, 0.2),
                                })
                                emitter.Transparency = NumberSequence.new({
                                    NumberSequenceKeypoint.new(0, 0.1),
                                    NumberSequenceKeypoint.new(1, 1),
                                })
                                emitter.Lifetime = NumberRange.new(0.45, 0.85)
                                emitter.Rate = 0       -- one-shot only
                                emitter.Speed = NumberRange.new(18, 30)
                                emitter.SpreadAngle = Vector2.new(35, 35)
                                emitter.Acceleration = Vector3.new(0, -45, 0)
                                emitter.LightEmission = 0.55
                                emitter.LightInfluence = 0
                                emitter.EmissionDirection = Enum.NormalId.Top
                                emitter.Parent = burstAnchor
                                emitter:Emit(45)
                                task.delay(1.2, function()
                                    if burstAnchor and burstAnchor.Parent then
                                        burstAnchor:Destroy()
                                    end
                                end)
                            end
                            -- Strip the Tower tag NOW so other systems
                            -- stop seeing this tower (target picker,
                            -- HUD, etc.). Without this, towers tween
                            -- transparent but still register as targets
                            -- for ~0.55s.
                            if CollectionService:HasTag(base, Tags.Tower) then
                                CollectionService:RemoveTag(base, Tags.Tower)
                            end
                            -- Capture for the deferred destroy below.
                            -- TWO-LAYER cleanup so towers ALWAYS go
                            -- away even if the model destroy somehow
                            -- gets blocked: (1) destroy the whole model
                            -- via Destroy(); (2) as a fallback, walk
                            -- every BasePart we already collected and
                            -- destroy them individually. Either layer
                            -- alone would normally suffice; both
                            -- together is belt + suspenders.
                            local victim = towerModel
                            local victimParts = towerDescParts
                            local victimName = towerModel.Name
                            task.delay(BURN_SEC, function()
                                if victim and victim.Parent then
                                    print(("[PickleLord] destroying tower model %s"):format(victimName))
                                    victim:Destroy()
                                else
                                    print(("[PickleLord] tower %s already gone before destroy fired"):format(victimName))
                                end
                                -- Fallback: destroy each part individually
                                -- in case the model destroy was a no-op.
                                for _, p in ipairs(victimParts) do
                                    if p and p.Parent then p:Destroy() end
                                end
                            end)
                        end
                        destroyed = destroyed + 1
                    end
                end
            end
        end

        -- Friendly fire on mini pickles. Walk every Tags.Mob part
        -- in radius and destroy it. The body's AncestryChanged hook
        -- (set in spawnMini) tears down the legs/eyes siblings on
        -- the model. Tags.FinalBoss is filtered so the smash never
        -- hits Pickle Lord himself.
        local minisKilled = 0
        for _, mobPart in ipairs(CollectionService:GetTagged(Tags.Mob)) do
            if mobPart:IsA("BasePart") and mobPart.Parent
               and not CollectionService:HasTag(mobPart, Tags.FinalBoss) then
                local dx = mobPart.Position.X - circleCenter.X
                local dz = mobPart.Position.Z - circleCenter.Z
                if dx*dx + dz*dz <= radiusSq then
                    -- Set Health = 0 first so any Damage.lua /
                    -- HUD listeners watching the Health attribute
                    -- see the death cleanly, then destroy the
                    -- part outright (the AncestryChanged hook in
                    -- spawnMini fires and removes the model).
                    mobPart:SetAttribute("Health", 0)
                    mobPart:Destroy()
                    minisKilled = minisKilled + 1
                end
            end
        end
        if minisKilled > 0 then
            print(("[PickleLord] Smash friendly fire → %d mini pickles killed"):format(minisKilled))
        end

        -- Player resolution DISABLED for playtest (Matthew 2026-04-25:
        -- "make me invuln to the smash for now"). Tower destruction +
        -- range-decay are the parts of the fight being tuned right now;
        -- the player-kill check just made the boss feel like a
        -- one-shot. Re-enable by uncommenting the loop below.
        -- for _, p in ipairs(Players:GetPlayers()) do
        --     local char = p.Character
        --     local hrp = char and char:FindFirstChild("HumanoidRootPart")
        --     local hum = char and char:FindFirstChildOfClass("Humanoid")
        --     if hrp and hum and hum.Health > 0 then
        --         local dx = hrp.Position.X - circleCenter.X
        --         local dz = hrp.Position.Z - circleCenter.Z
        --         if dx*dx + dz*dz <= radiusSq then
        --             hum.Health = 0
        --         end
        --     end
        -- end

        -- Always log the resolve count (used to be `> 0` only). Helps
        -- diagnose "the smash isn't destroying towers" reports — if
        -- this fires with `0 / N` the resolve ran but no towers were
        -- in radius; if it never fires the smash itself bailed
        -- earlier (riseComplete still false, no players, etc.).
        local towerCount = #CollectionService:GetTagged(Tags.Tower)
        print(("[PickleLord] Smash resolved → %d / %d towers destroyed (radius=%d, center=%s)"):format(
            destroyed, towerCount, PL.SmashRadiusStuds,
            tostring(circleCenter)))
    end

    -- Smash loop — runs as a registered Maid task so it's torn down on
    -- stop. GameTime.adaptiveWait scales the wait window with the
    -- player's chosen game speed (a SmashIntervalGameSec of 20 means
    -- 20 game-seconds, so at 5× the player gets 4 wallclock seconds
    -- between smashes).
    local function startSmashLoop()
        if not State.maid then return end
        State.maid:give(task.spawn(function()
            while State.active do
                GameTime.adaptiveWait(PL.SmashIntervalGameSec)
                if not State.active then break end
                performSmash()
            end
        end))
    end

    ----------------------------------------------------------------
    -- RANGE DECAY
    ----------------------------------------------------------------
    -- Every RangeDecayIntervalGameSec, multiply each player's
    -- RangeDecayMultiplier attribute by RangeDecayMultiplier (config,
    -- 0.9). Towers.lua reads it in findTarget and multiplies effective
    -- range by it. Drives towards 0 — no floor — so the player MUST
    -- kill Pickle Lord under a hard timer.
    local function applyRangeDecayTick()
        if not State.active then return end
        for _, p in ipairs(Players:GetPlayers()) do
            local cur = p:GetAttribute("RangeDecayMultiplier") or 1
            p:SetAttribute("RangeDecayMultiplier", cur * PL.RangeDecayMultiplier)
            -- Tick counter — separate from the multiplier so the
            -- client can ramp visual intensity by integer steps
            -- without doing log math. Cleared in stopPickleLord
            -- alongside RangeDecayMultiplier.
            local ticks = p:GetAttribute("RangeDecayTickCount") or 0
            p:SetAttribute("RangeDecayTickCount", ticks + 1)
        end
    end

    local function startRangeDecayLoop()
        if not State.maid then return end
        State.maid:give(task.spawn(function()
            -- First tick is delayed by RangeDecayFirstTickGameSec
            -- (default 60s game-time) so the player gets a clean
            -- one-minute opening window with full tower range
            -- before the decay starts. Subsequent ticks fire at
            -- the standard RangeDecayIntervalGameSec cadence.
            GameTime.adaptiveWait(PL.RangeDecayFirstTickGameSec
                or PL.RangeDecayIntervalGameSec)
            while State.active do
                if not State.active then break end
                applyRangeDecayTick()
                GameTime.adaptiveWait(PL.RangeDecayIntervalGameSec)
            end
        end))
    end

    ----------------------------------------------------------------
    -- MINI PICKLE ADDS
    ----------------------------------------------------------------
    -- Tiny pickle-shaped mobs that spawn from EnemySpawnMap3 and
    -- walk the standard EnemyPath toward the heart, mirroring the
    -- Canopy Bird egg pattern. Per Matthew (2026-04-25):
    --   • All minis share the same HP — no ramping by elapsed time.
    --     The DANGER comes from the shrinking tower-range decay,
    --     not from minis getting fatter mid-fight.
    --   • Each mini is a small ellipsoid body with two boxy "stupid
    --     little legs" that swing forward/back via per-frame
    --     Heartbeat tween. A walking-pickle silhouette is the joke.
    --   • Custom walker (task.spawn) like the eggs — can't reuse
    --     MobFactory because we need the bespoke leg animation and
    --     a non-wave-system spawn cadence.

    -- Inline 3D HP bar — same pattern as Map3BirdBoss.attachHpBar.
    -- Could be extracted to a shared module since both bosses now
    -- spawn standalone path mobs that need bars; deferring that until
    -- a third caller appears (the rule of three).
    local function attachMiniHpBar(part, opts)
        opts = opts or {}
        local bb = Instance.new("BillboardGui")
        bb.Name = "HpBar"
        bb.Size = UDim2.new(0, opts.width or 70, 0, opts.height or 12)
        bb.StudsOffset = Vector3.new(0, opts.yOffset or 3, 0)
        bb.AlwaysOnTop = true
        bb.LightInfluence = 0
        bb.MaxDistance = 0
        bb.Parent = part
        local bg = Instance.new("Frame")
        bg.Size = UDim2.fromScale(1, 1)
        bg.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
        bg.BackgroundTransparency = 0.25
        bg.BorderSizePixel = 0
        bg.Parent = bb
        local fill = Instance.new("Frame")
        fill.Size = UDim2.new(1, -2, 1, -2)
        fill.Position = UDim2.new(0, 1, 0, 1)
        fill.BackgroundColor3 = Color3.fromRGB(240, 80, 80)
        fill.BorderSizePixel = 0
        fill.Parent = bg
        -- HP number overlay: "X / MAX". White text, black stroke for
        -- readability against either green flame VFX or whatever
        -- environment is behind. Per playtest 2026-04-26.
        local hpText = Instance.new("TextLabel")
        hpText.Size = UDim2.fromScale(1, 1)
        hpText.BackgroundTransparency = 1
        hpText.TextColor3 = Color3.fromRGB(255, 255, 255)
        hpText.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        hpText.TextStrokeTransparency = 0
        hpText.Font = Enum.Font.FredokaOne
        hpText.TextSize = opts.textSize or 11
        hpText.ZIndex = 2
        hpText.Parent = bg
        local function refresh()
            local hp = part:GetAttribute("Health") or 0
            local max = part:GetAttribute("MaxHealth") or 1
            local frac = math.max(0, math.min(hp / max, 1))
            fill.Size = UDim2.new(frac, -2, 1, -2)
            hpText.Text = string.format("%d / %d",
                math.max(0, math.floor(hp)),
                math.floor(max))
        end
        refresh()
        part:GetAttributeChangedSignal("Health"):Connect(refresh)
        part:GetAttributeChangedSignal("MaxHealth"):Connect(refresh)
    end

    -- Spawn one mini pickle. Body is an anchored ellipsoid;
    -- two legs are anchored child Parts whose CFrame is updated
    -- per-frame by a Heartbeat task.spawn so they swing relative
    -- to the body as it walks. The body itself walks waypoints
    -- on a separate task.spawn — both end when egg.Parent is nil
    -- (destroyed at heart or by tower damage), which the shared
    -- standalone-mob branch in Damage.lua handles via the same
    -- Tags.Mob + Health attribute contract eggs use.
    local function spawnMini()
        if not State.active then return end
        local map3Room = Workspace:FindFirstChild("TreeOfLifeMap3Room")
        if not map3Room then return end
        local spawnPart
        for _, p in ipairs(map3Room:GetDescendants()) do
            if p:IsA("BasePart") and p.Name == "EnemySpawnMap3" then
                spawnPart = p
                break
            end
        end
        if not spawnPart then return end

        local model = Instance.new("Model")
        model.Name = "PickleMini"
        model.Parent = map3Room

        -- Body: ellipsoid via SpecialMesh.Sphere (Block + sphere
        -- mesh) so non-uniform Size renders as a stretched pickle
        -- instead of an inscribed sphere — same trick as the boss.
        local bodyW = PL.MiniBodyWidth
        local bodyH = PL.MiniBodyHeight
        local bodyY = spawnPart.Position.Y
                    + bodyH * 0.5
                    + PL.MiniLegLengthStuds  -- legs stand on ground
        local body = makePart({
            Name        = "PickleMiniBody",
            Size        = Vector3.new(bodyW, bodyH, bodyW),
            CFrame      = CFrame.new(spawnPart.Position.X, bodyY, spawnPart.Position.Z),
            Material    = Enum.Material.SmoothPlastic,
            Color       = PL.BodyColor,
            CanCollide  = false,
            Parent      = model,
        })
        local mesh = Instance.new("SpecialMesh")
        mesh.MeshType = Enum.MeshType.Sphere
        mesh.Parent = body
        body:SetAttribute("MapId",     3)
        body:SetAttribute("Health",    PL.MiniHp)
        body:SetAttribute("MaxHealth", PL.MiniHp)
        if Tags.Mob then
            CollectionService:AddTag(body, Tags.Mob)
        end
        attachMiniHpBar(body, {
            width = 110,            -- wider so "32000 / 32000" fits
            height = 16,            -- taller so text reads
            yOffset = bodyH * 0.6 + 1,
            textSize = 12,
        })

        -- Tiny eyes so the mini reads as a pickle face FROM THE
        -- FRONT (the direction it's walking). CFrame.lookAt
        -- convention: -Z = LookVector = forward. So the body's
        -- forward face is at NEGATIVE local Z; eyes go there.
        -- Earlier playtest had +Z (back of body) — looked correct
        -- at spawn before yaw was applied, then flipped behind once
        -- the body started turning toward waypoints.
        for sx = -1, 1, 2 do
            local eye = makePart({
                Name = "MiniEye",
                Size = Vector3.new(0.4, 0.4, 0.4),
                CFrame = body.CFrame
                    * CFrame.new(sx * bodyW * 0.18,
                                  bodyH * 0.15,
                                  -bodyW * 0.42),  -- forward face
                Material = Enum.Material.Neon,
                Color = Color3.fromRGB(255, 255, 255),
                Shape = Enum.PartType.Ball,
                CanCollide = false,
                Parent = model,
            })
            -- Per-frame follow in the walker loop re-CFrames the
            -- eye relative to body.CFrame; offsets stored as part
            -- attributes since Anchored parts don't auto-follow
            -- their parent's CFrame.
            eye:SetAttribute("LocalOffsetX", sx * bodyW * 0.18)
            eye:SetAttribute("LocalOffsetY", bodyH * 0.15)
            eye:SetAttribute("LocalOffsetZ", -bodyW * 0.42)
        end

        -- Two legs: rectangular boxes hanging from the body
        -- bottom. Anchored — animated by setting CFrame each frame
        -- relative to body. Hip pivot is at the body bottom; the
        -- leg rotates around its hip then translates legLength/2
        -- below the hip to put the leg's CENTER one half-length
        -- down from the pivot.
        local legL = PL.MiniLegLengthStuds
        local legT = PL.MiniLegThicknessStuds
        local legs = {}
        for i, sx in ipairs({ -1, 1 }) do
            local leg = makePart({
                Name        = "PickleMiniLeg" .. i,
                Size        = Vector3.new(legT, legL, legT),
                CFrame      = body.CFrame * CFrame.new(sx * bodyW * 0.25,
                                                        -bodyH * 0.5 - legL * 0.5,
                                                        0),
                Material    = Enum.Material.SmoothPlastic,
                Color       = PL.BodyColor,
                CanCollide  = false,
                Parent      = model,
            })
            legs[i] = { part = leg, sx = sx, phase = (i == 1) and 0 or math.pi }
        end

        -- Body-destroy listener: when towers kill the mini, the
        -- standalone-mob damage path destroys the BODY part but the
        -- legs + eyes are siblings under `model` (not children of
        -- body), so they'd be left floating in space. Tear down the
        -- whole model the moment body is unparented. AncestryChanged
        -- with parent=nil fires on Destroy() — matches both the
        -- damage-kill path and the normal "mini reached the heart"
        -- path (where we already explicitly model:Destroy()).
        body.AncestryChanged:Connect(function(_, parent)
            if not parent and model and model.Parent then
                model:Destroy()
            end
        end)

        -- Walker + animator: one task.spawn that does both, since
        -- both want per-frame Heartbeat updates and the leg swing
        -- is purely a function of elapsed time + body CFrame.
        local pathFolder = map3Room:FindFirstChild("EnemyPath")
        local waypoints = {}
        if pathFolder then
            for _, wp in ipairs(pathFolder:GetChildren()) do
                if wp:IsA("BasePart") and wp.Name:match("^Waypoint%d+$") then
                    table.insert(waypoints, wp)
                end
            end
            table.sort(waypoints, function(a, b)
                return (tonumber(a.Name:match("%d+")) or 0)
                     < (tonumber(b.Name:match("%d+")) or 0)
            end)
        end

        task.spawn(function()
            local startedAt = os.clock()
            local function updateLegs()
                local elapsed = os.clock() - startedAt
                local swingRad = math.rad(PL.MiniLegSwingDeg)
                local hz = PL.MiniLegSwingHz
                for _, leg in ipairs(legs) do
                    if not leg.part.Parent then return end
                    local angle = math.sin(elapsed * hz * 2 * math.pi
                                            + leg.phase) * swingRad
                    -- Hip CFrame: at body bottom, sx-offset on X.
                    local hipCFrame = body.CFrame
                        * CFrame.new(leg.sx * bodyW * 0.25, -bodyH * 0.5, 0)
                    -- Rotate around hip's X axis (forward/back swing),
                    -- then translate down legLength/2 to leg center.
                    leg.part.CFrame = hipCFrame
                        * CFrame.Angles(angle, 0, 0)
                        * CFrame.new(0, -legL * 0.5, 0)
                end
                -- Also follow the body's CFrame for the eyes
                -- (anchored, parent CFrame doesn't propagate). Walks
                -- the model's children — eyes were tagged with
                -- LocalOffsetX/Y/Z attributes at spawn.
                for _, child in ipairs(model:GetChildren()) do
                    if child.Name == "MiniEye" and child:IsA("BasePart") then
                        local ox = child:GetAttribute("LocalOffsetX") or 0
                        local oy = child:GetAttribute("LocalOffsetY") or 0
                        local oz = child:GetAttribute("LocalOffsetZ") or 0
                        child.CFrame = body.CFrame * CFrame.new(ox, oy, oz)
                    end
                end
            end

            local moveSpeed = PL.MiniMoveSpeedStud
            for i = 1, #waypoints do
                local wp = waypoints[i]
                body:SetAttribute("WaypointIndex", i)
                while body.Parent and wp.Parent and State.active do
                    local dt = RunService.Heartbeat:Wait()
                    if not (body.Parent and wp.Parent) then break end
                    updateLegs()
                    -- Path Y target is wp.Y + body bottom clearance
                    -- so the legs touch ground without clipping.
                    local targetY = wp.Position.Y
                                  + bodyH * 0.5
                                  + legL
                    local wpFlat = Vector3.new(wp.Position.X, targetY, wp.Position.Z)
                    local toWp = wpFlat - body.Position
                    local dist = toWp.Magnitude
                    if dist < 0.4 then break end
                    local step = math.min(dist, moveSpeed * GameTime.scaled(dt))
                    -- Yaw the body to face direction of travel so
                    -- the legs swing in the walking direction (not
                    -- sideways). Keep upright (no pitch / roll).
                    local lookAt = body.Position + toWp.Unit
                    local newCFrame = CFrame.lookAt(
                        body.Position + toWp.Unit * step,
                        lookAt + toWp.Unit)
                    -- Strip pitch/roll: rebuild from yaw only.
                    local _, yaw, _ = newCFrame:ToEulerAnglesYXZ()
                    body.CFrame = CFrame.new(newCFrame.Position)
                        * CFrame.Angles(0, yaw, 0)
                end
                if not body.Parent then return end
            end
            -- Reached the heart — damage and self-destruct.
            if body.Parent then
                local remainingHp = body:GetAttribute("Health") or 0
                MobUtil.damageHeart(map3Room:FindFirstChild("TreeHeartMap3"),
                    math.max(0, remainingHp))
                model:Destroy()
            end
        end)

        -- Safety guard: if the path walk hangs (e.g. waypoint
        -- sorting glitch, model reparented), kill the model after
        -- the safety timeout so the workspace doesn't leak.
        task.delay(PL.MiniSafetyDestroyWallclockSec, function()
            if model and model.Parent then model:Destroy() end
        end)
    end

    local function startMiniLoop()
        if not State.maid then return end
        State.maid:give(task.spawn(function()
            -- Wait for the rise to finish before the first spawn —
            -- riseComplete flips true the moment the entrance tween
            -- lands. Same pattern as performSmash's
            -- `if not riseComplete return` guard.
            while State.active and not State.riseComplete do
                task.wait(0.25)
            end
            -- Tiny extra breath after the rise so the first mini
            -- pops just AFTER the bars retract instead of the same
            -- frame the player gets control back.
            GameTime.adaptiveWait(PL.MiniFirstSpawnDelayGameSec)
            -- Spawn cadence: every cycle of 6 minis bunches the
            -- FIRST 3 (0.5s gaps) then spreads the next 3 with a
            -- long pause to the next bunch. Average rate matches
            -- the original MiniSpawnIntervalGameSec (≈4 game-sec
            -- per mini) so total pickle-pressure is unchanged —
            -- just clumpier so AOE / Splash towers can hit
            -- multiples on the bunched arrivals.
            -- Per-cycle wait pattern between successive minis:
            --   1→2: 0.5  (bunch)
            --   2→3: 0.5  (bunch)
            --   3→4: 5    (spread start)
            --   4→5: 5    (spread)
            --   5→6: 5    (spread)
            --   6→1: 8    (long reset before next bunch)
            -- Total: 24 game-sec for 6 minis = 4 sec/mini avg.
            local count = 0
            while State.active do
                count = count + 1
                spawnMini()
                if not State.active then break end
                local positionInCycle = ((count - 1) % 6) + 1
                local waitSec
                if positionInCycle == 1 or positionInCycle == 2 then
                    waitSec = 0.5   -- bunch (just spawned 1st or 2nd)
                elseif positionInCycle == 6 then
                    waitSec = 8     -- reset before next bunch
                else
                    waitSec = 5     -- spread (3rd, 4th, 5th)
                end
                GameTime.adaptiveWait(waitSec)
            end
        end))
    end

    ----------------------------------------------------------------
    -- LIFECYCLE
    ----------------------------------------------------------------
    local stopPickleLord  -- forward-decl for the Health=0 listener

    local function startPickleLord()
        if State.active then
            print("[PickleLord] startPickleLord called but already active — skipping")
            return
        end
        State.active    = true
        State.startedAt = os.clock()
        State.maid      = Maid.new()
        State.smashLockReleases = {}

        -- Position the boss off the platform edge — sits in front of the
        -- player vantage so head + shoulders read against the night sky.
        local origin = MAP3_CENTER + Vector3.new(0, 0, -PL.BodyOffsetFromCenter)
        print(("[PickleLord] startPickleLord: spawning at origin=%s, MAP3_CENTER=%s"):format(
            tostring(origin), tostring(MAP3_CENTER)))
        local body = buildModel(origin)
        print(("[PickleLord] body built — pos=%s, size=%s, top.Y=%.1f"):format(
            tostring(body.Position), tostring(body.Size),
            body.Position.Y + body.Size.Y * 0.5))
        State.maid:give(State.model)

        -- ALL entrance environment-destruction has been removed
        -- (Matthew 2026-04-25: "DO NOT DESTROY THE ENVIRONMENT"). The
        -- prior version culled half the butterflies, scattered shards,
        -- punched green-energy + black cracks into the floor, and blew
        -- the canopy apart with physics velocities — none of that
        -- happens anymore. The atmosphere shift comes from the lighting
        -- tween (PlayPickleLordEntrance below) and the slow rise.

        -- Slow rise. Build the model at its FINAL pivot, then immediately
        -- pivot down by RiseDistance so the boss starts buried below the
        -- platform. A task tweens the pivot back up over RiseSec wallclock
        -- using ease-out cubic (slow at the end so the boss settles into
        -- place rather than slamming up against the canopy). Set
        -- riseComplete=true on landing so the smash loop knows it can
        -- start firing. State.maid:give() the task so a stop mid-rise
        -- tears it down cleanly.
        do
            local riseDist = PL.RiseDistance or 70
            local riseSec  = PL.RiseSec or 7
            local landingPivot = State.model:GetPivot()
            local startPivot = landingPivot - Vector3.new(0, riseDist, 0)
            State.model:PivotTo(startPivot)
            State.maid:give(task.spawn(function()
                local startedAt = os.clock()
                while State.active do
                    -- Cinematic-skip fast-forward: if a player
                    -- skipped the cinematic on the client, they
                    -- fire PickleLordCinematicEnded, the server
                    -- handler below sets State.cinematicSkipped
                    -- = true. Snap to landing position + flag rise
                    -- complete so the smash + targetable phase
                    -- starts immediately rather than the player
                    -- watching the boss continue to silently rise
                    -- in the background.
                    if State.cinematicSkipped then
                        State.model:PivotTo(landingPivot)
                        State.riseComplete = true
                        if State.body then
                            State.body:SetAttribute("Untargetable", nil)
                        end
                        return
                    end
                    local elapsed = os.clock() - startedAt
                    local t = math.clamp(elapsed / riseSec, 0, 1)
                    -- Ease-out cubic: 1 - (1-t)^3
                    local eased = 1 - (1 - t) * (1 - t) * (1 - t)
                    local newPivot = startPivot
                        + Vector3.new(0, riseDist * eased, 0)
                    State.model:PivotTo(newPivot)
                    if t >= 1 then
                        State.riseComplete = true
                        -- Clear the Untargetable flag so towers
                        -- start firing on him from this frame on.
                        if State.body then
                            State.body:SetAttribute("Untargetable", nil)
                        end
                        return
                    end
                    task.wait()
                end
            end))
        end

        -- Wire the boss into the wave system's HP-bar broadcast loop.
        -- Without this, the dedicated bottom Pickle Lord HP bar stays
        -- pinned at 0/0 forever — broadcastWaveState only sends live
        -- bossHealth when it can find FinalBossState.instance OR a
        -- Tags.FinalBoss-tagged part. We do BOTH (tag is already set
        -- in buildModel) plus an explicit broadcast call so the bar
        -- starts populated immediately rather than waiting for the
        -- next wave-system-internal trigger (which may not fire
        -- during a stage-4 boss phase with no live waves).
        if ctx.FinalBossState then
            ctx.FinalBossState.instance = body
        end
        if ctx.broadcastWaveState then
            ctx.broadcastWaveState()
        end

        -- Cinematic entrance — fire to all clients so they tween
        -- lighting + take over the camera for the rise. Camera cuts
        -- between boss / player closeups, Dutch-angled, with black
        -- letterbox bars. Client handles all camera/UI work; server
        -- just sends the boss head position so the client knows where
        -- to point the camera.
        local bossHeadPos = Vector3.new(
            origin.X,
            origin.Y + PL.BodyVisibleHeight * 0.7,
            origin.Z)
        -- Phase-1 camera anchor: BACK-RIGHT of the map3 platform when
        -- facing the boss (boss is at -Z from MAP3_CENTER, so right =
        -- +X, back = +Z). Hard-coded relative to MAP3_CENTER instead
        -- of the player's HRP per playtest 2026-04-25 — basing the
        -- start on player position put the camera in different
        -- corners depending on where the player ended up after their
        -- aux pick. Now the establishing shot is consistent.
        local cinematicStartPos = Vector3.new(
            MAP3_CENTER.X + 75,        -- right edge of arena, ~5 stud in from boundary
            MAP3_CENTER.Y + 8,         -- just above platform / floor surface
            MAP3_CENTER.Z + 50)        -- back of arena (toward +Z)
        local cinematicEndPos = Vector3.new(
            MAP3_CENTER.X + 22,        -- closer to center
            MAP3_CENTER.Y + 5,         -- slightly lower (eye-level)
            MAP3_CENTER.Z - 10)        -- forward of center, toward boss
        -- Per playtest: nudge the start position 5 studs along the
        -- start→end vector so the establishing shot doesn't begin so
        -- far out in the canopy. The end position is unchanged, so
        -- the lerp arc is just shorter at the front.
        cinematicStartPos = cinematicStartPos
            + (cinematicEndPos - cinematicStartPos).Unit * 5
        -- Face Y offset above body CENTER (in body's local +Y axis,
        -- which the body tilt rotates 8° forward). Final face Y = origin.Y
        -- + BodyVisibleHeight*0.7; final body center Y = origin.Y +
        -- BodyVisibleHeight - BodyTotalHeight/2. Diff = BodyTotalHeight/2
        -- - 0.3 * BodyVisibleHeight. Client uses this on each frame to
        -- track the face position via PointToWorldSpace as the body
        -- rises — without it, the cinematic looks at the FINAL face
        -- position while the body's still 10+ stud below, framing
        -- empty sky above the rising silhouette.
        local faceOffsetY = (PL.BodyTotalHeight * 0.5)
                          - (PL.BodyVisibleHeight * 0.3)
        -- Arena center for the mid-cinematic teleport (phase 6's start
        -- snaps the player here so the zoom-out doesn't end up inside
        -- the canopy on whatever spot the player happened to be on).
        local arenaCenter = MAP3_CENTER

        -- Clear canopy leaves in front of the boss BEFORE the
        -- cinematic fires so the camera has a clean view of the
        -- pickle silhouette. Per playtest 2026-04-26: the boss was
        -- glitching THROUGH the decorative branches/leaves/flowers
        -- on his half of the arena because they're cosmetic parts
        -- the body's path-clear didn't account for. Solution: as
        -- he arrives, "crumble" everything on his side — unanchor,
        -- give a tumble velocity, fall + Destroy. Spread the
        -- staggered start times across phase 1 (~6s of the 9s
        -- zoom-in) so the destruction reads as a wave radiating out
        -- from the boss rather than a single instant disappearance.
        --
        -- "Boss side" = parts whose Z is on the same side of
        -- arenaCenter.Z as bossHeadPos. We pick names that are
        -- decorative (branches, leaves, flowers, butterflies, leaf
        -- stubs/pops) and skip the Map3Floor (we still need a
        -- floor to fight on) plus nest/egg parts (those are bird
        -- boss artifacts and are typically already cleared, but
        -- we exclude them defensively).
        do
            -- Crumble ANY Map3* part within the radius, except things
            -- we need to keep around: the floor (we still need to
            -- fight on it), the bird boss's nest/egg artifacts (those
            -- are unrelated state), and the heart (game-critical).
            -- Earlier version enumerated specific names but missed at
            -- least one bush type (Map3Leaf as Shape=Ball with bigger
            -- size — visually the green spheres at the boss's feet)
            -- per playtest 2026-04-26: "destruction bubble isn't
            -- working". Switching to allow-Map3-with-denylist so we
            -- don't have to keep adding names every time the world
            -- builder gets a new decorative type.
            local CRUMBLE_DENY = {
                Map3Floor      = true,
                Map3NestTwig   = true,
                TreeHeartMap3  = true,
                HeartHPAnchorMap3 = true,
            }
            -- Tight cylinder around the boss (XZ-radius only, all Y)
            -- so only parts the body would clip THROUGH crumble — not
            -- everything on his half of the arena. Per playtest:
            -- "keep it as tight around the pickle boss as you can".
            -- Pickle Lord body is 62 wide × 52 deep, so a 35-stud
            -- radius from his pivot only barely covers his own
            -- footprint — bushes nestled against his base sit ~30
            -- stud away and were getting missed. Bumped to 50.
            local CRUMBLE_RADIUS = 50
            local CRUMBLE_RADIUS_SQ = CRUMBLE_RADIUS * CRUMBLE_RADIUS
            local crumbleDur   = 4.0   -- spread starts across phase 1 (0-9s)
            local fallLifetime = 2.5   -- per-part fall + spin before Destroy
            local Debris = game:GetService("Debris")
            local cleared = 0
            local nameCounts = {}
            for _, part in ipairs(Workspace:GetDescendants()) do
                if part:IsA("BasePart")
                   and string.sub(part.Name, 1, 4) == "Map3"
                   and not CRUMBLE_DENY[part.Name]
                   -- Skip the egg parts dynamically (they're named
                   -- "Map3Egg1", "Map3Egg2", etc.). Same for any
                   -- "Map3EggSpeck"-prefixed leftover.
                   and string.sub(part.Name, 1, 7) ~= "Map3Egg" then
                    local dx = part.Position.X - bossHeadPos.X
                    local dz = part.Position.Z - bossHeadPos.Z
                    local distSqXZ = dx * dx + dz * dz
                    if distSqXZ <= CRUMBLE_RADIUS_SQ then
                        cleared = cleared + 1
                        nameCounts[part.Name] = (nameCounts[part.Name] or 0) + 1
                        -- Wave delay: nearer-to-boss parts fall
                        -- first, far ones fall last. Plus a small
                        -- random jitter so the crumble doesn't
                        -- look like a perfect ring.
                        local d = math.sqrt(distSqXZ)
                        local distT = math.clamp(d / CRUMBLE_RADIUS, 0, 1)
                        local jitter = math.random() * 0.4
                        local startDelay = distT * (crumbleDur - 0.4) + jitter
                        task.delay(startDelay, function()
                            if not part.Parent then return end
                            -- Some Map3 parts are children of models
                            -- with welds; unanchor + clear welds so
                            -- physics actually takes over.
                            part.Anchored = false
                            part.CanCollide = false
                            for _, w in ipairs(part:GetDescendants()) do
                                if w:IsA("WeldConstraint") or w:IsA("Weld")
                                   or w:IsA("Motor6D") then
                                    w:Destroy()
                                end
                            end
                            local v = Vector3.new(
                                (math.random() - 0.5) * 16,
                                -math.random() * 6 - 4,    -- always down
                                (math.random() - 0.5) * 16)
                            part.AssemblyLinearVelocity = v
                            part.AssemblyAngularVelocity = Vector3.new(
                                (math.random() - 0.5) * 12,
                                (math.random() - 0.5) * 12,
                                (math.random() - 0.5) * 12)
                            Debris:AddItem(part, fallLifetime)
                        end)
                    end
                end
            end
            -- Per-name breakdown so we can confirm WHICH part types
            -- got included in the crumble. If a known type (e.g.
            -- Map3Leaf) shows count=0 in this print but the user
            -- still sees that type around the boss, the problem is
            -- positional (out of radius / different parent / different
            -- name) not the crumble logic itself.
            local breakdown = {}
            for n, c in pairs(nameCounts) do
                table.insert(breakdown, string.format("%s=%d", n, c))
            end
            table.sort(breakdown)
            print(("[PickleLord] crumbling %d environment parts within %d studs of boss (dur=%.1fs) [%s]"):format(
                cleared, CRUMBLE_RADIUS, crumbleDur,
                table.concat(breakdown, ", ")))
        end

        -- Per-player FireClient (was FireAllClients) so each player
        -- gets their own seen-hint flag in the payload — the skip
        -- hint should only show on a player's FIRST cinematic,
        -- never again. Pref key: "hasSeenPickleLordSkipHint".
        -- Mark seen immediately after firing so subsequent runs in
        -- the same session also skip the hint.
        local SKIP_HINT_PREF = "hasSeenPickleLordSkipHint"
        for _, p in ipairs(Players:GetPlayers()) do
            local seenSkipHint =
                PermanentTowerStore.getPref(p, SKIP_HINT_PREF) == true
            playEntranceRemote:FireClient(p, {
                duration      = PL.EntranceCinematicWallclockSec,
                ambient       = PL.MoonlightAmbient,
                fogEnd        = PL.FogEnd,
                origin        = origin,
                bossPos       = bossHeadPos,
                cinematicSec  = PL.CinematicWallclockSec or 24.5,
                phase1Start   = cinematicStartPos,
                phase1End     = cinematicEndPos,
                faceOffsetY   = faceOffsetY,
                arenaCenter   = arenaCenter,
                seenSkipHint  = seenSkipHint,
            })
            if not seenSkipHint then
                PermanentTowerStore.setPref(p, SKIP_HINT_PREF, true)
            end
        end

        -- "Something ancient approaches..." leaf message — fired now
        -- (cinematic kickoff) instead of from TempTowerRewards' map
        -- closure (which fired 2s earlier when the player picked their
        -- aux tower, before the cinematic started). The line lands
        -- right as the camera takes over.
        if ctx.fireLeafMessage then
            -- priority=true so any in-flight leaf (e.g. the temp-
            -- tower-reward "you got X" line that fired ~2s ago)
            -- fast-fades and "something ancient approaches…" lands
            -- right as the camera takes over.
            for _, p in ipairs(Players:GetPlayers()) do
                ctx.fireLeafMessage(p, "something ancient approaches...", 6, true)
            end
        end

        -- HP=0 listener → reward chain. Same pattern as Map3BirdBoss.
        State.maid:give(body:GetAttributeChangedSignal("Health"):Connect(function()
            local hp = body:GetAttribute("Health") or 0
            if hp <= 0 and State.active then
                stopPickleLord(true)
            end
        end))

        startSmashLoop()
        startRangeDecayLoop()
        startMiniLoop()

        -- No leaf-message tip on entrance: per Matthew (2026-04-25),
        -- players figure out the range-decay effect themselves. The
        -- visual cinematic + tower-range visibly shrinking on each
        -- cycle should communicate it without exposition.
        print(("[PickleLord] started — HP %d, smash %ds, decay %ds"):format(
            PL.Hp, PL.SmashIntervalGameSec, PL.RangeDecayIntervalGameSec))
    end

    stopPickleLord = function(killed)
        if not State.active and not State.body then return end
        State.active = false

        -- Pop any held smash speed locks (a fast stop mid-smash would
        -- otherwise leave gs pinned at 1× until the closure GC).
        for _, release in ipairs(State.smashLockReleases) do
            if release then release() end
        end
        State.smashLockReleases = {}

        -- Tear down the maid (loops, listeners, model).
        if State.maid then
            State.maid:destroy()
            State.maid = nil
        end
        if State.model and State.model.Parent then
            State.model:Destroy()
        end
        State.body  = nil
        State.model = nil

        -- Always clear range decay on stop — whether killed or aborted —
        -- so a dev re-cycle / re-run starts at full range.
        for _, p in ipairs(Players:GetPlayers()) do
            p:SetAttribute("RangeDecayMultiplier", nil)
            p:SetAttribute("RangeDecayTickCount", nil)
        end

        if killed then
            print("[PickleLord] defeated — firing reward chain")
            pickleLordBindable:Fire()
        else
            print("[PickleLord] stopped (aborted)")
        end
    end

    ctx.startPickleLord = startPickleLord
    ctx.stopPickleLord  = stopPickleLord

    -- BossRewardClaimed mapId=3 is the trigger: bird died → temp picker
    -- shown → player picked → THIS fires. The full chain is documented
    -- in docs/pickle-lord-spec.md and PermanentTowers.lua.
    --
    -- Bindable lookup uses WaitForChild because TempTowerRewards may set
    -- it up later in the boot order; getOrCreate is also safe but
    -- WaitForChild matches the Map2 pattern at world/Map2.lua:1524.
    task.spawn(function()
        local rewardClaimed = ReplicatedStorage:WaitForChild(Remotes.Names.BossRewardClaimed, 30)
        if not rewardClaimed then
            warn("[PickleLord] BossRewardClaimed bindable never appeared — encounter won't trigger")
            return
        end
        rewardClaimed.Event:Connect(function(payload)
            local mapId = payload and payload.mapId
            if mapId ~= 3 then return end
            -- 2s delay after the player picks their aux tower —
            -- enough for the picker UI to fully close + the new
            -- tower to appear in the hotbar before the boss arrives.
            task.delay(2.0, function()
                startPickleLord()
            end)
        end)
    end)

    -- Dev shortcut: DevKillPickleLord already fires the bindable directly
    -- (PermanentTowers handles that hook). When that's invoked while the
    -- mob is alive, also tear the model down so it doesn't sit there
    -- post-reward; reuses stopPickleLord(true) for the full path.
    pickleLordBindable.Event:Connect(function()
        if State.active and State.body then
            -- HP=0 path will fire stopPickleLord(true) → re-enter this
            -- bindable → infinite loop. Guard by checking if we got
            -- here from the listener (HP already 0).
            local hp = State.body:GetAttribute("Health") or 0
            if hp > 0 then
                State.body:SetAttribute("Health", 0)
            end
        end
    end)
end

return PickleLordBoss
