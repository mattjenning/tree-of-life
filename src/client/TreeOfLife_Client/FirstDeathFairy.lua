--[[
    FirstDeathFairy.lua — cinematic + modal for the first-death tutorial
    loop.

    Flow on ShowFirstDeathFairy:
      1. Locate the player's downed character (HumanoidRootPart position,
         or a reasonable fallback).
      2. Spawn a glowing pink fairy Part high above + off-axis.
      3. Tween the fairy DOWN to the character with EasingStyle.Back /
         Out — overshoots slightly then eases back for the "quick halt."
      4. On impact: burst of sparkle particles, light flash.
      5. Dissolve the fairy, then open the modal with horizontal
         attachment cards.

    Flow on ShowResurrectionNotice (other players): a toast modal that
    says "Someone is being resurrected!" — no cinematic (the dying
    player gets that; spectators just need the info).

    setup(deps) captures:
      deps.playerGui, deps.ReplicatedStorage, deps.Remotes, deps.IS_MOBILE
      deps.player                — the LocalPlayer
      deps.unlockGameLost        — callback: gameLost=false so the
                                    resurrection WaveState broadcast
                                    isn't swallowed by the game-over gate.
]]

local TweenService = game:GetService("TweenService")
local Workspace    = game:GetService("Workspace")
local RunService   = game:GetService("RunService")
local Lighting     = game:GetService("Lighting")

local FirstDeathFairy = {}

local FAIRY_ATTACHMENTS = {
    {type = "PowerCore",
     title = "Power Core",
     blurb = "Boosts your Core tower's damage. Good for beating stage bosses faster."},
    {type = "Detonator",
     title = "Detonator",
     blurb = "Enemies explode when they die, damaging nearby enemies. Great for clearing waves."},
    {type = "Phoenix",
     title = "Phoenix Charm",
     blurb = "If the heart would die, burns all enemies in a huge area and saves it. Once per long cooldown."},
}

-- ---------------------------------------------------------------------
-- CINEMATIC: glowing fairy descends to the player.
-- ---------------------------------------------------------------------
local function playFairyCinematic(targetPos, onComplete)
    -- Prelude: darken the whole scene so the crumpled body reads in
    -- silence before the fairy arrives. ColorCorrectionEffect so we
    -- don't clobber the stage-lighting system's Ambient/ClockTime
    -- state — when we destroy the effect at the end, stage lighting
    -- is whatever it was before, untouched.
    local dim = Instance.new("ColorCorrectionEffect")
    dim.Brightness = 0
    dim.Saturation = 0
    dim.Contrast = 0
    dim.TintColor = Color3.fromRGB(255, 255, 255)
    dim.Parent = Lighting
    TweenService:Create(dim,
        TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { Brightness = -0.7, Saturation = -0.6 }):Play()

    -- Hold in darkness so the death reads before the rescue begins.
    task.wait(2.2)

    -- Fairy body: small neon-pink sphere. No imported model — cheap
    -- composed primitive keeps the module self-contained. Scale is
    -- tuned to read as a "fairy orb" at typical player-camera distance.
    local fairy = Instance.new("Part")
    fairy.Name = "TutorialFairy"
    fairy.Shape = Enum.PartType.Ball
    fairy.Size = Vector3.new(2, 2, 2)
    fairy.Anchored = true
    fairy.CanCollide = false
    fairy.CanQuery = false
    fairy.CastShadow = false
    fairy.Material = Enum.Material.Neon
    fairy.Color = Color3.fromRGB(255, 200, 240)
    fairy.Transparency = 0.05
    -- Start high above + off-axis so the descent is a diagonal arc,
    -- not a straight drop (more cinematic). Bigger start-height than the
    -- prior pass so the 8s descent has room to breathe.
    local startPos = targetPos + Vector3.new(-16, 110, -16)
    fairy.CFrame = CFrame.new(startPos)
    fairy.Parent = Workspace

    -- Halo light — very bright during descent, pulses up at impact.
    -- 3× the initial pass values after the "make her glow" ask.
    local light = Instance.new("PointLight")
    light.Color = Color3.fromRGB(255, 210, 235)
    light.Brightness = 24
    light.Range = 90
    light.Parent = fairy

    -- Attachment for particles; avoids needing a BasePart child.
    local attach = Instance.new("Attachment")
    attach.Parent = fairy

    -- Trail: dense during descent, clamped to 0 at impact.
    local trail = Instance.new("ParticleEmitter")
    trail.Texture = "rbxasset://textures/particles/sparkles_main.dds"
    trail.Lifetime = NumberRange.new(0.4, 0.8)
    trail.Rate = 60
    trail.Speed = NumberRange.new(0, 2)
    trail.SpreadAngle = Vector2.new(180, 180)
    trail.Rotation = NumberRange.new(0, 360)
    trail.Color = ColorSequence.new(Color3.fromRGB(255, 225, 245))
    trail.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.5),
        NumberSequenceKeypoint.new(1, 0.1),
    })
    trail.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.1),
        NumberSequenceKeypoint.new(1, 1),
    })
    trail.LightEmission = 1
    trail.Parent = attach

    -- Tween DOWN with EasingStyle.Back so the fairy overshoots slightly
    -- then snaps back — reads as a "quick halt" rather than a smooth
    -- linear stop. Hovers ~4 studs above the target so it's landing
    -- AT the character, not inside them. 8s at Back/Out gives a long
    -- slow approach — the fairy is a big enough story moment to earn
    -- the cinematic runtime.
    local endPos = targetPos + Vector3.new(0, 4, 0)
    local descent = TweenService:Create(fairy,
        TweenInfo.new(8.0, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
        { CFrame = CFrame.new(endPos) })
    descent:Play()
    descent.Completed:Wait()

    -- Impact: burst of sparkles + light flash. Stop the trail emitter
    -- so the cloud at rest isn't competing with the burst.
    trail.Rate = 0
    local burst = Instance.new("ParticleEmitter")
    burst.Texture = "rbxasset://textures/particles/sparkles_main.dds"
    burst.Lifetime = NumberRange.new(0.8, 1.5)
    burst.Speed = NumberRange.new(12, 30)
    burst.SpreadAngle = Vector2.new(180, 180)
    burst.Rotation = NumberRange.new(0, 360)
    burst.Rate = 0
    burst.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 240, 220)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 200, 240)),
    })
    burst.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1.2),
        NumberSequenceKeypoint.new(1, 0.2),
    })
    burst.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0),
        NumberSequenceKeypoint.new(1, 1),
    })
    burst.LightEmission = 1
    burst.Parent = attach
    burst:Emit(80)

    -- Light pulse at impact, then decay. 3× brighter than initial pass.
    light.Brightness = 75
    TweenService:Create(light,
        TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { Brightness = 0, Range = 180 }):Play()

    -- Fade the fairy itself over the burst duration so the impact
    -- reads as "she became light."
    TweenService:Create(fairy,
        TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { Transparency = 1, Size = Vector3.new(0.2, 0.2, 0.2) }):Play()

    -- Lift the room darkening as the fairy bursts with light — reads as
    -- "her glow chases away the dark" rather than a blunt cut back to
    -- normal lighting.
    TweenService:Create(dim,
        TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { Brightness = 0, Saturation = 0 }):Play()

    task.wait(0.7)
    fairy:Destroy()
    -- Tidy up the ColorCorrectionEffect once it's fully lifted. Delayed
    -- past the 0.9s tween so we don't snap-destroy mid-fade.
    task.delay(0.3, function()
        if dim and dim.Parent then dim:Destroy() end
    end)
    if onComplete then onComplete() end
end

-- Find a reasonable world position for the fairy to target. Prefers the
-- player's HumanoidRootPart (alive body, or ragdoll in place); falls
-- back to camera focus if the character is gone (already respawning).
local function findPlayerTargetPos(player)
    local char = player.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if hrp then return hrp.Position end
    local cam = Workspace.CurrentCamera
    if cam then return cam.CFrame.Position + cam.CFrame.LookVector * 8 end
    return Vector3.new(0, 5, 0)
end

-- ---------------------------------------------------------------------
-- MODAL: horizontal attachment cards.
-- ---------------------------------------------------------------------
local function openModal(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local IS_MOBILE         = deps.IS_MOBILE

    local old = playerGui:FindFirstChild("ToL_FirstDeathFairy")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_FirstDeathFairy"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 245
    gui.Parent = playerGui

    local dim = Instance.new("Frame")
    dim.Size = UDim2.fromScale(1, 1)
    dim.BackgroundColor3 = Color3.fromRGB(6, 10, 20)
    dim.BackgroundTransparency = 0.35
    dim.BorderSizePixel = 0
    dim.Parent = gui

    -- Modal width scales with card count (3 cards side-by-side).
    -- Horizontal -20%: CARD_W 210 → 168, keeps 3-across readable on
    -- desktop + tightens the modal so it doesn't dominate the screen.
    -- Vertical trimmed: modal height = header + cards + 16px footer,
    -- no extra empty space below.
    local CARD_W = IS_MOBILE and 120 or 168
    local CARD_H = IS_MOBILE and 200 or 210
    local CARD_GAP = 10
    local CARDS_ROW_W = 3 * CARD_W + 2 * CARD_GAP
    local PAD_X = 20
    local MODAL_W = CARDS_ROW_W + 2 * PAD_X
    local HEADER_H = IS_MOBILE and 120 or 130  -- title + speech block
    local MODAL_H = HEADER_H + CARD_H + 20     -- 20px footer breathing

    local card = Instance.new("Frame")
    card.AnchorPoint = Vector2.new(0.5, 0.5)
    card.Position = UDim2.fromScale(0.5, 0.5)
    card.Size = UDim2.fromOffset(MODAL_W, MODAL_H)
    card.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
    card.BorderSizePixel = 0
    card.Parent = dim
    local cc = Instance.new("UICorner")
    cc.CornerRadius = UDim.new(0.04, 0); cc.Parent = card
    local cstroke = Instance.new("UIStroke")
    cstroke.Thickness = 3
    cstroke.Color = Color3.fromRGB(255, 200, 230)
    cstroke.Parent = card

    local fairyHeader = Instance.new("TextLabel")
    fairyHeader.Size = UDim2.new(1, 0, 0, 46)
    fairyHeader.Position = UDim2.fromOffset(0, 14)
    fairyHeader.BackgroundTransparency = 1
    fairyHeader.Text = "✨  A Fairy Appears  ✨"
    fairyHeader.TextColor3 = Color3.fromRGB(255, 220, 240)
    fairyHeader.TextStrokeColor3 = Color3.fromRGB(40, 0, 40)
    fairyHeader.TextStrokeTransparency = 0.3
    fairyHeader.Font = Enum.Font.FredokaOne
    fairyHeader.TextSize = IS_MOBILE and 22 or 28
    fairyHeader.Parent = card

    local speech = Instance.new("TextLabel")
    speech.Size = UDim2.new(1, -32, 0, IS_MOBILE and 58 or 52)
    speech.Position = UDim2.fromOffset(16, IS_MOBILE and 62 or 64)
    speech.BackgroundTransparency = 1
    speech.Text = "The Tree of Life is hard. You'll have to try many times. Take one of these, and more help will come if you endure."
    speech.TextColor3 = Color3.fromRGB(235, 235, 245)
    speech.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    speech.TextStrokeTransparency = 0.4
    speech.Font = Enum.Font.Gotham
    speech.TextSize = IS_MOBILE and 13 or 15
    speech.TextWrapped = true
    speech.TextXAlignment = Enum.TextXAlignment.Center
    speech.TextYAlignment = Enum.TextYAlignment.Top
    speech.Parent = card

    -- Cards row container (horizontal layout).
    local row = Instance.new("Frame")
    row.Size = UDim2.fromOffset(CARDS_ROW_W, CARD_H)
    row.Position = UDim2.new(0.5, -CARDS_ROW_W / 2, 0, IS_MOBILE and 130 or 130)
    row.BackgroundTransparency = 1
    row.Parent = card
    local rowLayout = Instance.new("UIListLayout")
    rowLayout.FillDirection = Enum.FillDirection.Horizontal
    rowLayout.Padding = UDim.new(0, CARD_GAP)
    rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
    rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    rowLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    rowLayout.Parent = row

    for i, entry in ipairs(FAIRY_ATTACHMENTS) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(CARD_W, CARD_H)
        btn.BackgroundColor3 = Color3.fromRGB(44, 50, 70)
        btn.AutoButtonColor = true
        btn.BorderSizePixel = 0
        btn.Text = ""
        btn.LayoutOrder = i
        btn.Parent = row
        local bc = Instance.new("UICorner")
        bc.CornerRadius = UDim.new(0.08, 0); bc.Parent = btn
        local bs = Instance.new("UIStroke")
        bs.Thickness = 1.5
        bs.Color = Color3.fromRGB(200, 200, 200)  -- Common rarity border
        bs.Parent = btn

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -16, 0, 26)
        title.Position = UDim2.fromOffset(8, 10)
        title.BackgroundTransparency = 1
        title.Text = entry.title
        title.TextColor3 = Color3.fromRGB(255, 240, 200)
        title.Font = Enum.Font.FredokaOne
        title.TextSize = IS_MOBILE and 16 or 19
        title.TextXAlignment = Enum.TextXAlignment.Center
        title.Parent = btn

        local rarityPill = Instance.new("TextLabel")
        rarityPill.Size = UDim2.fromOffset(70, 18)
        rarityPill.Position = UDim2.new(0.5, -35, 0, 38)
        rarityPill.BackgroundColor3 = Color3.fromRGB(200, 200, 200)
        rarityPill.BackgroundTransparency = 0.2
        rarityPill.BorderSizePixel = 0
        rarityPill.Text = "COMMON"
        rarityPill.TextColor3 = Color3.fromRGB(40, 40, 50)
        rarityPill.Font = Enum.Font.FredokaOne
        rarityPill.TextSize = 11
        rarityPill.Parent = btn
        local pc = Instance.new("UICorner")
        pc.CornerRadius = UDim.new(0.5, 0); pc.Parent = rarityPill

        local blurb = Instance.new("TextLabel")
        blurb.Size = UDim2.new(1, -16, 1, -72)
        blurb.Position = UDim2.fromOffset(8, 66)
        blurb.BackgroundTransparency = 1
        blurb.Text = entry.blurb
        blurb.TextColor3 = Color3.fromRGB(210, 220, 235)
        blurb.Font = Enum.Font.Gotham
        blurb.TextSize = IS_MOBILE and 12 or 13
        blurb.TextWrapped = true
        blurb.TextXAlignment = Enum.TextXAlignment.Center
        blurb.TextYAlignment = Enum.TextYAlignment.Top
        blurb.Parent = btn

        btn.MouseButton1Click:Connect(function()
            local r = ReplicatedStorage:FindFirstChild(Remotes.Names.PickFirstDeathAttachment)
            if r then r:FireServer({ attType = entry.type }) end
            gui:Destroy()
        end)
    end
end

-- ---------------------------------------------------------------------
-- setup
-- ---------------------------------------------------------------------
function FirstDeathFairy.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local IS_MOBILE         = deps.IS_MOBILE
    local player            = deps.player
    local unlockGameLost    = deps.unlockGameLost

    ReplicatedStorage:WaitForChild(Remotes.Names.ShowFirstDeathFairy).OnClientEvent:Connect(function()
        -- Kill any pre-existing fairy gui + close GameOver banner. The
        -- cinematic replaces the defeat visual. Unlock gameLost so the
        -- resurrection WaveState broadcast (fires after the pick) isn't
        -- ignored by the game-over gate.
        local old = playerGui:FindFirstChild("ToL_FirstDeathFairy")
        if old then old:Destroy() end
        local over = playerGui:FindFirstChild("ToL_GameOver")
        if over then over:Destroy() end
        unlockGameLost()

        -- Play cinematic, THEN open the modal. Wrapping in task.spawn so
        -- the server-side event handler thread isn't blocked by the
        -- cinematic duration (~2s).
        task.spawn(function()
            local targetPos = findPlayerTargetPos(player)
            playFairyCinematic(targetPos, function()
                openModal(deps)
            end)
        end)
    end)

    -- Co-op toast: non-picker players see this while the picker chooses.
    -- Auto-dismisses after 30s or is visually superseded by the wave
    -- restart (WaveState broadcast after server resurrection).
    ReplicatedStorage:WaitForChild(Remotes.Names.ShowResurrectionNotice).OnClientEvent:Connect(function()
        local over = playerGui:FindFirstChild("ToL_GameOver")
        if over then over:Destroy() end
        unlockGameLost()

        local existing = playerGui:FindFirstChild("ToL_ResurrectionNotice")
        if existing then existing:Destroy() end
        local gui = Instance.new("ScreenGui")
        gui.Name = "ToL_ResurrectionNotice"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 246
        gui.Parent = playerGui

        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(6, 10, 20)
        dim.BackgroundTransparency = 0.5
        dim.BorderSizePixel = 0
        dim.Parent = gui

        local panel = Instance.new("Frame")
        panel.AnchorPoint = Vector2.new(0.5, 0.5)
        panel.Position = UDim2.fromScale(0.5, 0.5)
        panel.Size = UDim2.fromOffset(IS_MOBILE and 340 or 460, IS_MOBILE and 140 or 160)
        panel.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
        panel.BorderSizePixel = 0
        panel.Parent = dim
        local pc = Instance.new("UICorner")
        pc.CornerRadius = UDim.new(0.05, 0); pc.Parent = panel
        local ps = Instance.new("UIStroke")
        ps.Thickness = 2; ps.Color = Color3.fromRGB(255, 200, 230); ps.Parent = panel

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -20, 0, 44)
        title.Position = UDim2.fromOffset(10, 18)
        title.BackgroundTransparency = 1
        title.Text = "✨  Someone is being resurrected!  ✨"
        title.TextColor3 = Color3.fromRGB(255, 220, 240)
        title.Font = Enum.Font.FredokaOne
        title.TextSize = IS_MOBILE and 18 or 22
        title.TextWrapped = true
        title.Parent = panel

        local sub = Instance.new("TextLabel")
        sub.Size = UDim2.new(1, -20, 0, 60)
        sub.Position = UDim2.fromOffset(10, 64)
        sub.BackgroundTransparency = 1
        sub.Text = "The wave will restart with help from a fairy."
        sub.TextColor3 = Color3.fromRGB(210, 220, 235)
        sub.Font = Enum.Font.Gotham
        sub.TextSize = IS_MOBILE and 14 or 15
        sub.TextWrapped = true
        sub.Parent = panel

        task.delay(30, function() if gui.Parent then gui:Destroy() end end)
    end)
end

return FirstDeathFairy
