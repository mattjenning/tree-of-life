--[[
    TowerBuilders.lua — Model builders for every placeable tower type.

    WHY THIS MODULE EXISTS:
    Each tower's Model assembly (stems, gems, spikes, particles, glow
    lights, attribute stamping) is 60-100 lines of Instance.new /
    CFrame plumbing. Keeping all 10 builders in the hub orchestrator
    forced TreeOfLife_Hub to ~800 extra lines of pure visual code that
    drowned the rest of the file. Moving them to their own module leaves
    the hub handling flow + wiring, with Models living where they're
    conceptually cohesive.

    USAGE:
    The hub calls setup(ctx) once during startup. The module reads
    ctx.makePart (typed Instance.new wrapper) and ctx.tdRoom (parent
    Model for every built tower) and publishes:

        ctx.TOWER_BUILDERS = {
            Power           = fn(centerPos),
            FrostMelon      = fn(centerPos, player),
            RootSprout      = fn(centerPos, player),
            ThornVine       = fn(centerPos, player),
            HoneyHive       = fn(centerPos, player),
            AcornSniper     = fn(centerPos, player),
            LightningRadish = fn(centerPos, player),
            SporePuffball   = fn(centerPos, player),
            PepperCannon    = fn(centerPos, player),
            MushroomMortar  = fn(centerPos, player),
        }

    Each builder returns a Model parented to tdRoom with the
    tower-type-specific attributes stamped (AoeRadius / SlowPct /
    PierceCount / etc.). The generic placement handler in the hub layers
    on shared attributes (Owner, FloorY, Cells, TowerType Base snapshots
    for non-Power towers, etc.) after this builder runs.

    SHARED HELPER:
    stampAuxTowerAttributes handles the Core/Rarity/Damage-Range-FireRate
    boilerplate every aux tower shares, so each aux builder only has to
    focus on its unique visual + its per-type effect attributes. Power
    (Core) has its own attribute stamping inline because its attributes
    come from TowerTypes.Power rather than a TempTowers template.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared      = ReplicatedStorage:WaitForChild("Shared")
local Tags        = require(Shared:WaitForChild("Tags"))
local TowerTypes  = require(Shared:WaitForChild("TowerTypes"))
local TempTowers  = require(Shared:WaitForChild("TempTowers"))

local TowerBuilders = {}

function TowerBuilders.setup(ctx)
    local makePart = ctx.makePart
    local tdRoom   = ctx.tdRoom

    -- Shared attribute-stamping for aux tower builders.
    -- Every aux tower needs the same core attributes set up (TowerType,
    -- Rarity, Damage/Range/FireRate + BaseX snapshots + XBonusPct=0, and
    -- ProjectileColor + the CollectionService Tower tag). Pulling this into
    -- a helper keeps the 9 builders focused on their VISUAL parts + the
    -- tower-type-specific effect attributes (AoeRadius / SlowPct / pierce
    -- count / etc.) that make each tower distinct.
    --
    -- Fallback chain for each stat: stats.<field> → template default → 0.
    -- stats comes from TempTowers.resolveStats(towerId, rarity); if that
    -- returns nil or missing fields we fall back to the raw template so the
    -- tower still has sensible base numbers.
    local function stampAuxTowerAttributes(tower, towerId, stats, rarity, projectileColor, taggedPart)
        CollectionService:AddTag(taggedPart, Tags.Tower)
        local tpl = TempTowers.Templates[towerId] or {}
        local dmg = stats.damage   or tpl.damage   or 0
        local rng = stats.range    or tpl.range    or 0
        local fr  = stats.fireRate or tpl.fireRate or 0
        tower:SetAttribute("TowerType", towerId)
        tower:SetAttribute("Rarity",    rarity)
        tower:SetAttribute("Damage",       dmg)
        tower:SetAttribute("Range",        rng)
        tower:SetAttribute("FireRate",     fr)
        tower:SetAttribute("DamageBase",   dmg)
        tower:SetAttribute("RangeBase",    rng)
        tower:SetAttribute("FireRateBase", fr)
        tower:SetAttribute("DamageFlat",       0)
        tower:SetAttribute("RangeBonusPct",    0)
        tower:SetAttribute("FireRateBonusPct", 0)
        if projectileColor then
            tower:SetAttribute("ProjectileColor", projectileColor)
        end
    end

    -- ===========================================================================
    -- CORE TOWER (Power)
    -- ===========================================================================

    local function buildRedPowerTower(centerPos)
        local t = TowerTypes.Power

        local tower = Instance.new("Model")
        tower.Name = "PowerTower"
        tower.Parent = tdRoom

        -- 4x4 footprint = 8x8 studs. All dimensions scaled ~2x from the old 2x2 tower.
        makePart({
            Name = "TowerBase",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(3, 7.5, 7.5),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 1.5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.Wood,
            Color = Color3.fromRGB(95, 60, 35),
            Parent = tower,
        })
        makePart({
            Name = "TowerMidBand",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(1.5, 6, 6),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 4, 0)) * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.Slate,
            Color = Color3.fromRGB(120, 90, 75),
            Parent = tower,
        })
        makePart({
            Name = "TowerColumn",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(10, 5, 5),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 10, 0)) * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.Wood,
            Color = Color3.fromRGB(110, 75, 45),
            Parent = tower,
        })
        for _, y in ipairs({7, 13}) do
            makePart({
                Name = "TowerRing",
                Shape = Enum.PartType.Cylinder,
                Size = Vector3.new(0.8, 5.6, 5.6),
                CFrame = CFrame.new(centerPos + Vector3.new(0, y, 0)) * CFrame.Angles(0, 0, math.rad(90)),
                Material = Enum.Material.Metal,
                Color = Color3.fromRGB(180, 140, 80),
                Parent = tower,
            })
        end
        makePart({
            Name = "TowerPlatform",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(2, 6.8, 6.8),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 16, 0)) * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.Wood,
            Color = Color3.fromRGB(85, 55, 30),
            Parent = tower,
        })
        local gem = makePart({
            Name = "TowerGem",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(4.5, 4.5, 4.5),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 19.5, 0)),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(255, 70, 60),
            Transparency = 0.1,
            Parent = tower,
        })
        local gemLight = Instance.new("PointLight")
        gemLight.Color = Color3.fromRGB(255, 100, 80)
        gemLight.Brightness = 4
        gemLight.Range = 30
        gemLight.Parent = gem
        for i = 1, 4 do
            local a = (i / 4) * math.pi * 2
            makePart({
                Name = "TowerSpike",
                Size = Vector3.new(0.8, 3, 0.8),
                CFrame = CFrame.new(centerPos + Vector3.new(math.cos(a) * 2.2, 18.5, math.sin(a) * 2.2))
                         * CFrame.Angles(math.rad(15) * math.cos(a + math.pi/2), 0, math.rad(15) * math.sin(a + math.pi/2)),
                Material = Enum.Material.Neon,
                Color = Color3.fromRGB(220, 60, 60),
                Transparency = 0.2,
                Parent = tower,
            })
        end
        CollectionService:AddTag(tower.TowerBase, Tags.Tower)
        tower:SetAttribute("TowerType", t.name)
        -- Live stats. Upgrade cards mutate these each pick as
        --   Base * (1 + BonusPct/100).
        tower:SetAttribute("Damage",   t.damage)
        tower:SetAttribute("Range",    t.range)
        tower:SetAttribute("FireRate", t.fireRate)
        -- Base snapshots (immutable). Stat upgrades are ADDITIVE percentages of
        -- these base values so multiple picks don't compound exponentially.
        tower:SetAttribute("DamageBase",   t.damage)
        tower:SetAttribute("RangeBase",    t.range)
        tower:SetAttribute("FireRateBase", t.fireRate)
        -- Upgrade bonus attributes: Damage uses flat additive (DamageFlat),
        -- Range/FireRate use additive percentages. All start at 0.
        tower:SetAttribute("DamageFlat",       0)
        tower:SetAttribute("RangeBonusPct",    0)
        tower:SetAttribute("FireRateBonusPct", 0)
        return tower
    end

    -- ===========================================================================
    -- AUX TOWERS (map-boss temp-tower rewards)
    -- Each builder returns a Model + stamps tower-type-specific attributes.
    -- Stats are rarity-scaled via TempTowers.resolveStats(towerId, playerRarity).
    -- ===========================================================================

    -- Frost Melon: short fat blue-green gourd with a frosty glow. Fires pale-blue
    -- ice shards that apply an AOE chill on impact (SlowPct + SlowDuration).
    local function buildFrostMelonTower(centerPos, player)
        local rarity = (player and player:GetAttribute("FrostMelonRarity")) or "Rare"
        local stats = TempTowers.resolveStats("FrostMelon", rarity) or {}

        local tower = Instance.new("Model")
        tower.Name = "FrostMelonTower"
        tower.Parent = tdRoom

        -- Stubby dark-green stem
        makePart({
            Name = "Stem",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(2.5, 2, 2),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 1.25, 0)) * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.Grass,
            Color = Color3.fromRGB(40, 90, 45),
            Parent = tower,
        })
        -- Melon body — big round pale-teal ball
        makePart({
            Name = "Melon",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(7, 7, 7),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 6, 0)),
            Material = Enum.Material.SmoothPlastic,
            Color = Color3.fromRGB(150, 210, 220),
            Parent = tower,
        })
        -- Darker green stripes (4 vertical slices as thin parts)
        for i = 1, 4 do
            local a = (i / 4) * math.pi * 2
            makePart({
                Name = "Stripe",
                Size = Vector3.new(0.3, 7.2, 0.9),
                CFrame = CFrame.new(centerPos + Vector3.new(math.cos(a) * 3.45, 6, math.sin(a) * 3.45))
                         * CFrame.Angles(0, -a, 0),
                Material = Enum.Material.SmoothPlastic,
                Color = Color3.fromRGB(60, 130, 95),
                Parent = tower,
            })
        end
        -- Frost glow core. Daytime baseline kept subtle (was Brightness=3,
        -- Transparency=0.35, Range=22 — too glowy under bright Map 1 / 2
        -- ambient). Neon material still hints at glow without flooding the
        -- silhouette in light. Future: ramp Brightness back up on dusk /
        -- night via Map3StageVisuals' per-stage light table.
        local core = makePart({
            Name = "FrostCore",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(3.5, 3.5, 3.5),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 6, 0)),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(200, 240, 255),
            Transparency = 0.55,
            Parent = tower,
        })
        local chill = Instance.new("PointLight")
        chill.Color = Color3.fromRGB(170, 220, 255)
        chill.Brightness = 1.2
        chill.Range = 14
        chill.Parent = core
        -- Little leaf flick on top
        makePart({
            Name = "Leaf",
            Size = Vector3.new(2, 0.4, 0.8),
            CFrame = CFrame.new(centerPos + Vector3.new(0.5, 9.5, 0)) * CFrame.Angles(0, 0, math.rad(20)),
            Material = Enum.Material.Grass,
            Color = Color3.fromRGB(70, 140, 70),
            Parent = tower,
        })

        stampAuxTowerAttributes(tower, "FrostMelon", stats, rarity,
            Color3.fromRGB(170, 220, 255), tower.Stem)
        -- Chill-AOE effect: every hit bursts in AoeRadius and applies slow.
        tower:SetAttribute("AoeRadius",    stats.aoeRadius or 6)
        tower:SetAttribute("SlowPct",      stats.slowPct or 0.4)
        tower:SetAttribute("SlowDuration", stats.slowSeconds or 2.0)
        return tower
    end

    -- Root Sprout: low cluster of curling roots with small leaves, fires tiny
    -- green motes, and periodically stuns the nearest mob (PeriodicStunDuration
    -- + PeriodicStunCooldown). Short range — meant as a speed bump.
    local function buildRootSproutTower(centerPos, player)
        local rarity = (player and player:GetAttribute("RootSproutRarity")) or "Rare"
        local stats = TempTowers.resolveStats("RootSprout", rarity) or {}

        local tower = Instance.new("Model")
        tower.Name = "RootSproutTower"
        tower.Parent = tdRoom

        -- Low mound base (earth clod)
        makePart({
            Name = "Mound",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(6, 2, 6),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 1, 0)),
            Material = Enum.Material.Ground,
            Color = Color3.fromRGB(80, 55, 35),
            Parent = tower,
        })
        -- Six root tendrils curving up + out, each as a small angled cylinder
        for i = 1, 6 do
            local a = (i / 6) * math.pi * 2
            local ox = math.cos(a) * 1.8
            local oz = math.sin(a) * 1.8
            makePart({
                Name = "Root",
                Shape = Enum.PartType.Cylinder,
                Size = Vector3.new(4, 0.7, 0.7),
                CFrame = CFrame.new(centerPos + Vector3.new(ox, 3, oz))
                         * CFrame.Angles(0, -a, math.rad(50)),
                Material = Enum.Material.Wood,
                Color = Color3.fromRGB(95, 65, 45),
                Parent = tower,
            })
            -- Tiny leaf at the tip
            makePart({
                Name = "RootLeaf",
                Size = Vector3.new(1.2, 0.25, 0.6),
                CFrame = CFrame.new(centerPos + Vector3.new(ox * 1.9, 4.4, oz * 1.9))
                         * CFrame.Angles(0, -a, math.rad(-10)),
                Material = Enum.Material.Grass,
                Color = Color3.fromRGB(60, 140, 55),
                Parent = tower,
            })
        end
        -- Central sprout — a small green nub with a glowing seed
        makePart({
            Name = "Nub",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(1.8, 1.8, 1.8),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 3, 0)),
            Material = Enum.Material.Grass,
            Color = Color3.fromRGB(55, 130, 60),
            Parent = tower,
        })
        local seed = makePart({
            Name = "Seed",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(0.9, 0.9, 0.9),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 3.8, 0)),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(180, 240, 120),
            Transparency = 0.15,
            Parent = tower,
        })
        local glow = Instance.new("PointLight")
        glow.Color = Color3.fromRGB(180, 240, 120)
        glow.Brightness = 2
        glow.Range = 16
        glow.Parent = seed

        stampAuxTowerAttributes(tower, "RootSprout", stats, rarity,
            Color3.fromRGB(180, 240, 120), tower.Mound)
        -- Periodic stun effect (separate from probabilistic StunDuration used by
        -- upgrade cards — those two systems don't fight).
        tower:SetAttribute("PeriodicStunDuration", stats.stunSeconds or 0.5)
        tower:SetAttribute("PeriodicStunCooldown", stats.stunCooldown or 3.0)
        tower:SetAttribute("LastPeriodicStun", 0)
        return tower
    end

    -- ThornVine: low hedge-clump base with two taller thorny stalks that lean
    -- in opposite directions, bristling with dark-red thorn spikes. Fires pale
    -- green bolts that pierce through multiple mobs in a line.
    local function buildThornVineTower(centerPos, player)
        local rarity = (player and player:GetAttribute("ThornVineRarity")) or "Rare"
        local stats = TempTowers.resolveStats("ThornVine", rarity) or {}

        local tower = Instance.new("Model")
        tower.Name = "ThornVineTower"
        tower.Parent = tdRoom

        makePart({
            Name = "Clump",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(5, 2.4, 5),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 1.2, 0)),
            Material = Enum.Material.Grass,
            Color = Color3.fromRGB(35, 75, 35),
            Parent = tower,
        })
        -- Two thorny stalks
        for _, offset in ipairs({ Vector3.new(-1.2, 0, 0), Vector3.new(1.2, 0, 0) }) do
            makePart({
                Name = "Stalk",
                Shape = Enum.PartType.Cylinder,
                Size = Vector3.new(9, 0.9, 0.9),
                CFrame = CFrame.new(centerPos + offset + Vector3.new(0, 6, 0))
                         * CFrame.Angles(0, 0, math.rad(90 + (offset.X > 0 and -15 or 15))),
                Material = Enum.Material.Wood,
                Color = Color3.fromRGB(55, 90, 45),
                Parent = tower,
            })
        end
        -- Thorn spikes spiraling up
        for i = 1, 10 do
            local a = (i / 10) * math.pi * 2
            local h = 2.5 + i * 0.65
            makePart({
                Name = "Thorn",
                Size = Vector3.new(0.3, 1.2, 0.3),
                CFrame = CFrame.new(centerPos + Vector3.new(math.cos(a) * 1.6, h, math.sin(a) * 1.6))
                         * CFrame.Angles(0, -a, math.rad(30)),
                Material = Enum.Material.SmoothPlastic,
                Color = Color3.fromRGB(120, 40, 40),
                Parent = tower,
            })
        end
        -- Small glowing bud on top
        local bud = makePart({
            Name = "Bud",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(1.4, 1.4, 1.4),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 10.5, 0)),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(170, 230, 120),
            Transparency = 0.2,
            Parent = tower,
        })
        local bl = Instance.new("PointLight"); bl.Color = Color3.fromRGB(170, 230, 120)
        bl.Brightness = 2; bl.Range = 14; bl.Parent = bud

        stampAuxTowerAttributes(tower, "ThornVine", stats, rarity,
            Color3.fromRGB(170, 230, 120), tower.Clump)
        tower:SetAttribute("PierceCount", stats.pierceCount or 2)
        return tower
    end

    -- HoneyHive: hexagonal-ish golden hive shape atop a wooden plinth, with tiny
    -- honey drips. Fires small golden globs that splat sticky patches on the
    -- ground — the patches slow and tick damage.
    local function buildHoneyHiveTower(centerPos, player)
        local rarity = (player and player:GetAttribute("HoneyHiveRarity")) or "Rare"
        local stats = TempTowers.resolveStats("HoneyHive", rarity) or {}

        local tower = Instance.new("Model")
        tower.Name = "HoneyHiveTower"
        tower.Parent = tdRoom

        -- Wooden plinth (4×6 footprint → 8×12 studs, elongated on Z)
        makePart({
            Name = "Plinth",
            Size = Vector3.new(7, 2, 11),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 1, 0)),
            Material = Enum.Material.Wood,
            Color = Color3.fromRGB(80, 55, 30),
            Parent = tower,
        })
        -- Hive: three stacked discs of decreasing size
        for i, s in ipairs({ {sz=6, y=4, d=0.85}, {sz=5, y=7, d=0.9}, {sz=3.5, y=9.5, d=0.95} }) do
            makePart({
                Name = "HiveRing" .. i,
                Shape = Enum.PartType.Cylinder,
                Size = Vector3.new(2, s.sz, s.sz),
                CFrame = CFrame.new(centerPos + Vector3.new(0, s.y, 0)) * CFrame.Angles(0, 0, math.rad(90)),
                Material = Enum.Material.SmoothPlastic,
                Color = Color3.fromRGB(220, 170, 50),
                Parent = tower,
            })
        end
        -- Entry hole
        makePart({
            Name = "Hole",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(0.6, 2, 2),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 4, 3.1)) * CFrame.Angles(0, math.rad(90), math.rad(90)),
            Material = Enum.Material.SmoothPlastic,
            Color = Color3.fromRGB(50, 30, 10),
            Parent = tower,
        })
        -- Two honey drips
        for _, offset in ipairs({ Vector3.new(2, 2.5, 0), Vector3.new(-2.5, 1.5, 2) }) do
            makePart({
                Name = "Drip",
                Shape = Enum.PartType.Ball,
                Size = Vector3.new(1, 1.4, 1),
                CFrame = CFrame.new(centerPos + Vector3.new(0, 3, 0) + offset),
                Material = Enum.Material.Neon,
                Color = Color3.fromRGB(255, 210, 90),
                Transparency = 0.1,
                Parent = tower,
            })
        end

        stampAuxTowerAttributes(tower, "HoneyHive", stats, rarity,
            Color3.fromRGB(255, 210, 90), tower.Plinth)
        tower:SetAttribute("PatchRadius",     stats.patchRadius or 8)
        tower:SetAttribute("PatchSeconds",    stats.patchSeconds or 4)
        tower:SetAttribute("PatchSlowPct",    stats.patchSlowPct or 0.4)
        tower:SetAttribute("PatchTickDmg",    stats.patchTickDmg or 4)
        tower:SetAttribute("PatchTickPerSec", stats.patchTickPerSec or 2)
        return tower
    end

    -- AcornSniper: tall narrow tower shaped like an acorn — woody brown cap on
    -- a slender dark trunk with a glowing aiming reticle. Long range, slow fire,
    -- big single hit. No special mechanic — just stats.
    local function buildAcornSniperTower(centerPos, player)
        local rarity = (player and player:GetAttribute("AcornSniperRarity")) or "Rare"
        local stats = TempTowers.resolveStats("AcornSniper", rarity) or {}

        local tower = Instance.new("Model")
        tower.Name = "AcornSniperTower"
        tower.Parent = tdRoom

        -- Slim dark trunk
        makePart({
            Name = "Trunk",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(13, 2, 2),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 6.5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.Wood,
            Color = Color3.fromRGB(70, 45, 25),
            Parent = tower,
        })
        -- Acorn body (top)
        makePart({
            Name = "Acorn",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(4, 4.5, 4),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 14, 0)),
            Material = Enum.Material.SmoothPlastic,
            Color = Color3.fromRGB(180, 130, 70),
            Parent = tower,
        })
        -- Acorn cap (textured cross-hatched cap, rendered as a slightly larger dome)
        makePart({
            Name = "Cap",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(4.4, 2.4, 4.4),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 16, 0)),
            Material = Enum.Material.Fabric,
            Color = Color3.fromRGB(100, 70, 35),
            Parent = tower,
        })
        -- Stem above cap
        makePart({
            Name = "Stem",
            Size = Vector3.new(0.4, 1, 0.4),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 17.6, 0)),
            Material = Enum.Material.Wood,
            Color = Color3.fromRGB(60, 40, 20),
            Parent = tower,
        })
        -- Glowing reticle ring at mid-trunk
        local ret = makePart({
            Name = "Reticle",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(0.3, 3.4, 3.4),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 11, 0)) * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(255, 220, 120),
            Transparency = 0.3,
            Parent = tower,
        })
        local rl = Instance.new("PointLight")
        rl.Color = Color3.fromRGB(255, 220, 120); rl.Brightness = 1.5; rl.Range = 10; rl.Parent = ret

        stampAuxTowerAttributes(tower, "AcornSniper", stats, rarity,
            Color3.fromRGB(255, 220, 120), tower.Trunk)
        return tower
    end

    -- LightningRadish: fat purple radish body half-buried in the ground, green
    -- leaves on top with a small crackling electric arc between them. Fires
    -- purple bolts that chain to nearby mobs.
    local function buildLightningRadishTower(centerPos, player)
        local rarity = (player and player:GetAttribute("LightningRadishRarity")) or "Rare"
        local stats = TempTowers.resolveStats("LightningRadish", rarity) or {}

        local tower = Instance.new("Model")
        tower.Name = "LightningRadishTower"
        tower.Parent = tdRoom

        -- Radish body (chunky purple-pink inverted teardrop)
        makePart({
            Name = "Body",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(8, 9, 8),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 4.5, 0)),
            Material = Enum.Material.SmoothPlastic,
            Color = Color3.fromRGB(200, 80, 170),
            Parent = tower,
        })
        -- Paler highlight band
        makePart({
            Name = "Highlight",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(0.3, 8.2, 8.2),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.SmoothPlastic,
            Color = Color3.fromRGB(230, 140, 200),
            Transparency = 0.35,
            Parent = tower,
        })
        -- Leaves (3 upright blades)
        for i = 1, 3 do
            local a = (i / 3) * math.pi * 2
            makePart({
                Name = "Leaf",
                Size = Vector3.new(1, 4, 2.5),
                CFrame = CFrame.new(centerPos + Vector3.new(math.cos(a) * 1.2, 10.5, math.sin(a) * 1.2))
                         * CFrame.Angles(math.rad(-10), -a, 0),
                Material = Enum.Material.Grass,
                Color = Color3.fromRGB(80, 160, 70),
                Parent = tower,
            })
        end
        -- Central crackling arc (neon yellow ball)
        local arc = makePart({
            Name = "Arc",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(1.6, 1.6, 1.6),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 12.5, 0)),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(255, 240, 120),
            Transparency = 0.1,
            Parent = tower,
        })
        local al = Instance.new("PointLight")
        al.Color = Color3.fromRGB(230, 180, 255); al.Brightness = 4; al.Range = 22; al.Parent = arc

        stampAuxTowerAttributes(tower, "LightningRadish", stats, rarity,
            Color3.fromRGB(230, 180, 255), tower.Body)
        tower:SetAttribute("ChainJumps",   stats.chainJumps or 2)
        tower:SetAttribute("ChainFalloff", stats.chainFalloff or 0.6)
        tower:SetAttribute("ChainRange",   stats.chainRange or 14)
        return tower
    end

    -- SporePuffball: bulging pale-green mushroom dome with darker spore dots,
    -- emitting faint mist. Fires spore bolts that release a lingering poison
    -- cloud on impact — the cloud ticks damage to mobs inside.
    local function buildSporePuffballTower(centerPos, player)
        local rarity = (player and player:GetAttribute("SporePuffballRarity")) or "Rare"
        local stats = TempTowers.resolveStats("SporePuffball", rarity) or {}

        local tower = Instance.new("Model")
        tower.Name = "SporePuffballTower"
        tower.Parent = tdRoom

        -- Stubby stalk
        makePart({
            Name = "Stalk",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(3, 4, 4),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 1.5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.SmoothPlastic,
            Color = Color3.fromRGB(230, 220, 190),
            Parent = tower,
        })
        -- Puffball dome
        makePart({
            Name = "Dome",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(10, 8, 10),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 6, 0)),
            Material = Enum.Material.SmoothPlastic,
            Color = Color3.fromRGB(170, 200, 140),
            Parent = tower,
        })
        -- Spore dots scattered on the dome
        for _ = 1, 10 do
            local a = math.random() * math.pi * 2
            local el = math.random() * math.pi * 0.45 + 0.1
            local rad = 4.8
            local x = math.cos(a) * math.cos(el) * rad
            local y = math.sin(el) * rad
            local z = math.sin(a) * math.cos(el) * rad
            makePart({
                Name = "Spot",
                Shape = Enum.PartType.Ball,
                Size = Vector3.new(0.9, 0.9, 0.9),
                CFrame = CFrame.new(centerPos + Vector3.new(x, 6 + y, z)),
                Material = Enum.Material.SmoothPlastic,
                Color = Color3.fromRGB(90, 140, 80),
                Parent = tower,
            })
        end
        -- Glowing crown
        local crown = makePart({
            Name = "Crown",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(2, 2, 2),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 10.5, 0)),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(160, 240, 140),
            Transparency = 0.25,
            Parent = tower,
        })
        local cl = Instance.new("PointLight")
        cl.Color = Color3.fromRGB(160, 240, 140); cl.Brightness = 2.5; cl.Range = 16; cl.Parent = crown

        stampAuxTowerAttributes(tower, "SporePuffball", stats, rarity,
            Color3.fromRGB(160, 240, 140), tower.Stalk)
        tower:SetAttribute("CloudRadius",     stats.cloudRadius or 8)
        tower:SetAttribute("CloudSeconds",    stats.cloudSeconds or 3)
        tower:SetAttribute("CloudTickDmg",    stats.cloudTickDmg or 3)
        tower:SetAttribute("CloudTickPerSec", stats.cloudTickPerSec or 4)
        return tower
    end

    -- PepperCannon: fat red pepper mounted horizontally on a stone base, glowing
    -- orange muzzle at the tip. Fires heavy fireballs with splash damage.
    local function buildPepperCannonTower(centerPos, player)
        local rarity = (player and player:GetAttribute("PepperCannonRarity")) or "Rare"
        local stats = TempTowers.resolveStats("PepperCannon", rarity) or {}

        local tower = Instance.new("Model")
        tower.Name = "PepperCannonTower"
        tower.Parent = tdRoom

        -- Stone base block
        makePart({
            Name = "Base",
            Size = Vector3.new(14, 3, 14),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 1.5, 0)),
            Material = Enum.Material.Slate,
            Color = Color3.fromRGB(90, 85, 80),
            Parent = tower,
        })
        -- Pepper body (long tapered — use three stacked cylinders narrowing toward muzzle)
        for i, s in ipairs({ {sz=5.5, x=-3, d=6}, {sz=5, x=0, d=6.5}, {sz=4, x=3.5, d=7} }) do
            makePart({
                Name = "PepperSegment" .. i,
                Shape = Enum.PartType.Cylinder,
                Size = Vector3.new(s.d, s.sz, s.sz),
                CFrame = CFrame.new(centerPos + Vector3.new(s.x, 7, 0)),
                Material = Enum.Material.SmoothPlastic,
                Color = Color3.fromRGB(210, 55, 40),
                Parent = tower,
            })
        end
        -- Green stem at the back
        makePart({
            Name = "Stem",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(2, 1.8, 1.8),
            CFrame = CFrame.new(centerPos + Vector3.new(-6.5, 7, 0)),
            Material = Enum.Material.Grass,
            Color = Color3.fromRGB(70, 140, 55),
            Parent = tower,
        })
        -- Glowing orange muzzle at the front tip
        local muzzle = makePart({
            Name = "Muzzle",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(2.8, 2.8, 2.8),
            CFrame = CFrame.new(centerPos + Vector3.new(7.2, 7, 0)),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(255, 150, 50),
            Transparency = 0.15,
            Parent = tower,
        })
        local ml = Instance.new("PointLight")
        ml.Color = Color3.fromRGB(255, 120, 40); ml.Brightness = 4; ml.Range = 22; ml.Parent = muzzle

        stampAuxTowerAttributes(tower, "PepperCannon", stats, rarity,
            Color3.fromRGB(255, 150, 50), tower.Base)
        -- Uses the generic AoeRadius path (same as upgrade-card AOE specials)
        tower:SetAttribute("AoeRadius", stats.splashRadius or 8)
        return tower
    end

    -- MushroomMortar: massive red-capped mushroom with white spots, a wide stem,
    -- and a glowing cavity in the center. Lobs huge spore bombs in arcing shots
    -- over 2 seconds, then detonates with a giant blast radius.
    local function buildMushroomMortarTower(centerPos, player)
        local rarity = (player and player:GetAttribute("MushroomMortarRarity")) or "Rare"
        local stats = TempTowers.resolveStats("MushroomMortar", rarity) or {}

        local tower = Instance.new("Model")
        tower.Name = "MushroomMortarTower"
        tower.Parent = tdRoom

        -- Wide stubby stem
        makePart({
            Name = "Stem",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(9, 8, 8),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 4.5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.SmoothPlastic,
            Color = Color3.fromRGB(240, 220, 190),
            Parent = tower,
        })
        -- Cap (huge red dome)
        makePart({
            Name = "Cap",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(22, 12, 22),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 12, 0)),
            Material = Enum.Material.SmoothPlastic,
            Color = Color3.fromRGB(190, 45, 45),
            Parent = tower,
        })
        -- White spots on the cap
        for i = 1, 10 do
            local a = (i / 10) * math.pi * 2
            local r = 6 + math.random() * 3
            makePart({
                Name = "Spot",
                Shape = Enum.PartType.Ball,
                Size = Vector3.new(2.2, 2.2, 2.2),
                CFrame = CFrame.new(centerPos + Vector3.new(math.cos(a) * r, 15, math.sin(a) * r)),
                Material = Enum.Material.SmoothPlastic,
                Color = Color3.fromRGB(250, 245, 235),
                Parent = tower,
            })
        end
        -- Gill ring underneath the cap (slightly darker)
        makePart({
            Name = "Gills",
            Shape = Enum.PartType.Cylinder,
            Size = Vector3.new(1.2, 18, 18),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 9, 0)) * CFrame.Angles(0, 0, math.rad(90)),
            Material = Enum.Material.SmoothPlastic,
            Color = Color3.fromRGB(230, 200, 170),
            Parent = tower,
        })
        -- Glowing central cavity
        local cav = makePart({
            Name = "Cavity",
            Shape = Enum.PartType.Ball,
            Size = Vector3.new(4, 4, 4),
            CFrame = CFrame.new(centerPos + Vector3.new(0, 18, 0)),
            Material = Enum.Material.Neon,
            Color = Color3.fromRGB(255, 160, 80),
            Transparency = 0.15,
            Parent = tower,
        })
        local cvl = Instance.new("PointLight")
        cvl.Color = Color3.fromRGB(255, 160, 80); cvl.Brightness = 5; cvl.Range = 32; cvl.Parent = cav

        stampAuxTowerAttributes(tower, "MushroomMortar", stats, rarity,
            Color3.fromRGB(255, 160, 80), tower.Stem)
        tower:SetAttribute("LobSeconds", stats.lobSeconds or 2)
        tower:SetAttribute("BlastRadius", stats.blastRadius or 12)
        return tower
    end

    -- Publish builders onto ctx for the placement handler to dispatch.
    ctx.TOWER_BUILDERS = {
        Power           = buildRedPowerTower,
        FrostMelon      = buildFrostMelonTower,
        RootSprout      = buildRootSproutTower,
        ThornVine       = buildThornVineTower,
        HoneyHive       = buildHoneyHiveTower,
        AcornSniper     = buildAcornSniperTower,
        LightningRadish = buildLightningRadishTower,
        SporePuffball   = buildSporePuffballTower,
        PepperCannon    = buildPepperCannonTower,
        MushroomMortar  = buildMushroomMortarTower,
    }
end

return TowerBuilders
