--[[
    Infinite.lua — Phase 1 of the Infinite Arena (balance/benchmark
    sandbox per project_infinite_arena.md).

    OWNS:
    - Hub-portal entry handler (called from HubWorld.Touched after
      the player picks a scenario): teleports into Map4 + grants
      default tower stock + starts the scenario spawner.
    - Return-portal lazy build inside Map4 (touch → exit + summary).
    - Three scenarios: AOE / SingleBoss / Mixed. Each scenario has
      a per-round mob mix that the spawner ramps until the heart dies.
    - Heart-death listener: on Health <= 0, prints StatLedger.summary()
      and auto-returns the player to the hub.

    NOT YET:
    - Full UI for tweaking ramp constants live (today: read from
      Config.Map4.Difficulty)
    - Per-scenario damage / status separators in StatLedger summary
    - Multi-player Infinite (today assumes one player at a time)

    setup(ctx) reads:
      ctx.MAP4_PLAYER_SPAWN_CF / ctx.HUB_SPAWN_CF
      ctx.map4Heart, ctx.map4Room
      ctx.makeMob, ctx.activeMobs, ctx.clearAllMobs
      ctx.statLedger
      ctx.StageState  (we set currentMapId=4 on entry)

    Publishes:
      ctx.enterInfinite(player, scenarioName)
      ctx.exitInfinite(player)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")

local Shared   = ReplicatedStorage:WaitForChild("Shared")
local Remotes  = require(Shared:WaitForChild("Remotes"))
local Config   = require(Shared:WaitForChild("Config"))
local GameTime = require(Shared:WaitForChild("GameTime"))

local Infinite = {}

-- Cinematic timing
local ENTRY_FADE_OUT_SEC = 0.8
local EXIT_FADE_OUT_SEC  = 0.6

-- Lazy-wired return portal
local returnPortalSetup = false

------------------------------------------------------------
-- Run state. Single-player at a time; multi-player Infinite is
-- a future expansion (would require per-player StageState).
------------------------------------------------------------
local State = {
    active        = false,
    activePlayer  = nil :: Player?,
    scenario      = nil :: string?,
    round         = 0,
    spawnerToken  = 0,    -- bumped on stop() so live coroutines can detect abort
    heartConn     = nil :: RBXScriptConnection?,
}

------------------------------------------------------------
-- Scenario definitions.
--   AOE:        many small basic mobs in tight groups — exercises
--               splash damage, Detonator chains, knockback.
--   SingleBoss: one tanky mob per round — exercises sustained DPS,
--               stun-value (does my tower kill the boss faster
--               than its HP regen / phase windup?).
--   Mixed:     alternates basic / tank / boss waves so the spawner
--               doubles as a generic stress test.
--
-- Each entry returns a list of {mobType, count} pairs for round N.
------------------------------------------------------------
local SCENARIOS = {
    AOE = function(round)
        return {
            { mobType = "basic", count = 10 + round * 2 },
        }
    end,

    SingleBoss = function(round)
        -- Use the "tank" mob type as a stand-in for a single big
        -- target. MobFactory's run-difficulty hook scales HP per
        -- round via the spawner's pre-set RunDifficultyMult.
        return {
            { mobType = "tank", count = 1 + math.floor(round / 5) },
        }
    end,

    Mixed = function(round)
        local mod = round % 4
        if mod == 0 then
            return {
                { mobType = "tank",  count = 2 + math.floor(round / 3) },
                { mobType = "basic", count = 4 + round },
            }
        elseif mod == 1 then
            return {
                { mobType = "basic", count = 8 + round },
            }
        elseif mod == 2 then
            return {
                { mobType = "fast",  count = 6 + round },
            }
        else
            return {
                { mobType = "tank",  count = 2 + math.floor(round / 4) },
            }
        end
    end,
}

------------------------------------------------------------
-- Default tower loadout granted on Infinite entry. Generous so
-- the player can mix-and-match for any scenario without leaving
-- to the hub for stock.
------------------------------------------------------------
local LOADOUT = {
    PowerStock        = 5,
    RootSproutStock   = 4,
    FrostMelonStock   = 4,
    ThornVineStock    = 4,
    HoneyHiveStock    = 3,
    AcornSniperStock  = 3,
    LightningRadishStock = 3,
    SporePuffballStock   = 3,
    PepperCannonStock    = 3,
    MushroomMortarStock  = 3,
    RerollTokens      = 5,
    CarryingAmmo      = 0,
}

local function grantLoadout(player: Player)
    for attr, val in pairs(LOADOUT) do
        player:SetAttribute(attr, val)
    end
    -- Mark "stock granted" so the client unhides the hotbar via the
    -- standard plumbing (TreeOfLife_Hub watches HasBeenGrantedStock).
    player:SetAttribute("HasBeenGrantedStock", true)
end

------------------------------------------------------------
-- Return portal (built lazily on first entry).
------------------------------------------------------------
local function setupReturnPortal(map4Room: Model, spawnCF: CFrame, exitCallback: (Player) -> ())
    if returnPortalSetup then return end
    returnPortalSetup = true
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
    local pickRemote  = Remotes.getOrCreate(Remotes.Names.PickInfiniteScenario, "RemoteEvent")
    local roundRemote = Remotes.getOrCreate(Remotes.Names.InfiniteRoundUpdate, "RemoteEvent")
    -- Pre-create the picker remote so HubWorld can FireClient on it.
    Remotes.getOrCreate(Remotes.Names.ShowInfiniteScenarioPicker, "RemoteEvent")

    local function teleportTo(player: Player, cf: CFrame)
        local character = player.Character
        if not character then return end
        local hrp = character:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        hrp.CFrame = cf
    end

    ------------------------------------------------------------
    -- Spawner loop. Keeps spawning until State.active goes false.
    ------------------------------------------------------------
    local function spawnRound(scenario: string, round: number)
        local fn = SCENARIOS[scenario]
        if not fn then return end
        local groups = fn(round)
        local waypoints = ctx.getWaypoints()
        if not waypoints or #waypoints == 0 then
            warn("[Infinite] no waypoints — map 4 not active?")
            return
        end
        for _, group in ipairs(groups) do
            for _ = 1, group.count do
                if not State.active then return end
                local mob = ctx.makeMob(group.mobType, waypoints, 1.0)
                if mob then
                    mob:SetAttribute("MapId", 4)
                end
                -- Tiny stagger between mobs in a group so they don't
                -- spawn in the exact same frame (= same Position).
                task.wait(0.08)
            end
        end
    end

    local function startSpawnerLoop(scenario: string, myToken: number)
        task.spawn(function()
            local diff = (Config.Map4 and Config.Map4.Difficulty) or {}
            local intervalSec = diff.IntervalSec or 8
            local hpPerRound = diff.HpPerRound or 1.10
            local countPerRound = diff.CountPerRound or 1.05  -- reserved for future use
            local _ = countPerRound
            while State.active and State.spawnerToken == myToken do
                State.round = State.round + 1
                -- Set the run-difficulty multiplier BEFORE spawning so
                -- MobFactory.makeMob picks it up (mob HP ramps each round).
                Workspace:SetAttribute("RunDifficultyMult",
                    math.pow(hpPerRound, State.round - 1))
                if State.activePlayer then
                    roundRemote:FireClient(State.activePlayer, {
                        round    = State.round,
                        scenario = scenario,
                    })
                end
                print(("[Infinite] round %d (%s, HpMult=%.2f)"):format(
                    State.round, scenario,
                    Workspace:GetAttribute("RunDifficultyMult") or 1))
                spawnRound(scenario, State.round)
                if not State.active or State.spawnerToken ~= myToken then break end
                GameTime.adaptiveWait(intervalSec, function()
                    return State.active and State.spawnerToken == myToken
                end)
            end
        end)
    end

    local function stopSpawner()
        State.active = false
        State.spawnerToken = State.spawnerToken + 1
        if State.heartConn then
            State.heartConn:Disconnect()
            State.heartConn = nil
        end
        Workspace:SetAttribute("RunDifficultyMult", 1.0)
        if ctx.clearAllMobs then ctx.clearAllMobs() end
    end

    local function exit(player: Player)
        if not player or not player.Parent then return end
        -- Print + reset the stat ledger BEFORE we tear state down.
        if ctx.statLedger then
            print("[Infinite] -------- run summary --------")
            print(ctx.statLedger.summary())
            ctx.statLedger.reset()
        end
        stopSpawner()
        State.activePlayer = nil
        State.scenario = nil
        State.round = 0
        -- Restore StageState so the wave system's getHeart / getWaypoints
        -- resolve back to the player's last-played map (default 1 if
        -- they came straight from the hub).
        if ctx.StageState then ctx.StageState.currentMapId = 1 end
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

    local function hookHeartDeath()
        if State.heartConn then State.heartConn:Disconnect() end
        local heart = ctx.map4Heart
        if not heart then return end
        State.heartConn = heart:GetAttributeChangedSignal("Health"):Connect(function()
            if not State.active then return end
            local hp = heart:GetAttribute("Health") or 0
            if hp <= 0 and State.activePlayer then
                print("[Infinite] heart at 0 — ending run")
                exit(State.activePlayer)
            end
        end)
    end

    local function enter(player: Player, scenario: string?)
        if not player or not player.Parent then return end
        scenario = scenario or "Mixed"
        if not SCENARIOS[scenario] then
            warn("[Infinite] unknown scenario: " .. tostring(scenario))
            scenario = "Mixed"
        end
        if State.active then
            -- Reject overlapping enters; current architecture is single-player.
            warn(("[Infinite] %s tried to enter while a run was active"):format(player.Name))
            return
        end

        State.active        = true
        State.activePlayer  = player
        State.scenario      = scenario
        State.round         = 0
        State.spawnerToken  = State.spawnerToken + 1
        local myToken = State.spawnerToken

        -- Set StageState.currentMapId so getHeart / getWaypoints in the
        -- wave system resolve to map 4. Towers + mob update loops
        -- will then operate on the Pickle Swamp arena.
        if ctx.StageState then ctx.StageState.currentMapId = 4 end

        -- Reset the stat ledger so this run's stats start clean.
        if ctx.statLedger then ctx.statLedger.reset() end

        -- Heart full HP at run start (in case prior run damaged it
        -- and the heart wasn't auto-restored).
        if ctx.map4Heart then
            local maxHp = ctx.map4Heart:GetAttribute("MaxHealth") or Config.Map4.HeartMaxHp
            ctx.map4Heart:SetAttribute("Health", maxHp)
        end

        -- Lazy-build the return portal (first entry only).
        if ctx.map4Room then
            setupReturnPortal(ctx.map4Room, getMap4SpawnCF(), exit)
        end

        -- Cinematic + teleport.
        enterRemote:FireClient(player, {
            fadeOutSec = ENTRY_FADE_OUT_SEC,
            holdSec    = 0.4,
            fadeInSec  = 0.8,
            scenario   = scenario,
        })
        task.delay(ENTRY_FADE_OUT_SEC * 0.6, function()
            teleportTo(player, getMap4SpawnCF())
            grantLoadout(player)
            hookHeartDeath()
            startSpawnerLoop(scenario, myToken)
        end)
        print(("[Infinite] %s entered the pickle dimension (scenario=%s)"):format(
            player.Name, scenario))
    end

    -- Scenario picker handler. Validates payload + dispatches enter().
    pickRemote.OnServerEvent:Connect(function(player, payload)
        if type(payload) ~= "table" then return end
        local scenario = payload.scenario
        if type(scenario) ~= "string" then return end
        if Workspace:GetAttribute("InfiniteUnlocked") ~= true then
            warn(("[Infinite] %s picked scenario but Infinite is locked"):format(player.Name))
            return
        end
        enter(player, scenario)
    end)

    ctx.enterInfinite = enter
    ctx.exitInfinite  = exit

    print("[Infinite] system online (Workspace.InfiniteUnlocked = "
        .. tostring(Workspace:GetAttribute("InfiniteUnlocked")) .. ")")
end

return Infinite
