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

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local ZombieRig = {}

-- Part sizes. R6 standard EXCEPT for the Head, which we made
-- square-fronted (2×2) per Matthew 2026-05-01: standard 2×1×1
-- read as a flat brick; 2×2×1.5 reads as a Minecraft-block-style
-- square head, which complements the cardboard pickle face mask.
local PART_SIZE = {
    HumanoidRootPart = Vector3.new(2, 2, 1),
    Head             = Vector3.new(2, 2, 1.5),     -- square front (was 2,1,1)
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

-- Cardboard pickle FACE MASK — flat panels in front of the head
-- with a cutout that exposes the smiley face. Per Matthew
-- 2026-05-01: just cover the face (no torso sandwich-board).
-- Colors picked from his pickle pixel art: pickle-green body with
-- a darker stem cap. Material = SmoothPlastic for the matte
-- cardboard feel (Wood would read as actual wood, not paint).
local CARDBOARD_GREEN      = Color3.fromRGB( 60, 150,  70)  -- body
local CARDBOARD_GREEN_DARK = Color3.fromRGB( 35,  95,  45)  -- stem
local CARDBOARD_DEPTH      = 0.25                           -- flat-board thickness

-- Mask sizing: a single solid piece slightly bigger than the 2×2
-- head front. Per ea3-168: pre-rotated pickle PNG with transparent
-- background gets rendered via SurfaceGui+ImageLabel; the part
-- itself is fully transparent so only the pickle silhouette is
-- visible. The smiley face is overlaid in the same SurfaceGui
-- (ZIndex above the image) so the face draws on top of the pickle.
local MASK_W       = 2.6
local MASK_H       = 3.2
local MASK_Z       = -0.9                                   -- just in front of head's front face

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
    -- Square head: center at Y=+2 (head height 2 → bottom touches
    -- top of torso at Y=+1, top of head at Y=+3). Was Y=+1.5 when
    -- head was 2×1×1.
    head.CFrame  = CFrame.new( 0,    2, 0)
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
    -- Neck C1 head-side: bottom of head is 1.0 below center now
    -- (head height 2 → half-height 1, was 0.5 when head was height 1).
    makeMotor("Neck", torso, head,
              CFrame.new(0,  1.0, 0) * CFrame.Angles(0,  math.pi, 0),
              CFrame.new(0, -1.0, 0) * CFrame.Angles(0,  math.pi, 0))
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

    -- CARDBOARD PICKLE FACE MASK — single solid front piece, fully
    -- transparent, welded to the head. The pickle pixel art lives
    -- in a SurfaceGui+ImageLabel covering the whole front; the
    -- image's transparent background means only the pickle silhouette
    -- is visible. Smiley face is overlaid in the same SurfaceGui
    -- at higher ZIndex so eyes + mouth draw on top of the pickle.
    local mask = Instance.new("Part")
    mask.Name = "CardboardPickle"
    mask.Size = Vector3.new(MASK_W, MASK_H, CARDBOARD_DEPTH)
    mask.CFrame = head.CFrame * CFrame.new(0, 0, MASK_Z)
    mask.Color = CARDBOARD_GREEN                        -- only visible if image fails to load
    mask.Material = Enum.Material.SmoothPlastic
    mask.Transparency = 1                               -- invisible — SurfaceGui carries the visual
    mask.TopSurface = Enum.SurfaceType.Smooth
    mask.BottomSurface = Enum.SurfaceType.Smooth
    mask.CanCollide = false
    mask.Anchored = false
    mask.Massless = true                                -- don't unbalance the Humanoid
    mask.Parent = model

    do
        local weld = Instance.new("WeldConstraint")
        weld.Part0 = head
        weld.Part1 = mask
        weld.Parent = mask
    end

    -- Reference the unused dark-stem palette so the constant
    -- compiles cleanly until a future variant uses it.
    local _ = CARDBOARD_GREEN_DARK

    -- SurfaceGui on the mask front face. ImageLabel = pickle pixel
    -- art (background); smiley Frames = face overlay (ZIndex 2).
    local sg = Instance.new("SurfaceGui")
    sg.Name = "PickleSurface"
    sg.Face = Enum.NormalId.Front
    sg.LightInfluence = 0                               -- always full bright
    sg.PixelsPerStud = 60
    sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
    sg.Parent = mask

    local imgAsset = (Config.ZombieCostume and Config.ZombieCostume.CardboardImage) or ""
    if imgAsset ~= "" then
        local img = Instance.new("ImageLabel")
        img.Name = "PickleImage"
        img.Size = UDim2.fromScale(1, 1)
        img.AnchorPoint = Vector2.new(0.5, 0.5)
        img.Position = UDim2.fromScale(0.5, 0.5)
        img.BackgroundTransparency = 1
        img.Image = imgAsset
        img.Rotation =
            (Config.ZombieCostume and Config.ZombieCostume.CardboardImageRotation) or 0
        img.ScaleType = Enum.ScaleType.Fit
        img.ZIndex = 1
        img.Parent = sg
    end

    -- SMILEY FACE OVERLAY — eyes + mouth drawn on top of the pickle
    -- image. Frame + UICorner-radius=50% gives circle eyes; a wider
    -- rounded-rectangle Frame gives a smile-curve mouth. Lily can
    -- swap this for a hand-drawn Decal/asset overlay later.
    local function makeEye(xScale)
        local eye = Instance.new("Frame")
        eye.Size = UDim2.fromScale(0.10, 0.080)
        eye.AnchorPoint = Vector2.new(0.5, 0.5)
        eye.Position = UDim2.fromScale(xScale, 0.42)
        eye.BackgroundColor3 = Color3.new(0, 0, 0)
        eye.BorderSizePixel = 0
        eye.ZIndex = 2
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0.5, 0)
        c.Parent = eye
        eye.Parent = sg
    end
    makeEye(0.40)
    makeEye(0.60)

    local mouth = Instance.new("Frame")
    mouth.Name = "Mouth"
    mouth.Size = UDim2.fromScale(0.20, 0.040)
    mouth.AnchorPoint = Vector2.new(0.5, 0.5)
    mouth.Position = UDim2.fromScale(0.5, 0.55)
    mouth.BackgroundColor3 = Color3.new(0, 0, 0)
    mouth.BorderSizePixel = 0
    mouth.ZIndex = 2
    local mc = Instance.new("UICorner")
    mc.CornerRadius = UDim.new(0.5, 0)
    mc.Parent = mouth
    mouth.Parent = sg

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
