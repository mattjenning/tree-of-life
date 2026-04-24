--[[
    StatsModal.lua — dev-facing per-tower damage + lifetime-DPS panel.
    Polls the server-stamped `TotalDamageDone` + `FirstHitTime` attributes
    twice a second while the modal is open.

    Extracted to its own ModuleScript to keep the main chunk under the
    Luau 200-register ceiling (see CLAUDE.md convention note). The
    init.client.lua calls StatsModal.setup(deps) once at startup; the
    returned `open` is wired to the STATS dev-panel button's click.

    setup(deps) captures:
      deps.playerGui
      deps.player               — the LocalPlayer (for UserId filtering)
      deps.CollectionService
      deps.Tags                 — the Tags shared module (Tags.Tower)
      deps.closeActiveDevModal  — callable; closes any other dev modal first
      deps.registerCloser(fn)   — hand the modal's close fn to the main
                                  chunk's activeDevModalCloser slot so
                                  opening another dev modal closes this
                                  one; nil-able to clear.

    Returns: { open = fn() }
]]

local StatsModal = {}

function StatsModal.setup(deps)
    local playerGui          = deps.playerGui
    local player             = deps.player
    local CollectionService  = deps.CollectionService
    local Tags               = deps.Tags
    local closeActiveDevModal = deps.closeActiveDevModal
    local registerCloser     = deps.registerCloser

    local statsGui = nil

    local function open()
        closeActiveDevModal()  -- close any other dev panel first
        if statsGui then statsGui:Destroy(); statsGui = nil end
        statsGui = Instance.new("ScreenGui")
        statsGui.Name = "ToL_TowerStats"
        statsGui.IgnoreGuiInset = true
        statsGui.ResetOnSpawn = false
        statsGui.DisplayOrder = 250
        statsGui.Parent = playerGui

        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        dim.BackgroundTransparency = 0.4
        dim.BorderSizePixel = 0
        dim.Parent = statsGui

        local modal = Instance.new("Frame")
        modal.Size = UDim2.new(0, 460, 0, 520)
        modal.Position = UDim2.new(0.5, -230, 0.5, -260)
        modal.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
        modal.BorderSizePixel = 0
        modal.Parent = statsGui
        local mc = Instance.new("UICorner")
        mc.CornerRadius = UDim.new(0.05, 0)
        mc.Parent = modal

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, 0, 0, 44)
        title.BackgroundTransparency = 1
        title.Text = "TOWER STATS"
        title.TextColor3 = Color3.fromRGB(220, 235, 255)
        title.Font = Enum.Font.FredokaOne
        title.TextSize = 22
        title.Parent = modal

        local hint = Instance.new("TextLabel")
        hint.Size = UDim2.new(1, -20, 0, 28)
        hint.Position = UDim2.new(0, 10, 0, 44)
        hint.BackgroundTransparency = 1
        hint.Text = "Total damage dealt + average DPS since first hit"
        hint.TextColor3 = Color3.fromRGB(170, 180, 200)
        hint.TextWrapped = true
        hint.Font = Enum.Font.Gotham
        hint.TextSize = 12
        hint.Parent = modal

        local hdr = Instance.new("Frame")
        hdr.Size = UDim2.new(1, -20, 0, 22)
        hdr.Position = UDim2.new(0, 10, 0, 78)
        hdr.BackgroundColor3 = Color3.fromRGB(40, 46, 60)
        hdr.BorderSizePixel = 0
        hdr.Parent = modal
        local hdrc = Instance.new("UICorner")
        hdrc.CornerRadius = UDim.new(0.3, 0); hdrc.Parent = hdr
        local function hdrLabel(text, xScale, xOffset, wScale, wOffset, align)
            local l = Instance.new("TextLabel")
            l.Size = UDim2.new(wScale, wOffset, 1, 0)
            l.Position = UDim2.new(xScale, xOffset, 0, 0)
            l.BackgroundTransparency = 1
            l.Text = text
            l.TextColor3 = Color3.fromRGB(200, 210, 230)
            l.Font = Enum.Font.GothamBold
            l.TextSize = 11
            l.TextXAlignment = align or Enum.TextXAlignment.Left
            l.Parent = hdr
            return l
        end
        hdrLabel("TOWER",  0, 8, 0.50, -8)
        hdrLabel("DAMAGE", 0.50, 0, 0.25, 0, Enum.TextXAlignment.Right)
        hdrLabel("DPS",    0.75, 0, 0.25, -8, Enum.TextXAlignment.Right)

        local listFrame = Instance.new("ScrollingFrame")
        listFrame.Size = UDim2.new(1, -20, 1, -150)
        listFrame.Position = UDim2.new(0, 10, 0, 104)
        listFrame.BackgroundTransparency = 1
        listFrame.BorderSizePixel = 0
        listFrame.ScrollBarThickness = 6
        listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
        listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
        listFrame.Parent = modal
        local listLayout = Instance.new("UIListLayout")
        listLayout.FillDirection = Enum.FillDirection.Vertical
        listLayout.Padding = UDim.new(0, 4)
        listLayout.SortOrder = Enum.SortOrder.LayoutOrder
        listLayout.Parent = listFrame

        local closeBtn = Instance.new("TextButton")
        closeBtn.Size = UDim2.new(1, -20, 0, 38)
        closeBtn.Position = UDim2.new(0, 10, 1, -48)
        closeBtn.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
        closeBtn.BorderSizePixel = 0
        closeBtn.Text = "CLOSE"
        closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        closeBtn.Font = Enum.Font.FredokaOne
        closeBtn.TextSize = 16
        closeBtn.AutoButtonColor = false
        closeBtn.Parent = modal
        local cbc = Instance.new("UICorner")
        cbc.CornerRadius = UDim.new(0.2, 0); cbc.Parent = closeBtn

        local uid = player.UserId
        local function formatNum(n)
            if n >= 1e6 then return string.format("%.2fM", n / 1e6) end
            if n >= 1e3 then return string.format("%.1fK", n / 1e3) end
            return string.format("%d", math.floor(n + 0.5))
        end
        local function rebuild()
            if not listFrame.Parent then return end
            for _, child in ipairs(listFrame:GetChildren()) do
                if child:IsA("Frame") then child:Destroy() end
            end
            local rows = {}
            for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                local t = base.Parent
                if t and t:IsA("Model") and t:GetAttribute("Owner") == uid then
                    local dmg = t:GetAttribute("TotalDamageDone") or 0
                    local firstHit = t:GetAttribute("FirstHitTime")
                    local dps = 0
                    if firstHit then
                        local elapsed = math.max(0.1, os.clock() - firstHit)
                        dps = dmg / elapsed
                    end
                    local ttype = t:GetAttribute("TowerType") or t.Name
                    table.insert(rows, { name = ttype, dmg = dmg, dps = dps })
                end
            end
            table.sort(rows, function(a, b) return a.dmg > b.dmg end)
            for i, row in ipairs(rows) do
                local rf = Instance.new("Frame")
                rf.Size = UDim2.new(1, 0, 0, 24)
                rf.BackgroundColor3 = (i % 2 == 1)
                    and Color3.fromRGB(36, 40, 52) or Color3.fromRGB(32, 36, 48)
                rf.BorderSizePixel = 0
                rf.LayoutOrder = i
                rf.Parent = listFrame
                local rc = Instance.new("UICorner")
                rc.CornerRadius = UDim.new(0.2, 0); rc.Parent = rf
                local function cell(text, xScale, xOffset, wScale, wOffset, align, color)
                    local l = Instance.new("TextLabel")
                    l.Size = UDim2.new(wScale, wOffset, 1, 0)
                    l.Position = UDim2.new(xScale, xOffset, 0, 0)
                    l.BackgroundTransparency = 1
                    l.Text = text
                    l.TextColor3 = color or Color3.fromRGB(230, 235, 245)
                    l.Font = Enum.Font.Gotham
                    l.TextSize = 13
                    l.TextXAlignment = align or Enum.TextXAlignment.Left
                    l.Parent = rf
                end
                cell(row.name, 0, 8, 0.50, -8)
                cell(formatNum(row.dmg), 0.50, 0, 0.25, 0, Enum.TextXAlignment.Right)
                cell(string.format("%.1f", row.dps), 0.75, 0, 0.25, -8, Enum.TextXAlignment.Right)
            end
            if #rows == 0 then
                local empty = Instance.new("TextLabel")
                empty.Size = UDim2.new(1, 0, 0, 40)
                empty.BackgroundTransparency = 1
                empty.Text = "No towers placed."
                empty.TextColor3 = Color3.fromRGB(140, 150, 170)
                empty.Font = Enum.Font.Gotham
                empty.TextSize = 13
                empty.Parent = listFrame
            end
        end
        rebuild()
        local updateTask = task.spawn(function()
            while statsGui and statsGui.Parent do
                task.wait(0.5)
                rebuild()
            end
        end)

        local function closeMe()
            if statsGui then statsGui:Destroy(); statsGui = nil end
            if updateTask then pcall(task.cancel, updateTask); updateTask = nil end
            registerCloser(nil)
        end
        closeBtn.MouseButton1Click:Connect(closeMe)
        registerCloser(closeMe)
    end

    return { open = open }
end

return StatsModal
