--[[
    AttachmentsModal.lua — dev-panel "ATTACHMENTS" button modal.
    Shows each attachment type (PowerCore / Detonator / Phoenix) as a
    card: rarity-colored border, effect blurb, EQUIP button (green
    "EQUIPPED" when equipped, blue "EQUIP" when owned-but-not,
    grayed-out "locked" silhouette when not owned). Only one
    attachment can be equipped at a time.

    Server-pushed AttachmentsChanged events (fired on equip/unequip and
    on new-attachment grants) re-render the list while the modal is open.

    Coordinates with StatsModal via the shared closeActiveDevModal /
    registerCloser dance — opening this modal closes the stats panel
    (and vice-versa) so dev panels don't stack and block clicks.

    Extracted from init.client.lua to free main-chunk line count and
    mirror the StatsModal pattern.

    setup(deps) captures:
      deps.playerGui
      deps.ReplicatedStorage
      deps.Remotes              — shared Remotes module
      deps.closeActiveDevModal  — fn, closes any other dev panel first
      deps.registerCloser(fn)   — callback so opening closes any other
                                  dev modal that registers later
    Returns: { open = fn() }
]]

local AttachmentsModal = {}

-- Rarity palette from shared/Rarity (single source of truth across the
-- upgrade picker, attachment cards, tower info, Phoenix cooldown fill).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Rarity = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Rarity"))
local RARITY_NAMES  = Rarity.Names
local RARITY_COLORS = Rarity.Colors

-- Display-side attachment data — extracted to a sibling module so DevPanel
-- can share the same TYPE_DEFS + describeEffect (the reveal-modal it owns
-- referenced these as undeclared globals before).
local AttachmentTypes = require(script.Parent:WaitForChild("AttachmentTypes"))
local TYPE_DEFS       = AttachmentTypes.TYPE_DEFS
local TYPE_ORDER      = AttachmentTypes.TYPE_ORDER
local describeEffect  = AttachmentTypes.describeEffect

function AttachmentsModal.setup(deps)
    local playerGui           = deps.playerGui
    local ReplicatedStorage   = deps.ReplicatedStorage
    local Remotes             = deps.Remotes
    local closeActiveDevModal = deps.closeActiveDevModal
    local registerCloser      = deps.registerCloser

    local attachGui = nil
    local attachListFrame = nil

    local function renderInventory(payload)
        if not attachListFrame or not attachListFrame.Parent then return end
        for _, child in ipairs(attachListFrame:GetChildren()) do
            if child:IsA("Frame") then child:Destroy() end
        end

        -- Build a quick lookup: type → entry
        local owned = {}
        for _, e in ipairs(payload.owned or {}) do owned[e.type] = e end
        local equippedType = payload.equipped

        for orderIdx, attType in ipairs(TYPE_ORDER) do
            local entry = owned[attType]
            local def = TYPE_DEFS[attType]
            local row = Instance.new("Frame")
            -- Row height bumped from 80 to 100 to give the wrap-enabled
            -- blurb room for two lines (Phoenix's description is the
            -- long pole at ~"Saves the heart from a fatal blow. Recharges
            -- every 18 min of wave time.").
            row.Size = UDim2.new(1, -16, 0, 100)
            row.LayoutOrder = orderIdx
            row.BackgroundColor3 = entry
                and Color3.fromRGB(40, 45, 60)
                or  Color3.fromRGB(28, 30, 40)
            row.BackgroundTransparency = 0.1
            row.BorderSizePixel = 0
            row.Parent = attachListFrame
            local rc = Instance.new("UICorner")
            rc.CornerRadius = UDim.new(0.12, 0)
            rc.Parent = row
            -- Rarity-colored border (gray if unowned)
            local stroke = Instance.new("UIStroke")
            stroke.Thickness = 2
            stroke.Color = entry
                and RARITY_COLORS[entry.rarity]
                or  Color3.fromRGB(60, 60, 70)
            stroke.Parent = row

            -- Title row: "Common Power Core" or "??? (locked)"
            local title = Instance.new("TextLabel")
            title.Size = UDim2.new(1, -16, 0, 22)
            title.Position = UDim2.fromOffset(10, 6)
            title.BackgroundTransparency = 1
            title.TextXAlignment = Enum.TextXAlignment.Left
            title.Font = Enum.Font.FredokaOne
            title.TextSize = 16
            if entry then
                -- entry.rarity is guaranteed integer 1..6 by AttachmentStore.
                title.Text = string.format("%s %s",
                    RARITY_NAMES[entry.rarity], def.displayName)
                title.TextColor3 = RARITY_COLORS[entry.rarity]
            else
                title.Text = string.format("??? %s (locked)", def.displayName)
                title.TextColor3 = Color3.fromRGB(120, 120, 130)
            end
            title.Parent = row

            -- Effect blurb. Wrap enabled + extra height so Phoenix's
            -- two-sentence description fits on two lines without truncation.
            local blurb = Instance.new("TextLabel")
            blurb.Size = UDim2.new(1, -120, 0, 50)
            blurb.Position = UDim2.fromOffset(10, 30)
            blurb.BackgroundTransparency = 1
            blurb.TextXAlignment = Enum.TextXAlignment.Left
            blurb.TextYAlignment = Enum.TextYAlignment.Top
            blurb.TextWrapped = true
            blurb.Font = Enum.Font.Gotham
            blurb.TextSize = 13
            blurb.TextColor3 = entry
                and Color3.fromRGB(220, 220, 230)
                or  Color3.fromRGB(110, 110, 120)
            blurb.Text = entry
                and describeEffect(attType, entry.rarity)
                or  "Beat the Pickle Lord to roll a chance at this"
            blurb.Parent = row

            -- Equip / Equipped button on the right (only if owned)
            if entry then
                local isEquipped = (equippedType == attType)
                local equipBtn = Instance.new("TextButton")
                equipBtn.Size = UDim2.fromOffset(100, 36)
                -- Vertically centered in the 100px-tall row
                equipBtn.Position = UDim2.new(1, -110, 0, 32)
                equipBtn.BackgroundColor3 = isEquipped
                    and Color3.fromRGB(80, 200, 120)
                    or  Color3.fromRGB(70, 80, 110)
                equipBtn.BorderSizePixel = 0
                equipBtn.AutoButtonColor = false
                equipBtn.Text = isEquipped and "EQUIPPED" or "EQUIP"
                equipBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
                equipBtn.Font = Enum.Font.FredokaOne
                equipBtn.TextSize = 14
                equipBtn.Parent = row
                local ec = Instance.new("UICorner")
                ec.CornerRadius = UDim.new(0.25, 0)
                ec.Parent = equipBtn

                equipBtn.MouseButton1Click:Connect(function()
                    local equipRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.EquipAttachment)
                    if equipRemote then
                        -- Tapping EQUIPPED unequips; tapping EQUIP equips this type
                        equipRemote:FireServer(isEquipped and "" or attType)
                    end
                end)
            end
        end
    end

    -- Listen for server-pushed inventory updates (after equip changes / new awards)
    ReplicatedStorage:WaitForChild(Remotes.Names.AttachmentsChanged).OnClientEvent:Connect(function(payload)
        if attachGui and attachGui.Parent then renderInventory(payload) end
    end)

    local function open()
        closeActiveDevModal()  -- close any other dev panel first
        if attachGui then attachGui:Destroy() end
        attachGui = Instance.new("ScreenGui")
        attachGui.Name = "ToL_Attachments"
        attachGui.IgnoreGuiInset = true
        attachGui.ResetOnSpawn = false
        attachGui.DisplayOrder = 250
        attachGui.Parent = playerGui

        local dim = Instance.new("Frame")
        dim.Size = UDim2.fromScale(1, 1)
        dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        dim.BackgroundTransparency = 0.4
        dim.BorderSizePixel = 0
        dim.Parent = attachGui

        local modal = Instance.new("Frame")
        modal.Size = UDim2.fromOffset(420, 460)
        modal.Position = UDim2.new(0.5, -210, 0.5, -230)
        modal.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
        modal.BorderSizePixel = 0
        modal.Parent = attachGui
        local mc = Instance.new("UICorner")
        mc.CornerRadius = UDim.new(0.05, 0)
        mc.Parent = modal

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, 0, 0, 44)
        title.BackgroundTransparency = 1
        title.Text = "ATTACHMENTS"
        title.TextColor3 = Color3.fromRGB(220, 200, 255)
        title.Font = Enum.Font.FredokaOne
        title.TextSize = 22
        title.Parent = modal

        local hint = Instance.new("TextLabel")
        hint.Size = UDim2.new(1, -20, 0, 28)
        hint.Position = UDim2.fromOffset(10, 44)
        hint.BackgroundTransparency = 1
        hint.Text = "Equip ONE attachment for your starter tower"
        hint.TextColor3 = Color3.fromRGB(170, 180, 200)
        hint.TextWrapped = true
        hint.Font = Enum.Font.Gotham
        hint.TextSize = 12
        hint.Parent = modal

        attachListFrame = Instance.new("ScrollingFrame")
        attachListFrame.Size = UDim2.new(1, -20, 1, -130)
        attachListFrame.Position = UDim2.fromOffset(10, 78)
        attachListFrame.BackgroundTransparency = 1
        attachListFrame.BorderSizePixel = 0
        attachListFrame.ScrollBarThickness = 6
        attachListFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
        attachListFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
        attachListFrame.Parent = modal
        local listLayout = Instance.new("UIListLayout")
        listLayout.FillDirection = Enum.FillDirection.Vertical
        listLayout.Padding = UDim.new(0, 8)
        listLayout.SortOrder = Enum.SortOrder.LayoutOrder
        listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        listLayout.Parent = attachListFrame
        local listPad = Instance.new("UIPadding")
        listPad.PaddingTop = UDim.new(0, 6)
        listPad.Parent = attachListFrame

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
        cbc.CornerRadius = UDim.new(0.2, 0)
        cbc.Parent = closeBtn
        local function closeMe()
            if attachGui then attachGui:Destroy(); attachGui = nil end
            attachListFrame = nil
            registerCloser(nil)
        end
        closeBtn.MouseButton1Click:Connect(closeMe)
        registerCloser(closeMe)

        -- Initial fetch
        local getRemote = ReplicatedStorage:WaitForChild(Remotes.Names.GetAttachments)
        local ok, payload = pcall(function() return getRemote:InvokeServer() end)
        if ok and payload then renderInventory(payload) end
    end

    return { open = open }
end

return AttachmentsModal
