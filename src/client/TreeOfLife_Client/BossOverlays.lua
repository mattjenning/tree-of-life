--[[
    BossOverlays.lua — Tappable overlays attached to boss-mechanic Parts:

      1. Canopy Bird dive targets (Tag: BirdDiveMark)
         Server places these above a targeted tower; client adds a "TAP!"
         BillboardGui button. Tapping fires TapBirdDive → cancels the
         dive + bonus damage to the bird.

      2. Webbed-tower overlays (read from tower.WebbedUntil attribute)
         When a Web Weaver web hits a tower, the tower attribute
         WebbedUntil is set; this module renders a "WEBBED" bubble +
         3D ClickDetector that taps to remove the lock.

    Each overlay attaches reactively (CollectionService signal or
    per-frame Heartbeat poll), so server-side tag/attribute changes
    drive client visuals without explicit per-mob remotes.

    Note: the Canopy Spider's web Parts (Tag: SpiderWeb) handle their
    own click detection via server-side ClickDetector — no client UI
    needed there. Kept the related comment in the main client.

    setup(deps) captures:
      deps.ReplicatedStorage
      deps.Remotes
      deps.CollectionService
      deps.Tags
      deps.RunService
]]

local BossOverlays = {}

function BossOverlays.setup(deps)
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local CollectionService = deps.CollectionService
    local Tags              = deps.Tags
    local RunService        = deps.RunService

do
    local function attachBirdTargetUI(markPart)
        if markPart:FindFirstChild("BirdDiveGui") then return end
        local bb = Instance.new("BillboardGui")
        bb.Name = "BirdDiveGui"
        bb.Size = UDim2.new(0, 80, 0, 80)
        bb.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
        bb.AlwaysOnTop = true
        bb.LightInfluence = 0
        bb.MaxDistance = 500
        bb.Parent = markPart

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromScale(1, 1)
        btn.BackgroundColor3 = Color3.fromRGB(255, 180, 80)
        btn.BackgroundTransparency = 0.1
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Text = "TAP!"
        btn.TextColor3 = Color3.fromRGB(40, 20, 0)
        btn.Font = Enum.Font.FredokaOne
        btn.TextSize = 26
        btn.Parent = bb
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0.5, 0)
        corner.Parent = btn
        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(255, 255, 255)
        stroke.Thickness = 3
        stroke.Parent = btn

        btn.MouseButton1Click:Connect(function()
            local markId = markPart:GetAttribute("MarkId")
            if not markId then return end
            local r = ReplicatedStorage:FindFirstChild(Remotes.Names.TapBirdDive)
            if r then r:FireServer({ markId = markId }) end
            btn.Visible = false
        end)
    end

    for _, mark in ipairs(CollectionService:GetTagged(Tags.BirdDiveMark)) do
        attachBirdTargetUI(mark)
    end
    CollectionService:GetInstanceAddedSignal(Tags.BirdDiveMark):Connect(attachBirdTargetUI)
end

------------------------------------------------------------
-- WEBBED TOWER VISUAL
-- When a tower's WebbedUntil attribute is set in the future, overlay a
-- sticky-web BillboardGui on it. Removed automatically once the
-- timestamp passes. Simple white-stroked "X" inside a webbed circle
-- reads as "this tower is locked out" without needing an image asset.
------------------------------------------------------------
do
    local function attachWebbedOverlay(tower)
        if not tower:IsDescendantOf(workspace) then return end
        local existing = tower:FindFirstChild("WebbedOverlay")
        if existing then return end

        local anchor = Instance.new("Part")
        anchor.Name = "WebbedOverlay"
        -- Sized to roughly match the BillboardGui bubble's screen area so
        -- a click anywhere on the bubble raycasts onto this Part's hit box
        -- (the BillboardGui's TextButton was supposed to catch clicks but
        -- was unreliable; a ClickDetector on the anchor is the robust path).
        anchor.Shape = Enum.PartType.Ball
        -- 10-stud ball (was 5): gives the 3D ClickDetector backup a much
        -- wider hit box so clicks anywhere near the visible bubble catch,
        -- not just within the original 5-stud core. Invisible, so the
        -- visual impression still matches the BillboardGui circle.
        anchor.Size = Vector3.new(10, 10, 10)
        anchor.Transparency = 1
        anchor.CanCollide = false
        anchor.Anchored = true
        -- Position the overlay at the VERTICAL CENTER of the tower so the
        -- WEBBED bubble sits over the tower body itself — easier to read as
        -- "this tower is the webbed one" and harder to miss-tap than an
        -- overhead bubble that can drift into the HUD band.
        local centerCF
        if tower:IsA("Model") then
            local ok, cf = pcall(function() return tower:GetBoundingBox() end)
            if ok and cf then centerCF = cf end
        end
        local bb = tower:FindFirstChild("TowerBase")
            or tower:FindFirstChildWhichIsA("BasePart")
        if centerCF then
            anchor.CFrame = CFrame.new(centerCF.Position)
        elseif bb then
            anchor.CFrame = CFrame.new(bb.Position)
        end
        anchor.Parent = tower

        local gui = Instance.new("BillboardGui")
        gui.Size = UDim2.new(0, 120, 0, 120)  -- visual only; click zone = the 3D anchor ball
        gui.AlwaysOnTop = true
        gui.LightInfluence = 0
        gui.MaxDistance = 500
        gui.Adornee = anchor  -- explicit to avoid implicit-Adornee quirks
        gui.Parent = anchor

        -- Visual label (NOT a TextButton). Kept non-clickable so in-flight
        -- web Parts in front of the tower win the click raycast — GUI
        -- buttons would eat clicks regardless of what's visually on top,
        -- but a plain Frame is invisible to the input system. Actual
        -- click handling: the server-side WebbedClickDetector parented
        -- to the tower Model catches clicks on any descendant part
        -- (including the 10-stud anchor ball here), so the click area
        -- stays wide without a GUI layer.
        local visual = Instance.new("Frame")
        visual.Size = UDim2.fromScale(1, 1)
        visual.BackgroundColor3 = Color3.fromRGB(240, 240, 255)
        visual.BackgroundTransparency = 0.2
        visual.BorderSizePixel = 0
        visual.Parent = gui
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0.5, 0)
        corner.Parent = visual
        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(160, 160, 180)
        stroke.Thickness = 2
        stroke.Parent = visual

        local label = Instance.new("TextLabel")
        label.Size = UDim2.fromScale(1, 1)
        label.BackgroundTransparency = 1
        label.Text = "WEBBED"
        label.TextColor3 = Color3.fromRGB(80, 80, 110)
        label.TextStrokeColor3 = Color3.fromRGB(255, 255, 255)
        label.TextStrokeTransparency = 0.2
        label.Font = Enum.Font.FredokaOne
        label.TextSize = 16
        label.Parent = visual

        local function refresh()
            local taps = tower:GetAttribute("WebTapsRemaining")
            if taps and taps > 0 then
                label.Text = "WEBBED\n" .. tostring(taps)
            else
                label.Text = "WEBBED"
            end
        end
        refresh()
        tower:GetAttributeChangedSignal("WebTapsRemaining"):Connect(refresh)

        -- 3D ClickDetector on the invisible 10-stud anchor. Two reasons
        -- this exists alongside the server-side WebbedClickDetector on
        -- the tower Model:
        --   1. The anchor is a client-only Part — a server ClickDetector
        --      on the Model only reliably catches clicks on SERVER-side
        --      descendants (tower base, column, gem). A click on the
        --      anchor's widened area around the tower needs its own CD.
        --   2. Both ClickDetectors fire `TapSpiderWeb` which the server
        --      handler routes through the SAME decrement path, so they
        --      can't double-count — raycasts hit one Part per click,
        --      and whichever ClickDetector owns that Part fires.
        local cd = Instance.new("ClickDetector")
        cd.MaxActivationDistance = 500
        cd.Parent = anchor
        cd.MouseClick:Connect(function()
            local r = ReplicatedStorage:FindFirstChild(Remotes.Names.TapSpiderWeb)
            if r then r:FireServer({ tower = tower }) end
            visual.BackgroundTransparency = 0.5
            task.delay(0.12, function()
                if visual.Parent then visual.BackgroundTransparency = 0.2 end
            end)
        end)
    end

    local function tickWebbedOverlays()
        local now = os.clock()
        for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local tower = base.Parent
            if tower and tower.Parent then
                local webbedUntil = tower:GetAttribute("WebbedUntil") or 0
                local existing = tower:FindFirstChild("WebbedOverlay")
                if now < webbedUntil and not existing then
                    attachWebbedOverlay(tower)
                elseif now >= webbedUntil and existing then
                    existing:Destroy()
                end
            end
        end
    end

    RunService.Heartbeat:Connect(tickWebbedOverlays)
end
end

return BossOverlays
