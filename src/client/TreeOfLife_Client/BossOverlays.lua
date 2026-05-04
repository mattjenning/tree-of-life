--[[
    BossOverlays.lua — Tappable overlay for the Web Weaver boss mechanic.

    Webbed-tower overlays (read from tower.WebbedUntil attribute):
    when a web hits a tower, the tower attribute WebbedUntil is set;
    this module renders a "WEBBED" bubble + 3D ClickDetector that taps
    to remove the lock. Attaches reactively (Heartbeat poll) so server-
    side attribute changes drive the visual without explicit remotes.

    The Canopy Spider's web Parts (Tag: SpiderWeb) handle their own
    click detection via server-side ClickDetector — no client UI here.

    HISTORICAL NOTE: this file used to also handle the Canopy Bird's
    dive-target overlay (Tag: BirdDiveMark). That mechanic was retired
    in favor of the swoop/grab/carry/drop/daze fight in Map3BirdBoss —
    the BirdDiveMark plumbing was dead code (server-side BirdBoss.lua
    deleted, no marks were ever spawned). Removed in the cleanup pass.

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
    local Players           = game:GetService("Players")
    local localPlayer       = Players.LocalPlayer
    local playerGui         = localPlayer:WaitForChild("PlayerGui")

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

        -- Marker child keeps tickWebbedOverlays' "FindFirstChild
        -- WebbedOverlay" detection working the same way it did when
        -- attachment used a 3D anchor Part.
        local marker = Instance.new("Folder")
        marker.Name = "WebbedOverlay"
        marker.Parent = tower

        -- Screen-tracked overlay: previous BillboardGui-on-anchor-Part
        -- approach failed when 3D geometry (map-2 staircase) sat between
        -- camera and tower — input layer treated the click as occluded.
        -- ScreenGui input lives entirely in screen space and is immune
        -- to that occlusion. We project the tower's bbox center to a
        -- viewport pixel each frame and park the bubble there.
        local sg = Instance.new("ScreenGui")
        sg.Name = "ToL_WebbedBubble"
        sg.IgnoreGuiInset = true
        sg.ResetOnSpawn = false
        sg.DisplayOrder = 90
        sg.Parent = playerGui

        local visual = Instance.new("TextButton")
        visual.AnchorPoint = Vector2.new(0.5, 0.5)
        visual.Size = UDim2.fromOffset(110, 110)
        visual.BackgroundColor3 = Color3.fromRGB(240, 240, 255)
        visual.BackgroundTransparency = 0.2
        visual.BorderSizePixel = 0
        visual.AutoButtonColor = false
        visual.Active = true
        visual.Text = ""
        visual.Parent = sg
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0.5, 0)
            c.Parent = visual
            local s = Instance.new("UIStroke")
            s.Color = Color3.fromRGB(160, 160, 180)
            s.Thickness = 2
            s.Parent = visual
        end

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

        local function fireTap()
            local r = ReplicatedStorage:FindFirstChild(Remotes.Names.TapSpiderWeb)
            if r then r:FireServer({ tower = tower }) end
            visual.BackgroundTransparency = 0.5
            task.delay(0.12, function()
                if visual.Parent then visual.BackgroundTransparency = 0.2 end
            end)
        end
        visual.MouseButton1Click:Connect(fireTap)
        visual.TouchTap:Connect(fireTap)
        visual.Activated:Connect(fireTap)

        -- Per-frame follow.
        local function getAnchorPos()
            if tower:IsA("Model") then
                local ok, cf = pcall(function() return tower:GetBoundingBox() end)
                if ok and cf then return cf.Position end
            end
            local bb = tower:FindFirstChild("TowerBase")
                or tower:FindFirstChildWhichIsA("BasePart")
            return bb and bb.Position
        end
        local conn
        conn = RunService.RenderStepped:Connect(function()
            if not tower.Parent or not sg.Parent then
                if conn then conn:Disconnect() end
                return
            end
            local pos = getAnchorPos()
            local cam = workspace.CurrentCamera
            if not cam or not pos then return end
            local sp = cam:WorldToViewportPoint(pos)
            if sp.Z > 0 then
                visual.Visible = true
                visual.Position = UDim2.fromOffset(sp.X, sp.Y)
            else
                visual.Visible = false
            end
        end)

        -- Auto-cleanup when WebbedOverlay marker is destroyed
        -- (tickWebbedOverlays nukes it when WebbedUntil expires).
        marker.AncestryChanged:Connect(function(_, parent)
            if not parent then
                if conn then conn:Disconnect() end
                if sg.Parent then sg:Destroy() end
            end
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

-- SpiderWeb (in-flight) overlays. The server ClickDetector on each web
-- Part is unreliable when 3D geometry (map-2 staircase) sits between
-- the camera and the web — same occlusion class as the webbed-tower
-- bubble. Solution: a ScreenGui-tracked button per web that fires
-- TapSpiderWeb directly via webId, bypassing the world raycast.
do
    local function attachWebOverlay(webPart)
        if webPart:FindFirstChild("WebTapOverlay") then return end
        local marker = Instance.new("Folder")
        marker.Name = "WebTapOverlay"
        marker.Parent = webPart

        local sg = Instance.new("ScreenGui")
        sg.Name = "ToL_WebTapOverlay"
        sg.IgnoreGuiInset = true
        sg.ResetOnSpawn = false
        sg.DisplayOrder = 85
        sg.Parent = playerGui

        local btn = Instance.new("TextButton")
        btn.AnchorPoint = Vector2.new(0.5, 0.5)
        btn.Size = UDim2.fromOffset(90, 90)
        btn.BackgroundColor3 = Color3.fromRGB(240, 240, 255)
        btn.BackgroundTransparency = 0.4
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Active = true
        btn.Text = ""
        btn.Parent = sg
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0.5, 0)
            c.Parent = btn
            local s = Instance.new("UIStroke")
            s.Color = Color3.fromRGB(160, 160, 180)
            s.Thickness = 2
            s.Parent = btn
        end

        local function fireTap()
            local webId = webPart:GetAttribute("WebId")
            if not webId then return end
            local r = ReplicatedStorage:FindFirstChild(Remotes.Names.TapSpiderWeb)
            if r then r:FireServer({webId = webId}) end
            btn.BackgroundTransparency = 0.7
        end
        btn.MouseButton1Click:Connect(fireTap)
        btn.TouchTap:Connect(fireTap)
        btn.Activated:Connect(fireTap)

        local conn
        conn = RunService.RenderStepped:Connect(function()
            if not webPart.Parent or not sg.Parent then
                if conn then conn:Disconnect() end
                if sg.Parent then sg:Destroy() end
                return
            end
            local cam = workspace.CurrentCamera
            if not cam then return end
            local sp = cam:WorldToViewportPoint(webPart.Position)
            if sp.Z > 0 then
                btn.Visible = true
                btn.Position = UDim2.fromOffset(sp.X, sp.Y)
            else
                btn.Visible = false
            end
        end)
        webPart.AncestryChanged:Connect(function(_, parent)
            if not parent then
                if conn then conn:Disconnect() end
                if sg.Parent then sg:Destroy() end
            end
        end)
    end

    -- Register existing + future SpiderWeb-tagged parts.
    for _, web in ipairs(CollectionService:GetTagged(Tags.SpiderWeb)) do
        if web:IsA("BasePart") then attachWebOverlay(web) end
    end
    CollectionService:GetInstanceAddedSignal(Tags.SpiderWeb):Connect(function(web)
        if web:IsA("BasePart") then attachWebOverlay(web) end
    end)
end
end

return BossOverlays
