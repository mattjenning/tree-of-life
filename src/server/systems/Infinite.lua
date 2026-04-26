--[[
    Infinite.lua — Phase 1 of the Infinite Arena (balance/benchmark
    sandbox per project_infinite_arena.md).

    OWNS:
    - Lazy-built pickle dimension geometry (a small floating arena far
      from existing maps so the unified grid + lighting don't collide).
    - The hub portal touch handler: fires EnterInfinite cinematic to
      the client, then teleports the player into the dimension.
    - The return portal touch handler: fires ExitInfinite, teleports
      back to the hub spawn.

    NOT YET (B2 follow-up):
    - Mob spawning / wave loop / tower placement / heart / StatLedger
      summary. Tonight's deliverable is the entry/exit loop only —
      proves the cinematic + teleport plumbing.

    setup(ctx) reads:
      ctx.HUB_SPAWN_CF (or falls back to a default near the clearing)

    Publishes:
      ctx.enterInfinite(player)  — orchestrate entry from hub
      ctx.exitInfinite(player)   — orchestrate return to hub
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local Infinite = {}

-- Pickle dimension lives far from the existing maps so its grid /
-- lighting never collides. Y is high so the player's "drop through
-- the ground" reads as a real fall rather than a simple teleport
-- (the cinematic camera fades during the descent).
local DIMENSION_CENTER = Vector3.new(8000, 1000, 0)
local FLOOR_SIZE       = Vector3.new(120, 1, 120)
local SPAWN_OFFSET     = Vector3.new(0, 4, 0)        -- character lands 4 stud above floor
local RETURN_OFFSET    = Vector3.new(0, 0.5, 40)     -- exit portal sits 40 stud +Z from arena center
-- Cinematic timing — client owns the fade; server teleports halfway
-- through so the screen is dark when the character moves and the
-- "lands in a new place" reveal happens during the fade-in.
local ENTRY_FADE_OUT_SEC = 0.8
local EXIT_FADE_OUT_SEC  = 0.6

local dimensionBuilt = false
local exitPortalDisc: Part? = nil

local function buildDimension()
    if dimensionBuilt then return end
    dimensionBuilt = true

    local arena = Instance.new("Model")
    arena.Name = "PickleDimension"
    arena.Parent = Workspace

    -- Floor — dark green-gray, slightly irregular tone so it doesn't
    -- read as a flat console-test plane. Future: replace with an
    -- actual hex-tile arena or pickle-themed surface.
    local floor = Instance.new("Part")
    floor.Name = "PickleDimensionFloor"
    floor.Anchored = true
    floor.CanCollide = true
    floor.Size = FLOOR_SIZE
    floor.CFrame = CFrame.new(DIMENSION_CENTER + Vector3.new(0, -0.5, 0))
    floor.Material = Enum.Material.Slate
    floor.Color = Color3.fromRGB(40, 50, 35)
    floor.Parent = arena

    -- Atmospheric green light so the dimension reads as the same
    -- visual family as the hub portal + Pickle Lord himself.
    local skyboxTone = Instance.new("Part")
    skyboxTone.Name = "AmbientGlow"
    skyboxTone.Anchored = true
    skyboxTone.CanCollide = false
    skyboxTone.Size = Vector3.new(2, 2, 2)
    skyboxTone.Transparency = 1
    skyboxTone.CFrame = CFrame.new(DIMENSION_CENTER + Vector3.new(0, 30, 0))
    skyboxTone.Parent = arena
    local light = Instance.new("PointLight")
    light.Color = Color3.fromRGB(120, 220, 130)
    light.Brightness = 2
    light.Range = 80
    light.Parent = skyboxTone

    -- Return portal — same swirling-green family as the hub portal.
    local exitPos = DIMENSION_CENTER + RETURN_OFFSET
    local outerRing = Instance.new("Part")
    outerRing.Name = "ReturnPortalOuterRing"
    outerRing.Shape = Enum.PartType.Cylinder
    outerRing.Anchored = true
    outerRing.CanCollide = false
    outerRing.Size = Vector3.new(0.3, 14, 14)
    outerRing.CFrame = CFrame.new(exitPos) * CFrame.Angles(0, 0, math.rad(90))
    outerRing.Material = Enum.Material.Neon
    outerRing.Color = Color3.fromRGB(80, 220, 100)
    outerRing.Transparency = 0.35
    outerRing.Parent = arena

    local disc = Instance.new("Part")
    disc.Name = "ReturnPortalDisc"
    disc.Shape = Enum.PartType.Cylinder
    disc.Anchored = true
    disc.CanCollide = false
    disc.Size = Vector3.new(0.4, 10, 10)
    disc.CFrame = CFrame.new(exitPos + Vector3.new(0, 0.1, 0))
              * CFrame.Angles(0, 0, math.rad(90))
    disc.Material = Enum.Material.Neon
    disc.Color = Color3.fromRGB(60, 255, 110)
    disc.Transparency = 0.15
    disc.Parent = arena
    exitPortalDisc = disc

    -- Floating "RETURN TO HUB" label above the exit portal — leaves
    -- no ambiguity about what tapping the swirl does in v0.
    local labelAnchor = Instance.new("Part")
    labelAnchor.Name = "ReturnLabelAnchor"
    labelAnchor.Anchored = true
    labelAnchor.CanCollide = false
    labelAnchor.Size = Vector3.new(0.2, 0.2, 0.2)
    labelAnchor.Transparency = 1
    labelAnchor.CFrame = CFrame.new(exitPos + Vector3.new(0, 6, 0))
    labelAnchor.Parent = arena
    local billboard = Instance.new("BillboardGui")
    billboard.Size = UDim2.fromOffset(220, 50)
    billboard.LightInfluence = 0
    billboard.AlwaysOnTop = true
    billboard.MaxDistance = 200
    billboard.Parent = labelAnchor
    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Text = "RETURN TO HUB"
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 28
    label.TextColor3 = Color3.fromRGB(220, 255, 230)
    label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    label.TextStrokeTransparency = 0.4
    label.Parent = billboard

    print("[Infinite] pickle dimension built at "
        .. tostring(DIMENSION_CENTER) .. " (model: " .. arena.Name .. ")")
end

function Infinite.setup(ctx)
    -- Hub-spawn fallback: if ctx didn't publish HUB_SPAWN_CF, point at
    -- a sensible location near the clearing. The hub orchestrator
    -- normally publishes ctx.HUB_SPAWN_CF; this is a defensive default.
    local function getHubSpawnCF(): CFrame
        return ctx.HUB_SPAWN_CF or CFrame.new(0, 5, 5)
    end

    local enterRemote = Remotes.getOrCreate(Remotes.Names.EnterInfinite, "RemoteEvent")
    local exitRemote  = Remotes.getOrCreate(Remotes.Names.ExitInfinite, "RemoteEvent")

    local function teleportTo(player: Player, cf: CFrame)
        local character = player.Character
        if not character then return end
        local hrp = character:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        hrp.CFrame = cf
    end

    local function enter(player: Player)
        if not player or not player.Parent then return end
        buildDimension()
        -- Fire the cinematic FIRST so the client's fade-to-black
        -- starts before the teleport. Sleep half the fade so the
        -- screen is dark when the character moves.
        enterRemote:FireClient(player, {
            fadeOutSec  = ENTRY_FADE_OUT_SEC,
            holdSec     = 0.4,
            fadeInSec   = 0.8,
        })
        task.delay(ENTRY_FADE_OUT_SEC * 0.6, function()
            teleportTo(player, CFrame.new(DIMENSION_CENTER + SPAWN_OFFSET))
        end)
        print(("[Infinite] %s entered the pickle dimension"):format(player.Name))
    end

    local function exit(player: Player)
        if not player or not player.Parent then return end
        exitRemote:FireClient(player, {
            fadeOutSec = EXIT_FADE_OUT_SEC,
            holdSec    = 0.3,
            fadeInSec  = 0.6,
        })
        task.delay(EXIT_FADE_OUT_SEC * 0.6, function()
            teleportTo(player, getHubSpawnCF())
        end)
        print(("[Infinite] %s returned to hub"):format(player.Name))
    end

    -- Wire the return portal — but only after the dimension is built.
    -- We connect Touched lazily (inside enter()) so the per-frame
    -- Heartbeat / Touched setup cost is only paid once any player
    -- has actually entered.
    local returnTouchedConnected = false
    local function connectReturnTouched()
        if returnTouchedConnected or not exitPortalDisc then return end
        returnTouchedConnected = true
        local lastExitAt = {}  -- per-player os.clock() debounce
        exitPortalDisc.Touched:Connect(function(other)
            if not other or not other.Parent then return end
            if other.Name ~= "HumanoidRootPart" then return end
            local player = Players:GetPlayerFromCharacter(other.Parent)
            if not player then return end
            local now = os.clock()
            if now - (lastExitAt[player.UserId] or 0) < 1.0 then return end
            lastExitAt[player.UserId] = now
            exit(player)
        end)
    end

    -- Patch enter() to also wire the return-touch on first entry.
    local rawEnter = enter
    enter = function(player)
        rawEnter(player)
        connectReturnTouched()
    end

    -- Hub portal Touched is wired in HubWorld.lua but ALSO fires
    -- EnterInfinite directly to the client for the cinematic. We
    -- ALSO listen here so the server-side teleport happens — the
    -- HubWorld touch handler signals via the remote, we hear it
    -- via OnServerEvent (client just bounces the signal back).
    --
    -- Simpler architecture: HubWorld fires a server-side bindable.
    -- We expose ctx.enterInfinite as the canonical entry function
    -- so HubWorld can call it directly without any remote ping-pong.
    ctx.enterInfinite = enter
    ctx.exitInfinite  = exit

    print("[Infinite] system online (Workspace.InfiniteUnlocked = "
        .. tostring(Workspace:GetAttribute("InfiniteUnlocked")) .. ")")
end

return Infinite
