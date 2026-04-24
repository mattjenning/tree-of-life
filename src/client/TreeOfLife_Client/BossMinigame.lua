--[[
    BossMinigame.lua — Final-boss tap-the-targets minigame UI.

    The fight has three HP-gated phases (75% / 50% / 25%). Each phase the
    server fires:
      - BossWindup  : show a windup countdown bar
      - BossPhase   : spawn N tappable target reticles at random screen
                      positions; player taps each to fire BossTargetTap
                      (server grants a 5-second damage bonus on success)
      - BossPhaseMiss : missed at least one target → server applies
                        a temporary penalty
      - BossWeb     : Web Weaver overlay during their final-boss phase

    All four handlers + the shared bossTargetGui / bossCountdownGui /
    bossGlowGui state live together in this module.

    setup(deps) captures:
      deps.playerGui
      deps.ReplicatedStorage
      deps.Remotes
      deps.Rarity
      deps.TweenService
      deps.waveFrame    — the wave HUD strip (hidden during phase, restored
                          after) so the targets don't sit under it.
]]

local BossMinigame = {}

function BossMinigame.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local Rarity            = deps.Rarity
    local TweenService      = deps.TweenService
    local waveFrame         = deps.waveFrame

local bossTargetGui = nil
local bossCountdownGui = nil
local bossGlowGui = nil

local function clearBossTargets()
    if bossTargetGui then bossTargetGui:Destroy(); bossTargetGui = nil end
    if bossCountdownGui then bossCountdownGui:Destroy(); bossCountdownGui = nil end
    -- Restore wave HUD visibility
    if waveFrame then waveFrame.Visible = true end
end

local function showBossSuccessGlow(duration, bonusPct)
    bonusPct = bonusPct or 0
    if bossGlowGui then bossGlowGui:Destroy() end
    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_BossGlow"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 235
    gui.Parent = playerGui
    bossGlowGui = gui

    -- Red vignette: 4 sides feathered toward center
    local vignette = Instance.new("ImageLabel")
    vignette.Size = UDim2.fromScale(1, 1)
    vignette.BackgroundTransparency = 1
    vignette.Image = "rbxassetid://6011489167"  -- common radial gradient asset; falls back to colored bg
    vignette.ImageColor3 = Color3.fromRGB(255, 30, 30)
    vignette.ImageTransparency = 0.3
    vignette.ScaleType = Enum.ScaleType.Stretch
    vignette.Parent = gui

    -- Backup colored border in case the asset fails to load
    local border = Instance.new("Frame")
    border.Size = UDim2.fromScale(1, 1)
    border.BackgroundTransparency = 1
    border.BorderSizePixel = 0
    border.Parent = gui
    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 18
    stroke.Color = Color3.fromRGB(255, 40, 40)
    stroke.Transparency = 0.2
    stroke.Parent = border

    -- "BONUS DAMAGE! / 100% + X%" two-line banner with RichText so the
    -- speed-bonus half can be tinted distinctly from the base 100%.
    -- Faster clears → brighter / greener bonus color, making the
    -- payoff read visually as well as numerically.
    local bonusColor
    if bonusPct >= 75 then
        bonusColor = Color3.fromRGB(120, 255, 140)   -- bright green for near-instant
    elseif bonusPct >= 40 then
        bonusColor = Color3.fromRGB(160, 255, 255)   -- cyan for mid-speed
    elseif bonusPct >= 10 then
        bonusColor = Color3.fromRGB(255, 255, 160)   -- pale yellow for slow-ish
    else
        bonusColor = Color3.fromRGB(200, 200, 200)   -- muted for "just in time"
    end
    local bonusHex = string.format("#%02x%02x%02x",
        math.floor(bonusColor.R * 255 + 0.5),
        math.floor(bonusColor.G * 255 + 0.5),
        math.floor(bonusColor.B * 255 + 0.5))

    local banner = Instance.new("TextLabel")
    banner.Size = UDim2.new(1, 0, 0, 110)
    banner.Position = UDim2.new(0, 0, 0.14, 0)
    banner.BackgroundTransparency = 1
    banner.RichText = true
    banner.Text = string.format(
        "BONUS DAMAGE!\n<font size='38'>100%% <font color='%s'>+ %d%%</font></font>",
        bonusHex, bonusPct)
    banner.TextColor3 = Color3.fromRGB(255, 220, 100)
    banner.TextStrokeColor3 = Color3.fromRGB(80, 0, 0)
    banner.TextStrokeTransparency = 0.2
    banner.Font = Enum.Font.FredokaOne
    banner.TextSize = 42
    banner.TextYAlignment = Enum.TextYAlignment.Top
    banner.Parent = gui

    -- Fade out at end
    local TweenService = game:GetService("TweenService")
    task.delay(duration - 0.4, function()
        if not gui.Parent then return end
        local info = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        TweenService:Create(vignette, info, {ImageTransparency = 1}):Play()
        TweenService:Create(stroke, info, {Transparency = 1}):Play()
        TweenService:Create(banner, info, {TextTransparency = 1, TextStrokeTransparency = 1}):Play()
    end)
    task.delay(duration, function()
        if gui.Parent then gui:Destroy() end
        if bossGlowGui == gui then bossGlowGui = nil end
    end)
end

ReplicatedStorage:WaitForChild(Remotes.Names.BossPhase).OnClientEvent:Connect(function(payload)
    clearBossTargets()
    -- Also clear any leftover success glow from the PREVIOUS phase. Without
    -- this, if the player aces 75% (5s glow up) and 50% fires within those
    -- 5s, the misleading "DOUBLE DAMAGE!" banner is still on screen during
    -- the new attempt — making a missed phase look like a successful one.
    if bossGlowGui then
        bossGlowGui:Destroy()
        bossGlowGui = nil
    end
    local count = payload.targetCount or 4
    local window = payload.window or 5
    -- Stamped when the first dot renders so we can compute speed bonus
    -- (remainingTime / window) when all dots are cleared.
    local phaseStartTime = os.clock()

    -- Hide the regular wave HUD; the countdown bar takes its place
    if waveFrame then waveFrame.Visible = false end

    -- Purple countdown bar where the wave HUD used to be
    bossCountdownGui = Instance.new("ScreenGui")
    bossCountdownGui.Name = "ToL_BossCountdown"
    bossCountdownGui.IgnoreGuiInset = true
    bossCountdownGui.ResetOnSpawn = false
    bossCountdownGui.DisplayOrder = 240
    bossCountdownGui.Parent = playerGui

    local cdFrame = Instance.new("Frame")
    cdFrame.Size = UDim2.new(0, 280, 0, 46)
    cdFrame.Position = UDim2.new(0.5, -180, 0, 0)  -- same place as wave HUD, flush top
    cdFrame.BackgroundColor3 = Color3.fromRGB(40, 10, 60)
    cdFrame.BackgroundTransparency = 0.15
    cdFrame.BorderSizePixel = 0
    cdFrame.Parent = bossCountdownGui
    local cdCorner = Instance.new("UICorner")
    cdCorner.CornerRadius = UDim.new(0.18, 0)
    cdCorner.Parent = cdFrame

    -- Fill bar that drains. Uses Exceptional-purple from the shared rarity
    -- palette so the boss-minigame color reads consistent with attachment /
    -- upgrade-card rarity tinting; a drift to a random purple would feel off.
    local cdFill = Instance.new("Frame")
    cdFill.Size = UDim2.new(1, -8, 0, 8)
    cdFill.Position = UDim2.new(0, 4, 1, -12)
    cdFill.BackgroundColor3 = Rarity.Colors[3]
    cdFill.BorderSizePixel = 0
    cdFill.Parent = cdFrame
    local fillCorner = Instance.new("UICorner")
    fillCorner.CornerRadius = UDim.new(0.4, 0)
    fillCorner.Parent = cdFill

    -- "TAP THEM ALL!" header
    local cdLabel = Instance.new("TextLabel")
    cdLabel.Size = UDim2.new(1, 0, 0, 30)
    cdLabel.Position = UDim2.new(0, 0, 0, 4)
    cdLabel.BackgroundTransparency = 1
    cdLabel.Text = "TAP THEM ALL!"
    cdLabel.TextColor3 = Color3.fromRGB(230, 200, 255)
    cdLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    cdLabel.TextStrokeTransparency = 0.4
    cdLabel.Font = Enum.Font.FredokaOne
    cdLabel.TextSize = 22
    cdLabel.Parent = cdFrame

    -- Targets gui
    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_BossTargets"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 241
    gui.Parent = playerGui
    bossTargetGui = gui

    local TARGET_SIZE = 90
    local tappedCount = 0
    local minigameDone = false  -- guards against extra taps + late timeouts
    local TweenService = game:GetService("TweenService")

    -- Figure out the screen-space launch point: project the boss's world
    -- position to screen coords. Fallback to screen center if the boss is
    -- off-camera or bossPosition was missing from the payload (e.g., the
    -- boss died mid-windup — shouldn't happen but defend against it).
    local camera = Workspace.CurrentCamera
    local launchSx, launchSy = 0.5, 0.5
    if camera and payload.bossPosition then
        local sp, onScreen = camera:WorldToViewportPoint(payload.bossPosition)
        if onScreen and sp.Z > 0 then
            local vs = camera.ViewportSize
            if vs.X > 0 and vs.Y > 0 then
                launchSx = math.clamp(sp.X / vs.X, 0.05, 0.95)
                launchSy = math.clamp(sp.Y / vs.Y, 0.05, 0.95)
            end
        end
    end

    -- Each spot starts tiny AT the boss's screen position, then tweens
    -- to its final (random) resting spot while scaling up to full size.
    -- This reads as spots being launched OUT of the boss toward the player.
    local function makeBlob(i)
        -- Final landing position somewhere in the central screen area
        local sxFinal = 0.18 + math.random() * 0.64
        local syFinal = 0.22 + math.random() * 0.55

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, 6, 0, 6)  -- tiny seed; grows to TARGET_SIZE on arrival
        btn.Position = UDim2.new(launchSx, -3, launchSy, -3)
        btn.BackgroundColor3 = Color3.fromRGB(180, 60, 220)
        btn.BackgroundTransparency = 0
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = ""
        btn.Parent = gui
        local cc = Instance.new("UICorner")
        cc.CornerRadius = UDim.new(0.5, 0)
        cc.Parent = btn

        local ring = Instance.new("UIStroke")
        ring.Thickness = 4
        ring.Color = Color3.fromRGB(255, 200, 80)
        ring.Transparency = 0.15
        ring.Parent = btn

        -- Launch tween: fly from boss position to final spot while growing.
        -- Back easing gives a slight overshoot so the spot feels "thrown."
        local flyInfo = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
        TweenService:Create(btn, flyInfo, {
            Size = UDim2.new(0, TARGET_SIZE, 0, TARGET_SIZE),
            Position = UDim2.new(sxFinal, -TARGET_SIZE/2, syFinal, -TARGET_SIZE/2),
        }):Play()

        -- Per-dot guard: the btn lives for ~0.3s after tap during the pop
        -- animation, which is long enough to accept extra clicks. Without
        -- this flag rapid tapping one dot could count as N hits and win
        -- the minigame without actually tapping every dot.
        local tapped = false
        btn.MouseButton1Click:Connect(function()
            if minigameDone then return end
            if tapped then return end
            if not btn.Parent then return end
            tapped = true
            btn.AutoButtonColor = false
            btn.Active = false  -- stop further mouse events on this button
            tappedCount = tappedCount + 1

            -- Pop effect: a white burst ring that scales up + fades out,
            -- spawned as a sibling so destroying btn doesn't kill it mid-
            -- animation. Reads as a more satisfying "pop" than just the
            -- dot fading away.
            local burst = Instance.new("Frame")
            burst.AnchorPoint = Vector2.new(0.5, 0.5)
            burst.Position = UDim2.new(btn.Position.X.Scale, btn.Position.X.Offset + btn.Size.X.Offset / 2,
                                        btn.Position.Y.Scale, btn.Position.Y.Offset + btn.Size.Y.Offset / 2)
            burst.Size = UDim2.new(0, TARGET_SIZE, 0, TARGET_SIZE)
            burst.BackgroundTransparency = 1
            burst.BorderSizePixel = 0
            burst.Parent = gui
            local burstCorner = Instance.new("UICorner")
            burstCorner.CornerRadius = UDim.new(0.5, 0)
            burstCorner.Parent = burst
            local burstStroke = Instance.new("UIStroke")
            burstStroke.Thickness = 6
            burstStroke.Color = Color3.fromRGB(255, 240, 120)
            burstStroke.Transparency = 0
            burstStroke.Parent = burst
            local burstInfo = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
            TweenService:Create(burst, burstInfo, {
                Size = UDim2.new(0, TARGET_SIZE * 2.2, 0, TARGET_SIZE * 2.2),
            }):Play()
            TweenService:Create(burstStroke, burstInfo, {
                Transparency = 1, Thickness = 1,
            }):Play()
            task.delay(0.45, function() if burst.Parent then burst:Destroy() end end)

            -- Dot itself: quick fade + shrink.
            local popInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
            TweenService:Create(btn, popInfo, {
                Size = UDim2.new(0, TARGET_SIZE * 0.4, 0, TARGET_SIZE * 0.4),
                BackgroundTransparency = 1,
            }):Play()
            TweenService:Create(ring, popInfo, {Transparency = 1}):Play()
            task.delay(0.25, function() if btn.Parent then btn:Destroy() end end)

            if tappedCount >= count then
                minigameDone = true
                -- Speed bonus: fraction of the window NOT used → extra %
                -- on top of the base 100% damage buff. Instant clear = +100%,
                -- just-in-time clear = +0%.
                local elapsed = os.clock() - phaseStartTime
                local remaining = math.max(0, window - elapsed)
                local bonusPct = math.floor((remaining / window) * 100 + 0.5)
                ReplicatedStorage:WaitForChild(Remotes.Names.BossTargetTap):FireServer({
                    bonusPct = bonusPct,
                })
                showBossSuccessGlow(payload.bonusDuration or 5, bonusPct)
                clearBossTargets()
            end
        end)
    end

    for i = 1, count do makeBlob(i) end

    -- Drain the countdown bar over `window` seconds
    task.spawn(function()
        local tween = TweenService:Create(cdFill,
            TweenInfo.new(window, Enum.EasingStyle.Linear),
            {Size = UDim2.new(0, 0, 0, 8)})
        tween:Play()
    end)

    -- Timeout: if not all blobs were tapped, clean up AND tell the server
    -- so it can web the player.
    task.delay(window, function()
        if minigameDone then return end
        minigameDone = true
        clearBossTargets()
        local missRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.BossPhaseMiss)
        if missRemote then missRemote:FireServer() end
    end)

    -- Boss dies mid-phase cleanup: if towers/Phoenix finish the boss while
    -- the tap targets are still on screen, the dots would otherwise linger
    -- until the window timer runs out. Two-pronged approach because the
    -- AncestryChanged-only fix wasn't reliable:
    --   1. AncestryChanged on the boss mob (covers the common case).
    --   2. A polling loop that fires every 0.25s checking if ANY mob
    --      tagged as a boss is still alive; if not, clear. Covers:
    --      a) The boss dying BEFORE this handler runs (so our AncestryChanged
    --         bind targets a nil boss).
    --      b) The server firing BossPhase in the final hp-gate burst right
    --         as the boss dies — the ancestry event may fire before the
    --         connection is set up.
    --      c) Future boss types whose mob name isn't "Mob_finalboss".
    local BOSS_MOB_NAMES = {
        ["Mob_finalboss"] = true,
        ["Mob_spider"]    = true,
        ["Mob_bird"]      = true,
    }
    local function anyBossAlive()
        for _, p in ipairs(Workspace:GetDescendants()) do
            if p:IsA("BasePart") and BOSS_MOB_NAMES[p.Name] then
                return true
            end
        end
        return false
    end
    local function cleanupIfPhaseActive()
        if not minigameDone then
            minigameDone = true
            clearBossTargets()
        end
    end
    local boss = nil
    for _, p in ipairs(Workspace:GetDescendants()) do
        if p:IsA("BasePart") and BOSS_MOB_NAMES[p.Name] then
            boss = p
            break
        end
    end
    if boss then
        local conn
        conn = boss.AncestryChanged:Connect(function(_, newParent)
            if newParent == nil then
                cleanupIfPhaseActive()
                if conn then conn:Disconnect() end
            end
        end)
    end
    -- Poll fallback — runs until the phase resolves (either the boss dies,
    -- all taps hit, or the timeout). Short loop, cheap, guaranteed to
    -- catch cases the AncestryChanged bind missed.
    task.spawn(function()
        while not minigameDone do
            task.wait(0.25)
            if minigameDone then return end
            if not anyBossAlive() then
                cleanupIfPhaseActive()
                return
            end
        end
    end)
end)

------------------------------------------------------------
-- BOSS WINDUP: server says the Pickle Lord has stopped and is winding up.
-- Vibrate its Part for the duration by shaking its CFrame around the
-- origin each Heartbeat. The server freezes path movement during this
-- window, so we can safely animate around the mob's current position
-- without fighting the path-advance logic.
--
-- The boss Part is found by walking the Workspace for any Part named
-- "Mob_finalboss". That's how the server names it in makeMob.
------------------------------------------------------------
local function findFinalBossPart()
    for _, p in ipairs(Workspace:GetChildren()) do
        if p:IsA("BasePart") and p.Name == "Mob_finalboss" then return p end
    end
    -- Some mobs live inside sub-folders; do a shallow descendants scan as backup.
    for _, p in ipairs(Workspace:GetDescendants()) do
        if p:IsA("BasePart") and p.Name == "Mob_finalboss" then return p end
    end
    return nil
end

ReplicatedStorage:WaitForChild(Remotes.Names.BossWindup).OnClientEvent:Connect(function(payload)
    local duration = payload.duration or 1.2
    local boss = findFinalBossPart()
    if not boss then return end
    local origin = boss.CFrame
    local startedAt = os.clock()
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if not boss.Parent then
            if conn then conn:Disconnect(); conn = nil end
            return
        end
        local elapsed = os.clock() - startedAt
        if elapsed >= duration then
            -- Snap back to origin so the next path-advance tick starts clean
            boss.CFrame = origin
            if conn then conn:Disconnect(); conn = nil end
            return
        end
        -- Shake amplitude ramps up over the windup for anticipation.
        local ramp = elapsed / duration
        local amp = 0.15 + ramp * 0.6  -- 0.15 → 0.75 studs
        local dx = (math.random() - 0.5) * 2 * amp
        local dy = (math.random() - 0.5) * 2 * amp
        local dz = (math.random() - 0.5) * 2 * amp
        boss.CFrame = origin + Vector3.new(dx, dy, dz)
    end)
end)

------------------------------------------------------------
-- BOSS WEB: server tells us the player missed a phase → freeze movement
-- and overlay a green web on the screen for the payload duration.
-- Player can still interact with towers (important — they need to keep
-- defending while webbed). Movement + jump are blocked by setting
-- WalkSpeed + JumpPower to 0 on the humanoid; restored on timeout.
------------------------------------------------------------
ReplicatedStorage:WaitForChild(Remotes.Names.BossWeb).OnClientEvent:Connect(function(payload)
    local duration = payload.duration or 3
    local char = player.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    -- Save current walk/jump so we can restore whatever the player had
    local savedWalk, savedJump = 16, 50
    if hum then
        savedWalk = hum.WalkSpeed
        savedJump = hum.JumpPower
        hum.WalkSpeed = 0
        hum.JumpPower = 0
    end

    -- Web overlay: a full-screen translucent pale-green tint plus radial
    -- "strands" at each corner drawn with UIStroke + rotated frames.
    local existing = playerGui:FindFirstChild("ToL_BossWeb")
    if existing then existing:Destroy() end
    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_BossWeb"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 238
    gui.Parent = playerGui

    local tint = Instance.new("Frame")
    tint.Size = UDim2.fromScale(1, 1)
    tint.BackgroundColor3 = Color3.fromRGB(220, 255, 220)
    tint.BackgroundTransparency = 0.55
    tint.BorderSizePixel = 0
    tint.ZIndex = 1
    tint.Parent = gui

    -- Corner strand frames: thin white lines radiating from each corner
    -- toward the center. Rotated rectangles look web-like on the cheap.
    local function addStrand(originScale, rotationDeg)
        local f = Instance.new("Frame")
        f.Size = UDim2.new(0, 600, 0, 3)
        f.AnchorPoint = Vector2.new(0, 0.5)
        f.Position = originScale
        f.Rotation = rotationDeg
        f.BackgroundColor3 = Color3.fromRGB(240, 255, 240)
        f.BackgroundTransparency = 0.2
        f.BorderSizePixel = 0
        f.ZIndex = 2
        f.Parent = gui
    end
    addStrand(UDim2.new(0, 0, 0, 0), 30)
    addStrand(UDim2.new(0, 0, 0, 0), 60)
    addStrand(UDim2.new(1, 0, 0, 0), 120)
    addStrand(UDim2.new(1, 0, 0, 0), 150)
    addStrand(UDim2.new(0, 0, 1, 0), -30)
    addStrand(UDim2.new(0, 0, 1, 0), -60)
    addStrand(UDim2.new(1, 0, 1, 0), -120)
    addStrand(UDim2.new(1, 0, 1, 0), -150)

    -- "WEBBED!" banner so the player understands what happened
    local banner = Instance.new("TextLabel")
    banner.Size = UDim2.new(1, 0, 0, 50)
    banner.Position = UDim2.new(0, 0, 0.35, 0)
    banner.BackgroundTransparency = 1
    banner.Text = "WEBBED!"
    banner.TextColor3 = Color3.fromRGB(160, 255, 160)
    banner.TextStrokeColor3 = Color3.fromRGB(0, 40, 0)
    banner.TextStrokeTransparency = 0.2
    banner.Font = Enum.Font.FredokaOne
    banner.TextSize = 40
    banner.ZIndex = 3
    banner.Parent = gui

    -- Restore movement + remove overlay after duration. Uses wallclock
    -- since this is a client-side penalty tied to real player time.
    task.delay(duration, function()
        if gui.Parent then gui:Destroy() end
        -- Re-resolve humanoid in case the character respawned during the
        -- web window (shouldn't happen in our game but be safe).
        local char2 = player.Character
        local hum2 = char2 and char2:FindFirstChildOfClass("Humanoid")
        if hum2 then
            hum2.WalkSpeed = savedWalk
            hum2.JumpPower = savedJump
        end
    end)
end)
end

return BossMinigame
