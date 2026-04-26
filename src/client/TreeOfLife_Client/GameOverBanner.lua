--[[
    GameOverBanner.lua — fullscreen win/lose modal shown when the server
    fires Remotes.GameOver. On "lose" flips the player's client-side
    gameLost gate (HUD locks to DEFEATED, WaveState updates ignored);
    the "RESET & PLAY AGAIN" button drives DevReset + a follow-up
    DevTeleport(map1) so the player ends up back at the map-1 TD
    spawn regardless of where the heart actually fell.

    Tears down any competing modals before presenting (upgrade picker,
    temp-tower reward, permanent-tower equip/reward, boss minigame
    targets) so they don't sit underneath the banner.

    Extracted from init.client.lua to free main-chunk registers.

    setup(deps) captures:
      deps.playerGui
      deps.ReplicatedStorage
      deps.Remotes
      deps.markDefeated   — callback fired on "lose" result. The main
                            chunk owns the gameLost flag + the wave
                            HUD labels (waveLabel / waveFrame); hiding
                            the coupling behind one callback keeps this
                            module from needing either handle.
]]

local GameOverBanner = {}

function GameOverBanner.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local markDefeated      = deps.markDefeated

    ReplicatedStorage:WaitForChild(Remotes.Names.GameOver).OnClientEvent:Connect(function(payload)
        local old = playerGui:FindFirstChild("ToL_GameOver")
        if old then old:Destroy() end
        -- Also tear down the upgrade picker if it's currently showing, so the
        -- "TAP TO CLAIM" cards don't sit underneath the game-over modal.
        local picker = playerGui:FindFirstChild("ToL_UpgradePicker")
        if picker then picker:Destroy() end
        -- Same for the temp-tower reward picker (boss defeat → pick 1 of 3).
        local tempPicker = playerGui:FindFirstChild("ToL_TempTowerPicker")
        if tempPicker then tempPicker:Destroy() end
        -- Same for the permanent-tower equip modal (pedestal).
        local permEquip = playerGui:FindFirstChild("ToL_PermanentEquip")
        if permEquip then permEquip:Destroy() end
        -- Same for the permanent-tower reward modal (Pickle Lord defeat).
        local permReward = playerGui:FindFirstChild("ToL_PermanentTowerReward")
        if permReward then permReward:Destroy() end
        -- Tear down boss minigame targets if any are still up
        local bossTargets = playerGui:FindFirstChild("ToL_BossTargets")
        if bossTargets then bossTargets:Destroy() end

        local isWin = payload.result == "win"
        -- If we lost, override the wave HUD to say DEFEATED so it doesn't fall
        -- through to the "All waves cleared" branch when the loss happens on
        -- the boss (final wave). Main chunk owns the gameLost flag + the
        -- HUD label references, so it handles the flip behind one callback.
        if not isWin and markDefeated then
            markDefeated()
        end

        local gui = Instance.new("ScreenGui")
        gui.Name = "ToL_GameOver"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 230
        gui.Parent = playerGui

        local bg = Instance.new("Frame")
        bg.Size = UDim2.fromScale(1, 1)
        bg.BackgroundColor3 = isWin and Color3.fromRGB(20, 60, 30) or Color3.fromRGB(60, 20, 20)
        bg.BackgroundTransparency = 0.25
        bg.BorderSizePixel = 0
        bg.Parent = gui

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, 0, 0, 80)
        title.Position = UDim2.fromScale(0, 0.35)
        title.BackgroundTransparency = 1
        title.Text = isWin and "VICTORY!" or "THE HEART FELL"
        title.TextColor3 = isWin and Color3.fromRGB(255, 255, 180) or Color3.fromRGB(255, 120, 120)
        title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        title.TextStrokeTransparency = 0.3
        title.Font = Enum.Font.FredokaOne
        title.TextSize = 64
        title.Parent = bg

        local sub = Instance.new("TextLabel")
        sub.Size = UDim2.new(1, 0, 0, 64)  -- 2 lines for "...until falling to <long boss name>"
        sub.Position = UDim2.fromScale(0, 0.48)
        sub.BackgroundTransparency = 1
        sub.TextWrapped = true
        do
            local totalDefeated = payload.totalWavesDefeated or 0
            if isWin then
                if payload.defeatedFinalBoss then
                    sub.Text = string.format("You defeated the Pickle Lord after %d rounds!", totalDefeated)
                else
                    sub.Text = string.format("You defended the Tree through %d rounds", totalDefeated)
                end
            else
                if payload.killerBossName and totalDefeated > 0 then
                    sub.Text = string.format("You held out for %d rounds until falling to %s",
                        totalDefeated, payload.killerBossName)
                elseif payload.killerBossName then
                    sub.Text = string.format("%s has defeated you", payload.killerBossName)
                elseif totalDefeated > 0 then
                    sub.Text = string.format("You held out for %d rounds before falling", totalDefeated)
                else
                    sub.Text = "The first wave overwhelmed your defenses"
                end
            end
        end
        sub.TextColor3 = Color3.fromRGB(230, 230, 230)
        sub.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        sub.TextStrokeTransparency = 0.4
        sub.Font = Enum.Font.Gotham
        sub.TextSize = 22
        sub.Parent = bg

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(240, 50)
        btn.Position = UDim2.new(0.5, -120, 0.62, 0)  -- nudged down to clear the 2-line subtitle
        btn.BackgroundColor3 = Color3.fromRGB(80, 140, 200)
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        -- Run-victory: player just defeated the Pickle Lord. Send them
        -- back to the HUB (not map 1) so they can pick a new equipped
        -- permanent before the next run. Other paths (loss / wave-clear
        -- win) still route to map 1 for retry.
        local isRunVictory = isWin and payload.runVictory == true
        btn.Text = isRunVictory and "RETURN TO HUB" or "RESET & PLAY AGAIN"
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        btn.TextStrokeTransparency = 0.4
        btn.Font = Enum.Font.FredokaOne
        btn.TextSize = 20
        btn.Parent = bg
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0.2, 0)
        c.Parent = btn

        btn.MouseButton1Click:Connect(function()
            -- CRITICAL: clear the gameLost lock so the WaveState handler stops
            -- ignoring server updates. Without this, wave 1 runs server-side
            -- after reset but the HUD stays stuck on DEFEATED, looking frozen.
            if deps.unlockGameLost then deps.unlockGameLost() end
            ReplicatedStorage:WaitForChild(Remotes.Names.DevReset):FireServer()
            -- Run-victory routes to HUB; loss / wave-win route to map 1
            -- TD spawn for retry.
            local destination = isRunVictory and "hub" or "map1"
            task.delay(0.25, function()
                local tp = ReplicatedStorage:FindFirstChild(Remotes.Names.DevTeleport)
                if tp then tp:FireServer(destination) end
            end)
            gui:Destroy()
        end)
    end)
end

return GameOverBanner
