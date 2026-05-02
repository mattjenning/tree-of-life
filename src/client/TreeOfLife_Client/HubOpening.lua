--[[
    HubOpening.lua — first-spawn camera intro for the hub.

    Plays alongside Splash.lua (the gradient title card) by listening
    to the SAME ShowSplash remote (server fires it 0.5s after every
    CharacterAdded). Adds:
      • Black letterbox bars (top + bottom) that frame the title
      • Camera intro: high vantage above player → ease down to behind
      • Click / tap / spacebar to skip: jump to behind-player + roll
        bars back, fast-fade the splash title via Splash.cancel()
      • On natural end OR skip: fire a LOCAL leaf note "Zombies are
        attacking the Golden Pickle. Save it to save the world!"

    Why this lives here (and not in Splash.lua): Splash.lua is the
    title gradient — pure 2D fade-in/hold/fade-out. HubOpening adds
    the 3D camera + bar layer + skip + leaf-note hookup. Splitting
    them keeps each module focused; HubOpening owns the cinematic
    framing, Splash owns the title text.

    Camera math is RELATIVE to the player's HumanoidRootPart so the
    cinematic works regardless of spawn point. Player movement is
    locked (WalkSpeed/JumpPower → 0) for the duration of the
    cinematic and restored on end.

    setup(deps) captures:
      deps.player, deps.playerGui
      deps.workspace, deps.ReplicatedStorage
      deps.UserInputService, deps.RunService, deps.TweenService
      deps.Remotes
      deps.LeafMessage           -- has .queue(payload) public fn
      deps.Splash                -- has .cancel() public fn
      deps.IS_MOBILE
]]

local HubOpening = {}

-- Tween + visual constants. Picked to overlap cleanly with
-- Splash.lua's 0.9s fade-in + 2.1s hold + 1.1s fade-out (4.1s
-- total). Cinematic ends ~5s in so the bars retract just as the
-- splash finishes its natural fade-out.
local CINEMATIC_SEC = 5.0
local BAR_IN_SEC    = 0.4
local BAR_OUT_SEC   = 1.5
local BAR_HEIGHT    = 0.13         -- 13% screen each (matches PickleLordEntrance)
local CINEMATIC_FOV = 50           -- subtle FOV pull-in vs default 70

local LEAF_TEXT     = "Zombies are attacking the Golden Pickle. Save it to save the world!"
local LEAF_DURATION = 8

function HubOpening.setup(deps)
    local player            = deps.player
    local playerGui         = deps.playerGui
    local workspace_        = deps.workspace
    local ReplicatedStorage = deps.ReplicatedStorage
    local UserInputService  = deps.UserInputService
    local RunService        = deps.RunService
    local TweenService      = deps.TweenService
    local Remotes           = deps.Remotes
    local LeafMessage       = deps.LeafMessage
    local Splash            = deps.Splash

    -- Single-fire guard within a session. ShowSplash fires on every
    -- CharacterAdded (every respawn), but the OPENING cinematic is
    -- a once-per-session beat — re-running it on every respawn would
    -- be infuriating. The flag resets implicitly when the LocalScript
    -- reloads (next session).
    local hasPlayed = false

    local function play()
        if hasPlayed then return end
        hasPlayed = true

        -- Wait for character + root part. Server fires ShowSplash 0.5s
        -- after CharacterAdded so this should already exist, but defend.
        local char = player.Character or player.CharacterAdded:Wait()
        local root = char:FindFirstChild("HumanoidRootPart")
                  or char:WaitForChild("HumanoidRootPart", 3)
        if not root then return end
        local hum = char:FindFirstChildOfClass("Humanoid")

        local cam = workspace_.CurrentCamera
        if not cam then return end

        ----------------------------------------------------------------
        -- BARS — two black Frames anchored top + bottom, tween in/out.
        -- DisplayOrder 700 so they render OVER the splash title (which
        -- sits at 100), letterboxing the gradient inside the cinematic
        -- frame.
        ----------------------------------------------------------------
        local barGui = Instance.new("ScreenGui")
        barGui.Name = "ToL_HubOpeningBars"
        barGui.IgnoreGuiInset = true
        barGui.ResetOnSpawn = false
        barGui.DisplayOrder = 700
        barGui.Parent = playerGui
        local function makeBar(anchorY, posY)
            local bar = Instance.new("Frame")
            bar.AnchorPoint = Vector2.new(0.5, anchorY)
            bar.Position = UDim2.fromScale(0.5, posY)
            bar.Size = UDim2.fromScale(1, 0)  -- starts collapsed
            bar.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
            bar.BorderSizePixel = 0
            bar.Active = false                  -- don't intercept skip clicks
            bar.Parent = barGui
            return bar
        end
        local topBar = makeBar(0, 0)
        local botBar = makeBar(1, 1)
        local barInInfo = TweenInfo.new(BAR_IN_SEC, Enum.EasingStyle.Quad,
                                        Enum.EasingDirection.Out)
        TweenService:Create(topBar, barInInfo, { Size = UDim2.fromScale(1, BAR_HEIGHT) }):Play()
        TweenService:Create(botBar, barInInfo, { Size = UDim2.fromScale(1, BAR_HEIGHT) }):Play()

        ----------------------------------------------------------------
        -- CAMERA — Scriptable takeover. Save prior state for restore.
        ----------------------------------------------------------------
        local prevCameraType = cam.CameraType
        local prevFOV        = cam.FieldOfView
        cam.CameraType = Enum.CameraType.Scriptable
        cam.FieldOfView = CINEMATIC_FOV

        -- Lock player movement; restore on end. Defensive: hum may be
        -- nil if the character is mid-load.
        local prevWalkSpeed = hum and hum.WalkSpeed
        local prevJumpPower = hum and hum.JumpPower
        if hum then
            hum.WalkSpeed = 0
            hum.JumpPower = 0
        end

        ----------------------------------------------------------------
        -- CFRAMES — start (high on tree) → end (behind player).
        -- Relative to root so this works on any spawn point. Start is
        -- 80 studs up + 8 forward looking down at the player; end is
        -- 12 behind + 3 above looking forward (matches the default
        -- Roblox 3rd-person follow camera so the handoff is seamless).
        ----------------------------------------------------------------
        local rootPos = root.Position
        local startPos = rootPos + Vector3.new(0, 80, -8)
        local startCF  = CFrame.lookAt(startPos, rootPos + Vector3.new(0, 2, 0))

        local function computeEndCF()
            local r = player.Character
                  and player.Character:FindFirstChild("HumanoidRootPart")
            if not r then return startCF end
            local cf = r.CFrame
            local lookFrom = cf * CFrame.new(0, 3, 12)
            local lookAt   = cf.Position + Vector3.new(0, 1.5, 0)
            return CFrame.lookAt(lookFrom.Position, lookAt)
        end

        cam.CFrame = startCF

        ----------------------------------------------------------------
        -- TWEEN LOOP — RenderStepped, smoothstep eased lerp from
        -- startCF → computeEndCF(). End triggers either by elapsed
        -- exceeding CINEMATIC_SEC or by user click/tap/space.
        ----------------------------------------------------------------
        local startedAt = os.clock()
        local ended = false
        local renderConn, clickConn

        local function endCinematic()
            if ended then return end
            ended = true

            -- Fast-fade the title gradient so it doesn't outlast the
            -- bars during a click-skip. Splash.cancel is a no-op if
            -- the title already finished its natural lifecycle.
            if Splash and Splash.cancel then Splash.cancel() end

            -- Snap camera to end pose so the bar retraction reads as
            -- "we're behind you now — here's the world." Then release
            -- back to Custom; Roblox's default follow takes over from
            -- approximately the same offset.
            cam.CFrame = computeEndCF()
            cam.CameraType = prevCameraType
            cam.FieldOfView = prevFOV

            -- Roll bars out slowly. They live until the tween finishes
            -- (cleanup in the task.delay below) so the retraction is
            -- visible to completion.
            local barOutInfo = TweenInfo.new(BAR_OUT_SEC, Enum.EasingStyle.Quad,
                                             Enum.EasingDirection.Out)
            TweenService:Create(topBar, barOutInfo, { Size = UDim2.fromScale(1, 0) }):Play()
            TweenService:Create(botBar, barOutInfo, { Size = UDim2.fromScale(1, 0) }):Play()

            -- Restore movement. Guard against character despawn.
            if hum and hum.Parent then
                hum.WalkSpeed = prevWalkSpeed or 16
                hum.JumpPower = prevJumpPower or 50
            end

            if renderConn then renderConn:Disconnect() end
            if clickConn then clickConn:Disconnect() end

            task.delay(BAR_OUT_SEC + 0.15, function()
                if barGui.Parent then barGui:Destroy() end
            end)

            -- LEAF NOTE — fired locally via LeafMessage.queue so we
            -- don't pay the round-trip cost. Priority = true so any
            -- still-on-screen earlier leaf gets fast-forwarded (rare
            -- on first spawn, but defensive against rapid respawn).
            if LeafMessage and LeafMessage.queue then
                LeafMessage.queue({
                    text = LEAF_TEXT,
                    duration = LEAF_DURATION,
                    priority = true,
                })
            end
        end

        renderConn = RunService.RenderStepped:Connect(function()
            if ended then return end
            local elapsed = os.clock() - startedAt
            local t = math.clamp(elapsed / CINEMATIC_SEC, 0, 1)
            local eased = t * t * (3 - 2 * t)        -- smoothstep
            cam.CFrame = startCF:Lerp(computeEndCF(), eased)
            if elapsed >= CINEMATIC_SEC then
                endCinematic()
            end
        end)

        clickConn = UserInputService.InputBegan:Connect(function(input, gpe)
            if ended then return end
            if gpe then return end
            local t = input.UserInputType
            if t == Enum.UserInputType.MouseButton1
               or t == Enum.UserInputType.Touch
               or (t == Enum.UserInputType.Keyboard
                   and input.KeyCode == Enum.KeyCode.Space) then
                endCinematic()
            end
        end)
    end

    ReplicatedStorage:WaitForChild(Remotes.Names.ShowSplash).OnClientEvent:Connect(play)
end

return HubOpening
