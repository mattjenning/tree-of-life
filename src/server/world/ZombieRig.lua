--[[
    ZombieRig.lua — buildable R6 zombie rig for Lily to animate.

    Why a Lua builder (and not an .rbxmx asset committed to source):
    Rojo doesn't great-cleanly round-trip Studio-built models —
    we'd lose the rig if anyone re-saved the place. Building the
    rig in code on server boot guarantees Lily always sees the
    canonical version when she opens the running game in Studio.

    LILY'S ANIMATION WORKFLOW (EDIT MODE — important):
      The Animation Editor is hidden during runtime (Roblox Studio
      limitation), so animations are authored in EDIT MODE. The
      sequence:

        1. With Studio in EDIT mode (game NOT running, Rojo
           connected), open View → Command Bar.
        2. Paste this one-liner and press Enter — it drops a
           fresh anchored rig into Workspace:

           require(game:GetService("ServerScriptService"):WaitForChild("world"):WaitForChild("ZombieRig")).installEdit()

        3. The rig appears in Workspace (anchored, won't fall).
        4. Click ZombieRig in Workspace, open the Animation
           Editor (Avatar tab → Animation Editor, or Plugins →
           Animation Editor).
        5. Animate (idle / walk / attack / death). Save each
           animation to Roblox cloud — Studio gives you a
           numeric asset ID per save.
        6. Paste each ID into Config.ZombieAnimations:
              Stage.Idle   = "rbxassetid://1234567890"
              Stage.Walk   = "rbxassetid://1234567891"
              Stage.Attack = "rbxassetid://1234567892"
              Stage.Death  = "rbxassetid://1234567893"
           Boss anims (Mold King variant) fall back to Stage
           anims if left empty — ship Stage first.
        7. Re-run the command-bar snippet from step 2 any time you
           need a fresh rig (it auto-deletes the old one). The
           rig in Workspace can be deleted before saving the
           place file — it's just a scratch instance for the
           Animation Editor.

      For RUNTIME preview only (NOT animation): the sample copy at
      ReplicatedStorage.Models.ZombieRig (built by installSample on
      server boot) lets you eyeball the rig while playing. Animation
      Editor doesn't work on it.

    THE RIG:
      Standard R6 layout (HumanoidRootPart + Torso + Head + 2 arms
      + 2 legs, Motor6D-jointed). The Animation Editor expects R6
      part names + joint names exactly (e.g. "Right Shoulder"); we
      match them so Roblox's built-in idle/walk/run can also drive
      the rig if no custom anim is loaded.

      Sizes match the standard R6 character. Colors: sickly
      green-tan flesh + dark torn-cloth legs. Material: Slate
      (rough, "rotting flesh" feel).

    PUBLIC API:
      ZombieRig.build()           -> Model
        Returns a fresh, unanchored, jointed rig at origin. The
        Humanoid takes ownership; caller PivotTo's a spawn point.

      ZombieRig.installSample()
        Places ONE static, anchored copy in
        ReplicatedStorage.Models.ZombieRig. Idempotent — replaces
        any prior copy. Called once on server boot from
        TreeOfLife_Hub. NOTE: this is a RUNTIME-only reference;
        for animation work use installEdit() in the Command Bar.

      ZombieRig.installEdit()
        Edit-mode helper for Lily's animation flow. Drops a
        fresh rig into Workspace.ZombieRig, anchored. Replaces
        any prior copy in Workspace. The Animation Editor is
        edit-mode-only, so this is what Lily runs from the
        Studio Command Bar to get a riggable rig.

    Future spawn integration (follow-up commit, NOT this one):
      MobFactory will clone this rig (per-mob), un-anchor
      parts, swap to MobUpdate's CFrame-driver path on the
      HumanoidRootPart. Stage-boss = default size + flesh colors;
      map-1 boss = 2.2x scale + purple flesh.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZombieRig = {}

-- Standard R6 part sizes. The Animation Editor relies on these
-- names + sizes to display the joint manipulator handles correctly.
local PART_SIZE = {
    HumanoidRootPart = Vector3.new(2, 2, 1),
    Head             = Vector3.new(2, 1, 1),
    Torso            = Vector3.new(2, 2, 1),
    ["Left Arm"]     = Vector3.new(1, 2, 1),
    ["Right Arm"]    = Vector3.new(1, 2, 1),
    ["Left Leg"]     = Vector3.new(1, 2, 1),
    ["Right Leg"]    = Vector3.new(1, 2, 1),
}

-- Palette: sickly zombie green-tan flesh, dark torn-cloth pants.
local FLESH       = Color3.fromRGB(140, 165, 100)
local FLESH_DARK  = Color3.fromRGB(105, 130,  70)
local CLOTH_DARK  = Color3.fromRGB( 50,  45,  35)

-- Cardboard pickle costume — flat sandwich-board panels worn
-- front + back. "Cardboard pickle" reads as: cardboard painted to
-- look like a pickle, so the color is pickle-green with a slight
-- tan undertone, Material = SmoothPlastic for the matte cardboard
-- feel (Wood texture would read as actual wood, not paint).
local CARDBOARD_GREEN      = Color3.fromRGB(110, 165,  75)
local CARDBOARD_GREEN_DARK = Color3.fromRGB( 75, 125,  55)  -- stem
local CARDBOARD_DEPTH      = 0.3                            -- flat-board thickness
local CARDBOARD_W          = 4.0                            -- wider than torso (2)
local CARDBOARD_OFFSET_Z   = 0.7                            -- in front / behind torso

-- FACE HOLE — region of the front cardboard cut out so the head
-- shows through. Layout in torso-local coords (Y=0 at torso center,
-- head at Y=+1.5):
--    Y=+1.0 to +2.2   (slightly taller than the head's +1..+2)
--    X=-1.2 to +1.2   (slightly wider than head's -1..+1)
local FACE_HOLE_BOTTOM = 1.0
local FACE_HOLE_TOP    = 2.2
local FACE_HOLE_HALF_W = 1.2

local function makePart(name, color, material)
    local p = Instance.new("Part")
    p.Name = name
    p.Size = PART_SIZE[name]
    p.Color = color
    p.Material = material or Enum.Material.Slate
    p.TopSurface = Enum.SurfaceType.Smooth
    p.BottomSurface = Enum.SurfaceType.Smooth
    p.CanCollide = false                -- Humanoid handles collision via HRP
    p.Anchored = false                  -- Humanoid drives motion
    return p
end

local function makeMotor(name, part0, part1, c0, c1)
    local m = Instance.new("Motor6D")
    m.Name = name
    m.Part0 = part0
    m.Part1 = part1
    m.C0 = c0
    m.C1 = c1
    m.Parent = part0
    return m
end

function ZombieRig.build()
    local model = Instance.new("Model")
    model.Name = "ZombieRig"

    -- Build all 7 parts.
    local hrp      = makePart("HumanoidRootPart", FLESH)
    hrp.Transparency = 1                -- HRP is always invisible (R6 standard)
    local torso    = makePart("Torso",     FLESH_DARK)
    local head     = makePart("Head",      FLESH)
    local lArm     = makePart("Left Arm",  FLESH)
    local rArm     = makePart("Right Arm", FLESH)
    local lLeg     = makePart("Left Leg",  CLOTH_DARK)
    local rLeg     = makePart("Right Leg", CLOTH_DARK)
    for _, p in ipairs({ hrp, torso, head, lArm, rArm, lLeg, rLeg }) do
        p.Parent = model
    end

    -- T-pose layout. The animation editor handles all subsequent
    -- pose changes; the layout here only matters for the rig's
    -- "rest" frame. Y=0 sits at HRP center; legs hang below, head
    -- floats above the torso.
    hrp.CFrame   = CFrame.new( 0,    0, 0)
    torso.CFrame = CFrame.new( 0,    0, 0)
    head.CFrame  = CFrame.new( 0,  1.5, 0)
    lArm.CFrame  = CFrame.new(-1.5, 0,  0)
    rArm.CFrame  = CFrame.new( 1.5, 0,  0)
    lLeg.CFrame  = CFrame.new(-0.5, -2, 0)
    rLeg.CFrame  = CFrame.new( 0.5, -2, 0)

    -- Motor6D joints. R6 standard naming + offsets so the Animation
    -- Editor recognizes the rig as a valid R6.
    --
    -- C0/C1 here describe each joint's local "rest" pose. Roblox
    -- conventions:
    --   - Limb-on-torso joints face outward via the Y-axis flip
    --     baked into the C0 angle (math.pi/2 around Y).
    --   - Animation poses then add rotation deltas on top.
    makeMotor("RootJoint", hrp, torso,
              CFrame.new(0, 0, 0) * CFrame.Angles(0,  math.pi, 0),
              CFrame.new(0, 0, 0) * CFrame.Angles(0,  math.pi, 0))
    makeMotor("Neck", torso, head,
              CFrame.new(0,  1.0, 0) * CFrame.Angles(0,  math.pi, 0),
              CFrame.new(0, -0.5, 0) * CFrame.Angles(0,  math.pi, 0))
    makeMotor("Left Shoulder", torso, lArm,
              CFrame.new(-1.0,  0.5, 0) * CFrame.Angles(0, -math.pi / 2, 0),
              CFrame.new( 0.5,  0.5, 0) * CFrame.Angles(0, -math.pi / 2, 0))
    makeMotor("Right Shoulder", torso, rArm,
              CFrame.new( 1.0,  0.5, 0) * CFrame.Angles(0,  math.pi / 2, 0),
              CFrame.new(-0.5,  0.5, 0) * CFrame.Angles(0,  math.pi / 2, 0))
    makeMotor("Left Hip", torso, lLeg,
              CFrame.new(-0.5, -1.0, 0) * CFrame.Angles(0, -math.pi / 2, 0),
              CFrame.new( 0,    1.0, 0) * CFrame.Angles(0, -math.pi / 2, 0))
    makeMotor("Right Hip", torso, rLeg,
              CFrame.new( 0.5, -1.0, 0) * CFrame.Angles(0,  math.pi / 2, 0),
              CFrame.new( 0,    1.0, 0) * CFrame.Angles(0,  math.pi / 2, 0))

    -- CARDBOARD PICKLE COSTUME — sandwich-board panels worn front +
    -- back. The FRONT is built as a 4-piece "frame" around a face
    -- hole (top + bottom + left strip + right strip) so the head
    -- shows through; the BACK is one solid pickle silhouette.
    -- Each panel welds to the torso via WeldConstraint so it
    -- rotates with the torso during animation.
    local function makeCardboard(name, size, cf, color)
        local part = Instance.new("Part")
        part.Name = name
        part.Size = size
        part.CFrame = cf
        part.Color = color or CARDBOARD_GREEN
        part.Material = Enum.Material.SmoothPlastic
        part.TopSurface = Enum.SurfaceType.Smooth
        part.BottomSurface = Enum.SurfaceType.Smooth
        part.CanCollide = false
        part.Anchored = false
        part.Massless = true                            -- don't unbalance the Humanoid
        part.Parent = model
        return part
    end
    local function weldTo(parent, child)
        local w = Instance.new("WeldConstraint")
        w.Part0 = parent
        w.Part1 = child
        w.Parent = child
    end

    -- Vertical extent of the costume. Top extends above the head
    -- (so the pickle "arches over" the face hole); bottom extends
    -- below the torso to skirt-level.
    local TOP_Y    = FACE_HOLE_TOP + 0.65       -- ~2.85
    local BOT_Y    = -3.0
    local TOP_H    = (3.5 - FACE_HOLE_TOP)      -- 1.3
    local BOT_H    = (FACE_HOLE_BOTTOM - BOT_Y) -- 4.0
    local STRIP_W  = (CARDBOARD_W * 0.5) - FACE_HOLE_HALF_W   -- 0.8
    local STRIP_H  = (FACE_HOLE_TOP - FACE_HOLE_BOTTOM)        -- 1.2
    local STRIP_X  = (CARDBOARD_W * 0.5) - (STRIP_W * 0.5)     -- 1.6

    -- Front frame: 4 pieces around the face hole.
    local frontTop = makeCardboard("FrontTop",
        Vector3.new(CARDBOARD_W, TOP_H, CARDBOARD_DEPTH),
        CFrame.new(0, TOP_Y, -CARDBOARD_OFFSET_Z))
    local frontBottom = makeCardboard("FrontBottom",
        Vector3.new(CARDBOARD_W, BOT_H, CARDBOARD_DEPTH),
        CFrame.new(0, (BOT_Y + FACE_HOLE_BOTTOM) * 0.5, -CARDBOARD_OFFSET_Z))
    local frontLeft = makeCardboard("FrontLeftStrip",
        Vector3.new(STRIP_W, STRIP_H, CARDBOARD_DEPTH),
        CFrame.new(-STRIP_X, (FACE_HOLE_BOTTOM + FACE_HOLE_TOP) * 0.5,
                   -CARDBOARD_OFFSET_Z))
    local frontRight = makeCardboard("FrontRightStrip",
        Vector3.new(STRIP_W, STRIP_H, CARDBOARD_DEPTH),
        CFrame.new( STRIP_X, (FACE_HOLE_BOTTOM + FACE_HOLE_TOP) * 0.5,
                   -CARDBOARD_OFFSET_Z))

    -- Back: single solid pickle silhouette spanning the full extent.
    local backH = (3.5 - BOT_Y)                          -- 6.5
    local backY = (3.5 + BOT_Y) * 0.5                    -- 0.25
    local back = makeCardboard("BackPickle",
        Vector3.new(CARDBOARD_W, backH, CARDBOARD_DEPTH),
        CFrame.new(0, backY, CARDBOARD_OFFSET_Z))

    -- Pickle stems: small darker blocks on top of the front-top
    -- and back panels to reinforce the pickle silhouette.
    local frontStem = makeCardboard("FrontStem",
        Vector3.new(0.5, 0.5, CARDBOARD_DEPTH),
        CFrame.new(0, 3.65, -CARDBOARD_OFFSET_Z),
        CARDBOARD_GREEN_DARK)
    local backStem = makeCardboard("BackStem",
        Vector3.new(0.5, 0.5, CARDBOARD_DEPTH),
        CFrame.new(0, 3.65, CARDBOARD_OFFSET_Z),
        CARDBOARD_GREEN_DARK)

    for _, panel in ipairs({
        frontTop, frontBottom, frontLeft, frontRight,
        back, frontStem, backStem,
    }) do
        weldTo(torso, panel)
    end

    -- SMILEY FACE — SurfaceGui on the head's front face. Two black
    -- circle-Frames for eyes + one rounded rectangle Frame for the
    -- mouth. Drawn at runtime via UICorner-radius=50% so we don't
    -- depend on an external image asset; Lily can swap to a
    -- hand-drawn Decal later if she wants.
    local faceGui = Instance.new("SurfaceGui")
    faceGui.Name = "SmileyFace"
    faceGui.Face = Enum.NormalId.Front
    faceGui.LightInfluence = 0                          -- always full bright
    faceGui.PixelsPerStud = 50
    faceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
    faceGui.Parent = head

    local function makeEye(xScale)
        local eye = Instance.new("Frame")
        eye.Size = UDim2.fromScale(0.18, 0.20)
        eye.AnchorPoint = Vector2.new(0.5, 0.5)
        eye.Position = UDim2.fromScale(xScale, 0.40)
        eye.BackgroundColor3 = Color3.new(0, 0, 0)
        eye.BorderSizePixel = 0
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0.5, 0)
        c.Parent = eye
        eye.Parent = faceGui
    end
    makeEye(0.30)
    makeEye(0.70)

    local mouth = Instance.new("Frame")
    mouth.Name = "Mouth"
    mouth.Size = UDim2.fromScale(0.50, 0.10)
    mouth.AnchorPoint = Vector2.new(0.5, 0.5)
    mouth.Position = UDim2.fromScale(0.5, 0.72)
    mouth.BackgroundColor3 = Color3.new(0, 0, 0)
    mouth.BorderSizePixel = 0
    local mc = Instance.new("UICorner")
    mc.CornerRadius = UDim.new(0.5, 0)
    mc.Parent = mouth
    mouth.Parent = faceGui

    -- Humanoid: standard R6, so the Animation Editor recognises
    -- the rig and Roblox's built-in animations (idle, walk, run)
    -- can drive it as a fallback.
    local hum = Instance.new("Humanoid")
    hum.RigType = Enum.HumanoidRigType.R6
    hum.MaxHealth = 100
    hum.Health = 100
    hum.WalkSpeed = 8
    hum.JumpPower = 0                   -- zombies don't jump
    hum.AutoRotate = true
    hum.Parent = model

    model.PrimaryPart = hrp
    return model
end

-- Anchor ONLY the HumanoidRootPart; force all other parts to
-- Anchored=false. Standard R6 convention: HRP is the rig's "physics
-- handle"; limbs hang off it via Motor6Ds.
--
-- The Animation Editor refuses to open a rig where EVERY part is
-- anchored ("All of the parts on this model are anchored, making
-- it non-animatable"). We assert the correct shape on every install
-- so a stale Workspace copy or a Studio cache quirk can't leave
-- limbs anchored from a prior run.
--
-- In edit mode there's no physics so un-anchored parts stay in
-- their rest CFrames anyway; in runtime the Humanoid drives them
-- through the Motor6D joints.
local function anchorRoot(model)
    for _, p in ipairs(model:GetDescendants()) do
        if p:IsA("BasePart") then
            p.Anchored = (p.Name == "HumanoidRootPart")
        end
    end
end

-- Place ONE static reference rig in ReplicatedStorage.Models.ZombieRig
-- for runtime preview / future spawn-code cloning. Animation Editor
-- doesn't work on this copy (edit-mode only) — use installEdit() for
-- animation work.
function ZombieRig.installSample()
    local models = ReplicatedStorage:FindFirstChild("Models")
    if not models then
        models = Instance.new("Folder")
        models.Name = "Models"
        models.Parent = ReplicatedStorage
    end

    local prior = models:FindFirstChild("ZombieRig")
    if prior then prior:Destroy() end

    local m = ZombieRig.build()
    anchorRoot(m)
    m.Parent = models
end

-- Edit-mode helper for Lily's animation workflow. Drops a fresh
-- anchored rig into Workspace.ZombieRig, replacing any prior copy.
-- Run from Studio Command Bar in EDIT mode (game not running):
--
--   require(game:GetService("ServerScriptService"):WaitForChild("world"):WaitForChild("ZombieRig")).installEdit()
--
-- The Animation Editor (Avatar tab → Animation Editor) then works
-- on the Workspace.ZombieRig instance. Save anims to Roblox cloud,
-- paste asset IDs into Config.ZombieAnimations.
function ZombieRig.installEdit()
    local prior = workspace:FindFirstChild("ZombieRig")
    if prior then prior:Destroy() end

    local m = ZombieRig.build()
    anchorRoot(m)
    -- Lift 10 studs above origin so the rig sits visibly above the
    -- baseplate instead of half-buried (build() places the rig
    -- around Y=0, with legs hanging to roughly Y=-3). PivotTo
    -- translates all descendants uniformly via the PrimaryPart.
    m:PivotTo(CFrame.new(0, 10, 0))
    m.Parent = workspace
end

return ZombieRig
