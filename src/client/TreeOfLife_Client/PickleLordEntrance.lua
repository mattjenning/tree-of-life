--[[
    PickleLordEntrance.lua — client-side handlers for everything
    around the Pickle Lord boss reveal:
        • PlayPickleLordEntrance cinematic (24.5s scripted camera with
          black bars + skip hint + boss face tracking)
        • PlayPickleLordSmash camera-shake telegraph
        • The dedicated bottom-center boss health bar that replaces
          the top-HUD mini bar for this fight specifically

    EXTRACTED FROM init.client.lua (per CLAUDE.md note on the Luau
    200-register ceiling). The flag + bar table + fade fn used to
    live at top-level there; moving them here freed register slots
    so the rest of init.client.lua can keep growing without crashing
    on `Out of local registers`. Mirrors the LeafMessage.lua pattern
    next door — single setup(deps) entry point, deps captured as
    locals at setup time.

    Public API (after setup):
        PickleLordEntrance.isActive()             -> bool
        PickleLordEntrance.applyHpUpdate(state)   -- fill + pct from WaveState
        PickleLordEntrance.handleBossCleared()    -> bool
            -- returns true if Pickle Lord WAS active (and handled the
            -- clear via fade-out). Caller should suppress its own
            -- top-HUD CLEARED latch when this returns true.

    setup(deps) reads:
        deps.player, deps.playerGui
        deps.workspace, deps.ReplicatedStorage
        deps.UserInputService, deps.RunService
        deps.Remotes
        deps.IS_MOBILE
]]

local PickleLordEntrance = {}

-- Module-private state. Were top-level locals in init.client.lua;
-- moving them here is the whole point of the extraction.
local pickleLordActive = false
-- Distinct from pickleLordActive: TRUE only while the entrance
-- cinematic is still playing (set when PlayPickleLordEntrance fires,
-- cleared in endCinematic). pickleLordActive stays true the whole
-- boss fight; this flag is the narrow window during which placement
-- + grid + ghost should be suppressed.
local cinematicPlaying = false
-- Embedded HP row references — populated from setup deps. The
-- actual UI lives in init.client.lua's wave-HUD frame; this module
-- just toggles visibility + writes fill width / numeric text on
-- each HP broadcast.
local hpRowRefs = nil   -- { frame, fill, text }
local waveFrameRef = nil

local WAVE_FRAME_BASE_HEIGHT = 30
local WAVE_FRAME_BOSS_HEIGHT = 76    -- 30 (mapLabel) + 6 gap + 40 hp row

local function setBarVisible(visible)
    if hpRowRefs and hpRowRefs.frame then
        hpRowRefs.frame.Visible = visible
    end
    -- Grow / shrink waveFrame so the embedded row has room and
    -- the panel collapses back to its default height when the
    -- boss isn't active.
    if waveFrameRef then
        local h = visible and WAVE_FRAME_BOSS_HEIGHT or WAVE_FRAME_BASE_HEIGHT
        waveFrameRef.Size = UDim2.fromOffset(360, h)
    end
end

function PickleLordEntrance.isActive()
    return pickleLordActive
end

function PickleLordEntrance.isCinematicPlaying()
    return cinematicPlaying
end

-- Caller (updateBossBar in init.client.lua) provides WaveState; we
-- pull bossHealth/bossMaxHealth and write to fill + pct directly.
-- Returns nothing — the module owns the bar's visual state.
function PickleLordEntrance.applyHpUpdate(state)
    if not hpRowRefs then return end
    local hp    = state.bossHealth or 0
    local maxHp = state.bossMaxHealth or 0
    local frac  = (maxHp and maxHp > 0)
                  and math.max(0, math.min(hp / maxHp, 1))
                  or 1
    if hpRowRefs.fill then
        hpRowRefs.fill.Size = UDim2.new(frac, -4, 1, -4)
    end
    if hpRowRefs.text then
        if maxHp and maxHp > 0 then
            -- "X / MAX" — absolute HP only. Bar fill conveys the
            -- percent visually; absolute numbers help the player
            -- gauge per-shot impact against the 1M-HP run boss.
            hpRowRefs.text.Text = string.format("%d / %d",
                math.max(0, math.floor(hp)),
                math.floor(maxHp))
        else
            hpRowRefs.text.Text = "—"
        end
    end
end

function PickleLordEntrance.handleBossCleared()
    if pickleLordActive then
        pickleLordActive = false
        setBarVisible(false)
        return true
    end
    return false
end

function PickleLordEntrance.setup(deps)
    local player            = deps.player
    local playerGui         = deps.playerGui
    local workspace_        = deps.workspace
    local ReplicatedStorage = deps.ReplicatedStorage
    local UserInputService  = deps.UserInputService
    local RunService        = deps.RunService
    local Remotes           = deps.Remotes
    local IS_MOBILE         = deps.IS_MOBILE
    local Lighting          = game:GetService("Lighting")
    local TweenService      = game:GetService("TweenService")
    -- Embedded HP row inside the wave HUD frame. Built HERE
    -- (instead of in init.client.lua) so the parent file doesn't
    -- have to spend a top-level register on the reference table —
    -- it was hitting the Luau 200-register ceiling. Module owns
    -- the row build + visibility toggle.
    waveFrameRef = deps.waveFrame
    local forceExitPlacement = deps.forceExitPlacement
    if waveFrameRef then
        local row = Instance.new("Frame")
        row.AnchorPoint = Vector2.new(0.5, 0)
        row.Position = UDim2.new(0.5, 0, 0, 32)  -- below mapLabel
        row.Size = UDim2.new(1, -8, 0, 40)        -- 40 stud tall
        row.BackgroundColor3 = Color3.fromRGB(30, 12, 14)
        row.BorderSizePixel = 0
        row.Visible = false
        row.Parent = waveFrameRef
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0.25, 0)
            c.Parent = row
            local stroke = Instance.new("UIStroke")
            stroke.Thickness = 1
            stroke.Color = Color3.fromRGB(80, 30, 35)
            stroke.Parent = row
        end
        local fill = Instance.new("Frame")
        fill.Size = UDim2.new(1, -4, 1, -4)
        fill.Position = UDim2.fromOffset(2, 2)
        fill.BackgroundColor3 = Color3.fromRGB(220, 50, 70)
        fill.BorderSizePixel = 0
        fill.Parent = row
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0.25, 0)
            c.Parent = fill
        end
        -- "X / MAX" centered text, dedicated line.
        local hpText = Instance.new("TextLabel")
        hpText.Size = UDim2.fromScale(1, 1)
        hpText.BackgroundTransparency = 1
        hpText.Text = "—"
        hpText.TextColor3 = Color3.fromRGB(255, 255, 255)
        hpText.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        hpText.TextStrokeTransparency = 0.2
        hpText.Font = Enum.Font.FredokaOne
        hpText.TextSize = 22
        hpText.ZIndex = 4
        hpText.Parent = row
        hpRowRefs = { frame = row, fill = fill, text = hpText }
    end

    --------------------------------------------------------------
    -- PLAY PICKLE LORD ENTRANCE — main cinematic.
    --
    -- 24.5s 8-phase scripted camera:
    --   0-9    sweeping zoom-in into Dutch toward boss; shake
    --   9-12   1st player closeup, face centered
    --   12-16  STRAIGHT-ON close on pickle face
    --   16-17.5  2nd player closeup
    --   17.5-20  closer pickle face (eye-level lookAt)
    --   20-22.5  3rd player closeup
    --   22.5-24.5 zoom back out behind player toward pickle
    --
    -- Hides ALL existing PlayerGui ScreenGuis except cinematic
    -- bars + leaf-msg gui. Restores them on end. Locks player
    -- movement (WalkSpeed/JumpPower → 0; restored on end). Click
    -- anywhere skips. Lighting tweens to moonlit + foggy
    -- atmosphere. The dedicated boss bar fades in as the cinematic
    -- bars retract.
    --------------------------------------------------------------
    ReplicatedStorage:WaitForChild(Remotes.Names.PlayPickleLordEntrance).OnClientEvent:Connect(function(payload)
        local duration = (payload and payload.duration) or 5
        local ambient  = (payload and payload.ambient)
                       or Color3.fromRGB(70, 90, 130)
        local fogEnd   = (payload and payload.fogEnd) or 200
        -- Three properties tween in lockstep over the entrance window.
        local info = TweenInfo.new(duration, Enum.EasingStyle.Sine,
                                   Enum.EasingDirection.Out)
        TweenService:Create(Lighting, info, {
            Ambient        = ambient,
            OutdoorAmbient = ambient,
            FogEnd         = fogEnd,
            FogColor       = Color3.fromRGB(60, 70, 95),
        }):Play()

        local bossPos       = payload and payload.bossPos
        local cinematicSec  = (payload and payload.cinematicSec) or 22
        local phase1Start   = payload and payload.phase1Start
        local phase1End     = payload and payload.phase1End
        local faceOffsetY   = (payload and payload.faceOffsetY) or 191.5
        local arenaCenter   = payload and payload.arenaCenter
        local seenSkipHint  = payload and payload.seenSkipHint == true
        if not bossPos then return end

        -- Mark Pickle Lord as the active boss right now. The
        -- top-HUD bar suppression in init.client.lua reads this
        -- flag via PickleLordEntrance.isActive(); the bottom bar's
        -- visibility is gated separately on cinematic end below.
        pickleLordActive = true
        -- cinematicPlaying is the narrower flag — gates tower
        -- placement + grid + ghost. Cleared in endCinematic below.
        cinematicPlaying = true
        -- Defensive: if the player was MID-PLACEMENT when the
        -- entrance fired (e.g. somehow held over from before the
        -- aux-tower picker), bail them out so the grid + ghost
        -- 3D parts aren't sitting under the cinematic camera.
        -- enterPlacementMode is also gated on the cinematic gui
        -- existing, so re-entry during the rise is blocked.
        if forceExitPlacement then forceExitPlacement() end
        local cam = workspace_.CurrentCamera
        if not cam then return end

        -- Black-bar GUI: two Frames anchored top + bottom. Each
        -- starts 0-height and tweens to 13% screen height.
        local barGui = Instance.new("ScreenGui")
        barGui.Name = "ToL_PickleLordCinematic"
        barGui.IgnoreGuiInset = true
        barGui.ResetOnSpawn = false
        barGui.DisplayOrder = 700
        barGui.Parent = playerGui
        local function makeBar(anchorY, posY)
            local bar = Instance.new("Frame")
            bar.AnchorPoint = Vector2.new(0.5, anchorY)
            bar.Position = UDim2.fromScale(0.5, posY)
            bar.Size = UDim2.fromScale(1, 0)
            bar.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
            bar.BorderSizePixel = 0
            bar.Parent = barGui
            return bar
        end
        local topBar = makeBar(0, 0)
        local botBar = makeBar(1, 1)
        local barIn  = TweenInfo.new(0.6, Enum.EasingStyle.Quad,
                                     Enum.EasingDirection.Out)
        TweenService:Create(topBar, barIn, { Size = UDim2.fromScale(1, 0.13) }):Play()
        TweenService:Create(botBar, barIn, { Size = UDim2.fromScale(1, 0.13) }):Play()

        -- Skip hint: bottom-left "tap/click to skip" label, fades
        -- in at 3s. Skipped entirely for returning players.
        local skipLabel = nil
        if not seenSkipHint then
            skipLabel = Instance.new("TextLabel")
            skipLabel.Name = "SkipHint"
            skipLabel.AnchorPoint = Vector2.new(0, 1)
            skipLabel.Position = UDim2.new(0, 16, 1, -10)
            skipLabel.Size = UDim2.fromOffset(160, 24)
            skipLabel.BackgroundTransparency = 1
            skipLabel.Font = Enum.Font.FredokaOne
            skipLabel.TextSize = 16
            skipLabel.TextColor3 = Color3.fromRGB(220, 220, 200)
            skipLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
            skipLabel.TextStrokeTransparency = 0.3
            skipLabel.TextXAlignment = Enum.TextXAlignment.Left
            skipLabel.TextTransparency = 1
            skipLabel.Text = IS_MOBILE and "tap to skip" or "click to skip"
            skipLabel.Parent = barGui
        end

        -- Camera takeover.
        local prevCameraType = cam.CameraType
        local prevFOV        = cam.FieldOfView
        cam.CameraType = Enum.CameraType.Scriptable
        cam.FieldOfView = 38

        -- Lock player movement during cinematic.
        local hum = player.Character
                and player.Character:FindFirstChildOfClass("Humanoid")
        local prevWalkSpeed = hum and hum.WalkSpeed
        local prevJumpPower = hum and hum.JumpPower
        if hum then
            hum.WalkSpeed = 0
            hum.JumpPower = 0
        end

        -- Hide every existing PlayerGui ScreenGui for the duration.
        -- Skip our own bars + any leaf-msg gui (priority leaves
        -- still need to render during cinematic).
        local hiddenGuis = {}
        for _, g in ipairs(playerGui:GetChildren()) do
            if g:IsA("ScreenGui")
               and g ~= barGui
               and g.Name ~= "ToL_LeafMsg"
               and g.Enabled then
                hiddenGuis[g] = true
                g.Enabled = false
            end
        end

        local startedAt = os.clock()
        local ended    = false
        local renderConn, clickConn

        local function endCinematic()
            if ended then return end
            ended = true
            -- Drop the placement-suppression flag the instant the
            -- cinematic teardown begins so player input flows
            -- normally on the very next frame.
            cinematicPlaying = false
            if renderConn then renderConn:Disconnect(); renderConn = nil end
            if clickConn  then clickConn:Disconnect();  clickConn  = nil end
            cam.CameraType = prevCameraType
            cam.FieldOfView = prevFOV
            -- Restore movement (re-fetch humanoid in case respawn).
            local liveHum = player.Character
                and player.Character:FindFirstChildOfClass("Humanoid")
            if liveHum then
                liveHum.WalkSpeed = prevWalkSpeed or 16
                liveHum.JumpPower = prevJumpPower or 50
            end
            -- Restore every gui we hid at start.
            for g, _ in pairs(hiddenGuis) do
                if g.Parent then
                    g.Enabled = true
                end
            end
            local barOut = TweenInfo.new(0.4, Enum.EasingStyle.Quad,
                                         Enum.EasingDirection.In)
            TweenService:Create(topBar, barOut, { Size = UDim2.fromScale(1, 0) }):Play()
            TweenService:Create(botBar, barOut, { Size = UDim2.fromScale(1, 0) }):Play()
            task.delay(0.5, function()
                if barGui.Parent then barGui:Destroy() end
            end)
            -- Reveal the embedded HP row in the wave HUD as the
            -- cinematic bars retract. Updated each frame thereafter
            -- via applyHpUpdate (driven by WaveState in
            -- init.client.lua). Also resizes waveFrame to fit.
            setBarVisible(true)
            -- Tell the server the cinematic is over (skip OR natural).
            -- Server fast-forwards the entrance rise so the smash
            -- loop + tower targetability flip on immediately. If
            -- the rise has already finished naturally, this is a
            -- noop server-side.
            local endedRemote = ReplicatedStorage:FindFirstChild(
                Remotes.Names.PickleLordCinematicEnded)
            if endedRemote then
                endedRemote:FireServer()
            end
        end

        clickConn = UserInputService.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
               or input.UserInputType == Enum.UserInputType.Touch then
                endCinematic()
            end
        end)

        local function applyShake(pos, amplitude)
            return pos + Vector3.new(
                (math.random() - 0.5) * 2 * amplitude,
                (math.random() - 0.5) * 2 * amplitude,
                (math.random() - 0.5) * 2 * amplitude)
        end

        -- Phase scheduler. See line-by-line comments in the prior
        -- iteration of this code (init.client.lua before the
        -- extraction). Each branch returns (cameraPos, lookAt,
        -- rollDeg, fov) for the current elapsed time.
        local function computeShot(elapsed, playerPos, playerLookVec, headPos, liveFacePos)
            if elapsed < 9 then
                -- 0-9: sweeping zoom-in into Dutch.
                local t = elapsed / 9
                local pos
                if phase1Start and phase1End then
                    pos = phase1Start:Lerp(phase1End, t)
                else
                    local sb = -playerLookVec * 14 + Vector3.new(0, 7, 0)
                    local eb = -playerLookVec * 6 + Vector3.new(0, 4, 0)
                    pos = playerPos + sb:Lerp(eb, t)
                end
                local shakeAmp = 0.55 * (1 - t * 0.4)
                pos = applyShake(pos, shakeAmp)
                local dutchT = math.min(elapsed / 3, 1)
                return pos, liveFacePos, 12 * dutchT, 50
            elseif elapsed < 12 then
                -- 9-12: 1st player closeup (3s).
                local pos = headPos + playerLookVec * 8.5
                return pos, headPos, 0, 32
            elseif elapsed < 16 then
                -- 12-16: 1st straight-on pickle CU (4s).
                local pos = liveFacePos + Vector3.new(0, -8, 55)
                pos = applyShake(pos, 0.35)
                return pos, liveFacePos, 0, 36
            elseif elapsed < 17.5 then
                -- 16-17.5: 2nd player closeup (1.5s).
                local pos = headPos + playerLookVec * 8.5
                return pos, headPos, 0, 32
            elseif elapsed < 20 then
                -- 17.5-20: closer pickle CU on EYES (2.5s).
                local pos = liveFacePos + Vector3.new(0, 2, 45)
                pos = applyShake(pos, 0.45)
                return pos, liveFacePos + Vector3.new(0, 7.5, 0), 0, 28
            elseif elapsed < 22.5 then
                -- 20-22.5: 3rd player closeup (2.5s).
                local pos = headPos + playerLookVec * 8.5
                return pos, headPos, 0, 28
            else
                -- 22.5-24.5: pull back behind player (2s).
                local t = math.clamp((elapsed - 22.5) / 2, 0, 1)
                local startBack = -playerLookVec * 9 + Vector3.new(0, 4, 0)
                local endBack   = -playerLookVec * 26 + Vector3.new(0, 11, 0)
                local pos = playerPos + startBack:Lerp(endBack, t)
                local fov = 28 + (70 - 28) * t
                return pos, liveFacePos, 0, fov
            end
        end

        local teleportedToCenter = false
        local skipHintShown = false
        renderConn = RunService.RenderStepped:Connect(function()
            local elapsed = os.clock() - startedAt
            if elapsed >= cinematicSec then
                endCinematic()
                return
            end

            -- Skip hint fade-in at 3s.
            if skipLabel and (not skipHintShown) and elapsed >= 3 then
                skipHintShown = true
                local fadeIn = TweenInfo.new(0.4, Enum.EasingStyle.Quad,
                                             Enum.EasingDirection.Out)
                TweenService:Create(skipLabel, fadeIn, {
                    TextTransparency = 0.05,
                    TextStrokeTransparency = 0.3,
                }):Play()
            end

            local char = player.Character
            local hrp  = char and char:FindFirstChild("HumanoidRootPart")
            local head = char and char:FindFirstChild("Head")
            local playerPos = hrp and hrp.Position or bossPos
            local playerLookVec = hrp and hrp.CFrame.LookVector or Vector3.new(0, 0, -1)
            local headPos = head and head.Position
                            or (playerPos + Vector3.new(0, 2, 0))

            -- Live boss face tracking.
            local pickleModel = workspace_:FindFirstChild("PickleLord")
            local pickleBody  = pickleModel
                and pickleModel:FindFirstChild("PickleLordBody")
            local liveFacePos
            if pickleBody then
                liveFacePos = pickleBody.CFrame
                    :PointToWorldSpace(Vector3.new(0, faceOffsetY, 0))
            else
                liveFacePos = bossPos
            end

            -- Mid-cinematic teleport at 17.5s.
            if (not teleportedToCenter)
               and elapsed >= 17.5 and arenaCenter and hrp then
                hrp.CFrame = CFrame.new(
                    arenaCenter.X,
                    arenaCenter.Y + 4,
                    arenaCenter.Z)
                teleportedToCenter = true
            end

            local cameraPos, lookAt, rollDeg, fov =
                computeShot(elapsed, playerPos, playerLookVec, headPos, liveFacePos)
            cam.CFrame = CFrame.lookAt(cameraPos, lookAt)
                * CFrame.Angles(0, 0, math.rad(rollDeg))
            cam.FieldOfView = fov
        end)
    end)

    --------------------------------------------------------------
    -- PLAY PICKLE LORD SMASH — camera shake telegraph.
    -- Per-RenderStepped local-space CFrame offset on the camera.
    -- Magnitude ramps UP toward the resolve moment so the warning
    -- escalates, then sharp falloff in the last 0.2s as the hit
    -- lands. No CameraType change so this composes with whatever
    -- the bird-grab / boss-defeat camera was doing.
    --------------------------------------------------------------
    ReplicatedStorage:WaitForChild(Remotes.Names.PlayPickleLordSmash).OnClientEvent:Connect(function(payload)
        local duration = (payload and payload.totalSec) or 3
        local startedAt = os.clock()
        local conn
        conn = RunService.RenderStepped:Connect(function()
            local elapsed = os.clock() - startedAt
            if elapsed >= duration then
                if conn then conn:Disconnect() end
                return
            end
            local cam = workspace_.CurrentCamera
            if not cam then return end
            local t = elapsed / duration
            local mag = (t < 0.85) and (0.15 + 0.5 * t)
                                    or (0.65 * (1 - (t - 0.85) / 0.15))
            local dx = (math.random() - 0.5) * 2 * mag
            local dy = (math.random() - 0.5) * 2 * mag
            cam.CFrame = cam.CFrame * CFrame.new(dx, dy, 0)
        end)
    end)
end

return PickleLordEntrance
