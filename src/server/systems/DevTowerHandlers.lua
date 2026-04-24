--[[
    DevTowerHandlers.lua — Dev panel handlers that only touch tower
    attributes + per-player flags. No coupling to wave orchestrator
    state (no runWave / currentWave / waveRunToken reads), which is
    why these three can ship as a module while the boss-spawn /
    skip-to-boss dev handlers stay in TreeOfLife_WaveSystem.

    Handlers covered:
      - DevAddStun         : player presses "+STUN" — adds one Stun
                             stack to every tower the player owns.
      - DevResetCooldowns  : player presses "RESET COOLDOWNS" — clears
                             Phoenix cooldown + grace on their towers,
                             plus the server-side PhoenixGrace gate and
                             BonusDamageUntil timer.
      - DevUnlimitedAmmo   : toggles the per-player DevUnlimitedAmmo
                             attribute. Towers.lua reads it at fire
                             time to skip the Shots decrement.

    setup(ctx) reads:
      ctx.applyStunStackToOwnedTowers  (from UpgradeCards.setup)
      ctx.phoenixDisplayCd             (from Phoenix.setup — per-tower
      ctx.phoenixDisplayGrace            HUD cooldown/grace display maps)
      ctx.PhoenixGrace                 (from Phoenix.setup — server-side
                                        grace-window state for the
                                        mob-teleport check)

    Publishes nothing.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared   = ReplicatedStorage:WaitForChild("Shared")
local Remotes  = require(Shared:WaitForChild("Remotes"))
local Tags     = require(Shared:WaitForChild("Tags"))

local DevTowerHandlers = {}

function DevTowerHandlers.setup(ctx)
    local applyStunStackToOwnedTowers = ctx.applyStunStackToOwnedTowers

    local devAddStunRemote = ReplicatedStorage:WaitForChild(Remotes.Names.DevAddStun)
    local devResetCdRemote = ReplicatedStorage:WaitForChild(Remotes.Names.DevResetCooldowns)
    local devUnlimitedAmmoRemote = ReplicatedStorage:FindFirstChild(Remotes.Names.DevUnlimitedAmmo)
        or (function()
            local r = Instance.new("RemoteEvent")
            r.Name = Remotes.Names.DevUnlimitedAmmo
            r.Parent = ReplicatedStorage
            return r
        end)()

    ------------------------------------------------------------
    -- DEV: add a Stun stack to all of the calling player's towers. Mirrors
    -- what picking a Stun special card does (uses SPECIAL_EFFECTS["Stun"]
    -- base/increment), but bypasses the upgrade-picked path so it doesn't
    -- inflate RUN LUCK or affect the wave-progression flow. Used from the
    -- dev panel for testing the stun mechanic without waiting on RNG.
    ------------------------------------------------------------
    devAddStunRemote.OnServerEvent:Connect(function(player)
        local touched = applyStunStackToOwnedTowers(player)
        print(("[Waves] DEV: %s added Stun stack to %d tower(s)"):format(player.Name, touched))
    end)

    ------------------------------------------------------------
    -- DEV: reset all per-tower cooldowns AND timed buffs for the calling
    -- player. Useful for testing Phoenix without waiting 12+ minutes between
    -- triggers, and for clearing leftover BonusDamageUntil from boss minigame
    -- testing. Iterates only towers owned by the caller.
    ------------------------------------------------------------
    devResetCdRemote.OnServerEvent:Connect(function(player)
        local touched = 0
        for _, towerBase in ipairs(CollectionService:GetTagged(Tags.Tower)) do
            local t = towerBase.Parent
            if t and t:GetAttribute("Owner") == player.UserId then
                -- Phoenix: ready immediately, no cooldown, no active grace.
                -- Set the attributes regardless of EquippedType — cheap, and
                -- harmless on towers without Phoenix (they just get unused
                -- attributes set to 0/true, which they ignore).
                if t:GetAttribute("EquippedType") == "Phoenix" then
                    t:SetAttribute("PhoenixReady", true)
                    t:SetAttribute("PhoenixCdRemaining", 0)
                    t:SetAttribute("PhoenixGraceRemaining", 0)
                    ctx.phoenixDisplayCd[t]    = nil
                    ctx.phoenixDisplayGrace[t] = nil
                end
                touched = touched + 1
            end
        end
        -- Server-side grace state (for the actual mob-teleport check) — clear it
        -- too so a "reset" really means everything is cold.
        ctx.PhoenixGrace.activeUntil = 0
        -- Final-boss bonus damage timer (set by completing the tap minigame).
        player:SetAttribute("BonusDamageUntil", 0)
        player:SetAttribute("BonusDamageExtraPct", 0)
        print(("[Waves] DEV: %s reset cooldowns on %d tower(s)"):format(player.Name, touched))
    end)

    ------------------------------------------------------------
    -- DEV: Unlimited Ammo — toggle a per-player flag. updateTowers reads it
    -- via the tower's owner and skips Shots decrement when set.
    ------------------------------------------------------------
    devUnlimitedAmmoRemote.OnServerEvent:Connect(function(player, enabled)
        player:SetAttribute("DevUnlimitedAmmo", enabled and true or false)
        print(("[Dev] %s toggled Unlimited Ammo: %s"):format(
            player.Name, tostring(enabled and true or false)))
    end)
end

return DevTowerHandlers
