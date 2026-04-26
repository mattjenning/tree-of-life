--[[
    HoldEPickup.lua — Hold-E rapid-pickup loop driver.

    The ammo piles' ProximityPrompts on the server are kept as visual
    hints, but their hold semantics turned out unreliable —
    PromptButtonHoldEnded could fire spuriously while E was still
    physically held, killing the rapid pickup loop. So this module drives
    the loop client-side via UserInputService: fire PickupHoldStart when
    E goes down AND an AmmoPile is within 12 studs; fire PickupHoldStop
    on E release. Server runs the rapid pickup logic between those
    events.

    NOTE: the ammo system itself is currently retired (Towers fire
    unlimited; src/server/systems/Ammo.lua is not loaded). This client
    handler still fires the remotes — they have no listener, so the
    packets are dropped. Kept dormant for the "ammo returns" code path.

    setup(deps) captures:
      deps.player
      deps.ReplicatedStorage
      deps.Remotes
      deps.CollectionService
      deps.Tags
      deps.UserInputService
]]

local HoldEPickup = {}

function HoldEPickup.setup(deps)
    local player            = deps.player
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local CollectionService = deps.CollectionService
    local Tags              = deps.Tags
    local UserInputService  = deps.UserInputService

    local pickupStartRemote = ReplicatedStorage:WaitForChild(Remotes.Names.PickupHoldStart)
    local pickupStopRemote  = ReplicatedStorage:WaitForChild(Remotes.Names.PickupHoldStop)
    local pickupLoopActive  = false

    local function nearestAmmoPileWithin(maxDist)
        local char = player.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return nil end
        local nearest, nearestDist = nil, maxDist
        for _, glow in ipairs(CollectionService:GetTagged(Tags.AmmoPile)) do
            if glow:IsA("BasePart") then
                local d = (hrp.Position - glow.Position).Magnitude
                if d <= nearestDist then
                    nearest = glow
                    nearestDist = d
                end
            end
        end
        return nearest
    end

    UserInputService.InputBegan:Connect(function(input, _gameProcessed)
        if input.KeyCode ~= Enum.KeyCode.E then return end
        -- Check nearest pile FIRST. If there's one in range, the player
        -- is clearly trying to pick up — fire the remote even though the
        -- pile's own ProximityPrompt (KeyboardKeyCode = E) has already
        -- consumed the press and set gameProcessed=true. Without a pile
        -- nearby, respect gameProcessed so chat/UI typing doesn't
        -- trigger pickup.
        if not nearestAmmoPileWithin(12) then return end
        if pickupLoopActive then return end
        pickupLoopActive = true
        pickupStartRemote:FireServer()
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.KeyCode ~= Enum.KeyCode.E then return end
        if not pickupLoopActive then return end
        pickupLoopActive = false
        pickupStopRemote:FireServer()
    end)
end

return HoldEPickup
