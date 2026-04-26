--[[
    Ammo.lua — Ammo pile construction + pickup/load flow.

    Builds two ammo piles in map 1 (SW and NW corners) and two in map 2
    (SW and SE corners). Each pile is a stack of crates with a glowing
    neon ball + ProximityPrompt on top. Players hold E near a pile to
    rapidly pick up packs (1 pack per 0.15s), then walk to a tower and
    tap E to load 10 shots from one pack.

    The hold-to-pickup uses client-driven remotes (PickupHoldStart /
    PickupHoldStop) rather than ProximityPrompt's native hold semantics.
    ProximityPrompt's PromptButtonHoldEnded fired spuriously after
    Triggered completed, killing the loop while the player was still
    holding. See inline comment at the pickup handler.

    Each tower's load prompt is enabled only when:
      (a) a player carrying ≥1 pack is within LOAD_RANGE studs, AND
      (b) the tower isn't already full.
    A background poll (every 0.2s) keeps the enabled flags in sync.

    setup(ctx) reads:
      ctx.makePart             (helper)
      ctx.tdRoom, rc, halfW, halfD  (map 1 placement)
      ctx.MAP2_AMMO_SW_POS, MAP2_AMMO_SE_POS  (map 2 pile world positions)

    Nothing is published — Ammo is a pure consumer + handler owner.
]]

local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Tags    = require(Shared:WaitForChild("Tags"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Ammo = {}

function Ammo.setup(ctx)
    local makePart = ctx.makePart
    local tdRoom   = ctx.tdRoom
    local rc       = ctx.rc
    local halfW    = ctx.halfW
    local halfD    = ctx.halfD

    local pickupStartRemote = ReplicatedStorage:WaitForChild(Remotes.Names.PickupHoldStart)
    local pickupStopRemote  = ReplicatedStorage:WaitForChild(Remotes.Names.PickupHoldStop)

    local ammoPiles = {}  -- collected so we can wire up pickup handlers below

    local function buildAmmoPile(center, pileName, parentModel, mapId)
        parentModel = parentModel or tdRoom
        mapId = mapId or 1
        local ammoGroup = Instance.new("Model")
        ammoGroup.Name = pileName
        ammoGroup.Parent = parentModel

        local function makeCrate(offset, size)
            makePart({
                Name = "AmmoCrate",
                Size = size,
                CFrame = CFrame.new(center + offset) * CFrame.Angles(0, math.rad(math.random(-15, 15)), 0),
                Material = Enum.Material.Wood,
                Color = Color3.fromRGB(180, 140, 70):Lerp(Color3.fromRGB(155, 115, 55), math.random() * 0.3),
                Parent = ammoGroup,
            })
        end

        makeCrate(Vector3.new(-1.2, 1.2, -1.2), Vector3.new(2.2, 2.2, 2.2))
        makeCrate(Vector3.new( 1.2, 1.2, -1.2), Vector3.new(2.2, 2.2, 2.2))
        makeCrate(Vector3.new(-1.2, 1.2,  1.2), Vector3.new(2.2, 2.2, 2.2))
        makeCrate(Vector3.new( 1.2, 1.2,  1.2), Vector3.new(2.2, 2.2, 2.2))
        makeCrate(Vector3.new(-0.8, 3.4, 0), Vector3.new(2.0, 2.0, 2.0))
        makeCrate(Vector3.new( 0.8, 3.4, 0), Vector3.new(2.0, 2.0, 2.0))
        makeCrate(Vector3.new(0, 5.2, 0), Vector3.new(1.8, 1.8, 1.8))

        local ammoGlow = makePart({
            Name = "AmmoGlow",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(1.2, 1.2, 1.2),
            CFrame = CFrame.new(center + Vector3.new(0, 6.8, 0)),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(255, 200, 100),
            Transparency = 0.1,
            CanCollide = false,
            Parent = ammoGroup,
        })
        local ammoLight = Instance.new("PointLight")
        ammoLight.Color = Color3.fromRGB(255, 200, 120)
        ammoLight.Brightness = 2
        ammoLight.Range = 15
        ammoLight.Parent = ammoGlow

        local labelAnchor = makePart({
            Name = "AmmoLabelAnchor",
            Size = Vector3.new(0.1, 0.1, 0.1),
            CFrame = CFrame.new(center + Vector3.new(0, 9, 0)),
            Transparency = 1,
            CanCollide = false,
            Parent = ammoGroup,
        })
        local bb = Instance.new("BillboardGui")
        bb.Size = UDim2.fromOffset(160, 30)
        bb.AlwaysOnTop = true
        bb.LightInfluence = 0
        bb.MaxDistance = 120
        bb.Parent = labelAnchor
        local label = Instance.new("TextLabel")
        label.Size = UDim2.fromScale(1, 1)
        label.BackgroundTransparency = 1
        label.Text = "AMMO PILE"
        label.TextColor3 = Color3.fromRGB(255, 220, 150)
        label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        label.TextStrokeTransparency = 0
        label.Font = Enum.Font.FredokaOne
        label.TextSize = 20
        label.Parent = bb

        local prompt = Instance.new("ProximityPrompt")
        prompt.ActionText = "Hold to pick up"
        prompt.ObjectText = "Ammo"
        -- HoldDuration = 0 keeps the prompt as a pure visual hint. Actual hold
        -- detection happens on the client via UserInputService (E key down/up)
        -- because ProximityPrompt's hold semantics were unreliable here:
        -- PromptButtonHoldEnded would fire spuriously after Triggered completed,
        -- killing the loop while the player was still holding.
        prompt.HoldDuration = 0
        prompt.MaxActivationDistance = 12
        prompt.RequiresLineOfSight = false
        prompt.KeyboardKeyCode = Enum.KeyCode.E
        prompt.Parent = ammoGlow

        CollectionService:AddTag(ammoGlow, Tags.AmmoPile)
        ammoGlow:SetAttribute("MapId", mapId)
        table.insert(ammoPiles, {glow = ammoGlow, prompt = prompt})
        return ammoGlow, prompt
    end

    -- Map 1 piles: SW (near the heart) and NW (opposite corner)
    buildAmmoPile(rc + Vector3.new(-halfW + 8, 0, halfD - 8), "AmmoPile_SW")
    buildAmmoPile(rc + Vector3.new(-halfW + 8, 0, -halfD + 8), "AmmoPile_NW")

    -- Map 2 piles: SW and SE corners. Map2.setup has already built
    -- TreeOfLifeMap2Room in Workspace by the time Ammo.setup runs.
    do
        local map2Room = Workspace:FindFirstChild("TreeOfLifeMap2Room")
        if map2Room then
            buildAmmoPile(ctx.MAP2_AMMO_SW_POS, "AmmoPile_Map2_SW", map2Room, 2)
            buildAmmoPile(ctx.MAP2_AMMO_SE_POS, "AmmoPile_Map2_SE", map2Room, 2)
            print("[ToL] Map 2 ammo piles built (SW + SE corners)")
        else
            warn("[ToL] Map 2 ammo piles skipped — map2Room missing")
        end
    end


    ------------------------------------------------------------
    -- PICKUP + LOAD handlers
    ------------------------------------------------------------
    -- Per-player carry capacity. Default = DEFAULT_MAX_CARRY; can be raised by
    -- the AmmoCapacity special card (each pick adds +DEFAULT_MAX_CARRY to this).
    local DEFAULT_MAX_CARRY = 15

    local function getMaxCarry(player)
        return player:GetAttribute("MaxCarry") or DEFAULT_MAX_CARRY
    end

    -- Per-player guard: prevents stacking multiple rapid-pickup loops if the
    -- player taps E repeatedly. Maps userId → "pickup" or "load" or nil.
    local rapidActionInProgress = {}

    local RAPID_INTERVAL = 0.15  -- seconds between repeats

    -- Per-player state for the hold-to-pickup loop. holdActive[userId] = true
    -- while the loop should keep iterating; flipped false on hold end.
    local holdActive = {}

    -- Defensive: clear both guards if the player leaves mid-loop
    Players.PlayerRemoving:Connect(function(p)
        rapidActionInProgress[p.UserId] = nil
        holdActive[p.UserId] = nil
    end)

    -- Wire up pickup. The pickup loop runs only while E is HELD on the
    -- client. The client fires PickupHoldStart when E goes down near any
    -- pile, and PickupHoldStop on E release. Server runs the rapid-pickup
    -- loop between those events. This replaces an earlier ProximityPrompt
    -- HoldBegan/HoldEnded approach which fired spurious end events after
    -- Triggered completed, killing the loop while the player was still
    -- holding. ProximityPrompts on the piles are kept as visual hints only.
    pickupStartRemote.OnServerEvent:Connect(function(player)
        local userId = player.UserId
        if rapidActionInProgress[userId] then return end
        rapidActionInProgress[userId] = "pickup"
        holdActive[userId] = true
        task.spawn(function()
            while holdActive[userId] do
                local count = player:GetAttribute("CarryingAmmo") or 0
                local cap = getMaxCarry(player)
                if count >= cap then break end
                local char = player.Character
                local hrp = char and char:FindFirstChild("HumanoidRootPart")
                if not hrp then break end
                -- Find the closest pile within 12 studs. Player may be moving
                -- between piles mid-hold, so re-resolve each iteration rather
                -- than locking onto whichever pile fired first.
                local nearestPile = nil
                local nearestDist = 12
                for _, pile in ipairs(ammoPiles) do
                    local d = (hrp.Position - pile.glow.Position).Magnitude
                    if d <= nearestDist then
                        nearestPile = pile
                        nearestDist = d
                    end
                end
                if not nearestPile then break end
                player:SetAttribute("CarryingAmmo", count + 1)
                task.wait(RAPID_INTERVAL)
            end
            rapidActionInProgress[userId] = nil
            holdActive[userId] = nil
        end)
    end)

    pickupStopRemote.OnServerEvent:Connect(function(player)
        holdActive[player.UserId] = false
    end)

    -- Wire up load prompt on each tower. Each tap of E loads exactly ONE pack
    -- (+10 shots). Single-tap behavior — NOT a hold/repeat loop. The pickup
    -- side at the piles still uses the rapid-loop pattern (see above).
    local function wireTowerLoadPrompt(towerBase)
        local tower = towerBase.Parent
        if not tower then return end
        local prompt = towerBase:FindFirstChildOfClass("ProximityPrompt")
        if not prompt then return end
        prompt.Triggered:Connect(function(player)
            local count = player:GetAttribute("CarryingAmmo") or 0
            if count <= 0 then return end
            if not tower or not tower.Parent then return end
            local shots = tower:GetAttribute("Shots") or 0
            local maxShots = tower:GetAttribute("MaxShots") or 50
            if shots >= maxShots then return end
            local newShots = math.min(maxShots, shots + 10)
            tower:SetAttribute("Shots", newShots)
            player:SetAttribute("CarryingAmmo", count - 1)
        end)
    end

    for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
        wireTowerLoadPrompt(towerBase)
    end
    CollectionService:GetInstanceAddedSignal(Tags.Tower):Connect(wireTowerLoadPrompt)

    -- Each tower's load prompt is enabled only when:
    --   (a) a player carrying ≥1 pack is within 10 studs, AND
    --   (b) the tower isn't already full.
    -- Each pile's pickup prompt is enabled only when the nearby player isn't at carry cap.
    local LOAD_RANGE = 20  -- studs (doubled from 10)

    task.spawn(function()
        while true do
            task.wait(0.2)

            -- For each carrying player, find their CLOSEST non-full tower within range.
            -- Only that tower's prompt will be enabled (avoids multiple prompts overlapping).
            -- Ownership doesn't matter: any player can load any tower.
            local enabledTowers = {}  -- [towerBase] = true
            for _, p in ipairs(Players:GetPlayers()) do
                if (p:GetAttribute("CarryingAmmo") or 0) > 0 then
                    local char = p.Character
                    local hrp = char and char:FindFirstChild("HumanoidRootPart")
                    if hrp then
                        local bestBase, bestDist = nil, nil
                        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                            local tower = towerBase.Parent
                            if tower then
                                local shots = tower:GetAttribute("Shots") or 0
                                local maxShots = tower:GetAttribute("MaxShots") or 50
                                if shots < maxShots then
                                    local d = (hrp.Position - towerBase.Position).Magnitude
                                    if d <= LOAD_RANGE and (not bestDist or d < bestDist) then
                                        bestBase = towerBase
                                        bestDist = d
                                    end
                                end
                            end
                        end
                        if bestBase then enabledTowers[bestBase] = true end
                    end
                end
            end

            -- Apply enabled/disabled state to every tower's prompt
            for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
                local prompt = towerBase:FindFirstChildOfClass("ProximityPrompt")
                if prompt then
                    prompt.Enabled = enabledTowers[towerBase] == true
                end
            end

            -- Pile pickup prompts: disabled only when a nearby player is already at cap
            for _, pile in ipairs(ammoPiles) do
                local anyAtCapNearby = false
                for _, p in ipairs(Players:GetPlayers()) do
                    if (p:GetAttribute("CarryingAmmo") or 0) >= getMaxCarry(p) then
                        local char = p.Character
                        local hrp = char and char:FindFirstChild("HumanoidRootPart")
                        if hrp and (hrp.Position - pile.glow.Position).Magnitude <= 12 then
                            anyAtCapNearby = true
                            break
                        end
                    end
                end
                pile.prompt.Enabled = not anyAtCapNearby
            end
        end
    end)
end

return Ammo
