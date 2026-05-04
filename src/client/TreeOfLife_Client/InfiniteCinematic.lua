--[[
    InfiniteCinematic.lua — client-side fade for the Infinite Arena
    entry / exit cinematics.

    Drop-through-the-ground feel: when EnterInfinite fires, fade to
    black, hold while the server teleports the character, fade back
    in to reveal the pickle dimension. ExitInfinite is the matching
    return cinematic (slightly faster — players don't need to re-
    establish "where am I" on the way back to the hub).

    Payload (both remotes):
      { fadeOutSec = number, holdSec = number, fadeInSec = number }

    Falls back to sensible defaults if the payload is missing.

    Public API:
      InfiniteCinematic.setup(deps)
        deps.player, deps.playerGui, deps.ReplicatedStorage,
        deps.Remotes, deps.TweenService

    setup() wires both remotes' OnClientEvent handlers and returns.
    Module is self-contained — no per-frame work, no exported state.
]]

local InfiniteCinematic = {}

function InfiniteCinematic.setup(deps)
    local playerGui        = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes          = deps.Remotes
    local TweenService     = deps.TweenService

    -- Singleton fade overlay. Built lazily on first cinematic.
    local fadeGui: ScreenGui? = nil
    local fadeFrame: Frame? = nil

    local function ensureFadeGui()
        if fadeGui and fadeGui.Parent then return end
        local gui = Instance.new("ScreenGui")
        gui.Name = "ToL_InfiniteCinematic"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 50  -- above gameplay HUD, below confirmation modals
        gui.Parent = playerGui
        local frame = Instance.new("Frame")
        frame.Size = UDim2.fromScale(1, 1)
        frame.Position = UDim2.fromScale(0, 0)
        frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        frame.BackgroundTransparency = 1
        frame.BorderSizePixel = 0
        frame.Parent = gui
        fadeGui = gui
        fadeFrame = frame
    end

    local function runCinematic(payload)
        ensureFadeGui()
        if not fadeFrame then return end
        local fadeOutSec = (payload and payload.fadeOutSec) or 0.8
        local holdSec    = (payload and payload.holdSec)    or 0.4
        local fadeInSec  = (payload and payload.fadeInSec)  or 0.8

        -- Fade to black.
        fadeFrame.BackgroundTransparency = 1
        local outTween = TweenService:Create(fadeFrame,
            TweenInfo.new(fadeOutSec, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
            { BackgroundTransparency = 0 })
        outTween:Play()
        outTween.Completed:Wait()

        -- Hold dark while the server is mid-teleport.
        if holdSec > 0 then task.wait(holdSec) end

        -- Fade back in to reveal the destination.
        local inTween = TweenService:Create(fadeFrame,
            TweenInfo.new(fadeInSec, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            { BackgroundTransparency = 1 })
        inTween:Play()
        inTween.Completed:Wait()
    end

    local enterRemote = ReplicatedStorage:WaitForChild(Remotes.Names.EnterInfinite)
    local exitRemote  = ReplicatedStorage:WaitForChild(Remotes.Names.ExitInfinite)

    enterRemote.OnClientEvent:Connect(function(payload)
        runCinematic(payload)
    end)
    exitRemote.OnClientEvent:Connect(function(payload)
        runCinematic(payload)
    end)
end

return InfiniteCinematic
