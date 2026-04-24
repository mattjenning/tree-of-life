--[[
    BossDefeatCutscene.lua — The "you killed the map boss, your Core
    walks over to absorb itself" cutscene that plays after the temp-
    tower picker closes (server fires Remotes.PlayBossCutscene with the
    Core tower's world position).

    Cutscene flow: run to the tower (Humanoid:MoveTo, server-driven),
    walk slowly the last beat, kneel/face the tower, pause 0.5s, then
    fire BossCutsceneDone → server destroys the Core + Map2 drops the
    rope ladder.

    All motion is Humanoid-driven (MoveTo + WalkSpeed + JumpPower
    blocking) so pathfinding + animation transitions come for free.
    JumpPower restoration relies on the cutscene completing; if it
    aborts mid-way (player leaves, etc.) the JumpPower stays at 0
    until the next character respawn — acceptable failure mode.

    setup(deps) captures:
      deps.player
      deps.ReplicatedStorage
      deps.Remotes
]]

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

        -- Run to the tower, wait for arrival (not a fixed timer — the path
        -- length varies by where the player died relative to where they
        -- placed their Core), then a 0.5s pause, then signal the server to
        -- destroy the tower + drop the ladder. MoveToFinished's `reached`
        -- arg handles both cases (arrived / 8s internal timeout) identically
        -- — either way, we stop and pause at whatever spot we ended up at.
        local origJump = hum.JumpPower
        hum.JumpPower = 0
        hum.WalkSpeed = 22
        hum:MoveTo(approachPos)
        hum.MoveToFinished:Wait()
        hum.WalkSpeed = 0
        hrp.CFrame = CFrame.new(hrp.Position,
            Vector3.new(target.X, hrp.Position.Y, target.Z))
        task.wait(0.5)
        hum.WalkSpeed = 16
        hum.JumpPower = origJump
        local doneRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.BossCutsceneDone)
        if doneRemote then doneRemote:FireServer() end
    end)
end

return BossDefeatCutscene
