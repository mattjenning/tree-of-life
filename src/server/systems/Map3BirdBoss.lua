--[[
    Map3BirdBoss.lua — The Canopy Bird boss-phase mechanics for Map 3.

    Per Matthew's 2026-04-24 spec:
      • Eggs (path mobs) come out continuously through the phase. Spawn
        interval ramps EXPONENTIALLY — slow start, accelerating until a
        hard cap at ~5 minutes when the phase auto-ends.
      • Every 30 seconds the bird swoops down, picks a player, grabs them
        by the head, and starts carrying them upward toward the canopy.
      • A grabbed player must CLICK the bird 10 times to be released
        (clicks fire BirdClick remote). If the bird carries them past the
        map's vertical bounds first, the player dies and is "carried off."
      • A "cool bird model" — procedural body / wings / beak / talons.

    setup(ctx) reads:
      ctx.MAP3_CENTER, ctx.MAP3_WIDTH, ctx.MAP3_DEPTH, ctx.MAP3_HEIGHT,
      ctx.makePart, ctx.rand, ctx.MAP3_PLAYER_SPAWN_CF (for arena eyeline)

    Publishes:
      ctx.startBirdBoss(opts)  -- begin the phase
      ctx.stopBirdBoss()       -- abort early (dev / cleanup)

    PHASE-D STATUS (2026-04-25): partial.
      Done: bird body tagged Tags.FinalBoss so the wave system's HP-bar
            fallback in broadcastWaveState picks it up exactly like it
            picks up the spider (no separate BirdBossCountdown remote
            needed for HP tracking, though that remote still drives the
            damageable gray↔red flip — separate concern). Tunables now
            live in Config.Map3.CanopyBird. GameTime + Maid replace the
            ad-hoc time/cleanup patterns.
      Deferred: full move into WaveContext as systems/CanopyBirdBoss.lua
            (sibling to CanopySpiderBoss.lua). Requires routing the bird's
            spawn through ctx.makeMob("bird") + registering it in
            ctx.activeMobs so Damage.lua's standard path destroys the
            body Part on HP=0, plus replumbing MAP3_CENTER / MAP3_HEIGHT
            access from HubContext to WaveContext (publish via Workspace
            attributes or pass through a bindable). Tracked as the
            run-boss-precursor; safe to do once the Pickle Lord encounter
            is being designed since both share the same hub→wave-context
            seam.

    Phase lifecycle:
      start → ACTIVE (egg-spawn + swoop loops) → 5min hard-cap → stop
                ↓
              swoop pattern: HOVER ↺ → DIVE → GRAB → CARRY ↑
                                                    ↓        ↓
                                              10 clicks  bounds-kill
                                                    ↓        ↓
                                                 RELEASE  (player dies)
                                                    ↓        ↓
                                                       HOVER ↺
]]

local Workspace         = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")

local Shared   = ReplicatedStorage:WaitForChild("Shared")
local Remotes  = require(Shared:WaitForChild("Remotes"))
local Tags     = require(Shared:WaitForChild("Tags"))
local Config   = require(Shared:WaitForChild("Config"))
local GameTime = require(Shared:WaitForChild("GameTime"))
local Maid     = require(Shared:WaitForChild("Maid"))
local MobUtil  = require(Shared:WaitForChild("MobUtil"))

local Map3BirdBoss = {}

function Map3BirdBoss.setup(ctx)
    local MAP3_CENTER = ctx.MAP3_CENTER
    local MAP3_HEIGHT = ctx.MAP3_HEIGHT
    local makePart    = ctx.makePart
    local rand        = ctx.rand

    -- 3D HP bar helper — eggs + bird don't go through MobFactory (which
    -- builds its own bars), so they need their own. BillboardGui anchored
    -- on the part with a StudsOffset, fill width tracks Health attribute.
    -- Returns a small handle: { gui, setFillColor(c) } so callers can flip
    -- the fill color (e.g. bird "gray while hovering, red while diving").
    local function attachHpBar(part, opts)
        opts = opts or {}
        local bb = Instance.new("BillboardGui")
        bb.Name = "HpBar"
        bb.Size = UDim2.fromOffset(opts.width or 80, opts.height or 14)
        bb.StudsOffset = Vector3.new(0, opts.yOffset or 4, 0)
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
        local bgCorner = Instance.new("UICorner")
        bgCorner.CornerRadius = UDim.new(0.4, 0)
        bgCorner.Parent = bg
        local fill = Instance.new("Frame")
        fill.Size = UDim2.new(1, -2, 1, -2)
        fill.Position = UDim2.fromOffset(1, 1)
        fill.BackgroundColor3 = opts.fillColor or Color3.fromRGB(240, 80, 80)
        fill.BorderSizePixel = 0
        fill.Parent = bg
        local fillCorner = Instance.new("UICorner")
        fillCorner.CornerRadius = UDim.new(0.4, 0)
        fillCorner.Parent = fill
        local hpText
        if opts.showText then
            hpText = Instance.new("TextLabel")
            hpText.Size = UDim2.fromScale(1, 1)
            hpText.BackgroundTransparency = 1
            hpText.TextColor3 = Color3.fromRGB(255, 255, 255)
            hpText.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
            hpText.TextStrokeTransparency = 0
            hpText.Font = Enum.Font.FredokaOne
            hpText.TextSize = opts.textSize or 12
            hpText.ZIndex = 2
            hpText.Parent = bg
        end
        local function refresh()
            local hp = part:GetAttribute("Health") or 0
            local max = part:GetAttribute("MaxHealth") or 1
            local frac = math.max(0, math.min(hp / max, 1))
            fill.Size = UDim2.new(frac, -2, 1, -2)
            if hpText then
                hpText.Text = string.format("%d / %d", math.max(0, math.floor(hp)), math.floor(max))
            end
        end
        refresh()
        part:GetAttributeChangedSignal("Health"):Connect(refresh)
        part:GetAttributeChangedSignal("MaxHealth"):Connect(refresh)
        return {
            gui = bb,
            setFillColor = function(c) fill.BackgroundColor3 = c end,
        }
    end

    -- Tunables — sourced from Config.Map3.CanopyBird so balance lives in
    -- one greppable place (see comment on Config.Map3.CanopyBird for units).
    local CB                        = Config.Map3.CanopyBird
    local PHASE_HARD_CAP_SEC        = CB.PhaseHardCapWallclockSec
    local SWOOP_INTERVAL_SEC        = CB.SwoopIntervalSec
    local CLICKS_TO_RELEASE         = CB.ClicksToRelease
    local DAZE_GAME_SEC             = CB.DazeGameSec
    local DIVE_SPEED_STUDS_PER_SEC  = CB.DiveStudsPerSec
    -- Drop = post-release descent back to cruise altitude. Player has
    -- already been released (recordGrabHit calls releasePlayer the moment
    -- the 10th click lands), so the bird is now empty-handed and can
    -- plummet at boss-bird speed instead of the slow carry pace. 4× DIVE
    -- means a full ascent's worth of drop in ~1.5s wallclock.
    local DROP_SPEED_STUDS_PER_SEC  = CB.DiveStudsPerSec * 4
    local CARRY_SPEED_STUDS_PER_SEC = CB.CarryStudsPerSec
    local HOVER_PATROL_SPEED        = CB.HoverStudsPerSec
    local HOVER_HEIGHT_OFFSET_Y     = CB.HoverHeightOffsetY
    local HOVER_PATROL_RADIUS       = CB.HoverPatrolRadius
    local HOVER_PATROL_REPICK_SEC   = CB.HoverPatrolRepickGameSec
    local BIRD_MAX_HP               = CB.BirdMaxHp
    -- Carried past = die. Lowered by 20% (×0.8) per Matthew (2026-04-25)
    -- so the bird threatens an actual kill sooner during the carry — used
    -- to require nearly the full arena height of vertical travel before
    -- the kill check tripped. Now ~80% of (height + 18-stud overhead).
    local BOUNDS_KILL_Y             = MAP3_CENTER.Y + (MAP3_HEIGHT + 18) * 0.8

    local EGG_INTERVAL_SEC = CB.EggIntervalGameSec
    local EGG_BASE_HP      = CB.EggBaseHp
    local EGG_FINAL_HP     = CB.EggFinalHp
    local EGG_BASE_SIZE    = CB.EggBaseSize
    local EGG_FINAL_SIZE   = CB.EggFinalSize
    local EGG_SAFETY_DESTROY_SEC = CB.EggSafetyDestroyWallclockSec

    ----------------------------------------------------------------
    -- Bird model — procedural. Body / head / beak / wings / tail / legs / talons.
    -- Returns the Model + a `grabber` Part attached at the talons (the player
    -- attaches to this via WeldConstraint when grabbed).
    ----------------------------------------------------------------
    local BODY_COLOR    = Color3.fromRGB( 60,  45,  40)
    local FEATHER_DARK  = Color3.fromRGB( 40,  30,  28)
    local FEATHER_LIGHT = Color3.fromRGB( 90,  72,  62)
    local BEAK_COLOR    = Color3.fromRGB(220, 175,  60)
    local TALON_COLOR   = Color3.fromRGB( 30,  25,  20)
    local EYE_COLOR     = Color3.fromRGB(230, 220, 100)

    local function buildBirdModel(spawnPos)
        local model = Instance.new("Model")
        model.Name = "Map3CanopyBird"
        local function part(name, size, cframe, color, mat, shape)
            return makePart({
                Name = name,
                Size = size,
                CFrame = cframe,
                Material = mat or Enum.Material.SmoothPlastic,
                Color = color,
                Shape = shape,
                CanCollide = false,
                Parent = model,
            })
        end

        -- Body — Block, NOT Ball. Critical: a Ball part with non-uniform
        -- Size renders as an ELLIPSOID inscribed in the bounding box, not
        -- a stretched sphere. With Size (5, 4, 8) the ellipsoid only reaches
        -- ~z=2.65 at y=1.5 — but the neck child is anchored at (0, 1.5, 4)
        -- and every other child sits at a similar bounding-box edge, so they
        -- all visually float in empty space outside the rendered ellipsoid.
        -- Diagnostic prints confirmed the math is correct (delta = 0.0000)
        -- — the gap was purely a Ball-vs-Block render mismatch. See memory
        -- under feedback_bird_neck_unresolved.md for the 5 prior attempts.
        local body = part("Body",
            Vector3.new(5, 4, 8),
            CFrame.new(spawnPos),
            BODY_COLOR, Enum.Material.SmoothPlastic, Enum.PartType.Block)
        model.PrimaryPart = body

        -- Tail (rear plank) — slight upward angle to read like a bird.
        part("Tail",
            Vector3.new(2.5, 0.4, 4),
            CFrame.new(spawnPos + Vector3.new(0, 0.2, -5))
                * CFrame.Angles(math.rad(-15), 0, 0),
            FEATHER_DARK, Enum.Material.Fabric)

        -- Neck + head: head sits forward of the body.
        part("Neck",
            Vector3.new(2.6, 2.6, 2),
            CFrame.new(spawnPos + Vector3.new(0, 1.5, 4)),
            BODY_COLOR, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
        local head = part("Head",
            Vector3.new(3, 3, 3),
            CFrame.new(spawnPos + Vector3.new(0, 2.4, 5.4)),
            BODY_COLOR, Enum.Material.SmoothPlastic, Enum.PartType.Ball)

        -- Beak — pointed cone (use a stretched wedge approximation: thin
        -- tapered cylinder). Hangs forward off the head.
        local beak = part("Beak",
            Vector3.new(2.6, 1.0, 1.4),
            CFrame.new(spawnPos + Vector3.new(0, 2.0, 7.1))
                * CFrame.Angles(0, math.rad(90), 0),
            BEAK_COLOR, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)

        -- Eyes — glowing "headlights". Bigger neon balls + PointLights so
        -- they cast actual light forward, making the bird readable in
        -- the night arena (was nearly invisible against dark fog).
        for _, dx in ipairs({-1.0, 1.0}) do
            local eye = part("Eye",
                Vector3.new(1.0, 1.0, 1.0),
                CFrame.new(spawnPos + Vector3.new(dx, 2.8, 6.4)),
                EYE_COLOR, Enum.Material.Neon, Enum.PartType.Ball)
            local eyeLight = Instance.new("PointLight")
            eyeLight.Color = Color3.fromRGB(255, 235, 140)
            eyeLight.Range = 14
            eyeLight.Brightness = 4
            eyeLight.Parent = eye
        end

        -- (No glowing collar — eyes are the only Neon-lit element so the
        -- bird's silhouette stays clear in the night arena.)

        -- Wings — two wide planks, swept slightly back. Stored for flap anim.
        local function wing(side)
            local sign = (side == "L") and -1 or 1
            return part("Wing" .. side,
                Vector3.new(8, 0.5, 5),
                CFrame.new(spawnPos + Vector3.new(sign * 4.5, 0.6, -0.4))
                    * CFrame.Angles(0, math.rad(sign * 12), math.rad(sign * 8)),
                FEATHER_LIGHT, Enum.Material.Fabric)
        end
        local wingL = wing("L")
        local wingR = wing("R")

        -- Legs + talons hanging below the body. The grabber sits between
        -- the talons; this is the part we weld players to during a grab.
        for _, dx in ipairs({-1.0, 1.0}) do
            part("Leg",
                Vector3.new(0.5, 2.2, 0.5),
                CFrame.new(spawnPos + Vector3.new(dx, -2.2, 0)),
                TALON_COLOR, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
            -- Talon: 3 small pointy parts arranged like a bird foot.
            for j = 1, 3 do
                local angle = math.rad(-20 + (j - 1) * 20)
                part("Talon",
                    Vector3.new(0.3, 0.9, 0.3),
                    CFrame.new(spawnPos + Vector3.new(dx, -3.5, 0))
                        * CFrame.Angles(angle, 0, 0)
                        * CFrame.new(0, -0.4, 0.4),
                    TALON_COLOR)
            end
        end

        -- The "grabber" — invisible part at the talons where players attach.
        local grabber = part("Grabber",
            Vector3.new(2, 1, 2),
            CFrame.new(spawnPos + Vector3.new(0, -3.8, 0)),
            TALON_COLOR)
        grabber.Transparency = 1

        -- Rigid assembly: ALL parts anchored (body + every child). Each
        -- frame the flight loop sets body.CFrame and explicitly snaps every
        -- child to body.CFrame * its captured offset. This avoids physics
        -- entirely — no welds, no constraints, no PivotTo bugs. The previous
        -- approaches (WeldConstraint between anchored parts, classic Weld
        -- with unanchored children, model:PivotTo) all left visible gaps.
        local bodyOriginInv = body.CFrame:Inverse()
        local childOffsets = {}
        for _, p in ipairs(model:GetChildren()) do
            if p ~= body and p:IsA("BasePart") then
                p.Anchored = true
                childOffsets[p] = bodyOriginInv * p.CFrame
            end
        end
        -- Wings need their flap rotation overlaid; track them separately so
        -- the flight loop can apply a per-frame flap on top of the rig pose.
        local wingOffsets = {
            [wingL] = childOffsets[wingL],
            [wingR] = childOffsets[wingR],
        }

        -- Per Matthew: the YELLOW CIRCLE is the only tap target. Clicking
        -- the bird body should do nothing — the circle is the trigger.
        -- (Old ClickDetector on body is removed; only the BillboardGui's
        -- TextButton fires BirdClick → recordGrabHit now.)

        -- HP attribute setup — bird is damageable ONLY while swooping/
        -- carrying (Tags.Boss + Tags.Mob are added/removed in startFlight).
        body:SetAttribute("MaxHealth", BIRD_MAX_HP)
        body:SetAttribute("Health", BIRD_MAX_HP)
        body:SetAttribute("MapId", 3)
        -- 2× damage during swoop. The bird is only hittable while Tags.Mob
        -- is on (dive / grab / carry / drop), so this multiplier effectively
        -- applies only during swoops. damageMob reads DamageTakenMultiplier
        -- and scales incoming damage before subtracting from Health.
        body:SetAttribute("DamageTakenMultiplier", 2.0)
        -- 3D HP bar floating well above the bird (clear of head + beak).
        -- Gray fill while hovering (untargetable) — broadcastBossStatus
        -- flips the color when the bird transitions to a damageable state.
        -- yOffset 12 (was 7) so the bar sits clearly above the grab
        -- indicator (which floats at +5y) and the two BillboardGuis don't
        -- z-fight in screen space. showText prints "current / max" inline,
        -- matching every other mob's HP bar so the bird isn't a special case.
        local bodyHpBar = attachHpBar(body, {
            width = 240, height = 26, yOffset = 12,
            fillColor = Color3.fromRGB(140, 140, 140),
            showText = true,
            textSize = 16,
        })
        -- NOTE: NOT tagged on creation — towers shouldn't lock onto a
        -- bird that's hovering high up. Tag toggles in the flight loop.

        model.Parent = Workspace

        return {
            model = model,
            body = body,
            head = head,
            beak = beak,
            wingL = wingL,
            wingR = wingR,
            grabber = grabber,
            hpBar = bodyHpBar,
            childOffsets = childOffsets,  -- ALL non-body parts (including wings)
            wingOffsets = wingOffsets,    -- wings only (for flap overlay)
        }
    end

    ----------------------------------------------------------------
    -- Phase state — only one instance at a time.
    ----------------------------------------------------------------
    local State = {
        active = false,
        bird = nil,            -- { model, body, ... } from buildBirdModel
        startedAt = 0,
        targetPlayer = nil,    -- player currently being targeted / grabbed
        grabbedPlayer = nil,   -- player currently held (subset of targetPlayer)
        grabClicks = 0,        -- click counter for the active grab
        hoverPos = MAP3_CENTER + Vector3.new(0, HOVER_HEIGHT_OFFSET_Y, 0),
        eggSpawnConn = nil,    -- task spawn id for egg loop
        swoopConn = nil,       -- task spawn id for swoop loop
        flapConn = nil,        -- RBXScriptConnection for wing flap
        flightConn = nil,      -- RBXScriptConnection for movement
        flightState = "idle",  -- "hover" / "dive" / "grab" / "carry" / "drop" / "dazed" / "kill" / "idle"
        dazedGameTimeRemaining = 0,  -- counts DOWN by dt × gs each frame; daze ends at 0
        flightTarget = nil,    -- Vector3 destination for current movement
    }

    ----------------------------------------------------------------
    -- Player-attach helpers.
    ----------------------------------------------------------------
    local function getHRP(player)
        local char = player and player.Character
        return char and char:FindFirstChild("HumanoidRootPart")
    end
    local function getHumanoid(player)
        local char = player and player.Character
        return char and char:FindFirstChildWhichIsA("Humanoid")
    end

    -- Yellow "X TAPS LEFT" indicator broadcast (server → grabbed-player only).
    -- carryProgress payload: startY (player's Y at grab) and killY
    -- (BOUNDS_KILL_Y) let the client lerp the tap-button outline from
    -- black → red as the bird carries the player upward toward death.
    -- We forward whatever extra fields the call site passes; tap-only
    -- updates (mid-grab on each click) skip them and the client falls
    -- back to its cached values from the initial grab fire.
    local grabStateRemote = ReplicatedStorage:WaitForChild(Remotes.Names.BirdGrabState)
    local function fireGrabState(player, grabbed, tapsLeft, extra)
        if not player or not player.Parent then return end
        local payload = {
            grabbed  = grabbed,
            tapsLeft = tapsLeft or 0,
        }
        if extra then
            payload.startY = extra.startY
            payload.killY  = extra.killY
        end
        grabStateRemote:FireClient(player, payload)
    end

    local activeGrabWeld = nil
    local function attachPlayerToGrabber(player)
        local hrp = getHRP(player)
        if not hrp or not State.bird then return end
        -- Remove existing weld if any.
        if activeGrabWeld then
            activeGrabWeld:Destroy()
            activeGrabWeld = nil
        end
        -- Position the player just below the grabber so the bird visibly
        -- has them by the head.
        hrp.CFrame = State.bird.grabber.CFrame * CFrame.new(0, -2.5, 0)
        local w = Instance.new("WeldConstraint")
        w.Name = "BirdGrab"
        w.Part0 = State.bird.grabber
        w.Part1 = hrp
        w.Parent = State.bird.grabber
        activeGrabWeld = w
        State.grabbedPlayer = player
        State.grabClicks = 0
        -- Send the carry-bounds so the client can render the outline-red
        -- countdown ring on the tap button. startY = where the player is
        -- AT THIS MOMENT (grab origin); killY = the bounds-kill ceiling.
        -- progress = (currentY - startY) / (killY - startY).
        fireGrabState(player, true, CLICKS_TO_RELEASE, {
            startY = hrp.Position.Y,
            killY  = BOUNDS_KILL_Y,
        })
        -- Hide the bird's 3D HP bar while a player is grabbed — the click
        -- circle floats in the same screen pixels and the two BillboardGuis
        -- z-fight. The screen-HUD boss bar still shows HP.
        if State.bird and State.bird.hpBar and State.bird.hpBar.gui then
            State.bird.hpBar.gui.Enabled = false
        end
        -- Force 1× speed during the carry/click window. GameTime.lockSpeed
        -- returns a release closure that's idempotent — pairs the lock to a
        -- single owner so we can't accidentally double-release.
        State.grabSpeedRelease = GameTime.lockSpeed()
    end
    local function releasePlayer(killThem)
        local player = State.grabbedPlayer
        State.grabbedPlayer = nil
        State.grabClicks = 0
        if activeGrabWeld then
            activeGrabWeld:Destroy()
            activeGrabWeld = nil
        end
        -- Pop the matching speed lock. The release closure is idempotent
        -- so calling it after stopBirdBoss already released is safe.
        if State.grabSpeedRelease then
            State.grabSpeedRelease()
            State.grabSpeedRelease = nil
        end
        -- Restore the 3D HP bar (was hidden during grab to avoid z-fight
        -- with the click circle).
        if State.bird and State.bird.hpBar and State.bird.hpBar.gui then
            State.bird.hpBar.gui.Enabled = true
        end
        if not player then return end
        fireGrabState(player, false, 0)
        if killThem then
            local hum = getHumanoid(player)
            if hum then hum.Health = 0 end
            -- Carry-kill = run failure. Killing the heart triggers the wave
            -- system's existing GameOver flow (DEFEATED banner + retry
            -- modal). No special "dropped" path — reuse the heart-death
            -- pipeline so the UX is identical to other lose conditions.
            local map3Room = Workspace:FindFirstChild("TreeOfLifeMap3Room")
            local heart = map3Room and map3Room:FindFirstChild("TreeHeartMap3")
            if heart and (heart:GetAttribute("Health") or 0) > 0 then
                heart:SetAttribute("Health", 0)
            end
        else
            -- Reset orientation: bird was rotated 180° during dive, so the
            -- weld left HRP at a flipped Y rotation; without this the
            -- character lands sideways/upside-down. Preserve world position,
            -- snap to identity orientation so the humanoid drops normally.
            local hrp = getHRP(player)
            if hrp then
                hrp.CFrame = CFrame.new(hrp.Position)
                -- Per Matthew (2026-04-25): "the bird should drop [the
                -- player] fast, like the speed of gravity." On weld
                -- destroy the player inherits the bird's slow upward
                -- carry velocity (~8 stud/s up) and has to decelerate
                -- before falling — the moment of "I escaped!" is undercut
                -- by a soft hang. Slam the velocity to terminal-fall so
                -- they plummet straight down. Default Workspace.Gravity
                -- (~196 stud/s²) brings characters to ~125 stud/s
                -- terminal anyway; this just front-loads it.
                hrp.AssemblyLinearVelocity = Vector3.new(0, -125, 0)
            end
        end
    end

    ----------------------------------------------------------------
    -- Bird movement — Heartbeat-driven, no physics; we just drive body.CFrame.
    ----------------------------------------------------------------
    local function pickRandomPlayer()
        -- Players whose character is in/near the map 3 arena.
        local candidates = {}
        for _, p in ipairs(Players:GetPlayers()) do
            local hrp = getHRP(p)
            if hrp then
                local d = (hrp.Position - MAP3_CENTER).Magnitude
                if d < 200 then table.insert(candidates, p) end
            end
        end
        if #candidates == 0 then return nil end
        return candidates[math.random(1, #candidates)]
    end

    -- Pick a random patrol point at the bird's hover altitude. Used for
    -- the lazy "wandering around 20 studs up" behaviour between swoops.
    local function pickHoverPoint()
        local angle = math.random() * math.pi * 2
        local r = HOVER_PATROL_RADIUS * (0.4 + math.random() * 0.6)
        return MAP3_CENTER + Vector3.new(
            math.cos(angle) * r,
            HOVER_HEIGHT_OFFSET_Y,
            math.sin(angle) * r
        )
    end

    -- Damageability gate: tag the bird as a Boss/Mob ONLY during the
    -- attack states (dive / grab / carry). Towers won't lock onto it
    -- while it's lazily hovering — players have to wait for swoops to
    -- shoot it down. Also flips CanCollide so projectile raycasts hit.
    local function applyDamageableTag(stateName)
        local body = State.bird and State.bird.body
        if not body then return end
        local damageable = (stateName == "dive"
                         or stateName == "grab"
                         or stateName == "carry"
                         or stateName == "drop"
                         or stateName == "dazed")  -- post-drop pile-on window
        body.CanCollide = damageable
        if damageable then
            if Tags.Boss then CollectionService:AddTag(body, Tags.Boss) end
            if Tags.Mob  then CollectionService:AddTag(body, Tags.Mob)  end
        else
            if Tags.Boss then CollectionService:RemoveTag(body, Tags.Boss) end
            if Tags.Mob  then CollectionService:RemoveTag(body, Tags.Mob)  end
        end
    end

    -- Stun-stars VFX: 3 yellow Neon balls orbiting above the bird's head
    -- while it's dazed. Same pattern MobUpdate uses for stunned mobs (so
    -- the visual reads consistently). Created on entering "dazed",
    -- destroyed on leaving.
    local function spawnStunStars()
        if State.stunStars then return end
        local stars = {}
        for i = 1, 3 do
            local star = Instance.new("Part")
            star.Name = "BirdStunStar"
            star.Shape = Enum.PartType.Ball
            star.Size = Vector3.new(0.9, 0.9, 0.9)
            star.Anchored = true
            star.CanCollide = false
            star.CastShadow = false
            star.Material = Enum.Material.Neon
            star.Color = Color3.fromRGB(255, 230, 60)
            star.Parent = Workspace
            stars[i] = star
        end
        State.stunStars = stars
    end
    local function clearStunStars()
        if not State.stunStars then return end
        for _, star in ipairs(State.stunStars) do
            if star.Parent then star:Destroy() end
        end
        State.stunStars = nil
    end

    local function setFlightTarget(stateName, target)
        local prev = State.flightState
        State.flightState = stateName
        State.flightTarget = target
        applyDamageableTag(stateName)
        if stateName == "dazed" then
            spawnStunStars()
        elseif prev == "dazed" then
            clearStunStars()
        end
        -- Dive-window speed lock: dive must feel slow so the player has
        -- time to react / line up taps before the grab. Push 1× on enter,
        -- pop on exit (regardless of where we go next — grab pushes its
        -- own lock, so nested-count handles the overlap; hover/etc. fall
        -- back to the player's chosen speed). Movement scales with
        -- Workspace.GameSpeed in the flight loop, so a 1× lock also
        -- forces the bird's own dive speed to 1×.
        if stateName == "dive" and not State.diveSpeedRelease then
            State.diveSpeedRelease = GameTime.lockSpeed()
        elseif prev == "dive" and stateName ~= "dive" and State.diveSpeedRelease then
            State.diveSpeedRelease()
            State.diveSpeedRelease = nil
        end
        -- Broadcast immediately on state changes so the boss-bar gray↔red
        -- flip lands the moment a swoop starts (otherwise it lags up to
        -- 0.5s waiting for the next status-loop tick).
        if prev ~= stateName and State.broadcastBossStatus then
            State.broadcastBossStatus()
        end
    end

    -- Manual-rigging flight loop: each frame, move the body, then re-apply
    -- every child's stored relative CFrame so the assembly stays rigid.
    -- Wings are overridden after for the flap animation. Body's local +Z
    -- (where the head was placed at build time) is rotated to point along
    -- the direction of motion via a 180° Y-axis turn after CFrame.lookAt
    -- (lookAt makes -Z face the target, but our head sits on +Z).
    local function startFlight()
        if State.flightConn then State.flightConn:Disconnect() end
        State.flightConn = RunService.Heartbeat:Connect(function(dt)
            if not State.bird or not State.bird.body.Parent then return end
            local body = State.bird.body
            local stateName = State.flightState
            -- Dive: chase the player's CURRENT position (not a stale
            -- snapshot), so they can't just stand still and the bird
            -- overshoots. Carry / hover / drop use their stored targets.
            if stateName == "dive" then
                local p = State.targetPlayer
                if p then
                    local hrp = getHRP(p)
                    if hrp then
                        State.flightTarget = hrp.Position + Vector3.new(0, 4, 0)
                    end
                end
            end
            local target = State.flightTarget

            -- "Dazed" state: bird stays in place, levels out, takes damage.
            -- Position is whatever was passed to setFlightTarget("dazed",pos)
            -- — set to the bird's current position at drop time so the stun
            -- begins exactly where the player escaped, not after a recovery
            -- flight.
            if stateName == "dazed" then
                local dazePos = State.flightTarget or State.hoverPos
                body.CFrame = CFrame.new(dazePos)
                target = nil  -- skip the per-frame movement step below
                -- Bleed the daze countdown by dt × gs (game-time). When
                -- the countdown hits 0, the exit check at the bottom of
                -- this function flips us back to hover.
                State.dazedGameTimeRemaining = State.dazedGameTimeRemaining
                    - GameTime.scaled(dt)
                -- Orbit the stun stars above the bird's head.
                if State.stunStars then
                    local now2 = os.clock()
                    local cx, cy, cz = dazePos.X, dazePos.Y + 4.5, dazePos.Z
                    local radius = 2.4
                    for i, star in ipairs(State.stunStars) do
                        local a = now2 * 5 + (i - 1) * (2 * math.pi / 3)
                        star.CFrame = CFrame.new(
                            cx + math.cos(a) * radius,
                            cy + math.sin(a * 2) * 0.3,
                            cz + math.sin(a) * radius)
                    end
                end
            end

            -- Movement toward flightTarget. Uses Model:PivotTo to translate
            -- the entire bird (anchored body + all anchored children) as a
            -- rigid assembly. Carry mode preserves the body's CURRENT
            -- rotation (so the bird doesn't tilt straight up while ascending
            -- with the player) — translation only.
            if target then
                local pos = body.Position
                local toTarget = target - pos
                local dist = toTarget.Magnitude
                local speed
                if stateName == "dive" then speed = DIVE_SPEED_STUDS_PER_SEC
                elseif stateName == "carry" then speed = CARRY_SPEED_STUDS_PER_SEC
                elseif stateName == "drop"  then speed = DROP_SPEED_STUDS_PER_SEC
                else speed = HOVER_PATROL_SPEED
                end
                -- Scale with the wave-system game speed so dive / carry /
                -- drop / patrol speed up at 2×/3×/5×/10× alongside mobs.
                local step = math.min(dist, speed * GameTime.scaled(dt))
                if dist > 0.01 then
                    local dir = toTarget.Unit
                    local newPos = pos + dir * step
                    local newCF
                    if stateName == "carry" or stateName == "drop" then
                        -- Translation-only: keep current rotation. The
                        -- player is still welded to the grabber during
                        -- both carry (ascending) and drop (descending to
                        -- cruise height) — flipping the bird via lookAt
                        -- would yank the welded player upside-down.
                        newCF = (body.CFrame - body.CFrame.Position) + newPos
                    else
                        -- 180° flip so head (built at +Z) leads, not trails.
                        newCF = CFrame.lookAt(newPos, newPos + dir)
                                * CFrame.Angles(0, math.rad(180), 0)
                    end
                    body.CFrame = newCF
                end
            end

            -- Manual rig: ALL non-body children get snapped to their stored
            -- relative offset every frame. Wings get a flap overlay below.
            for child, offset in pairs(State.bird.childOffsets) do
                child.CFrame = body.CFrame * offset
            end

            -- Wing flap — overlay AFTER the rig pass so flap is visible.
            local flapSpeed = (stateName == "dive" or stateName == "carry") and 14 or 6
            local flap = math.sin(os.clock() * flapSpeed) * math.rad(28)
            local function flapWing(wing, sign)
                wing.CFrame = body.CFrame
                    * CFrame.new(sign * 4.5, 0.6, -0.4)
                    * CFrame.Angles(0, math.rad(sign * 12), math.rad(sign * 8 + sign * math.deg(flap) * 0.6))
            end
            flapWing(State.bird.wingL, -1)
            flapWing(State.bird.wingR,  1)

            -- Arrival/state-transition logic.
            if target then
                local toTarget = target - body.Position
                local dist = toTarget.Magnitude
                if dist < 5 then
                    if stateName == "dive" then
                        -- Reached the player → grab them.
                        local p = State.targetPlayer
                        if p and getHRP(p) then
                            attachPlayerToGrabber(p)
                            -- Carry up: target is straight up out the top.
                            setFlightTarget("carry",
                                MAP3_CENTER + Vector3.new(0,
                                    MAP3_HEIGHT + 80,
                                    rand(-20, 20)))
                        else
                            -- Target lost: bail back to hover.
                            setFlightTarget("hover", State.hoverPos)
                        end
                    elseif stateName == "drop" then
                        -- Drop completed. Bird carried the player straight
                        -- down to cruising height — now release them AND
                        -- enter the 3-game-second daze in one beat. Daze
                        -- position is the current XZ (where the drop ended),
                        -- not hoverPos (map center) — keeps the bird stunned
                        -- right above where the player escaped.
                        if State.grabbedPlayer then
                            releasePlayer(false)
                        end
                        -- Daze counts down in GAME-time (decremented by dt×gs
                        -- each frame in the dazed branch above). Earlier
                        -- impl set a wallclock deadline that read GameSpeed
                        -- ONCE — if that snapshot caught a stale gs=1 from
                        -- the carry lock or a player speed-change mid-daze
                        -- didn't reflect, the bird sat motionless for the
                        -- wrong duration. Polling per-frame ducks both.
                        State.dazedGameTimeRemaining = DAZE_GAME_SEC
                        setFlightTarget("dazed", body.Position)
                    end
                end
            end
            -- Dazed cooldown: when the game-time countdown drains, resume hover.
            if stateName == "dazed" and State.dazedGameTimeRemaining <= 0 then
                setFlightTarget("hover", State.hoverPos)
            end

            -- During CARRY: keep player welded to grabber (the weld already
            -- handles position) AND check bounds-kill.
            if stateName == "carry" and State.grabbedPlayer then
                local hrp = getHRP(State.grabbedPlayer)
                if hrp and hrp.Position.Y > BOUNDS_KILL_Y then
                    -- Carried off the map — kill the player.
                    setFlightTarget("kill", nil)
                    releasePlayer(true)
                    -- After the kill, return to hover.
                    State.flightTarget = State.hoverPos
                    State.flightState = "hover"
                end
            end
        end)
    end

    ----------------------------------------------------------------
    -- Egg spawn loop. Spawns a path mob via the wave-system mob factory
    -- if available; otherwise spawns a placeholder egg part at the path
    -- start that pathfinds (well — falls toward) the heart. For now we
    -- simply create a tagged "egg mob" Part using ctx.makePart and let
    -- the existing wave-system mob update tick it (it tags as Mob and
    -- has MapId=3, Health, etc., matching the contract used elsewhere).
    ----------------------------------------------------------------
    local function spawnEgg()
        -- Find the EnemySpawn for map 3.
        local map3Room = Workspace:FindFirstChild("TreeOfLifeMap3Room")
        if not map3Room then return end
        local spawnPart
        for _, p in ipairs(map3Room:GetDescendants()) do
            if p:IsA("BasePart") and p.Name == "EnemySpawnMap3" then
                spawnPart = p
                break
            end
        end
        if not spawnPart then
            warn("[Map3BirdBoss] EnemySpawnMap3 not found — egg skipped")
            return
        end
        -- Linear ramp by elapsed phase time. Earlier eggs are tiny + low HP;
        -- later eggs are huge + nearly unkillable.
        local elapsed = math.max(0, os.clock() - (State.startedAt or os.clock()))
        local progress = math.min(elapsed / PHASE_HARD_CAP_SEC, 1)
        local eggHp   = math.floor(EGG_BASE_HP   + (EGG_FINAL_HP   - EGG_BASE_HP)   * progress)
        local eggSize = EGG_BASE_SIZE + (EGG_FINAL_SIZE - EGG_BASE_SIZE) * progress
        -- Egg-shaped Ball + vertical-stretch SpecialMesh + eggshell white
        -- SmoothPlastic + faint warm PointLight glow.
        local egg = makePart({
            Name = "BirdBossEgg",
            Size = Vector3.new(eggSize, eggSize, eggSize),
            CFrame = spawnPart.CFrame * CFrame.new(0, eggSize * 0.7 + 1, 0),
            Material = Enum.Material.SmoothPlastic,
            Color = Color3.fromRGB(245, 235, 215),  -- eggshell white
            Shape = Enum.PartType.Ball,
            CanCollide = false,
            Parent = map3Room,
        })
        local eggMesh = Instance.new("SpecialMesh")
        eggMesh.MeshType = Enum.MeshType.Sphere
        eggMesh.Scale = Vector3.new(1.0, 1.55, 1.0)
        eggMesh.Parent = egg
        local eggLight = Instance.new("PointLight")
        eggLight.Color = Color3.fromRGB(255, 240, 210)
        eggLight.Range = math.max(4, eggSize * 1.2)
        eggLight.Brightness = 1.2
        eggLight.Parent = egg
        egg:SetAttribute("MapId", 3)
        egg:SetAttribute("Health", eggHp)
        egg:SetAttribute("MaxHealth", eggHp)
        if Tags.Mob then
            CollectionService:AddTag(egg, Tags.Mob)
        end
        -- 3D HP bar above the egg, scaled with the egg's size so a tiny
        -- early-game egg gets a small bar and a late-game giant gets a
        -- proportionally large one. showText prints "hp / maxHp" so the
        -- player can tell at a glance how tough each egg is.
        attachHpBar(egg, {
            width = math.floor(80 + eggSize * 8),
            height = 16,
            yOffset = eggSize * 1.1 + 1,
            showText = true,
            textSize = 13,
        })
        -- Walk the egg along the EnemyPath waypoints. The wave system's
        -- mob-update tick only drives mobs it spawned itself; my eggs are
        -- created via makePart so I move them manually.
        local pathFolder = map3Room:FindFirstChild("EnemyPath")
        if pathFolder then
            local waypoints = {}
            for _, wp in ipairs(pathFolder:GetChildren()) do
                if wp:IsA("BasePart") and wp.Name:match("^Waypoint%d+$") then
                    table.insert(waypoints, wp)
                end
            end
            table.sort(waypoints, function(a, b)
                return (tonumber(a.Name:match("%d+")) or 0)
                     < (tonumber(b.Name:match("%d+")) or 0)
            end)
            local moveSpeed = 6  -- stud/s
            -- Eggs ride 1 stud above the waypoint line — keeps them clear of
            -- the floor mesh and gives them a visual "rolling" lift. The
            -- walker only moves on the XZ plane, preserving this Y offset.
            local EGG_Y_LIFT = eggSize * 0.7 + 1
            task.spawn(function()
                for i = 1, #waypoints do
                    local wp = waypoints[i]
                    -- Stamp the current path index on the egg so findTarget's
                    -- "First" mode can sort by REAL waypoint progress instead
                    -- of guessing from closest-waypoint Magnitude. Without
                    -- this, a winding path can put an egg near the heart
                    -- physically close to an early-WP elbow, and "First"
                    -- picks a mid-path egg instead of the front-most one.
                    egg:SetAttribute("WaypointIndex", i)
                    while egg.Parent and wp.Parent do
                        -- Per-frame dt × gameSpeed (via GameTime.scaled) so
                        -- movement advances by GAME-time. Heartbeat:Wait
                        -- returns true wallclock dt (~0.017 at 60fps);
                        -- gameSpeed scales each tick. Avoids the older
                        -- task.wait(s/gs) floor at one frame.
                        local dt = RunService.Heartbeat:Wait()
                        if not (egg.Parent and wp.Parent) then break end
                        local wpFlat = Vector3.new(wp.Position.X,
                            wp.Position.Y + EGG_Y_LIFT, wp.Position.Z)
                        local toWp = wpFlat - egg.Position
                        local dist = toWp.Magnitude
                        if dist < 0.4 then break end
                        local step = math.min(dist, moveSpeed * GameTime.scaled(dt))
                        egg.CFrame = CFrame.new(egg.Position + toWp.Unit * step)
                    end
                    if not egg.Parent then return end
                end
                -- Reached the heart — damage it and self-destruct via the
                -- shared MobUtil helper. Damage = egg's REMAINING HP (not
                -- MaxHp). A tower-damaged egg arrives weaker — matches
                -- the wave-system mob contract (MobUpdate uses data.hp
                -- not data.damage). The Health attribute mirrors the
                -- egg's running HP via Damage.lua's standalone path.
                if egg.Parent then
                    local remainingHp = egg:GetAttribute("Health") or 0
                    MobUtil.damageHeart(map3Room:FindFirstChild("TreeHeartMap3"),
                        math.max(0, remainingHp))
                    egg:Destroy()
                end
            end)
        end
        -- Safety: self-destruct after EggSafetyDestroyWallclockSec in case
        -- path walk gets stuck. Sized in Config so the longest plausible
        -- path even at 1× game-speed completes before the safety fires.
        task.delay(EGG_SAFETY_DESTROY_SEC,
            function() if egg.Parent then egg:Destroy() end end)
    end

    -- Phase-active predicate for GameTime.adaptiveWait: true while the
    -- phase is running, false once stopBirdBoss has been called. Lets
    -- adaptive waits abort cleanly mid-tick when the boss is killed/aborted
    -- so loop bodies don't run a final tick against a torn-down State.
    local function isActive() return State.active end

    local function startEggLoop()
        State.maid:give(task.spawn(function()
            spawnEgg()  -- immediate first egg
            local t0 = os.clock()
            while State.active do
                local elapsed = os.clock() - t0
                if elapsed >= PHASE_HARD_CAP_SEC then break end
                GameTime.adaptiveWait(EGG_INTERVAL_SEC, isActive)
                if State.active then spawnEgg() end
            end
        end))
    end

    ----------------------------------------------------------------
    -- Swoop loop — every SWOOP_INTERVAL_SEC, pick a target and dive.
    ----------------------------------------------------------------
    local function startSwoopLoop()
        State.maid:give(task.spawn(function()
            setFlightTarget("hover", pickHoverPoint())
            GameTime.adaptiveWait(10 + math.random() * 5, isActive)
            while State.active do
                if State.flightState == "hover" then
                    local target = pickRandomPlayer()
                    if target then
                        State.targetPlayer = target
                        local hrp = getHRP(target)
                        if hrp then
                            setFlightTarget("dive", hrp.Position + Vector3.new(0, 4, 0))
                        end
                    end
                end
                GameTime.adaptiveWait(SWOOP_INTERVAL_SEC, isActive)
            end
        end))
    end

    -- Hover patrol: while in "hover" state, pick a new low-altitude point
    -- every HOVER_PATROL_REPICK_SEC so the bird drifts around the arena
    -- instead of standing still.
    local function startPatrolLoop()
        State.maid:give(task.spawn(function()
            while State.active do
                if State.flightState == "hover" then
                    setFlightTarget("hover", pickHoverPoint())
                end
                GameTime.adaptiveWait(HOVER_PATROL_REPICK_SEC, isActive)
            end
        end))
    end

    ----------------------------------------------------------------
    -- Click handler: BirdClick remote increments per-grab counter; at 10,
    -- the bird releases the player and switches to a "drop" flight that
    -- returns to hover.
    ----------------------------------------------------------------
    -- Single increment + UI-update path so both ClickDetector and the
    -- BirdClick remote share behaviour.
    local function recordGrabHit(player)
        if not State.active or not State.grabbedPlayer then return end
        if player ~= State.grabbedPlayer then return end
        State.grabClicks = State.grabClicks + 1
        local tapsLeft = math.max(0, CLICKS_TO_RELEASE - State.grabClicks)
        if State.grabClicks >= CLICKS_TO_RELEASE then
            -- 10 clicks done — bird drops STRAIGHT DOWN to cruising
            -- altitude, carrying the player WELDED along for the
            -- descent (per Matthew 2026-04-25: "drop initially with
            -- the bird, then continue down at the new velocity,
            -- otherwise you land on the bird"). Player stays attached
            -- so the bird's body never overtakes them mid-air; the
            -- arrival branch in the flight loop calls releasePlayer
            -- which slams HRP velocity to -125 stud/s for the final
            -- fall to the floor.
            local body = State.bird and State.bird.body
            local cur  = body and body.Position
            local dropTarget = (cur
                and Vector3.new(cur.X, State.hoverPos.Y, cur.Z))
                or State.hoverPos
            setFlightTarget("drop", dropTarget)
            -- Keep the grab indicator up but at "0" so the player
            -- knows the descent is in progress; hides on release.
            fireGrabState(player, true, 0)
        else
            fireGrabState(player, true, tapsLeft)
        end
    end
    local birdClickRemote = ReplicatedStorage:WaitForChild(Remotes.Names.BirdClick)
    birdClickRemote.OnServerEvent:Connect(recordGrabHit)
    -- ClickDetector path retired — the yellow grab-circle BillboardGui is
    -- the sole tap target now. Stub kept so callers (startBirdBoss) don't
    -- need to know.
    local function bindClickDetector() end

    ----------------------------------------------------------------
    -- start / stop
    ----------------------------------------------------------------
    -- Boss-status broadcast: client uses this to drive the boss HP bar.
    -- (Renamed semantics from a countdown to {active, hp, maxHp} per
    -- Matthew's "give it a healthbar, take away the timer" pivot.)
    local statusRemote = ReplicatedStorage:WaitForChild(Remotes.Names.BirdBossCountdown)
    local function broadcastBossStatus()
        if not State.active or not State.bird or not State.bird.body.Parent then
            statusRemote:FireAllClients({
                active = false, hp = 0, maxHp = BIRD_MAX_HP,
                damageable = false,
            })
            return
        end
        local hp = State.bird.body:GetAttribute("Health") or 0
        -- damageable = bird is currently in a state that lets towers hit it.
        -- Hover/idle = NOT damageable (gray bar so players don't waste shots).
        -- Dive/grab/carry/drop = damageable (red bar).
        local s = State.flightState
        local damageable = (s == "dive" or s == "grab" or s == "carry"
                         or s == "drop" or s == "dazed")
        -- Sync the bird's 3D HP bar color (gray ↔ red) on every tick so
        -- it tracks the same gating as the screen HUD bar.
        if State.bird.hpBar and State.bird.hpBar.setFillColor then
            State.bird.hpBar.setFillColor(damageable
                and Color3.fromRGB(220, 50, 70)
                or  Color3.fromRGB(140, 140, 140))
        end
        statusRemote:FireAllClients({
            active = true,
            hp = hp,
            maxHp = BIRD_MAX_HP,
            damageable = damageable,
        })
    end
    State.broadcastBossStatus = broadcastBossStatus  -- exposed for setFlightTarget
    local function startStatusLoop()
        task.spawn(function()
            local startedFor = State.startedAt
            while State.active and State.startedAt == startedFor do
                broadcastBossStatus()
                task.wait(0.5)
            end
        end)
    end

    local stopBirdBoss  -- forward-declare for the Health=0 handler
    local function startBirdBoss()
        if State.active then return end
        State.active = true
        State.startedAt = os.clock()
        -- Fresh Maid for this run. Everything spawned/connected/built
        -- during the phase gets registered to it; stopBirdBoss tears
        -- the whole bag down in one call (no per-resource cleanup
        -- branch to forget when adding new state).
        State.maid = Maid.new()
        State.bird = buildBirdModel(MAP3_CENTER + Vector3.new(0, HOVER_HEIGHT_OFFSET_Y, 0))
        State.maid:give(State.bird.model)
        bindClickDetector()
        -- Health → 0 ends the phase. Tagged FinalBoss so the wave-system
        -- HUD HP-bar fallback in broadcastWaveState picks the bird up
        -- without needing a separate boss-status remote (parity with
        -- spider, mold king).
        if Tags.FinalBoss then
            CollectionService:AddTag(State.bird.body, Tags.FinalBoss)
        end
        State.maid:give(State.bird.body:GetAttributeChangedSignal("Health"):Connect(function()
            local hp = State.bird and State.bird.body:GetAttribute("Health") or 0
            if hp <= 0 and State.active then
                -- Bird ACTUALLY killed (vs hard-cap or dev abort) →
                -- map 3 won → kick off the run-boss reward chain.
                stopBirdBoss(true)
            end
        end))
        startFlight()
        startEggLoop()
        startSwoopLoop()
        startPatrolLoop()
        startStatusLoop()
        broadcastBossStatus()
        -- First-timer leaf-message tip: shows only to players who haven't
        -- beaten map 3 yet (tracked via HasBeatenMap3 attribute, set by
        -- the wave system on map-3 boss kill — TODO when the win flow lands).
        -- Per-session HasSeenBirdBossTip prevents re-firing if they re-enter.
        if ctx.fireLeafMessage then
            for _, p in ipairs(Players:GetPlayers()) do
                if not p:GetAttribute("HasBeatenMap3")
                   and not p:GetAttribute("HasSeenBirdBossTip") then
                    p:SetAttribute("HasSeenBirdBossTip", true)
                    -- Mobile-first plain text. No hotkey highlight —
                    -- iPad and PC see the same message.
                    ctx.fireLeafMessage(p,
                        "remember: you can select a tower and choose its target...",
                        9)
                end
            end
        end
        print("[Map3BirdBoss] started — bird HP " .. BIRD_MAX_HP
            .. ", swoops every " .. SWOOP_INTERVAL_SEC .. "s")
    end

    stopBirdBoss = function(bossKilled)
        State.active = false
        if State.flightConn then State.flightConn:Disconnect(); State.flightConn = nil end
        releasePlayer(false)
        -- Pop any held dive lock so the wave-system count doesn't drift
        -- if the bird died/aborted mid-dive (releasePlayer handles the
        -- separate carry/grab lock). Release closures are idempotent.
        if State.diveSpeedRelease then
            State.diveSpeedRelease()
            State.diveSpeedRelease = nil
        end
        -- Tear down the per-run Maid: spawned task threads (egg loop, swoop
        -- loop, patrol loop, status loop), one-shot connections (e.g.
        -- Health attribute listener), the bird Model itself. One call
        -- replaces the ad-hoc cleanup that used to leak threads on abort.
        if State.maid then
            State.maid:destroy()
            State.maid = nil
        end
        clearStunStars()
        if State.bird and State.bird.model and State.bird.model.Parent then
            State.bird.model:Destroy()
        end
        State.bird = nil
        State.targetPlayer = nil
        -- Wipe every in-flight egg. Eggs are spawned via makePart (not
        -- through ctx.makeMob), so ctx.clearAllMobs doesn't see them
        -- and clearAllManualTargetIndicators won't catch their tap
        -- highlights either. They walk via per-egg task.spawn loops
        -- that gate on `egg.Parent` — destroying the part exits the
        -- loop on the next Heartbeat:Wait. Per Matthew (2026-04-25):
        -- "eggs don't clear after bird dies" — the bird falls, the
        -- temp picker shows, but path mobs from the encounter keep
        -- walking and chip the heart from behind the picker.
        for _, egg in ipairs(CollectionService:GetTagged(Tags.Mob)) do
            if egg:IsA("BasePart") and egg.Name == "BirdBossEgg" then
                egg:Destroy()
            end
        end
        broadcastBossStatus()  -- final tick: active=false hides the bar
        print("[Map3BirdBoss] stopped (eggs cleared)")
        -- Map-3 reward: only when the bird ACTUALLY died (not on dev abort
        -- or 5-min hard cap). Fires BossDefeated mapId=3 → TempTowerRewards
        -- shows the map-3 aux-tower picker. The Pickle Lord run-boss
        -- encounter is planned to follow this beat (platform smash + dark
        -- fog cinematic) and then drop the permanent tower; not yet built,
        -- so the chain stops at the map-3 aux pick for now.
        if bossKilled then
            local bossDefeated = ReplicatedStorage:FindFirstChild(
                Remotes.Names.BossDefeated)
            if bossDefeated then
                bossDefeated:Fire({ mapId = 3 })
            end
        end
    end

    -- Auto-stop after the hard cap.
    task.spawn(function()
        while true do
            task.wait(1)
            if State.active and os.clock() - State.startedAt >= PHASE_HARD_CAP_SEC then
                stopBirdBoss()
                break
            end
        end
    end)

    ctx.startBirdBoss = startBirdBoss
    ctx.stopBirdBoss  = stopBirdBoss

    -- Dev trigger remote — lets the dev panel kick off the phase for testing
    -- before the wave system wires it to the real final-boss flow.
    local devStartRemote = ReplicatedStorage:WaitForChild(Remotes.Names.DevStartBirdBoss)
    devStartRemote.OnServerEvent:Connect(function(_player)
        if State.active then
            stopBirdBoss()
        else
            startBirdBoss()
        end
    end)
end

return Map3BirdBoss
