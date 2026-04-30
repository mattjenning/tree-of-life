--[[
    PickleLordRangeDecayHUD.lua — first-time-player UX scaffolding for
    Pickle Lord's range-decay mechanic. Per memory file
    project_pickle_lord_range_decay_ux.md (2026-04-30):

      "First-time players don't see this happening — towers just
       gradually stop reaching the boss. By the time they figure
       out 'wait, I need to focus the boss,' range is already
       shrunk and they can't reach. Make the mechanic LEGIBLE."

    Two visual signals, both story-mode-only (server gates on
    Workspace.Map4ArenaSweepActive ≠ true so arena sweeps don't get
    UX overlay 100× per sweep):

      1. PRE-TICK WARNING. ~3 game-seconds before each decay tick
         the server fires PickleLordRangeDecayWarning with the next
         tick index + lead time. Client renders a centred chyron
         "RANGES SHRINKING IN N..." that counts down + plays a
         short rumble cue.

      2. TICK FLASH. At the moment of decay the server fires
         PickleLordRangeDecayTick with priorMult / newMult /
         decayFraction. Client iterates every player-owned tower
         (CollectionService Tags.Tower with Owner == localPlayer)
         and draws a transient cyan range circle at the tower's
         pre-decay radius, then animates it shrinking to the new
         radius over ~0.5s, then fades out. Reuses the SelectionVisuals
         range-circle Part shape so the visual "contract" matches
         the in-game tower-selected range overlay players already
         recognize.

    Extracted as a sibling module to free init.client.lua main-chunk
    register slots (the file hovers at ~187/200 per CLAUDE.md
    convention #5; new top-level locals here would push it over).

    setup(deps) captures:
      deps.playerGui
      deps.player
      deps.Remotes
      deps.Tags
]]

local Workspace         = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local TweenService      = game:GetService("TweenService")

local PickleLordRangeDecayHUD = {}

-- Tunable presentation constants. Single source of truth at the top of
-- the module so future tweaks land in one place. Values match the
-- memory file's "options in priority order" sketch.
local CHYRON_DISPLAY_ORDER     = 220
local CHYRON_BG_COLOR          = Color3.fromRGB(120, 30, 30)
local CHYRON_BG_TRANSPARENCY   = 0.15
local CHYRON_TEXT_COLOR        = Color3.fromRGB(255, 230, 180)
local CHYRON_STROKE_COLOR      = Color3.fromRGB(20, 0, 0)
local CHYRON_TEXT_SIZE         = 38
local TICK_VISUAL_HOLD_SEC     = 0.4   -- pre-shrink hold (full circle visible)
local TICK_VISUAL_SHRINK_SEC   = 0.5   -- shrink animation duration
local TICK_VISUAL_FADE_SEC     = 0.4   -- post-shrink fade-out
local TICK_RING_TRANSPARENCY   = 0.55  -- starting transparency
local TICK_RING_COLOR          = Color3.fromRGB(120, 200, 255)
local TICK_RING_THICKNESS_STUDS = 0.5  -- vertical thickness of the disc
local TICK_RING_HEIGHT_OFFSET  = 0.2   -- studs above tower base — sit just on the floor

function PickleLordRangeDecayHUD.setup(deps)
    local playerGui         = deps.playerGui
    local localPlayer       = deps.player
    local Remotes           = deps.Remotes
    local Tags              = deps.Tags
    local ReplicatedStorage = game:GetService("ReplicatedStorage")

    ----------------------------------------------------------------
    -- Pre-tick chyron — countdown banner shown ~3 game-seconds
    -- before each decay tick.
    ----------------------------------------------------------------
    local activeChyron: ScreenGui? = nil

    local function destroyChyron()
        if activeChyron then
            activeChyron:Destroy()
            activeChyron = nil
        end
    end

    local function showChyron(leadGameSec, decayFraction)
        destroyChyron()  -- clear any in-flight from a prior tick

        local gui = Instance.new("ScreenGui")
        gui.Name = "ToL_PickleLordRangeDecayChyron"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = CHYRON_DISPLAY_ORDER
        gui.Parent = playerGui
        activeChyron = gui

        local bg = Instance.new("Frame")
        bg.Size = UDim2.new(0.7, 0, 0, 80)
        bg.Position = UDim2.fromScale(0.5, 0.18)
        bg.AnchorPoint = Vector2.new(0.5, 0)
        bg.BackgroundColor3 = CHYRON_BG_COLOR
        bg.BackgroundTransparency = CHYRON_BG_TRANSPARENCY
        bg.BorderSizePixel = 0
        bg.Parent = gui
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0.2, 0)
            c.Parent = bg
            local s = Instance.new("UIStroke")
            s.Thickness = 2
            s.Color = Color3.fromRGB(255, 100, 100)
            s.Transparency = 0.2
            s.Parent = bg
        end

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -16, 0.55, 0)
        title.Position = UDim2.fromOffset(8, 4)
        title.BackgroundTransparency = 1
        title.Text = "RANGES SHRINKING SOON"
        title.TextColor3 = CHYRON_TEXT_COLOR
        title.TextStrokeColor3 = CHYRON_STROKE_COLOR
        title.TextStrokeTransparency = 0.2
        title.Font = Enum.Font.FredokaOne
        title.TextSize = CHYRON_TEXT_SIZE
        title.Parent = bg

        local sub = Instance.new("TextLabel")
        sub.Size = UDim2.new(1, -16, 0.45, -8)
        sub.Position = UDim2.new(0, 8, 0.55, 4)
        sub.BackgroundTransparency = 1
        sub.Text = string.format(
            "Pickle Lord shrinks tower range by %d%%   •   focus him with G + click/tap",
            math.floor((1 - (decayFraction or 0.95)) * 100 + 0.5))
        sub.TextColor3 = Color3.fromRGB(255, 255, 220)
        sub.TextStrokeColor3 = CHYRON_STROKE_COLOR
        sub.TextStrokeTransparency = 0.4
        sub.Font = Enum.Font.Gotham
        sub.TextSize = 18
        sub.Parent = bg

        -- Auto-destroy slightly after the lead time (game-seconds
        -- maps to wallclock via Workspace.GameSpeed; we use a
        -- conservative 1.0 ratio + 0.5s padding so the chyron is
        -- still visible at the moment of decay).
        local gameSpeed = Workspace:GetAttribute("GameSpeed") or 1
        local wallSec = (leadGameSec or 3) / math.max(0.1, gameSpeed) + 0.5
        task.delay(wallSec, function()
            if gui and gui.Parent then gui:Destroy() end
            if activeChyron == gui then activeChyron = nil end
        end)
    end

    ----------------------------------------------------------------
    -- Per-tower range-circle visual telegraph on tick.
    ----------------------------------------------------------------
    local function drawTowerRingPulse(tower: Model, priorMult: number, newMult: number)
        local base = tower:FindFirstChild("Base") or tower.PrimaryPart
        if not base or not base:IsA("BasePart") then return end
        local rangeAttr = tower:GetAttribute("Range")
        if type(rangeAttr) ~= "number" or rangeAttr <= 0 then return end

        -- Pre-decay radius = tower.Range × priorMult. Post-decay = ×
        -- newMult. Animate the disc shrinking between them so the
        -- player SEES the rings contract. Mounted at the tower base
        -- so it sits on the floor regardless of tower height.
        local priorRadius = rangeAttr * (priorMult or 1)
        local newRadius   = rangeAttr * (newMult or priorMult or 1)

        local ring = Instance.new("Part")
        ring.Name = "PickleLordRangeDecayRing"
        ring.Anchored = true
        ring.CanCollide = false
        ring.CanTouch = false
        ring.CanQuery = false
        ring.Material = Enum.Material.Neon
        ring.Color = TICK_RING_COLOR
        ring.Transparency = TICK_RING_TRANSPARENCY
        ring.Size = Vector3.new(priorRadius * 2, TICK_RING_THICKNESS_STUDS, priorRadius * 2)
        ring.CFrame = CFrame.new(base.Position.X,
            base.Position.Y + TICK_RING_HEIGHT_OFFSET,
            base.Position.Z)
        ring.Parent = Workspace
        local mesh = Instance.new("SpecialMesh")
        mesh.MeshType = Enum.MeshType.Cylinder
        mesh.Parent = ring
        -- Cylinder mesh: rotate 90° so the disc lies flat (Roblox
        -- cylinders are oriented along X axis by default; we want Y).
        ring.CFrame = CFrame.new(base.Position.X,
            base.Position.Y + TICK_RING_HEIGHT_OFFSET,
            base.Position.Z) * CFrame.Angles(0, 0, math.rad(90))

        -- Animation: hold full size, shrink to new size, fade out.
        task.spawn(function()
            task.wait(TICK_VISUAL_HOLD_SEC)
            if not ring or not ring.Parent then return end
            local shrinkTween = TweenService:Create(ring,
                TweenInfo.new(TICK_VISUAL_SHRINK_SEC,
                    Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
                { Size = Vector3.new(newRadius * 2, TICK_RING_THICKNESS_STUDS, newRadius * 2) })
            shrinkTween:Play()
            shrinkTween.Completed:Wait()
            if not ring or not ring.Parent then return end
            local fadeTween = TweenService:Create(ring,
                TweenInfo.new(TICK_VISUAL_FADE_SEC),
                { Transparency = 1.0 })
            fadeTween:Play()
            fadeTween.Completed:Wait()
            if ring and ring.Parent then ring:Destroy() end
        end)
    end

    local function pulseAllOwnedTowers(priorMult, newMult)
        for _, base in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local tower = base.Parent
            if tower and tower:IsA("Model") then
                local owner = tower:GetAttribute("Owner")
                if owner == localPlayer.UserId then
                    drawTowerRingPulse(tower, priorMult, newMult)
                end
            end
        end
    end

    ----------------------------------------------------------------
    -- Wire the remotes.
    ----------------------------------------------------------------
    local warningRemote = ReplicatedStorage:WaitForChild(
        Remotes.Names.PickleLordRangeDecayWarning)
    local tickRemote    = ReplicatedStorage:WaitForChild(
        Remotes.Names.PickleLordRangeDecayTick)

    warningRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" then return end
        showChyron(payload.leadGameSec or 3, payload.decayFraction or 0.95)
    end)

    tickRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" then return end
        destroyChyron()  -- clear the warning overlay if still up
        pulseAllOwnedTowers(payload.priorMult or 1, payload.newMult or 1)
    end)

end

return PickleLordRangeDecayHUD
