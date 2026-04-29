--[[
    InfiniteHUD.lua — Top-center label "WAVE N (TestType)" for the
    Balance Studio. Visible only when mapId == 4 (Pickle Swamp). Updates
    on every InfiniteRoundUpdate broadcast from systems/Infinite.lua.

    Phase 1 of project_infinite_arena.md — minimal informational HUD so
    the player can tell at a glance which wave they're on + which test
    type is running, without tabbing to the server log.

    Future work (this stays minimal until the user-designed Balance
    Studio panels land):
      - Heart HP overlay
      - Round timer
      - Active-mob count
      - Tower DPS chips

    setup(deps):
      deps.player, deps.playerGui, deps.ReplicatedStorage, deps.Remotes
]]

local InfiniteHUD = {}

-- Color per test type — matches the role-color convention from
-- project_tower_categories.md so the player learns to associate
-- red/blue/purple with the spawn type they're seeing.
local TEST_COLORS = {
    AOE      = Color3.fromRGB(255, 110, 110),   -- DPS-stress red
    Combined = Color3.fromRGB(180, 130, 240),   -- mixed purple
    Solo     = Color3.fromRGB(255, 200, 80),    -- single-target gold
}

function InfiniteHUD.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_InfiniteHUD"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 230
    gui.Enabled = false  -- hidden until first round update lands
    gui.Parent = playerGui

    local panel = Instance.new("Frame")
    panel.AnchorPoint = Vector2.new(0.5, 0)
    -- Pinned near the top of the screen — out of the way of the
    -- camera-roam area + the heart HP bar. Was y=80 (clipped by the
    -- main wave HUD when both showed); raised so the WAVE N (TestType)
    -- label is the dominant top-of-screen element on Map 4.
    panel.Position = UDim2.new(0.5, 0, 0, 20)
    panel.Size = UDim2.fromOffset(280, 44)
    panel.BackgroundColor3 = Color3.fromRGB(20, 24, 30)
    panel.BackgroundTransparency = 0.2
    panel.BorderSizePixel = 0
    panel.Parent = gui
    do
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 10)
        corner.Parent = panel
        local stroke = Instance.new("UIStroke")
        stroke.Thickness = 2
        stroke.Color = Color3.fromRGB(120, 220, 140)
        stroke.Parent = panel
    end

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    -- Idle state shows "THE PICKLE SWAMP" — replaces the regular hub
    -- "Entrance to the Tree of Life" label which would otherwise leak
    -- through on Map 4. (See init.client.lua's WaveState handler:
    -- waveFrame.Visible = false on mapId==4 so this panel is the
    -- only top-of-screen label.)
    label.Text = "THE PICKLE SWAMP"
    label.Font = Enum.Font.FredokaOne
    label.TextSize = 22
    label.TextColor3 = Color3.fromRGB(180, 255, 200)
    label.Parent = panel

    -- Constant for the idle label so the round-end / sweep-done
    -- listeners revert cleanly without retyping the string.
    local IDLE_LABEL_TEXT = "THE PICKLE SWAMP"
    local IDLE_LABEL_COLOR = Color3.fromRGB(180, 255, 200)

    -- AUTO RUN progress subtitle. Pinned just below the WAVE label.
    -- Visible during the benchmark sweep ("AUTO RUN: 12/73 — Power +
    -- ThornVine + FrostMelon"); cleared on InfiniteAutoRunDone.
    -- Sits in its own ScreenGui-ish frame to widen past the wave
    -- panel, since loadout labels can be 60+ chars.
    local autoRunPanel = Instance.new("Frame")
    autoRunPanel.AnchorPoint = Vector2.new(0.5, 0)
    autoRunPanel.Position = UDim2.new(0.5, 0, 0, 70)  -- below wave panel
    autoRunPanel.Size = UDim2.fromOffset(640, 32)
    autoRunPanel.BackgroundColor3 = Color3.fromRGB(20, 30, 22)
    autoRunPanel.BackgroundTransparency = 0.25
    autoRunPanel.BorderSizePixel = 0
    autoRunPanel.Visible = false
    autoRunPanel.Parent = gui
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 8)
        c.Parent = autoRunPanel
        local s = Instance.new("UIStroke")
        s.Thickness = 1.5
        s.Color = Color3.fromRGB(120, 220, 140)
        s.Parent = autoRunPanel
    end
    local autoRunLabel = Instance.new("TextLabel")
    autoRunLabel.Size = UDim2.fromScale(1, 1)
    autoRunLabel.BackgroundTransparency = 1
    autoRunLabel.Text = ""
    autoRunLabel.Font = Enum.Font.GothamBold
    autoRunLabel.TextSize = 16
    autoRunLabel.TextColor3 = Color3.fromRGB(160, 240, 180)
    autoRunLabel.TextXAlignment = Enum.TextXAlignment.Center
    autoRunLabel.TextTruncate = Enum.TextTruncate.AtEnd
    autoRunLabel.Parent = autoRunPanel

    -- Big centered countdown overlay (5..4..3..2..1 before wave 1).
    -- TextLabel (NOT TextButton) — earlier we used a TextButton so the
    -- player could click anywhere on the big "5" to skip, but that
    -- 300×220 button was intercepting RMB-camera-drag input across
    -- most of the screen, freezing the camera during the countdown.
    -- Now: visible digit is input-inert; the "TAP TO SKIP" hint
    -- below it is the actual click target (sized just to itself).
    local countdownLabel = Instance.new("TextLabel")
    countdownLabel.AnchorPoint = Vector2.new(0.5, 0.5)
    countdownLabel.Position = UDim2.fromScale(0.5, 0.4)
    countdownLabel.Size = UDim2.fromOffset(300, 220)
    countdownLabel.BackgroundTransparency = 1
    countdownLabel.Text = ""
    countdownLabel.Font = Enum.Font.FredokaOne
    countdownLabel.TextSize = 140
    countdownLabel.TextColor3 = Color3.fromRGB(255, 240, 140)
    countdownLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    countdownLabel.TextStrokeTransparency = 0.3
    countdownLabel.Visible = false
    -- Active=false belt-and-suspenders: ensures even with a future
    -- TextButton swap by accident the input still passes through.
    countdownLabel.Active = false
    countdownLabel.Parent = gui

    -- The actual click target — small button below the digit. Sized
    -- to itself so camera input passes everywhere else.
    local skipHint = Instance.new("TextButton")
    skipHint.AnchorPoint = Vector2.new(0.5, 0)
    skipHint.Position = UDim2.new(0.5, 0, 0, 200)
    skipHint.Size = UDim2.fromOffset(220, 36)
    skipHint.BackgroundColor3 = Color3.fromRGB(20, 30, 22)
    skipHint.BackgroundTransparency = 0.4
    skipHint.BorderSizePixel = 0
    skipHint.AutoButtonColor = true
    skipHint.Text = "TAP TO SKIP"
    skipHint.Font = Enum.Font.GothamBold
    skipHint.TextSize = 14
    skipHint.TextColor3 = Color3.fromRGB(220, 240, 220)
    skipHint.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    skipHint.TextStrokeTransparency = 0.4
    skipHint.Visible = false
    skipHint.Parent = gui
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = skipHint
    end

    local skipRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteSkipCountdown)
    skipHint.Activated:Connect(function()
        skipRemote:FireServer()
        countdownLabel.Visible = false
        skipHint.Visible = false
    end)

    -- Visibility gate: HUD shows only when on Map 4 AND no modal
    -- (admin / loadout picker / monitor) is open. Hoisted above the
    -- event listeners so they can route through it instead of
    -- forcing gui.Enabled = true (which would override the modal
    -- gate). Per Matthew 2026-04-26: "hide the AUTO RUN bubble when
    -- admin is open".
    local onMap4 = false
    local function refreshVisibility()
        local count = playerGui:GetAttribute("InfiniteModalCount") or 0
        local modalsOpen = count > 0
        gui.Enabled = onMap4 and not modalsOpen
    end

    local roundRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteRoundUpdate)
    roundRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" then return end
        local wave     = payload.wave
        local testType = payload.testType
        if type(wave) ~= "number" or type(testType) ~= "string" then return end
        label.Text = string.format("WAVE %d  (%s)", wave, testType)
        label.TextColor3 = TEST_COLORS[testType] or Color3.fromRGB(220, 240, 220)
    end)

    local countdownRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteCountdown)
    countdownRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" then return end
        local n = payload.countdown
        if type(n) ~= "number" then return end
        refreshVisibility()
        if n > 0 then
            countdownLabel.Visible = true
            countdownLabel.Text = tostring(n)
            skipHint.Visible = true
        else
            -- 0 = clear / hide. Wave 1 spawn fires immediately after.
            countdownLabel.Visible = false
            countdownLabel.Text = ""
            skipHint.Visible = false
        end
    end)

    -- AUTO RUN progress: server fires per-run with { current, total,
    -- label }. Show in the subtitle until InfiniteAutoRunDone clears.
    local autoRunProgressRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteAutoRunProgress)
    autoRunProgressRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" then return end
        local current = payload.current
        local total   = payload.total
        local lbl     = payload.label
        if type(current) ~= "number" or type(total) ~= "number" or type(lbl) ~= "string" then return end
        refreshVisibility()  -- gates on modals + onMap4
        autoRunPanel.Visible = true
        -- Strip "Power + " — Core is always present.
        local shortLbl = lbl:gsub("^Power %+ ", "")
        autoRunLabel.Text = string.format("AUTO RUN  %d/%d  —  %s", current, total, shortLbl)
    end)

    -- AUTO RUN done: clear the subtitle, revert to idle label.
    -- Tier list itself prints to the server log + lands in the
    -- payload's `tiers` field for future in-game display work.
    local autoRunDoneRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteAutoRunDone)
    autoRunDoneRemote.OnClientEvent:Connect(function(payload)
        autoRunPanel.Visible = false
        autoRunLabel.Text = ""
        label.Text = IDLE_LABEL_TEXT
        label.TextColor3 = IDLE_LABEL_COLOR
        if type(payload) == "table" and type(payload.results) == "table" then
            print(("[InfiniteHUD] AUTO RUN done — %d run(s); see server log for tier list"):format(
                #payload.results))
        end
    end)

    -- ea3-56: arena combo-info second row. Shows the active sweep
    -- combo (Core + auxes) + which story map this phase simulates.
    -- Server fires per phase start; subtitle clears on autoRunDone
    -- (no separate "arena sweep done" remote yet, so we piggyback).
    local arenaInfoPanel = Instance.new("Frame")
    arenaInfoPanel.AnchorPoint = Vector2.new(0.5, 0)
    -- Anchored below autoRunPanel (which is at y=70, 32 high) so
    -- the two stack cleanly during AUTORUN/SUPER AUTORUN sweeps.
    -- VALIDATE / single-combo runs only show this panel.
    arenaInfoPanel.Position = UDim2.new(0.5, 0, 0, 106)
    arenaInfoPanel.Size = UDim2.fromOffset(720, 30)
    arenaInfoPanel.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
    arenaInfoPanel.BackgroundTransparency = 0.25
    arenaInfoPanel.BorderSizePixel = 0
    arenaInfoPanel.Visible = false
    arenaInfoPanel.Parent = gui
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 8)
        c.Parent = arenaInfoPanel
        local s = Instance.new("UIStroke")
        s.Thickness = 1.5
        s.Color = Color3.fromRGB(170, 110, 200)  -- mauve, matches VALIDATE
        s.Parent = arenaInfoPanel
    end
    local arenaInfoLabel = Instance.new("TextLabel")
    arenaInfoLabel.Size = UDim2.fromScale(1, 1)
    arenaInfoLabel.BackgroundTransparency = 1
    arenaInfoLabel.Text = ""
    arenaInfoLabel.Font = Enum.Font.GothamBold
    arenaInfoLabel.TextSize = 15
    arenaInfoLabel.TextColor3 = Color3.fromRGB(220, 200, 240)
    arenaInfoLabel.TextXAlignment = Enum.TextXAlignment.Center
    arenaInfoLabel.TextTruncate = Enum.TextTruncate.AtEnd
    arenaInfoLabel.Parent = arenaInfoPanel

    local arenaComboInfoRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteArenaComboInfo)
    arenaComboInfoRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" then return end
        local coreId = payload.coreId or "?"
        local auxIds = payload.auxIds or {}
        local mapName = payload.simulatedMap or "?"
        -- Compose a compact label. Auxes shown as "Pepper / Honey /
        -- Pace" (last word of each towerId, dropped suffix). Empty
        -- aux list shows "(solo)".
        local function shortAux(id)
            -- Strip common suffixes for compactness: BlinkBerry → Blink,
            -- AcornSniper → Acorn, etc. Just take the first word-like
            -- prefix up to a capitalized boundary.
            local s = id:match("^([A-Z][a-z]+)") or id
            return s
        end
        local auxStrs = {}
        for _, id in ipairs(auxIds) do table.insert(auxStrs, shortAux(id)) end
        local auxLine = (#auxStrs > 0) and table.concat(auxStrs, " / ") or "(solo)"
        arenaInfoLabel.Text = string.format("%s + %s  •  %s", coreId, auxLine, mapName)
        arenaInfoPanel.Visible = true
    end)
    -- Clear the panel on autoRunDone (arena sweep done).
    autoRunDoneRemote.OnClientEvent:Connect(function()
        arenaInfoPanel.Visible = false
        arenaInfoLabel.Text = ""
    end)

    -- ea3-57: ETA progress bar — middle-of-screen-top during sweeps.
    -- Server fires {elapsedSec, totalSec, label, fraction} per phase
    -- boundary; bar fills from 0 → 1, center text counts down ETA.
    local progressFrame = Instance.new("Frame")
    progressFrame.AnchorPoint = Vector2.new(0.5, 0)
    progressFrame.Position = UDim2.new(0.5, 0, 0, 142)  -- below combo-info row (y=106 + 30 + 6)
    progressFrame.Size = UDim2.fromOffset(720, 24)
    progressFrame.BackgroundColor3 = Color3.fromRGB(20, 28, 40)
    progressFrame.BackgroundTransparency = 0.2
    progressFrame.BorderSizePixel = 0
    progressFrame.Visible = false
    progressFrame.Parent = gui
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = progressFrame
        local s = Instance.new("UIStroke")
        s.Thickness = 1.5
        s.Color = Color3.fromRGB(170, 110, 200)  -- mauve
        s.Parent = progressFrame
    end
    local progressFill = Instance.new("Frame")
    progressFill.AnchorPoint = Vector2.new(0, 0.5)
    progressFill.Position = UDim2.fromScale(0, 0.5)
    progressFill.Size = UDim2.fromScale(0, 1)  -- fraction-driven
    progressFill.BackgroundColor3 = Color3.fromRGB(170, 110, 200)
    progressFill.BackgroundTransparency = 0.4
    progressFill.BorderSizePixel = 0
    progressFill.Parent = progressFrame
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = progressFill
    end
    local progressLabel = Instance.new("TextLabel")
    progressLabel.Size = UDim2.fromScale(1, 1)
    progressLabel.BackgroundTransparency = 1
    progressLabel.Text = ""
    progressLabel.Font = Enum.Font.GothamBold
    progressLabel.TextSize = 13
    progressLabel.TextColor3 = Color3.fromRGB(240, 230, 250)
    progressLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    progressLabel.TextStrokeTransparency = 0.4
    progressLabel.TextXAlignment = Enum.TextXAlignment.Center
    progressLabel.Parent = progressFrame

    local arenaProgressRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteArenaProgress)
    arenaProgressRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" then return end
        local elapsed  = payload.elapsedSec or 0
        local total    = payload.totalSec or 0
        local fraction = payload.fraction or 0
        local lbl      = payload.label or ""
        if lbl == "DONE" or fraction >= 1 then
            -- Fade out after a short delay.
            progressFill.Size = UDim2.fromScale(1, 1)
            progressLabel.Text = lbl == "DONE" and "DONE" or "—"
            task.delay(1.5, function()
                progressFrame.Visible = false
                progressFill.Size = UDim2.fromScale(0, 1)
                progressLabel.Text = ""
            end)
            return
        end
        progressFrame.Visible = true
        progressFill.Size = UDim2.fromScale(math.max(0, math.min(1, fraction)), 1)
        local etaSec = math.max(0, total - elapsed)
        local etaMin = math.floor(etaSec / 60)
        local etaSecRem = math.floor(etaSec % 60)
        if etaMin > 0 then
            progressLabel.Text = string.format("%s  •  %dm %02ds left", lbl, etaMin, etaSecRem)
        else
            progressLabel.Text = string.format("%s  •  %ds left", lbl, etaSecRem)
        end
    end)

    -- Hide whenever the player leaves Map 4 (back to hub or another map).
    -- WaveState payload's mapId tells us the active map.
    -- (refreshVisibility + onMap4 forward-declared near the top of
    -- setup so the round/countdown/auto-run progress listeners can
    -- route through them.)
    local waveStateRemote = ReplicatedStorage:WaitForChild(Remotes.Names.WaveState)
    local wasOnMap4 = false
    waveStateRemote.OnClientEvent:Connect(function(state)
        if type(state) ~= "table" then return end
        if state.mapId == 4 then
            onMap4 = true
            -- Fresh arrival on Map 4 — reset to idle label. Subsequent
            -- InfiniteRoundUpdate events will overwrite this with
            -- "WAVE N (TestType)" once the run starts.
            if not wasOnMap4 then
                label.Text = IDLE_LABEL_TEXT
                label.TextColor3 = IDLE_LABEL_COLOR
            end
            wasOnMap4 = true
        else
            onMap4 = false
            wasOnMap4 = false
            label.Text = IDLE_LABEL_TEXT
            label.TextColor3 = IDLE_LABEL_COLOR
            autoRunPanel.Visible = false
            autoRunLabel.Text = ""
        end
        refreshVisibility()
    end)

    -- Hide HUD when the loadout picker or admin panel is open.
    -- Modals increment/decrement playerGui.InfiniteModalCount;
    -- attribute-based count is race-safe across overlapping modals.
    playerGui:GetAttributeChangedSignal("InfiniteModalCount"):Connect(refreshVisibility)
end

return InfiniteHUD
