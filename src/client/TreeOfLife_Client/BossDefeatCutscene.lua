--[[
    BossDefeatCutscene.lua — The "you killed the map boss, your Core
    walks over to absorb itself" cutscene that plays after the temp-
    tower picker closes (server fires Remotes.PlayBossCutscene with the
    Core tower's world position).

    Cutscene flow: pathfind to the tower (PathfindingService waypoints,
    walking each leg with Humanoid:MoveTo), pause 0.5s on arrival, then
    fire BossCutsceneDone → server destroys the Core + Map1 drops the
    ladder OR Map2 destroys all towers + descends the next portal.

    PATHFINDING: previously the cutscene called MoveTo straight at the
    Core tower, which on Map 2 left the player stuck against the spiral
    staircase if the boss died on the opposite side from the Core.
    PathfindingService:CreatePath gives a list of waypoints around any
    obstacles; walking them in sequence routes the player around the
    staircase cleanly. Falls back to a direct MoveTo if the path
    computation fails (e.g. unreachable destination).

    JumpPower restoration relies on the cutscene completing; if it
    aborts mid-way (player leaves, etc.) the JumpPower stays at 0
    until the next character respawn — acceptable failure mode.

    setup(deps) captures:
      deps.player
      deps.ReplicatedStorage
      deps.Remotes
]]

local ContextActionService = game:GetService("ContextActionService")
local PathfindingService   = game:GetService("PathfindingService")

local BossDefeatCutscene = {}

function BossDefeatCutscene.setup(deps)
    local player            = deps.player
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes

    ReplicatedStorage:WaitForChild(Remotes.Names.PlayBossCutscene).OnClientEvent:Connect(function(payload)
        local target = payload and payload.corePosition
        if not target then return end
        local char = player.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        local hum  = char and char:FindFirstChildWhichIsA("Humanoid")
        if not (hrp and hum) then return end

        -- Stop a couple of studs back from the tower's footprint.
        local dir = hrp.Position - target
        if dir.Magnitude < 0.01 then dir = Vector3.new(0, 0, 4) end
        local approachPos = Vector3.new(
            target.X + dir.Unit.X * 4,
            hrp.Position.Y,
            target.Z + dir.Unit.Z * 4)

        -- Sink WASD + jump so player input doesn't fight the MoveTo path.
        -- Without this, holding W during the cutscene drags the character
        -- past approachPos and the cutscene "completes" wherever the player
        -- happened to be — replaces a clean victory walk with a confused
        -- shuffle. ContextActionService.Sink absorbs the input at high
        -- priority so other handlers (camera shake, etc.) don't run either.
        local SINK_NAME = "ToL_BossCutsceneInputSink"
        ContextActionService:BindActionAtPriority(
            SINK_NAME,
            function() return Enum.ContextActionResult.Sink end,
            false,
            Enum.ContextActionPriority.High.Value,
            Enum.PlayerActions.CharacterForward,
            Enum.PlayerActions.CharacterBackward,
            Enum.PlayerActions.CharacterLeft,
            Enum.PlayerActions.CharacterRight,
            Enum.PlayerActions.CharacterJump
        )

        -- Pathfind to the tower so the player routes AROUND obstacles
        -- (Map 2's spiral staircase is the big one — straight MoveTo
        -- left them grinding into a step). Walk each path waypoint in
        -- sequence; on path-fail, fall back to direct MoveTo so the
        -- cutscene still completes (just with the old "may get stuck"
        -- behaviour rather than refusing to move at all).
        local origJump = hum.JumpPower
        hum.JumpPower = 0
        hum.WalkSpeed = 22

        local path = PathfindingService:CreatePath({
            AgentRadius      = 2,
            AgentHeight      = 5,
            AgentCanJump     = false,
            WaypointSpacing  = 4,
        })
        local pathOk = false
        local pcSuccess, pcErr = pcall(function()
            path:ComputeAsync(hrp.Position, approachPos)
        end)
        if pcSuccess and path.Status == Enum.PathStatus.Success then
            pathOk = true
        else
            warn(("[BossDefeatCutscene] path %s — falling back to direct MoveTo"):format(
                pcSuccess and tostring(path.Status) or tostring(pcErr)))
        end

        if pathOk then
            for _, wp in ipairs(path:GetWaypoints()) do
                if not (hrp.Parent and hum.Parent) then break end
                hum:MoveTo(wp.Position)
                hum.MoveToFinished:Wait()
            end
        else
            hum:MoveTo(approachPos)
            hum.MoveToFinished:Wait()
        end

        hum.WalkSpeed = 0
        hrp.CFrame = CFrame.new(hrp.Position,
            Vector3.new(target.X, hrp.Position.Y, target.Z))
        task.wait(0.5)
        hum.WalkSpeed = 16
        hum.JumpPower = origJump
        ContextActionService:UnbindAction(SINK_NAME)
        local doneRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.BossCutsceneDone)
        if doneRemote then doneRemote:FireServer() end
    end)
end

return BossDefeatCutscene
