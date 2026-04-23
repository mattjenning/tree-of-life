--[[
    TdRoom.lua — Tower-defense room (map 1) construction: floor, four
    walls, sculpted ceiling balls, four neon light shafts, atmospheric
    fill light.

    setup(ctx) reads module-level constants + helpers from ctx and
    publishes the handles downstream code needs:
      ctx.tdRoom  -- Model, parent for towers/decor/ammo piles
      ctx.rc      -- Vector3, room center (used by grid math, ammo
                     placement, tower range checks, stage decor)
      ctx.halfW   -- number, TD_ROOM_WIDTH / 2  (used by the same)
      ctx.halfD   -- number, TD_ROOM_DEPTH / 2
      ctx.floor   -- Part, TDFloor — tweened by StageVisuals

    Constants read from ctx (set by the hub orchestrator):
      TD_ROOM_CENTER, TD_ROOM_WIDTH, TD_ROOM_DEPTH, TD_ROOM_HEIGHT,
      TD_WALL_THICK

    Helpers read from ctx:
      makePart
]]

local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tags = require(Shared:WaitForChild("Tags"))

local TdRoom = {}

function TdRoom.setup(ctx)
    local TD_ROOM_CENTER = ctx.TD_ROOM_CENTER
    local TD_ROOM_WIDTH  = ctx.TD_ROOM_WIDTH
    local TD_ROOM_DEPTH  = ctx.TD_ROOM_DEPTH
    local TD_ROOM_HEIGHT = ctx.TD_ROOM_HEIGHT
    local TD_WALL_THICK  = ctx.TD_WALL_THICK

    local makePart = ctx.makePart

    local tdRoom = Instance.new("Model")
    tdRoom.Name = "TreeOfLifeTDRoom"
    tdRoom.Parent = Workspace

    local rc = TD_ROOM_CENTER
    local halfW = TD_ROOM_WIDTH / 2
    local halfD = TD_ROOM_DEPTH / 2

    local floor = makePart({
        Name = "TDFloor",
        Size = Vector3.new(TD_ROOM_WIDTH, 2, TD_ROOM_DEPTH),
        CFrame = CFrame.new(rc),
        Material = Enum.Material.WoodPlanks,
        Color = Color3.fromRGB(130, 90, 55),
        Parent = tdRoom,
    })
    CollectionService:AddTag(floor, Tags.TDFloor)

    makePart({
        Name = "TDWallWest",
        Size = Vector3.new(TD_WALL_THICK, TD_ROOM_HEIGHT, TD_ROOM_DEPTH + TD_WALL_THICK * 2),
        CFrame = CFrame.new(rc + Vector3.new(-halfW - TD_WALL_THICK/2, TD_ROOM_HEIGHT/2, 0)),
        Material = Enum.Material.Wood,
        Color = Color3.fromRGB(105, 70, 42),
        Parent = tdRoom,
    })
    makePart({
        Name = "TDWallEast",
        Size = Vector3.new(TD_WALL_THICK, TD_ROOM_HEIGHT, TD_ROOM_DEPTH + TD_WALL_THICK * 2),
        CFrame = CFrame.new(rc + Vector3.new(halfW + TD_WALL_THICK/2, TD_ROOM_HEIGHT/2, 0)),
        Material = Enum.Material.Wood,
        Color = Color3.fromRGB(105, 70, 42),
        Parent = tdRoom,
    })
    makePart({
        Name = "TDWallNorth",
        Size = Vector3.new(TD_ROOM_WIDTH + TD_WALL_THICK * 2, TD_ROOM_HEIGHT, TD_WALL_THICK),
        CFrame = CFrame.new(rc + Vector3.new(0, TD_ROOM_HEIGHT/2, -halfD - TD_WALL_THICK/2)),
        Material = Enum.Material.Wood,
        Color = Color3.fromRGB(100, 66, 40),
        Parent = tdRoom,
    })
    makePart({
        Name = "TDWallSouth",
        Size = Vector3.new(TD_ROOM_WIDTH + TD_WALL_THICK * 2, TD_ROOM_HEIGHT, TD_WALL_THICK),
        CFrame = CFrame.new(rc + Vector3.new(0, TD_ROOM_HEIGHT/2, halfD + TD_WALL_THICK/2)),
        Material = Enum.Material.Wood,
        Color = Color3.fromRGB(100, 66, 40),
        Parent = tdRoom,
    })

    local ceilRowsX = 6
    local ceilRowsZ = 5
    for ix = 0, ceilRowsX - 1 do
        for iz = 0, ceilRowsZ - 1 do
            local px = -halfW + (ix + 0.5) * (TD_ROOM_WIDTH / ceilRowsX)
            local pz = -halfD + (iz + 0.5) * (TD_ROOM_DEPTH / ceilRowsZ)
            makePart({
                Name = "TDCeiling",
                Shape = Enum.PartType.Ball,
                Size = Vector3.new(24, 14, 24),
                CFrame = CFrame.new(rc + Vector3.new(px, TD_ROOM_HEIGHT + 2, pz)),
                Material = Enum.Material.Wood,
                Color = Color3.fromRGB(80, 52, 30):Lerp(Color3.fromRGB(95, 62, 38), math.random()),
                Parent = tdRoom,
            })
        end
    end

    local shaftSpots = {
        Vector3.new(-25,  TD_ROOM_HEIGHT - 5, -15),
        Vector3.new( 25,  TD_ROOM_HEIGHT - 5, -15),
        Vector3.new(-25,  TD_ROOM_HEIGHT - 5,  15),
        Vector3.new( 25,  TD_ROOM_HEIGHT - 5,  15),
    }
    for _, offset in ipairs(shaftSpots) do
        local shaft = makePart({
            Name = "TDLightShaft",
            Size = Vector3.new(6, TD_ROOM_HEIGHT - 6, 6),
            CFrame = CFrame.new(rc + offset),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(255, 235, 180),
            Transparency = 0.88,
            CanCollide = false,
            CastShadow = false,
            Parent = tdRoom,
        })
        local pl = Instance.new("PointLight")
        pl.Color = Color3.fromRGB(255, 220, 160)
        pl.Brightness = 1.5
        pl.Range = 30
        pl.Parent = shaft
    end

    local fillAnchor = makePart({
        Name = "TDFillAnchor",
        Size = Vector3.new(1,1,1),
        CFrame = CFrame.new(rc + Vector3.new(0, TD_ROOM_HEIGHT * 0.6, 0)),
        Transparency = 1,
        CanCollide = false,
        Parent = tdRoom,
    })
    local fillLight = Instance.new("PointLight")
    fillLight.Color = Color3.fromRGB(255, 210, 150)
    fillLight.Brightness = 2
    fillLight.Range = 120
    fillLight.Parent = fillAnchor

    -- Publish fields downstream modules + hub code need.
    ctx.tdRoom = tdRoom
    ctx.rc = rc
    ctx.halfW = halfW
    ctx.halfD = halfD
    ctx.floor = floor
end

return TdRoom
