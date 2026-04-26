--[[
    Infinite.lua — Phase 1 of the Infinite Arena (balance/benchmark
    sandbox per project_infinite_arena.md).

    OWNS:
    - Hub-portal entry handler: fires EnterInfinite cinematic on the
      client, then teleports the player into the Map4 (Pickle Swamp)
      arena.
    - Return-portal lazy wiring: the swirling green disc inside the
      Map4 spawn area triggers ExitInfinite + teleport back to hub.

    Map4 terrain itself lives in src/server/world/Map4.lua and is
    built at server boot (so the dimension is ready before any
    player touches the hub portal).

    NOT YET (B2d follow-up):
    - Custom infinite wave spawner (no WAVES[4] table; instead a
      programmatic ramp that scales mob HP / count per round)
    - StatLedger summary print on heart death + auto-return to hub
    - Default Core loadout granted on entry

    setup(ctx) reads:
      ctx.MAP4_PLAYER_SPAWN_CF  (Map4 publishes this)
      ctx.HUB_SPAWN_CF          (Portal publishes this)
      ctx.map4Heart, ctx.map4Room

    Publishes:
      ctx.enterInfinite(player)
      ctx.exitInfinite(player)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local Infinite = {}

-- Cinematic timing — client owns the fade; server teleports halfway
-- through so the screen is dark when the character moves and the
-- "drops into a swamp" reveal happens during the fade-in.
local ENTRY_FADE_OUT_SEC = 0.8
local EXIT_FADE_OUT_SEC  = 0.6

-- Lazy-wired return portal (spawned next to the Map4 player spawn).
-- Built on first entry so it adopts the Map4 terrain's lighting
-- without an extra setup phase.
local returnPortalSetup = false

local function setupReturnPortal(map4Room: Model, spawnCF: CFrame, exitCallback: (Player) -> ())
    if returnPortalSetup then return end
    returnPortalSetup = true

    -- Place return portal a few stud +X from the player-spawn so it's
    -- the first thing they see on landing. Match the hub portal's
    -- visual (outer ring + inner disc + glowing label).
    local pos = spawnCF.Position + Vector3.new(6, -3, 0)

    local outerRing = Instance.new("Part")
    outerRing.Name = "ReturnPortalOuterRing"
    outerRing.Shape = Enum.PartType.Cylinder
    outerRing.Anchored = true
    outerRing.CanCollide = false
    outerRing.Size = Vector3.new(0.3, 14, 14)
    outerRing.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
    outerRing.Material = Enum.Material.Neon
    outerRing.Color = Color3.fromRGB(80, 220, 100)
    outerRing.Transparency = 0.35
    outerRing.Parent = map4Room

    local disc = Instance.new("Part")
    disc.Name = "ReturnPortalDisc"
    disc.Shape = Enum.PartType.Cylinder
    disc.Anchored = true
    disc.CanCollide = false
    disc.Size = Vector3.new(0.4, 10, 10)
    disc.CFrame = CFrame.new(pos + Vector3.new(0, 0.1, 0))
              * CFrame.Angles(0, 0, math.rad(90))
    disc.Material = Enum.Material.Neon
    disc.Color = Color3.fromRGB(60, 255, 110)
    disc.Transparency = 0.15
    disc.Parent = map4Room

    -- Floating "RETURN TO HUB" label.
    local labelAnchor = Instance.new("Part")
    labelAnchor.Name = "ReturnLabelAnchor"
    labelAnchor.Anchored = true
    labelAnchor.CanCollide = false
    labelAnchor.Size = Vector3.new(0.2, 0.2, 0.2)
    labelAnchor.Transparency = 1
    labelAnchor.CFrame = CFrame.new(pos + Vector3.new(0, 6, 0))
    labelAnchor.Parent = map4Room
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

    -- Touched handler with per-player 1s debounce.
    local lastExitAt = {}
    disc.Touched:Connect(function(other)
        if not other or not other.Parent then return end
        if other.Name ~= "HumanoidRootPart" then return end
        local player = Players:GetPlayerFromCharacter(other.Parent)
        if not player then return end
        local now = os.clock()
        if now - (lastExitAt[player.UserId] or 0) < 1.0 then return end
        lastExitAt[player.UserId] = now
        exitCallback(player)
    end)

    print("[Infinite] return portal wired in pickle dimension")
end

function Infinite.setup(ctx)
    local function getHubSpawnCF(): CFrame
        return ctx.HUB_SPAWN_CF or CFrame.new(0, 5, 5)
    end
    local function getMap4SpawnCF(): CFrame
        return ctx.MAP4_PLAYER_SPAWN_CF or CFrame.new(8000, 105, 0)
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

    local function enter(player: Player)
        if not player or not player.Parent then return end
        if ctx.map4Room then
            setupReturnPortal(ctx.map4Room, getMap4SpawnCF(), exit)
        end
        enterRemote:FireClient(player, {
            fadeOutSec  = ENTRY_FADE_OUT_SEC,
            holdSec     = 0.4,
            fadeInSec   = 0.8,
        })
        task.delay(ENTRY_FADE_OUT_SEC * 0.6, function()
            teleportTo(player, getMap4SpawnCF())
        end)
        print(("[Infinite] %s entered the pickle dimension"):format(player.Name))
    end

    ctx.enterInfinite = enter
    ctx.exitInfinite  = exit

    print("[Infinite] system online (Workspace.InfiniteUnlocked = "
        .. tostring(workspace:GetAttribute("InfiniteUnlocked")) .. ")")
end

return Infinite
