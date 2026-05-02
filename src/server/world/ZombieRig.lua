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

-- Mask sizing: scaled up per Matthew 2026-05-01 ea3-169 so the
-- visible pickle silhouette matches the head's 2-stud width. Image
-- aspect is ~1:2 vertical (pickle is taller than wide); ScaleType.Fit
-- on a 3.4×4.2 mask gives the pickle a rendered width near 2.1 —
-- effectively filling the head width with a touch of overhang.
local MASK_W       = 3.4
local MASK_H       = 4.2
local MASK_Z       = -0.9                                   -- just in front of head's front face

-- HEADSTRAP — thin black bands wrapping the head's left/right/back
-- sides, plus two short connector pieces (StrapConnL / StrapConnR)
-- bridging the side straps' front edges out to the mask's outer
-- corners. Front face of the head is hidden by the mask anyway, so
-- no full front strap. The connectors are most visible on tank-
-- sized rigs where the head→mask-edge gap is largest.
local STRAP_COLOR     = Color3.fromRGB(28, 28, 32)
local STRAP_HEIGHT    = 0.32
local STRAP_THICKNESS = 0.08

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

function ZombieRig.build(scale)
    -- Optional Vector3 scale per axis (X/Y/Z). Defaults to 1×1×1.
    -- Per-axis scale is what enables "tall thin / small / beefy" mob
    -- variants — uniform Roblox Model:ScaleTo would make tall-thin
    -- impossible. We multiply scale through every PART_SIZE, every
    -- part CFrame position, every Motor6D C0/C1 position, and the
    -- mask + strap dimensions, so welded children stay properly
    -- proportioned to the scaled head/torso.
    scale = scale or Vector3.new(1, 1, 1)
    local sx, sy, sz = scale.X, scale.Y, scale.Z
    local function s3(v) return Vector3.new(v.X * sx, v.Y * sy, v.Z * sz) end
    local function sCF(cf)
        local p = cf.Position
        return (cf - p) + Vector3.new(p.X * sx, p.Y * sy, p.Z * sz)
    end

    local model = Instance.new("Model")
    model.Name = "ZombieRig"

    -- Build all 7 parts. Scaled sizes applied here.
    local function scaledPart(name, color, material)
        local p = makePart(name, color, material)
        p.Size = s3(PART_SIZE[name])
        return p
    end
    local hrp      = scaledPart("HumanoidRootPart", FLESH)
    hrp.Transparency = 1                -- HRP is always invisible (R6 standard)
    local torso    = scaledPart("Torso",     FLESH_DARK)
    local head     = scaledPart("Head",      FLESH)
    local lArm     = scaledPart("Left Arm",  FLESH)
    local rArm     = scaledPart("Right Arm", FLESH)
    local lLeg     = scaledPart("Left Leg",  CLOTH_DARK)
    local rLeg     = scaledPart("Right Leg", CLOTH_DARK)
    for _, p in ipairs({ hrp, torso, head, lArm, rArm, lLeg, rLeg }) do
        p.Parent = model
    end

    -- T-pose layout, scaled. Y=0 sits at HRP center; legs hang below
    -- head floats above the torso. Each Vector3 component picks up
    -- the corresponding axis scale.
    hrp.CFrame   = CFrame.new(0, 0, 0)
    torso.CFrame = CFrame.new(0, 0, 0)
    head.CFrame  = CFrame.new(0, 2 * sy, 0)
    lArm.CFrame  = CFrame.new(-1.5 * sx, 0, 0)
    rArm.CFrame  = CFrame.new( 1.5 * sx, 0, 0)
    lLeg.CFrame  = CFrame.new(-0.5 * sx, -2 * sy, 0)
    rLeg.CFrame  = CFrame.new( 0.5 * sx, -2 * sy, 0)

    -- Motor6D joints — same R6 layout, but with C0/C1 position
    -- components scaled per axis. Rotations are scale-invariant,
    -- so animations baked at default scale should still play
    -- correctly on scaled rigs.
    makeMotor("RootJoint", hrp, torso,
              sCF(CFrame.new(0, 0, 0)) * CFrame.Angles(0, math.pi, 0),
              sCF(CFrame.new(0, 0, 0)) * CFrame.Angles(0, math.pi, 0))
    makeMotor("Neck", torso, head,
              sCF(CFrame.new(0,  1.0, 0)) * CFrame.Angles(0, math.pi, 0),
              sCF(CFrame.new(0, -1.0, 0)) * CFrame.Angles(0, math.pi, 0))
    makeMotor("Left Shoulder", torso, lArm,
              sCF(CFrame.new(-1.0, 0.5, 0)) * CFrame.Angles(0, -math.pi / 2, 0),
              sCF(CFrame.new( 0.5, 0.5, 0)) * CFrame.Angles(0, -math.pi / 2, 0))
    makeMotor("Right Shoulder", torso, rArm,
              sCF(CFrame.new( 1.0, 0.5, 0)) * CFrame.Angles(0, math.pi / 2, 0),
              sCF(CFrame.new(-0.5, 0.5, 0)) * CFrame.Angles(0, math.pi / 2, 0))
    makeMotor("Left Hip", torso, lLeg,
              sCF(CFrame.new(-0.5, -1.0, 0)) * CFrame.Angles(0, -math.pi / 2, 0),
              sCF(CFrame.new( 0,    1.0, 0)) * CFrame.Angles(0, -math.pi / 2, 0))
    makeMotor("Right Hip", torso, rLeg,
              sCF(CFrame.new( 0.5, -1.0, 0)) * CFrame.Angles(0, math.pi / 2, 0),
              sCF(CFrame.new( 0,    1.0, 0)) * CFrame.Angles(0, math.pi / 2, 0))

    -- CARDBOARD PICKLE FACE MASK — single solid front piece, fully
    -- transparent, welded to the head. The pickle pixel art lives
    -- in a SurfaceGui+ImageLabel covering the whole front; the
    -- image's transparent background means only the pickle silhouette
    -- is visible. Smiley face is overlaid in the same SurfaceGui
    -- at higher ZIndex so eyes + mouth draw on top of the pickle.
    local mask = Instance.new("Part")
    mask.Name = "CardboardPickle"
    -- Mask scales with head: width = MASK_W × sx, height = MASK_H × sy,
    -- depth = CARDBOARD_DEPTH × sz. Z offset (in front of head's front
    -- face) scales with sz so the mask sits flush against the front of
    -- the scaled head, regardless of head depth.
    mask.Size = Vector3.new(MASK_W * sx, MASK_H * sy, CARDBOARD_DEPTH * sz)
    mask.CFrame = head.CFrame * CFrame.new(0, 0, MASK_Z * sz)
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
    sg.LightInfluence = 0.7                             -- partial blend: env-lit but never fully black
    sg.PixelsPerStud = 60
    sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
    sg.Parent = mask

    -- HARDCODED FALLBACKS — Studio's require() caches modules per
    -- ModuleScript instance, and Config tables can be frozen at
    -- runtime, making mid-session swap-in painful. We resolve image
    -- IDs in priority order:
    --   1. Workspace attribute (live-mutable from Command Bar; takes
    --      precedence so Lily can iterate without Studio restart)
    --   2. Config.ZombieCostume.<Field> (sourced from Config.lua;
    --      reflects committed state but cached after first require)
    --   3. Hardcoded constant (last-resort default so the rig
    --      always renders correctly even with a stale Config cache)
    -- 2026-05-02 ea3-176: pickle mask asset has the face baked in,
    -- so this is the ONLY image we render — no separate smiley
    -- overlay. Old standalone-pickle asset (132374065433959)
    -- retired in favor of the face-included version.
    -- 2026-05-02 ea3-188: swapped 101189651590823 → 73345227135447.
    -- 2026-05-02 ea3-190: swapped 73345227135447 → 133842821844631.
    -- 2026-05-02 ea3-191: swapped 133842821844631 → 98708777334781.
    -- 2026-05-02 ea3-192: swapped 98708777334781  → 113856601966070.
    local DEFAULT_PICKLE_IMG = "rbxassetid://113856601966070"
    local function resolveAsset(attrName, configKey, default)
        local override = workspace:GetAttribute(attrName)
        if override and override ~= "" then return override end
        if Config.ZombieCostume and Config.ZombieCostume[configKey] then
            local v = Config.ZombieCostume[configKey]
            if v ~= "" then return v end
        end
        return default
    end
    local imgAsset = resolveAsset(
        "ZombieRigCardboardImage", "CardboardImage", DEFAULT_PICKLE_IMG)
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

    -- BACK-FACE white silhouette per Matthew 2026-05-02 ea3-183:
    -- without this, the mask is invisible from behind so the zombie
    -- "loses its face" when it turns around a path corner. Roblox
    -- ImageColor3 can't recolor a colored asset to white (multiplier
    -- only — no replace), so we approximate the pickle silhouette
    -- with a UICorner-rounded white pill Frame instead of trying to
    -- recolor the front asset. Gives a clean "white outline of the
    -- mask from behind" read.
    local backSg = Instance.new("SurfaceGui")
    backSg.Name = "PickleSurfaceBack"
    backSg.Face = Enum.NormalId.Back
    backSg.LightInfluence = 0.7
    backSg.PixelsPerStud = 60
    backSg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
    backSg.Parent = mask

    local whiteSilhouette = Instance.new("Frame")
    whiteSilhouette.Name = "WhiteSilhouette"
    -- Sized to roughly match the front pickle's visible silhouette
    -- (~70% mask width × 90% mask height, vertical-pill shape).
    whiteSilhouette.Size = UDim2.fromScale(0.70, 0.90)
    whiteSilhouette.AnchorPoint = Vector2.new(0.5, 0.5)
    whiteSilhouette.Position = UDim2.fromScale(0.5, 0.5)
    whiteSilhouette.BackgroundColor3 = Color3.new(1, 1, 1)
    whiteSilhouette.BorderSizePixel = 0
    whiteSilhouette.Parent = backSg
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0.5, 0)        -- pill (rounded ends)
        c.Parent = whiteSilhouette
        local s = Instance.new("UIStroke")
        s.Thickness = 2
        s.Color = Color3.fromRGB(40, 50, 60)     -- dark navy outline matches front
        s.Parent = whiteSilhouette
    end

    -- Face overlay removed per Matthew 2026-05-02 ea3-176: the
    -- pickle-mask asset already includes the face baked in, so
    -- drawing a separate smiley on top just clutters it. The
    -- SmileyImage Config field + procedural ^^/‿ fallback paths
    -- have been deleted from this build; if a face overlay is
    -- needed in the future, restore from git history (ea3-175).

    -- HEADSTRAP — three thin black bands (left side / right side /
    -- back of head), welded so they animate with head rotation.
    -- Front strap is intentionally omitted: the mask covers it.
    -- Plus two connector bands (StrapConnL/R) that bridge each side
    -- strap's front edge outward to the mask's outer corner — the
    -- gap between head side (X=±1) and mask side (X=±1.7) was
    -- visible on tank-sized rigs without these.
    -- Head dims are 2×2×1.5; sides at X=±1, back at Z=+0.75.
    local function makeStrap(name, size, localCF)
        local part = Instance.new("Part")
        part.Name = name
        part.Size = size
        part.CFrame = head.CFrame * localCF
        part.Color = STRAP_COLOR
        part.Material = Enum.Material.SmoothPlastic
        part.TopSurface = Enum.SurfaceType.Smooth
        part.BottomSurface = Enum.SurfaceType.Smooth
        part.CanCollide = false
        part.Anchored = false
        part.Massless = true
        part.Parent = model
        return part
    end

    -- Scale strap dimensions and offsets so the band still hugs the
    -- head's surface on a non-uniform-scaled rig. Side straps' Z-len
    -- matches head depth (1.5 × sz); back-strap's X-len matches head
    -- width (2 × sx). Outer X/Z offsets are head_half × scale plus
    -- half-strap-thickness so the strap sits flush against the head.
    local strapTh = STRAP_THICKNESS                       -- thickness in studs (un-scaled feels right)
    local strapLeft = makeStrap("StrapLeft",
        Vector3.new(strapTh, STRAP_HEIGHT, 1.5 * sz),
        CFrame.new(-1 * sx - strapTh * 0.5, 0, 0))
    local strapRight = makeStrap("StrapRight",
        Vector3.new(strapTh, STRAP_HEIGHT, 1.5 * sz),
        CFrame.new( 1 * sx + strapTh * 0.5, 0, 0))
    local strapBack = makeStrap("StrapBack",
        Vector3.new(2 * sx, STRAP_HEIGHT, strapTh),
        CFrame.new(0, 0, 0.75 * sz + strapTh * 0.5))

    -- Connector bands — bridge each side strap's front-outer
    -- corner DIAGONALLY to the mask's front-outer corner. ea3-214
    -- v1 had the bands lying along X (perpendicular to head), so
    -- they read as ears/wings sticking sideways. ea3-215 orients
    -- them along the actual diagonal so each band looks like a
    -- strap stretched from head-side to mask-corner.
    --
    -- Endpoints (head-local space):
    --   inner = side-strap front-outer corner  (X=±(1+strapTh/2)·sx, Z=-0.75·sz)
    --   outer = mask front-outer corner        (X=±1.7·sx,           Z=-1.025·sz)
    -- Band is a Block with long axis = local Z; CFrame.lookAt(mid,
    -- outer) places its local -Z toward `outer`, so the long axis
    -- spans inner ↔ outer along the diagonal.
    local function makeConnector(name, sign)
        local inner = Vector3.new(sign * (1 * sx + strapTh * 0.5), 0, -0.75 * sz)
        local outer = Vector3.new(sign * 1.7 * sx,                 0, -1.025 * sz)
        local mid   = (inner + outer) * 0.5
        local len   = (outer - inner).Magnitude
        return makeStrap(name,
            Vector3.new(strapTh, STRAP_HEIGHT, len),
            CFrame.lookAt(mid, outer))
    end
    local strapConnL = makeConnector("StrapConnL", -1)
    local strapConnR = makeConnector("StrapConnR",  1)

    for _, strap in ipairs({ strapLeft, strapRight, strapBack, strapConnL, strapConnR }) do
        local w = Instance.new("WeldConstraint")
        w.Part0 = head
        w.Part1 = strap
        w.Parent = strap
    end

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

    -- Cleanup: destroy any leftover Workspace.ZombieRig from a
    -- prior edit-mode installEdit() session. Without this, Lily's
    -- animation-scratch rig persists into runtime when she presses
    -- F5 (Studio forks the edit-mode Workspace into runtime), so
    -- the rig appears at game start. Per Matthew 2026-05-02
    -- ea3-185: "hide the ZombieRig on start." Destroy is cleaner
    -- than hiding — the canonical reference lives in
    -- ReplicatedStorage.Models above; the Workspace copy was only
    -- there for the Animation Editor.
    local workspaceCopy = workspace:FindFirstChild("ZombieRig")
    if workspaceCopy then workspaceCopy:Destroy() end
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
