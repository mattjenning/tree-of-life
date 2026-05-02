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
local EYE_GLOW    = Color3.fromRGB(255, 230, 100)  -- glowy yellow eyes

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

    -- Glowy yellow eyes via SurfaceLight on the head front face.
    -- A subtle visual that makes the zombie read as a zombie even
    -- without a face decal. Lily can add a hand-drawn face Decal
    -- on Head.front later.
    local eyeGlow = Instance.new("SurfaceLight")
    eyeGlow.Name = "EyeGlow"
    eyeGlow.Face = Enum.NormalId.Front
    eyeGlow.Color = EYE_GLOW
    eyeGlow.Brightness = 1.5
    eyeGlow.Range = 6
    eyeGlow.Angle = 60
    eyeGlow.Parent = head

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
