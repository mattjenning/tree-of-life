--[[
    InfiniteMonitorWindow.lua — Live AUTO RUN stats overlay.

    Pops up when AUTO RUN starts; shows current loadout, progress
    (N/total), recent results (last few completed runs with their
    finalWave + testType), and a header.

    DESIGN:
    - Independent ScreenGui so it can be opened/closed/dragged
      separately from the admin panel.
    - Auto-shows on first InfiniteAutoRunProgress event of a sweep.
    - Tracks the last 8 results client-side from progress events
      (server includes the per-loadout `finalWave` in the autoRunDone
      payload, but for live updates we infer "previous run finished"
      from the progress event advancing).
    - Closes via X button (independently of the admin panel).
    - Hides when sweep finishes, AUTO RUN aborts, or player exits.

    Per Matthew 2026-04-26: "when auto run is running change button
    to MONITOR and pop up a window with current run stats that I can
    move as well and close independently."

    setup(deps): builds the GUI + listeners once. Public API:
      - open()  : show the window (also fired automatically on
                  first AUTO RUN progress event)
      - close() : hide the window
]]

local InfiniteMonitorWindow = {}

local windowGui = nil

local function buildWindow(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes

    local gui = Instance.new("ScreenGui")
    gui.Name = "ToL_InfiniteMonitorWindow"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    -- DisplayOrder 64 → 235 (2026-04-27) per Matthew "monitor should
    -- be on top here" — when AUTO RUN was firing the WAVE banner
    -- (init.client.lua waveGui = 225) and the InfiniteHUD (230) both
    -- rendered above the monitor, clipping its title row. 235 sits
    -- above both wave HUDs but still below permanent-tower modals
    -- (250+) and dev-panel reveal (260) so those still stack
    -- correctly.
    gui.DisplayOrder = 235
    gui.Enabled = false
    gui.Parent = playerGui

    -- Compact, top-right by default. User can drag anywhere.
    -- Tall enough to fit progress + recent runs + live tower
    -- stats with prospective tier (added 2026-04-26 per Matthew:
    -- "add a section on the autorun monitor to show tower stats
    -- on the run so far and prospective tier placement").
    local panel = Instance.new("Frame")
    panel.AnchorPoint = Vector2.new(1, 0)
    panel.Position = UDim2.new(1, -20, 0, 60)
    -- Width 720 (was 420) so DPS / Control / Support tier
    -- columns can lay out HORIZONTALLY 3-up instead of stacked.
    -- Per Matthew 2026-04-28 monitor redesign — frees vertical
    -- space the OBSERVATIONS scroll uses to accommodate role-mix
    -- means + top-3-combos breakdown.
    -- Height 640 (was 540) for the multi-line-per-combo
    -- observations block.
    panel.Size = UDim2.fromOffset(580, 640)
    panel.BackgroundColor3 = Color3.fromRGB(20, 28, 22)
    panel.BorderSizePixel = 0
    panel.Parent = gui
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 12)
        c.Parent = panel
        local s = Instance.new("UIStroke")
        s.Color = Color3.fromRGB(120, 220, 140)
        s.Thickness = 2
        s.Parent = panel
    end

    -- Drag handle covering the title bar.
    local dragHandle = Instance.new("Frame")
    dragHandle.Size = UDim2.new(1, 0, 0, 44)
    dragHandle.Position = UDim2.fromOffset(0, 0)
    dragHandle.BackgroundTransparency = 1
    dragHandle.Active = true
    dragHandle.Parent = panel

    local title = Instance.new("TextLabel")
    -- Width trimmed (was -56) to leave room for the new STOP RUN
    -- button between the title and the close X.
    title.Size = UDim2.new(1, -160, 0, 28)
    title.Position = UDim2.fromOffset(12, 8)
    title.BackgroundTransparency = 1
    title.Text = "AUTO RUN MONITOR  ⋮⋮"
    title.Font = Enum.Font.FredokaOne
    title.TextSize = 18
    title.TextColor3 = Color3.fromRGB(180, 255, 200)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = panel

    -- STOP-RUN three-mode picker (Matthew 2026-04-28 redesign):
    --   < CONTINUOUS >    — sweep auto-loops. Cycling to this state
    --                       fires stopRun{mode="continuous"} as a
    --                       toggle (auto-applies on arrival).
    --   < STOP AT END >   — current sweep finishes, no next loop.
    --                       Cycling to this state fires
    --                       stopRun{mode="atEnd"} as a toggle.
    --   < STOP NOW >      — abort immediately. Does NOT auto-fire on
    --                       cycle-arrival. User must explicitly CLICK
    --                       the center button to commit.
    -- Left/right arrows rotate through the modes (wraps). The
    -- center button shows the current mode; in CONTINUOUS / STOP
    -- AT END states it's a passive label (already-applied state).
    -- In STOP NOW state it's a clickable abort action.
    -- Hidden when no sweep is active.
    local stopRunRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteStopRun)
    local STOP_MODES = { "continuous", "atEnd", "now" }
    local STOP_LABELS = {
        continuous = "CONTINUOUS",
        atEnd      = "STOP AT END",
        now        = "STOP NOW",
    }
    local STOP_COLORS = {
        continuous = Color3.fromRGB(80, 180, 100),   -- green: keep going
        atEnd      = Color3.fromRGB(220, 130, 60),   -- orange: wind down
        now        = Color3.fromRGB(220, 50, 50),    -- red: abort
    }
    local stopMode = "continuous"

    -- Layout (right-anchored at AnchorPoint(1,0); position = RIGHT
    -- edge of each button). 4px gap between buttons.
    --   close X      : right -8,   width 32  → spans -40  .. -8
    --   right arrow >: right -44,  width 28  → spans -72  .. -44
    --   center btn   : right -76,  width 108 → spans -184 .. -76
    --   left arrow < : right -188, width 28  → spans -216 .. -188
    local stopRunBtn = Instance.new("TextButton")
    stopRunBtn.AnchorPoint = Vector2.new(1, 0)
    stopRunBtn.Position = UDim2.new(1, -76, 0, 8)
    stopRunBtn.Size = UDim2.fromOffset(108, 28)
    stopRunBtn.BackgroundColor3 = STOP_COLORS.continuous
    stopRunBtn.BorderSizePixel = 0
    stopRunBtn.AutoButtonColor = true
    stopRunBtn.Text = STOP_LABELS.continuous
    stopRunBtn.Font = Enum.Font.FredokaOne
    stopRunBtn.TextSize = 14
    stopRunBtn.TextColor3 = Color3.fromRGB(255, 240, 235)
    stopRunBtn.ZIndex = 5
    stopRunBtn.Visible = false
    stopRunBtn.Parent = panel
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = stopRunBtn
    end

    local function makeArrowBtn(label, xOffset)
        local b = Instance.new("TextButton")
        b.AnchorPoint = Vector2.new(1, 0)
        b.Position = UDim2.new(1, xOffset, 0, 8)
        b.Size = UDim2.fromOffset(28, 28)
        b.BackgroundColor3 = Color3.fromRGB(60, 64, 70)
        b.BorderSizePixel = 0
        b.AutoButtonColor = true
        b.Text = label
        b.Font = Enum.Font.FredokaOne
        b.TextSize = 16
        b.TextColor3 = Color3.fromRGB(220, 230, 220)
        b.ZIndex = 5
        b.Visible = false
        b.Parent = panel
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = b
        return b
    end
    local stopLeftBtn  = makeArrowBtn("<", -188)
    local stopRightBtn = makeArrowBtn(">", -44)

    local function applyStopMode(mode)
        stopMode = mode
        stopRunBtn.Text = STOP_LABELS[mode] or "?"
        stopRunBtn.BackgroundColor3 = STOP_COLORS[mode] or Color3.fromRGB(60, 60, 60)
        -- Toggle modes (continuous / atEnd) auto-fire on arrival.
        -- The "now" mode does NOT — user must click the center
        -- button to commit the abort.
        if mode == "continuous" or mode == "atEnd" then
            stopRunRemote:FireServer({ mode = mode })
        end
    end

    local function indexOfStopMode(mode)
        for i, m in ipairs(STOP_MODES) do
            if m == mode then return i end
        end
        return 1
    end

    stopLeftBtn.MouseButton1Click:Connect(function()
        local i = indexOfStopMode(stopMode)
        i = i - 1
        if i < 1 then i = #STOP_MODES end
        applyStopMode(STOP_MODES[i])
    end)
    stopRightBtn.MouseButton1Click:Connect(function()
        local i = indexOfStopMode(stopMode)
        i = i + 1
        if i > #STOP_MODES then i = 1 end
        applyStopMode(STOP_MODES[i])
    end)
    stopRunBtn.MouseButton1Click:Connect(function()
        -- Only the "now" mode commits on center-button click.
        -- Other modes' click is a no-op (they were already applied
        -- on arrival via the cycle arrows).
        if stopMode == "now" then
            stopRunRemote:FireServer({ mode = "now" })
            -- autoRunDone event will hide the button trio.
        end
    end)

    local function resetStopBtnToStage1()
        -- Sweep starts in CONTINUOUS by default (server defaults
        -- autoRun.continuous = true). Don't fire continuous on
        -- reset — server already has the right state; just sync
        -- the visual.
        stopMode = "continuous"
        stopRunBtn.Text = STOP_LABELS.continuous
        stopRunBtn.BackgroundColor3 = STOP_COLORS.continuous
    end

    local closeBtn = Instance.new("TextButton")
    closeBtn.AnchorPoint = Vector2.new(1, 0)
    closeBtn.Position = UDim2.new(1, -8, 0, 8)
    closeBtn.Size = UDim2.fromOffset(32, 28)
    closeBtn.BackgroundColor3 = Color3.fromRGB(70, 30, 30)
    closeBtn.BorderSizePixel = 0
    closeBtn.AutoButtonColor = false
    closeBtn.Text = "X"
    closeBtn.Font = Enum.Font.FredokaOne
    closeBtn.TextSize = 16
    closeBtn.TextColor3 = Color3.fromRGB(240, 200, 200)
    closeBtn.ZIndex = 5
    closeBtn.Parent = panel
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = closeBtn
    end
    closeBtn.MouseButton1Click:Connect(function()
        gui.Enabled = false
    end)

    -- Drag wiring (same pattern as InfiniteAdminPanel).
    local UserInputService = game:GetService("UserInputService")
    local dragging, dragStart, startPos = false, nil, nil
    dragHandle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            dragging  = true
            dragStart = input.Position
            startPos  = panel.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
           and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end
        local delta = input.Position - dragStart
        panel.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end)

    -- Body content: divider → tower stats → observations.
    -- Per Matthew 2026-04-27: "remove the whole recent runs
    -- section." The combo # moved down to the observations
    -- header line so per-run identification still survives.
    -- state.recent stays as a backing data structure (used by
    -- observations to find the last 3 completed combos), it just
    -- has no rendered surface anymore.
    local divider = Instance.new("Frame")
    divider.Size = UDim2.new(1, -24, 0, 1)
    divider.Position = UDim2.fromOffset(12, 42)
    divider.BackgroundColor3 = Color3.fromRGB(60, 80, 60)
    divider.BorderSizePixel = 0
    divider.Parent = panel

    -- ── TOWER STATS section ─────────────────────────────────
    -- Per-tower aggregate of fail-wave averages plus prospective
    -- tier placement (computed client-side using the same alpha-
    -- bucket logic as server's assembleTiers).
    local towerStatsTitle = Instance.new("TextLabel")
    towerStatsTitle.Size = UDim2.new(1, -24, 0, 18)
    towerStatsTitle.Position = UDim2.fromOffset(12, 50)
    towerStatsTitle.BackgroundTransparency = 1
    towerStatsTitle.Text = "TOWER STATS  +  PROSPECTIVE TIER"
    towerStatsTitle.Font = Enum.Font.FredokaOne
    towerStatsTitle.TextSize = 13
    towerStatsTitle.TextColor3 = Color3.fromRGB(255, 200, 140)
    towerStatsTitle.TextXAlignment = Enum.TextXAlignment.Left
    towerStatsTitle.Parent = panel

    -- 3-up column layout for tier list (DPS / Control / Support).
    -- 2026-04-28 update per Matthew: columns now content-tall +
    -- packed tight with NO gap, so left edge of Control aligns
    -- with right edge of DPS (and same for Support). Empty space
    -- below shorter role lists is reclaimed; OBSERVATIONS title
    -- + OVERALL PATTERNS region move up to fill it.
    --
    -- Column geometry: each column is 180 wide (fits longest
    -- tower-name + stats string at GothamBold 11). Three columns
    -- packed = 540 + 24 outer padding = 564 → panel widened to
    -- 580 to keep the title bar's STOP picker breathing room.
    -- Columns are AutomaticSize.Y so each ends right after its
    -- last row — no fixed-height frame, no internal scroll
    -- needed at typical tower counts (max 6 per role).
    local TIER_COL_W = 180
    local TIER_TOP   = 72

    local towerStatsCols = {}  -- { DPS = column Frame, ... }
    local function makeTierColumn(role, x, color)
        local col = Instance.new("Frame")
        col.Size = UDim2.fromOffset(TIER_COL_W, 0)
        col.AutomaticSize = Enum.AutomaticSize.Y
        col.Position = UDim2.fromOffset(x, TIER_TOP)
        col.BackgroundTransparency = 1
        col.Parent = panel

        local layout = Instance.new("UIListLayout")
        layout.FillDirection = Enum.FillDirection.Vertical
        layout.Padding = UDim.new(0, 1)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = col

        local header = Instance.new("TextLabel")
        header.Name = "RoleHeader"
        header.Size = UDim2.new(1, 0, 0, 14)
        header.LayoutOrder = 0
        header.BackgroundTransparency = 1
        header.Text = role:upper()
        header.Font = Enum.Font.GothamBold
        header.TextSize = 11
        header.TextColor3 = color
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.Parent = col

        return col
    end

    -- Defer the column creation until ROLE_COLORS exists below.
    -- (Forward-declare nil; populated after ROLE_COLORS table.)

    -- Tier color map (rarity palette — same as the admin panel's
    -- tier list).
    local Shared = ReplicatedStorage:WaitForChild("Shared")
    local TempTowers = require(Shared:WaitForChild("TempTowers"))
    local TIER_COLORS = {
        S = TempTowers.RarityColors.Mythical,
        A = TempTowers.RarityColors.Legendary,
        B = TempTowers.RarityColors.Exceptional,
        C = TempTowers.RarityColors.Rare,
        D = TempTowers.RarityColors.Common,
        F = Color3.fromRGB(110, 110, 110),
    }
    local ROLE_COLORS = {
        DPS     = Color3.fromRGB(220, 90, 90),
        Control = Color3.fromRGB(180, 100, 230),
        Support = Color3.fromRGB(80, 180, 240),
    }

    -- Now that ROLE_COLORS is defined, instantiate the 3 tier
    -- columns. Packed tight (Control's left edge = DPS's right
    -- edge, same for Support) per Matthew 2026-04-28.
    towerStatsCols.DPS     = makeTierColumn("DPS",     12,                       ROLE_COLORS.DPS)
    towerStatsCols.Control = makeTierColumn("Control", 12 + TIER_COL_W,           ROLE_COLORS.Control)
    towerStatsCols.Support = makeTierColumn("Support", 12 + TIER_COL_W * 2,       ROLE_COLORS.Support)

    -- In-memory tracker for what we display. Reset on first
    -- progress event of a fresh sweep.
    local state = {
        sweepActive = false,
        total       = 0,
        currentIdx  = 0,
        currentLabel = "",
        recent      = {},  -- list of { idx, label, finalWave, testType }
        -- Per-tower aggregates: [towerId] = { runs, totalWaves }.
        -- Avg wave + tier are derived during render.
        towerAgg    = {},
        -- cumulative — full DataStore-backed pool. Populated from
        -- lastSweepDataRemote payload.results. Survives sweep
        -- restarts (state.recent gets cleared but cumulative
        -- doesn't). Used by the per-tower wave-breakdown modal's
        -- "Last 5 runs (mean)" section per Matthew 2026-04-28.
        cumulative  = {},
    }

    -- Compute tier letters via VALUE-BASED breakpoints across all
    -- towers. Mirror of server-side assembleTiers in Infinite.lua.
    -- Per Matthew 2026-04-27: "only the top tower can be S and only
    -- the bottom tower can be F. then set the tier distribution
    -- wave breakpoints and place the other towers in it."
    --
    -- Algorithm: top → S. Bottom → F. Middle towers normalized to
    -- [0,1] of the top→bottom range, bucketed by quartile into
    -- A/B/C/D. Tier letters reflect actual performance GAPS, not
    -- just rank position.
    --
    -- Display still groups by role; tier letters within a role
    -- bucket may have gaps (e.g. DPS S/A/D — global #3/#4 are
    -- Control so they don't appear in the DPS list).
    local function computeProspectiveTiers()
        -- Flatten across roles for global sort.
        local flat = {}
        for towerId, agg in pairs(state.towerAgg) do
            if agg.runs > 0 then
                local role = TempTowers.RoleByTowerId[towerId] or "DPS"
                table.insert(flat, {
                    towerId = towerId,
                    avgWave = agg.totalWaves / agg.runs,
                    runs    = agg.runs,
                    role    = role,
                })
            end
        end
        table.sort(flat, function(a, b) return a.avgWave > b.avgWave end)
        local n = #flat
        local function bandForNorm(norm)
            if norm >= 0.75 then return "A" end
            if norm >= 0.50 then return "B" end
            if norm >= 0.25 then return "C" end
            return "D"
        end
        for i, e in ipairs(flat) do
            if i == 1 then
                e.tier = "S"
            elseif n > 1 and i == n then
                e.tier = "F"
            else
                local topAvg = flat[1].avgWave or 0
                local botAvg = flat[n].avgWave or 0
                local range = topAvg - botAvg
                if range <= 0 then
                    e.tier = "C"
                else
                    local norm = ((e.avgWave or 0) - botAvg) / range
                    e.tier = bandForNorm(norm)
                end
            end
        end
        -- Group back by role (preserving descending avgWave order
        -- since flat was sorted that way).
        local byRole = { DPS = {}, Control = {}, Support = {} }
        for _, e in ipairs(flat) do
            local bucket = byRole[e.role] or byRole.DPS
            table.insert(bucket, e)
        end
        return byRole
    end

    -- Strip the always-present "Power + " prefix from loadout
    -- labels — Power Core is in every run by definition. Per
    -- Matthew 2026-04-26: "remove 'power +' text in recent runs
    -- since it's a given." Keeps the row text shorter so longer
    -- aux names fit without truncating.
    --
    -- Also strips the trailing "+ AcornSniper" from trios — per
    -- Matthew 2026-04-27: "trio the acornsniper like a core,
    -- i.e. it's not 'combo' it's baseline." Trios after stripping
    -- read as the 2-aux combo only ("RootSprout + ThornVine"),
    -- with the trio difficulty implied by sweep context. Duos
    -- retain "AcornSniper + X" since AcornSniper there is part
    -- of the tested pair, not a baseline anchor.
    --
    -- DECLARED EARLY (before showWaveStats / rebuildTowerStats /
    -- rebuildObservations) so its upvalue resolves at function-
    -- definition time. Lua captures free variables when a function
    -- is DEFINED, not when it's called — moving stripPower below
    -- the consumers would resolve it as `nil` (the global) and
    -- crash at click time. Per CLAUDE.md "Lua resolves free
    -- variables at function-DEFINITION time, not call time."
    local function stripPower(label)
        if type(label) ~= "string" then return label end
        local stripped = label:gsub("^Power %+ ", "")
        stripped = stripped:gsub(" %+ InfiniteStandard$", "")
        return stripped
    end

    -- Per-tower wave breakdown popup. Filters state.recent for
    -- runs containing the clicked tower, lists each as
    -- "wave X.XX (TestType) — combo". Per Matthew 2026-04-27.
    local function showWaveStats(towerId)
        local existing = panel:FindFirstChild("WaveStatsModal")
        if existing then existing:Destroy() end
        local modal = Instance.new("Frame")
        modal.Name = "WaveStatsModal"
        modal.AnchorPoint = Vector2.new(0.5, 0.5)
        modal.Position = UDim2.fromScale(0.5, 0.5)
        modal.Size = UDim2.fromOffset(360, 360)
        modal.BackgroundColor3 = Color3.fromRGB(22, 28, 22)
        modal.BorderSizePixel = 0
        modal.ZIndex = 30
        modal.Parent = panel
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 12)
            c.Parent = modal
            local s = Instance.new("UIStroke")
            s.Color = Color3.fromRGB(120, 220, 140)
            s.Thickness = 2
            s.Parent = modal
        end
        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -56, 0, 28)
        title.Position = UDim2.fromOffset(12, 10)
        title.BackgroundTransparency = 1
        title.Text = towerId
        title.Font = Enum.Font.FredokaOne
        title.TextSize = 16
        title.TextColor3 = Color3.fromRGB(180, 255, 200)
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.ZIndex = 31
        title.Parent = modal
        -- Layout per Matthew 2026-04-27: "[X] [(i)]" reading
        -- left-to-right (X on left, info on the right edge).
        -- Info button hugs the modal's right edge; X sits to its
        -- left with a 4px gap.
        local close = Instance.new("TextButton")
        close.AnchorPoint = Vector2.new(1, 0)
        -- (i) is at right -10 with width 28 → its left edge is at right -38.
        -- Place X to the left of that with 4px gap → right -42.
        close.Position = UDim2.new(1, -42, 0, 10)
        close.Size = UDim2.fromOffset(36, 28)
        close.BackgroundColor3 = Color3.fromRGB(70, 30, 30)
        close.BorderSizePixel = 0
        close.Text = "X"
        close.Font = Enum.Font.FredokaOne
        close.TextSize = 16
        close.TextColor3 = Color3.fromRGB(240, 200, 200)
        close.ZIndex = 32
        close.Parent = modal
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 6)
            c.Parent = close
        end
        close.MouseButton1Click:Connect(function() modal:Destroy() end)

        -- Info (i) button — sits to the RIGHT of the X (modal's
        -- right edge). Opens the shared TowerInfoCard popup
        -- (extracted to TowerInfoCard.lua). Per Matthew 2026-04-27:
        -- "move the (i) to the right of the (x)."
        local TowerInfoCard = require(script.Parent:WaitForChild("TowerInfoCard"))
        local infoBtn = Instance.new("TextButton")
        infoBtn.AnchorPoint = Vector2.new(1, 0)
        infoBtn.Position = UDim2.new(1, -10, 0, 10)
        infoBtn.Size = UDim2.fromOffset(28, 28)
        infoBtn.BackgroundColor3 = Color3.fromRGB(80, 140, 220)
        infoBtn.BorderSizePixel = 0
        infoBtn.AutoButtonColor = true
        infoBtn.Text = "i"
        infoBtn.Font = Enum.Font.FredokaOne
        infoBtn.TextSize = 16
        infoBtn.TextColor3 = Color3.fromRGB(240, 245, 255)
        infoBtn.ZIndex = 32
        infoBtn.Parent = modal
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(1, 0)  -- circular
            c.Parent = infoBtn
        end
        infoBtn.MouseButton1Click:Connect(function()
            -- Parent to playerGui so closing the monitor window
            -- doesn't auto-destroy the card. TowerInfoCard.toggle
            -- handles the open/close state.
            TowerInfoCard.toggle(playerGui, towerId)
        end)

        local scroll = Instance.new("ScrollingFrame")
        scroll.Size = UDim2.new(1, -24, 1, -56)
        scroll.Position = UDim2.fromOffset(12, 44)
        scroll.BackgroundTransparency = 1
        scroll.BorderSizePixel = 0
        scroll.ScrollBarThickness = 4
        scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        scroll.ZIndex = 31
        scroll.Parent = modal
        do
            local layout = Instance.new("UIListLayout")
            layout.FillDirection = Enum.FillDirection.Vertical
            layout.Padding = UDim.new(0, 1)
            layout.SortOrder = Enum.SortOrder.LayoutOrder
            layout.Parent = scroll
        end

        -- Filter state.recent for runs containing the clicked tower
        -- (excluding InfiniteStandard's anchor appearances since
        -- those don't count toward its tier stats).
        local hits = {}
        for _, r in ipairs(state.recent) do
            local aux = r.auxIds or {}
            local isTrio = #aux >= 3
            local hit = false
            for _, id in ipairs(aux) do
                if id == towerId
                   and not (id == "InfiniteStandard" and isTrio) then
                    hit = true
                    break
                end
            end
            if hit then table.insert(hits, r) end
        end
        table.sort(hits, function(a, b)
            return (a.finalWave or 0) > (b.finalWave or 0)
        end)

        -- Last-5-mean header (Matthew 2026-04-28): pulls from
        -- state.cumulative (DataStore-backed pool — preserved
        -- across sweep starts, includes runs from prior balance
        -- versions). Filters by tower presence, takes the LAST
        -- 5 entries by insertion order (cumulative is appended
        -- chronologically so the tail is most recent), computes
        -- mean finalWave. Renders even when state.recent is
        -- empty (the historical mean is still informative).
        local cumulHits = {}
        for _, r in ipairs(state.cumulative) do
            local aux = r.auxIds or {}
            local isTrio = #aux >= 3
            for _, id in ipairs(aux) do
                if id == towerId
                   and not (id == "InfiniteStandard" and isTrio) then
                    table.insert(cumulHits, r)
                    break
                end
            end
        end
        local last5 = {}
        for i = math.max(1, #cumulHits - 4), #cumulHits do
            if cumulHits[i] then table.insert(last5, cumulHits[i]) end
        end
        local last5Header = Instance.new("TextLabel")
        last5Header.Size = UDim2.new(1, -8, 0, 36)
        last5Header.BackgroundTransparency = 1
        last5Header.Font = Enum.Font.GothamBold
        last5Header.TextSize = 12
        last5Header.TextColor3 = Color3.fromRGB(180, 200, 230)
        last5Header.TextXAlignment = Enum.TextXAlignment.Left
        last5Header.TextYAlignment = Enum.TextYAlignment.Top
        last5Header.TextWrapped = true   -- header may exceed one line
        last5Header.LayoutOrder = -100   -- always at top
        last5Header.ZIndex = 32
        last5Header.Parent = scroll
        if #last5 == 0 then
            last5Header.Text = "  Last 5 runs (mean): (no cumulative data yet)"
        else
            local sum = 0
            for _, r in ipairs(last5) do sum = sum + (r.finalWave or 0) end
            local mean = sum / #last5
            last5Header.Text = string.format(
                "  Last 5 runs (mean): wave %.2f  (across %d run%s, all balance versions)",
                mean, #last5, #last5 == 1 and "" or "s")
        end
        -- Spacer between the mean line and the per-run list.
        local spacer = Instance.new("Frame")
        spacer.Size = UDim2.new(1, -8, 0, 6)
        spacer.BackgroundTransparency = 1
        spacer.LayoutOrder = -99
        spacer.Parent = scroll

        if #hits == 0 then
            local empty = Instance.new("TextLabel")
            empty.Size = UDim2.new(1, -8, 0, 24)
            empty.BackgroundTransparency = 1
            empty.Text = "  (no runs containing " .. towerId .. " in this view)"
            empty.Font = Enum.Font.Gotham
            empty.TextSize = 11
            empty.TextColor3 = Color3.fromRGB(140, 140, 140)
            empty.TextXAlignment = Enum.TextXAlignment.Left
            empty.ZIndex = 32
            empty.Parent = scroll
            return
        end

        -- Header for the current-view list, separating it from the
        -- last-5 mean above.
        local listHeader = Instance.new("TextLabel")
        listHeader.Size = UDim2.new(1, -8, 0, 18)
        listHeader.BackgroundTransparency = 1
        listHeader.Text = "  Current view runs:"
        listHeader.Font = Enum.Font.GothamBold
        listHeader.TextSize = 12
        listHeader.TextColor3 = Color3.fromRGB(180, 200, 180)
        listHeader.TextXAlignment = Enum.TextXAlignment.Left
        listHeader.LayoutOrder = -50
        listHeader.ZIndex = 32
        listHeader.Parent = scroll

        for i, r in ipairs(hits) do
            local entry = Instance.new("TextLabel")
            entry.Size = UDim2.new(1, -8, 0, 16)
            entry.BackgroundTransparency = 1
            local label = stripPower(r.label or "?")
            -- testType formatted as %s (no padding) so AOE/Boss/
            -- Combined render flush against the closing paren.
            -- Per Matthew 2026-04-28.
            entry.Text = string.format(
                "  wave %5.2f  (%s)  %s",
                r.finalWave or 0,
                r.testType or "?",
                label)
            entry.Font = Enum.Font.Code
            entry.TextSize = 11
            entry.TextColor3 = Color3.fromRGB(200, 220, 200)
            entry.TextXAlignment = Enum.TextXAlignment.Left
            entry.TextTruncate = Enum.TextTruncate.AtEnd
            entry.LayoutOrder = i
            entry.ZIndex = 32
            entry.Parent = scroll
        end
    end

    local function rebuildTowerStats()
        -- Clear all 3 columns EXCEPT each column's RoleHeader
        -- label (kept as the persistent role tag at top of column).
        for _, col in pairs(towerStatsCols) do
            for _, c in ipairs(col:GetChildren()) do
                if c:IsA("GuiObject") and c.Name ~= "RoleHeader" then
                    c:Destroy()
                end
            end
        end
        local tiers = computeProspectiveTiers()
        local anyContent = false
        for _, role in ipairs({"DPS", "Control", "Support"}) do
            local list = tiers[role] or {}
            local col = towerStatsCols[role]
            if not col then continue end
            -- Tower rows go directly into the column Frame
            -- (column has its own UIListLayout). LayoutOrder
            -- starts at 1 since the RoleHeader is at 0.
            local layoutOrder = 0
            for _, e in ipairs(list) do
                layoutOrder = layoutOrder + 1
                anyContent = true
                -- Row is a TextButton so the entire row is clickable
                -- (showWaveStats modal). Same row geometry as the
                -- pre-3-column layout; just lives in a per-role
                -- column now.
                local row = Instance.new("TextButton")
                row.Size = UDim2.new(1, -4, 0, 16)
                row.BackgroundColor3 = Color3.fromRGB(40, 50, 40)
                row.BackgroundTransparency = 1
                row.AutoButtonColor = false
                row.Text = ""
                row.LayoutOrder = layoutOrder
                row.Parent = col
                row.MouseEnter:Connect(function()
                    row.BackgroundTransparency = 0.7
                end)
                row.MouseLeave:Connect(function()
                    row.BackgroundTransparency = 1
                end)
                local capturedTowerId = e.towerId
                row.MouseButton1Click:Connect(function()
                    showWaveStats(capturedTowerId)
                end)

                -- 2026-04-28 row pack: horizontal UIListLayout so
                -- tier letter, name, and stats sit shoulder-to-
                -- shoulder with no dead space between name and
                -- stats. Per Matthew "clear all black space between
                -- tower [name] and mean / sample size."
                local rowLayout = Instance.new("UIListLayout")
                rowLayout.FillDirection = Enum.FillDirection.Horizontal
                rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
                rowLayout.Padding = UDim.new(0, 4)
                rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
                rowLayout.Parent = row

                local tierLbl = Instance.new("TextLabel")
                tierLbl.Size = UDim2.fromOffset(14, 16)
                tierLbl.BackgroundTransparency = 1
                tierLbl.Text = e.tier or "?"
                tierLbl.Font = Enum.Font.FredokaOne
                tierLbl.TextSize = 12
                tierLbl.TextColor3 = TIER_COLORS[e.tier] or Color3.fromRGB(200, 200, 200)
                tierLbl.TextXAlignment = Enum.TextXAlignment.Center
                tierLbl.LayoutOrder = 1
                tierLbl.Parent = row

                -- Auto-size name to its text width so the stats
                -- label sits IMMEDIATELY after, no whitespace gap.
                local nameLbl = Instance.new("TextLabel")
                nameLbl.AutomaticSize = Enum.AutomaticSize.X
                nameLbl.Size = UDim2.fromOffset(0, 16)
                nameLbl.BackgroundTransparency = 1
                nameLbl.Text = e.towerId
                nameLbl.Font = Enum.Font.GothamBold
                nameLbl.TextSize = 11
                nameLbl.TextColor3 = Color3.fromRGB(220, 220, 220)
                nameLbl.TextXAlignment = Enum.TextXAlignment.Left
                nameLbl.LayoutOrder = 2
                nameLbl.Parent = row

                local statsLbl = Instance.new("TextLabel")
                statsLbl.AutomaticSize = Enum.AutomaticSize.X
                statsLbl.Size = UDim2.fromOffset(0, 16)
                statsLbl.BackgroundTransparency = 1
                statsLbl.Text = string.format("%.2f/%d", e.avgWave, e.runs)
                statsLbl.Font = Enum.Font.Code
                statsLbl.TextSize = 10
                statsLbl.TextColor3 = Color3.fromRGB(160, 180, 160)
                statsLbl.LayoutOrder = 3
                statsLbl.TextXAlignment = Enum.TextXAlignment.Right
                statsLbl.Parent = row
            end
        end
        if not anyContent then
            local empty = Instance.new("TextLabel")
            empty.Size = UDim2.new(1, -8, 0, 24)
            empty.BackgroundTransparency = 1
            empty.Text = "  (waiting for first run...)"
            empty.Font = Enum.Font.Gotham
            empty.TextSize = 11
            empty.TextColor3 = Color3.fromRGB(140, 140, 140)
            empty.TextXAlignment = Enum.TextXAlignment.Left
            empty.LayoutOrder = 1
            empty.Parent = towerStatsCols.DPS
        end
    end

    -- (stripPower moved above showWaveStats — see CLAUDE.md
    -- "Lua resolves free variables at function-DEFINITION time".)

    -- (rebuildRecent removed — RECENT RUNS panel was removed and
    -- the run number moved into the observations header per
    -- Matthew 2026-04-27.)

    -- ── OBSERVATIONS section (bottom of panel) ───────────────
    -- One line per completed run, focused on the aux tower(s) that
    -- got switched in for that round vs the prior run. Per Matthew
    -- 2026-04-26: "only update observations after a single, duo,
    -- or trio run, and show observation for whatever aux tower
    -- was switched in for that round." Per-wave commentary was
    -- removed — wave-level color cues live in the recent-runs row
    -- and the InfiniteHUD top-of-screen ticker. Observations are
    -- the run-vs-run delta tracker. Cleared at sweep start so each
    -- sweep gets its own narrative.
    -- 2026-04-28 monitor redesign:
    --   • OBSERVATIONS moved UP to y=200 (auto-Y tier columns
    --     end around y=182).
    --   • OBSERVATIONS scroll narrower y-band (210 tall) — only
    --     scrolls the per-combo wave-breakdown blocks (last 10).
    --   • OVERALL PATTERNS extracted to its own NON-SCROLLING
    --     fixed-height region below the OBS scroll, so the role-
    --     mix means + top-solo/duo/triple lines + MORE TOP
    --     COMBOS button always stay visible regardless of scroll
    --     position. Per Matthew "only the observations sub
    --     window should scroll, not overall patterns."
    local observationsTitle = Instance.new("TextLabel")
    observationsTitle.Size = UDim2.new(1, -24, 0, 18)
    observationsTitle.Position = UDim2.fromOffset(12, 200)
    observationsTitle.BackgroundTransparency = 1
    observationsTitle.Text = "OBSERVATIONS"
    observationsTitle.Font = Enum.Font.FredokaOne
    observationsTitle.TextSize = 13
    observationsTitle.TextColor3 = Color3.fromRGB(180, 200, 255)
    observationsTitle.TextXAlignment = Enum.TextXAlignment.Left
    observationsTitle.Parent = panel

    local observationsScroll = Instance.new("ScrollingFrame")
    observationsScroll.Size = UDim2.new(1, -24, 0, 210)
    observationsScroll.Position = UDim2.fromOffset(12, 220)
    observationsScroll.BackgroundTransparency = 1
    observationsScroll.BorderSizePixel = 0
    observationsScroll.ScrollBarThickness = 8
    observationsScroll.ScrollBarImageColor3 = Color3.fromRGB(120, 180, 220)
    observationsScroll.ScrollingDirection = Enum.ScrollingDirection.Y
    observationsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    observationsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    observationsScroll.ClipsDescendants = true
    observationsScroll.Parent = panel

    -- ── OVERALL PATTERNS region (non-scrolling) ───────────────
    -- Fixed-position content below the OBS scroll. Re-rendered
    -- via rebuildOverallPatterns() whenever state.recent updates.
    -- Children get cleared + rebuilt each render; parent stays.
    local overallTitle = Instance.new("TextLabel")
    overallTitle.Size = UDim2.new(1, -24, 0, 18)
    overallTitle.Position = UDim2.fromOffset(12, 438)
    overallTitle.BackgroundTransparency = 1
    overallTitle.Text = "OVERALL PATTERNS"
    overallTitle.Font = Enum.Font.FredokaOne
    overallTitle.TextSize = 13
    overallTitle.TextColor3 = Color3.fromRGB(255, 220, 140)
    overallTitle.TextXAlignment = Enum.TextXAlignment.Left
    overallTitle.Parent = panel

    local overallFrame = Instance.new("Frame")
    overallFrame.Size = UDim2.new(1, -24, 0, 174)
    overallFrame.Position = UDim2.fromOffset(12, 458)
    overallFrame.BackgroundTransparency = 1
    overallFrame.BorderSizePixel = 0
    overallFrame.Parent = panel
    do
        local overallLayout = Instance.new("UIListLayout")
        overallLayout.FillDirection = Enum.FillDirection.Vertical
        overallLayout.Padding = UDim.new(0, 2)
        overallLayout.SortOrder = Enum.SortOrder.LayoutOrder
        overallLayout.Parent = overallFrame
    end
    do
        local layout = Instance.new("UIListLayout")
        layout.FillDirection = Enum.FillDirection.Vertical
        layout.Padding = UDim.new(0, 1)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = observationsScroll
    end

    -- (TOWER_THOUGHTS map removed — it was only ever consumed by
    -- the now-deleted thoughtFor() pipeline. The current
    -- rebuildObservations builds its commentary from cohort +
    -- median deltas in `state.recent`, no archetype string lookup.)

    -- (verdictForCohort removed 2026-04-27 — was the carry-signal
    -- helper for the now-deleted "X carries (BELOW/AVG/ABOVE)" line.
    -- Carry verdicts now surface via the per-tower partner stats
    -- and the global tier letter on the tier dump.)

    local function computeSlateMedian()
        local avgs = {}
        for _, agg in pairs(state.towerAgg) do
            if agg.runs > 0 then
                table.insert(avgs, agg.totalWaves / agg.runs)
            end
        end
        if #avgs == 0 then return 0 end
        table.sort(avgs)
        return avgs[math.ceil(#avgs / 2)]
    end

    -- (thoughtFor + diffAuxIds + obsState removed — they were
    -- the previous "compose a thought from cohort delta + tower
    -- archetype" pipeline that fed observations one tower at a
    -- time. The current rebuildObservations is sweep-relative
    -- and doesn't need per-run prev-aux diffing — it computes
    -- combo cohort + median deltas from `state.recent` directly.)

    local function appendObsLine(text, color, layoutOrder, font)
        local entry = Instance.new("TextLabel")
        entry.Size = UDim2.new(1, -8, 0, 14)
        entry.BackgroundTransparency = 1
        entry.Text = text
        entry.Font = font or Enum.Font.Code
        entry.TextSize = 11
        entry.TextColor3 = color or Color3.fromRGB(200, 215, 230)
        entry.TextXAlignment = Enum.TextXAlignment.Left
        entry.TextTruncate = Enum.TextTruncate.AtEnd
        entry.LayoutOrder = layoutOrder
        entry.Parent = observationsScroll
    end

    -- Word-wrapping variant of appendObsLine. Used by OVERALL
    -- PATTERNS' single takeaway line (Matthew 2026-04-28: "word
    -- wrap the first line and extend it to the three lines").
    -- Caller passes a `lines` count = expected vertical extent
    -- in line-heights so the row reserves enough height for the
    -- wrapped string.
    local function appendObsLineWrapped(text, color, layoutOrder, lines, font)
        local entry = Instance.new("TextLabel")
        local lineH = 14
        entry.Size = UDim2.new(1, -8, 0, lineH * (lines or 1))
        entry.BackgroundTransparency = 1
        entry.Text = text
        entry.Font = font or Enum.Font.Code
        entry.TextSize = 11
        entry.TextColor3 = color or Color3.fromRGB(200, 215, 230)
        entry.TextXAlignment = Enum.TextXAlignment.Left
        entry.TextYAlignment = Enum.TextYAlignment.Top
        entry.TextWrapped = true
        entry.LayoutOrder = layoutOrder
        entry.Parent = observationsScroll
    end

    local function appendObsSpacer(layoutOrder)
        local sp = Instance.new("Frame")
        sp.Size = UDim2.new(1, -8, 0, 6)
        sp.BackgroundTransparency = 1
        sp.LayoutOrder = layoutOrder
        sp.Parent = observationsScroll
    end

    local function clearObservations()
        for _, c in ipairs(observationsScroll:GetChildren()) do
            if c:IsA("GuiObject") then c:Destroy() end
        end
    end

    -- Best/worst per-combo helper. Ranks the aux list by their
    -- cumulative avg wave (state.towerAgg) so we can spotlight
    -- the strongest contributor and the weakest link in each
    -- combination's commentary lines. Excludes AcornSniper from
    -- trios (it's the standardization anchor, not a tested tower).
    local function rankAuxByAvg(auxIds)
        local ranked = {}
        local isTrio = #auxIds >= 3
        for _, id in ipairs(auxIds) do
            if not (id == "InfiniteStandard" and isTrio) then
                local agg = state.towerAgg[id]
                local avg = (agg and agg.runs > 0)
                    and agg.totalWaves / agg.runs or 0
                local runs = (agg and agg.runs) or 0
                table.insert(ranked, { id = id, avg = avg, runs = runs })
            end
        end
        table.sort(ranked, function(a, b) return a.avg > b.avg end)
        return ranked
    end

    -- Forward-decls — comboObservation / comboFailureObservation /
    -- effectiveAuxCount are defined LATER in the file but
    -- rebuildObservations needs to call them. Lua resolves free
    -- variables at function-DEFINITION time (per CLAUDE.md
    -- convention #1), so the captured upvalues need to exist
    -- BEFORE the consumers. Declare nil here, assign actual
    -- functions further down.
    local comboObservation
    local comboFailureObservation
    local effectiveAuxCount

    -- Rebuild the observations panel from the last 10 completed
    -- runs in state.recent (was 3 before 2026-04-28 redesign).
    -- Each combo block consolidates the header + cohort line +
    -- mix line into ONE wrapped paragraph followed by a
    -- "why-it-worked" or "why-it-failed" sentence + per-tower
    -- best/worst-partner lines.
    local function rebuildObservations()
        clearObservations()
        local recent = state.recent
        if #recent == 0 then return end
        local startIdx = math.max(1, #recent - 9)
        local order = 0
        local median = computeSlateMedian()

        -- Pair stats across ALL completed runs. For each ordered pair
        -- (a, b) appearing in the same run's auxIds, accumulate
        -- finalWave + run count. Used below to surface "best/worst
        -- partner for each tower in this run" — replaces the prior
        -- "Died on X wave" line per Matthew 2026-04-27 ("i don't
        -- need to know what wave the died on, its in the headline.
        -- add current top and bottom tower partners instead").
        local pairStats = {}  -- [a][b] = { runs, total }
        for _, r in ipairs(recent) do
            local aux = r.auxIds or {}
            local fw = r.finalWave or 0
            local isTrio = #aux >= 3
            for i = 1, #aux do
                for j = 1, #aux do
                    if i ~= j then
                        local a, b = aux[i], aux[j]
                        -- Skip the trio anchor on either side.
                        if not (a == "InfiniteStandard" and isTrio)
                           and not (b == "InfiniteStandard" and isTrio) then
                            pairStats[a] = pairStats[a] or {}
                            pairStats[a][b] = pairStats[a][b] or { runs = 0, total = 0 }
                            pairStats[a][b].runs  = pairStats[a][b].runs + 1
                            pairStats[a][b].total = pairStats[a][b].total + fw
                        end
                    end
                end
            end
        end
        local function findExtremePartners(towerId)
            local entries = pairStats[towerId]
            if not entries then return nil, nil end
            local best, worst
            for partnerId, agg in pairs(entries) do
                local avg = agg.total / math.max(1, agg.runs)
                if not best  or avg > best.avg  then best  = { id = partnerId, avg = avg } end
                if not worst or avg < worst.avg then worst = { id = partnerId, avg = avg } end
            end
            return best, worst
        end

        -- Iterate newest → oldest so the most recent run sits at
        -- the TOP of the OBSERVATIONS panel. Per Matthew 2026-04-27:
        -- "put the latest waves on top." Was oldest-first; flipped
        -- so the freshest run is what reads first when the player
        -- glances at the panel mid-sweep.
        for i = #recent, startIdx, -1 do
            local r = recent[i]
            local label = stripPower(r.label or "?")
            local fw = r.finalWave or 0
            local testType = r.testType or "?"

            -- Outcome color based on the wave bucket the run died in.
            local outcomeColor
            if fw < 5 then       outcomeColor = Color3.fromRGB(255, 110, 110)
            elseif fw < 8 then   outcomeColor = Color3.fromRGB(255, 180, 80)
            elseif fw < 11 then  outcomeColor = Color3.fromRGB(180, 220, 180)
            elseif fw < 14 then  outcomeColor = Color3.fromRGB(120, 220, 240)
            else                 outcomeColor = Color3.fromRGB(220, 130, 240)
            end

            local auxIds  = r.auxIds or {}
            local ranked  = rankAuxByAvg(auxIds)

            -- Combo-level cohort delta: average of the towers'
            -- cumulative averages, compared to slate median.
            local comboAvg, comboRuns = 0, 0
            for _, e in ipairs(ranked) do
                comboAvg = comboAvg + e.avg
                comboRuns = math.max(comboRuns, e.runs)
            end
            comboAvg = (#ranked > 0) and (comboAvg / #ranked) or fw

            -- Cohort delta sentence — "First read..." vs "On-trend..."
            -- vs above/below track record. 2026-04-28: dropped the
            -- "vs slate" qualifier per Matthew (just "vs median").
            local runVsCombo  = fw - comboAvg
            local runVsMedian = fw - median
            local cohortLine
            if comboRuns < 2 then
                cohortLine = string.format(
                    "First read on this combo (%+.1f vs median %.1f).",
                    runVsMedian, median)
            elseif math.abs(runVsCombo) < 1.0 then
                cohortLine = string.format(
                    "On-trend for this combo (%.2f vs avg %.2f, %+.1f vs median).",
                    fw, comboAvg, runVsMedian)
            elseif runVsCombo > 0 then
                cohortLine = string.format(
                    "Above this combo's track record by +%.1f (%.2f vs avg %.2f).",
                    runVsCombo, fw, comboAvg)
            else
                cohortLine = string.format(
                    "Below this combo's track record by %.1f (%.2f vs avg %.2f).",
                    runVsCombo, fw, comboAvg)
            end

            -- Role-mix counts. Drop the "mixed roles." / "pure
            -- Control" / etc descriptor text per Matthew
            -- 2026-04-28 mockup strikethroughs. If both DPS and
            -- Control counts are zero (pure-Support combo), skip
            -- the Mix segment entirely.
            local nDps, nCtrl = 0, 0
            for _, id in ipairs(auxIds) do
                if not (id == "InfiniteStandard" and #auxIds >= 3) then
                    local role = TempTowers.RoleByTowerId[id]
                    if role == "DPS" then nDps = nDps + 1
                    elseif role == "Control" then nCtrl = nCtrl + 1
                    end
                end
            end

            -- Consolidated header + cohort + mix paragraph. One
            -- wrapped block instead of three separate indented
            -- lines per Matthew "arrows pointing across line
            -- breaks" mockup. "wave" word stripped before the
            -- finalWave number.
            local mixSegment = ""
            if not (nDps == 0 and nCtrl == 0) then
                mixSegment = string.format(" Mix %dD/%dC.", nDps, nCtrl)
            end
            local headerParagraph = string.format(
                "#%d  %s  →  %.2f (%s). %s%s",
                r.idx or 0, label, fw, testType,
                cohortLine, mixSegment)
            order = order + 1
            appendObsLineWrapped(headerParagraph, outcomeColor, order, 4, Enum.Font.GothamBold)

            -- WHY-IT-WORKED / WHY-IT-FAILED commentary. Above-
            -- median runs use comboObservation (positive framing:
            -- synergies that drove the result). Below-median runs
            -- use comboFailureObservation (structural problems,
            -- shared weaknesses, individual tower limitations).
            -- Per Matthew 2026-04-28: "observations should be
            -- similar to why a tower is in top or bottom position;
            -- focus especially on the synergies or shared
            -- weaknesses between towers, as well as individual
            -- tower performance."
            order = order + 1
            local commentary
            local commentaryColor
            if runVsMedian >= 0 then
                commentary = comboObservation(r)
                commentaryColor = Color3.fromRGB(180, 220, 200)
            else
                commentary = comboFailureObservation(r)
                commentaryColor = Color3.fromRGB(220, 180, 180)
            end
            appendObsLineWrapped("  " .. commentary, commentaryColor, order, 2)

            -- Per-tower best/worst partner — one line per tower in
            -- the current run, sourced from cumulative pair stats
            -- across all completed runs in state.recent. Skips the
            -- trio anchor (InfiniteStandard). Skips towers with no
            -- pair data yet (e.g. first sweep, only solos so far).
            for _, id in ipairs(auxIds) do
                if not (id == "InfiniteStandard" and #auxIds >= 3) then
                    local best, worst = findExtremePartners(id)
                    if best and worst then
                        if best.id == worst.id then
                            -- Only one partner sampled so far.
                            order = order + 1
                            appendObsLine(string.format(
                                "  %s: only +%s sampled (%.1f).",
                                id, best.id, best.avg),
                                Color3.fromRGB(200, 200, 200), order)
                        else
                            order = order + 1
                            appendObsLine(string.format(
                                "  %s: best +%s (%.1f) / worst +%s (%.1f).",
                                id, best.id, best.avg, worst.id, worst.avg),
                                Color3.fromRGB(220, 200, 175), order)
                        end
                    end
                end
            end

            order = order + 1
            appendObsSpacer(order)
        end

        -- (OVERALL PATTERNS extracted to rebuildOverallPatterns —
        -- renders to a non-scrolling fixed region below the OBS
        -- scroll, per Matthew 2026-04-28 redesign.)
    end

    -- ─────────────────────────────────────────────────────────
    -- comboObservation — heuristic one-sentence commentary on a
    -- run, used by both the OVERALL PATTERNS top-combo lines and
    -- the MORE TOP COMBOS modal. Pattern-matches auxIds for the
    -- dominant mechanic + combines with testType for context.
    -- Module-level helper (was nested inside rebuildObservations
    -- before the 2026-04-28 split).
    -- ─────────────────────────────────────────────────────────
    -- (forward-declared above so rebuildObservations can call this)
    function comboObservation(r)
        local aux = r.auxIds or {}
        local function has(id)
            for _, a in ipairs(aux) do
                if a == id then return true end
            end
            return false
        end
        local hasMortar  = has("MushroomMortar")
        local hasPepper  = has("PepperCannon")
        local hasSpore   = has("SporePuffball")
        local hasChain   = has("LightningRadish")
        local hasPierce  = has("ThornVine")
        local hasFrost   = has("FrostMelon")
        local hasHoney   = has("HoneyHive")
        local hasRoot    = has("RootSprout")
        local hasBlink   = has("BlinkBerry")
        local hasAcorn   = has("AcornSniper")
        local hasPower   = has("PowerSeed")
        local hasPace    = has("PaceFlower")
        local hasSpy     = has("SpyglassRoot")
        local hasLink    = has("BloodlinkVine")
        local hasSlow    = hasFrost or hasHoney
        local hasAura    = hasPower or hasPace or hasSpy
        local tt         = r.testType or "?"

        if hasMortar and hasSlow then
            return "Mortar lob lands clean on slowed clusters."
        elseif hasMortar and hasAura then
            return "Aura amplifies Mortar's splash damage per shell."
        elseif hasMortar then
            return "Mortar splash + lob carries the cluster catch."
        elseif hasPepper and hasChain then
            return "Pepper splash + Lightning chain stack AOE damage."
        elseif hasPepper and hasSlow then
            return "Slow holds clusters under Pepper splash."
        elseif hasPepper then
            return "Pepper splash anchors the wave-clear."
        elseif hasChain and hasSlow then
            return "Chain hits scale across slowed cluster."
        elseif hasChain and hasAura then
            return "Aura boosts Chain primary; falloff hits stay relevant."
        elseif hasChain then
            return "Chain damage scales with mob density."
        elseif hasSpore and hasSlow then
            return "Slow keeps mobs in Spore cloud DOT."
        elseif hasSpore then
            return "Spore cloud DOT racks up sustained damage."
        elseif hasFrost and hasAura then
            return "Aura + Frost slow stack — Core fires faster on slowed targets."
        elseif hasSlow and hasAura then
            return "Slow window + aura buff compound on the Core."
        elseif hasSlow then
            return "Slow buffer extends Core's engagement window."
        elseif hasPierce and hasAcorn then
            return "Pierce + Sniper line up single-target lanes."
        elseif hasPierce then
            return "Pierce shots cleave lined-up enemies."
        elseif hasAcorn then
            return "Sniper picks off priority targets at long range."
        elseif hasAura and hasLink then
            return "Aura + Link distribute and amplify damage."
        elseif hasAura then
            return "Aura amplifies the Core's effective DPS."
        elseif hasLink then
            return "Bloodlink mirrors damage across linked mobs."
        elseif hasRoot and hasBlink then
            return "Root + Blink stagger mob progress repeatedly."
        elseif hasRoot then
            return "Root stuns create damage windows for the Core."
        elseif hasBlink then
            return "Blink resets force mobs back into tower range."
        elseif #aux == 0 then
            return "Power Core solo — baseline."
        elseif tt == "Boss" then
            return "Single-target focus carries the boss wave."
        elseif tt == "AOE" then
            return "AOE wave clear on raw firepower."
        elseif tt == "Combined" then
            return "Mid-tier — bottlenecked on mixed mob types."
        else
            return "Pure damage stacking — no cross-mechanic synergy."
        end
    end

    -- ─────────────────────────────────────────────────────────
    -- comboFailureObservation — heuristic one-sentence WHY-IT-
    -- FAILED commentary for BOTTOM-tier combos. Mirror of
    -- comboObservation but framed negatively. Per Matthew
    -- 2026-04-28: "when combo is in bottom, explanation should
    -- be why it's bad, not why it works."
    --
    -- Pattern-match priority: structural problems first
    -- (pure-Support / pure-Control / too many buff towers),
    -- then per-tower limitations on solos, then testType
    -- fallbacks for ambiguous cases.
    -- ─────────────────────────────────────────────────────────
    -- (forward-declared above so rebuildObservations can call this)
    function comboFailureObservation(r)
        local aux = r.auxIds or {}
        local nDps, nCtrl, nSup = 0, 0, 0
        local roleByTower = TempTowers.RoleByTowerId
        local isTrio = #aux >= 3
        for _, id in ipairs(aux) do
            if not (id == "InfiniteStandard" and isTrio) then
                local role = roleByTower[id]
                if role == "DPS" then nDps = nDps + 1
                elseif role == "Control" then nCtrl = nCtrl + 1
                elseif role == "Support" then nSup = nSup + 1
                end
            end
        end
        local total = nDps + nCtrl + nSup
        local function has(id)
            for _, a in ipairs(aux) do
                if a == id then return true end
            end
            return false
        end

        -- Structural failures first.
        if total > 0 and nDps == 0 and nCtrl == 0 then
            if nSup >= 2 then
                return "All buff aura, nothing for the auras to amplify."
            end
            return "Solo Support — Core does the work, buff barely registers."
        end
        if nDps == 0 and nCtrl > 0 and nSup == 0 then
            if nCtrl >= 2 then
                return "Stacked slow + stun, no kill power — mobs walk through."
            end
            return "Slow alone doesn't kill — Core can't keep up."
        end
        if nSup >= 3 then
            return "Too much buff, not enough damage — auras need targets to matter."
        end
        if nDps == 1 and nSup >= 2 then
            return "Two buffs piled on one DPS — still single-tower bottleneck."
        end
        if nDps == 0 and nCtrl >= 1 and nSup >= 1 then
            return "Slow + buff, no DPS — can't out-damage HP scaling."
        end

        -- Solo low-tier tower.
        if total == 1 then
            local id = aux[1]
            if id == "BlinkBerry" then
                return "Blink alone delays but doesn't kill."
            elseif id == "AcornSniper" then
                return "Sniper solo — slow cadence, narrow target priority."
            elseif id == "RootSprout" then
                return "Stuns aren't damage; Core overwhelmed alone."
            elseif id == "BloodlinkVine" then
                return "Link needs multiple linked mobs to matter."
            elseif id == "PaceFlower" or id == "PowerSeed" or id == "SpyglassRoot" then
                return "Buff with nothing to amplify — Core solo'd it."
            end
        end

        -- Specific weak-pair patterns.
        if has("BlinkBerry") and has("BloodlinkVine") then
            return "Blink + Link — neither kills; mobs just relocate."
        end
        if has("BlinkBerry") and (has("PaceFlower") or has("SpyglassRoot")) then
            return "Blink + buff — both wait for damage that never comes."
        end
        if has("AcornSniper") and nCtrl == 0 and nSup >= 1 then
            return "Sniper + buff — long-range single target can't AOE."
        end

        -- testType fallbacks for ambiguous combos.
        local tt = r.testType or "?"
        if tt == "Boss" then
            return "Boss wave outpaces this combo's burst."
        elseif tt == "AOE" then
            return "AOE wave overwhelms — no splash density."
        elseif tt == "Combined" then
            return "Mixed mob types — no answer for tank or swarm."
        end
        return "Loadout doesn't synergize — towers fight independently."
    end

    -- Count the non-anchor aux towers in a run (excludes
    -- InfiniteStandard from trios — same exclusion the tier
    -- aggregator uses).
    -- (forward-declared above so rebuildObservations can call this)
    function effectiveAuxCount(r)
        local aux = r.auxIds or {}
        local n = #aux
        if n >= 3 then
            -- Trio: drop InfiniteStandard if present.
            for _, id in ipairs(aux) do
                if id == "InfiniteStandard" then
                    return n - 1
                end
            end
        end
        return n
    end

    -- ─────────────────────────────────────────────────────────
    -- showMoreTopCombos — modal window opened from the
    -- "MORE TOP COMBOS" button. Tabs at top: SOLO / DUO /
    -- TRIPLE / ALL. Body shows top 20 + bottom 10 combos for
    -- the active tab. Close button at bottom.
    -- ─────────────────────────────────────────────────────────
    local function showMoreTopCombos()
        local existing = panel:FindFirstChild("MoreTopCombosModal")
        if existing then existing:Destroy() end

        local modal = Instance.new("Frame")
        modal.Name = "MoreTopCombosModal"
        modal.AnchorPoint = Vector2.new(0.5, 0.5)
        modal.Position = UDim2.fromScale(0.5, 0.5)
        modal.Size = UDim2.fromOffset(520, 580)
        modal.BackgroundColor3 = Color3.fromRGB(22, 28, 22)
        modal.BorderSizePixel = 0
        modal.ZIndex = 30
        modal.Parent = panel
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 12); c.Parent = modal
            local s = Instance.new("UIStroke")
            s.Color = Color3.fromRGB(120, 220, 140)
            s.Thickness = 2
            s.Parent = modal
        end

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -32, 0, 28)
        title.Position = UDim2.fromOffset(16, 12)
        title.BackgroundTransparency = 1
        title.Text = "MORE TOP COMBOS"
        title.Font = Enum.Font.FredokaOne
        title.TextSize = 18
        title.TextColor3 = Color3.fromRGB(255, 220, 140)
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.ZIndex = 31
        title.Parent = modal

        -- Tabs — SOLO / DUO / TRIPLE / ALL.
        local TABS = { "SOLO", "DUO", "TRIPLE", "ALL" }
        local tabBar = Instance.new("Frame")
        tabBar.Size = UDim2.new(1, -32, 0, 28)
        tabBar.Position = UDim2.fromOffset(16, 46)
        tabBar.BackgroundTransparency = 1
        tabBar.ZIndex = 31
        tabBar.Parent = modal
        do
            local layout = Instance.new("UIListLayout")
            layout.FillDirection = Enum.FillDirection.Horizontal
            layout.Padding = UDim.new(0, 8)
            layout.Parent = tabBar
        end

        -- Body scroll for combo list.
        local body = Instance.new("ScrollingFrame")
        body.Size = UDim2.new(1, -32, 1, -130)
        body.Position = UDim2.fromOffset(16, 84)
        body.BackgroundTransparency = 1
        body.BorderSizePixel = 0
        body.ScrollBarThickness = 6
        body.ScrollBarImageColor3 = Color3.fromRGB(120, 180, 220)
        body.CanvasSize = UDim2.new(0, 0, 0, 0)
        body.AutomaticCanvasSize = Enum.AutomaticSize.Y
        body.ClipsDescendants = true
        body.ZIndex = 31
        body.Parent = modal
        do
            local layout = Instance.new("UIListLayout")
            layout.FillDirection = Enum.FillDirection.Vertical
            layout.Padding = UDim.new(0, 0)  -- 2026-04-28: tight pack, no row gaps
            layout.Parent = body
        end

        local activeTab = "ALL"
        local tabBtns = {}

        -- Aggregate cumulative results by aux signature so each
        -- unique loadout shows once with its avgWave.
        local function aggregateByLoadout(filterFn)
            local pool = state.cumulative
            if not pool or #pool == 0 then pool = state.recent or {} end
            local byLoadout = {}
            for _, r in ipairs(pool) do
                if filterFn(r) then
                    local aux = r.auxIds or {}
                    local sorted = {}
                    for _, id in ipairs(aux) do table.insert(sorted, id) end
                    table.sort(sorted)
                    local sig = table.concat(sorted, "+")
                    local b = byLoadout[sig]
                    if not b then
                        b = { auxIds = sorted, label = stripPower(r.label or "?"),
                              runs = 0, totalWave = 0, sample = r }
                        byLoadout[sig] = b
                    end
                    b.runs      = b.runs + 1
                    b.totalWave = b.totalWave + (r.finalWave or 0)
                    -- Keep the highest-finalWave example for the
                    -- comboObservation pattern-match (uses testType
                    -- + auxIds; testType varies between samples).
                    if (r.finalWave or 0) > (b.sample.finalWave or 0) then
                        b.sample = r
                    end
                end
            end
            local list = {}
            for _, b in pairs(byLoadout) do
                b.avgWave = b.totalWave / b.runs
                table.insert(list, b)
            end
            table.sort(list, function(a, b) return a.avgWave > b.avgWave end)
            return list
        end

        local function renderTab(tab)
            for _, c in ipairs(body:GetChildren()) do
                if c:IsA("GuiObject") then c:Destroy() end
            end
            -- Re-add UIListLayout (got destroyed in the clear).
            -- Tight pack — no row gap (Matthew 2026-04-28: "spaces
            -- in boxes needs to go").
            local layout = Instance.new("UIListLayout")
            layout.FillDirection = Enum.FillDirection.Vertical
            layout.Padding = UDim.new(0, 0)
            layout.Parent = body

            local filter
            if tab == "SOLO" then
                filter = function(r) return effectiveAuxCount(r) == 1 end
            elseif tab == "DUO" then
                filter = function(r) return effectiveAuxCount(r) == 2 end
            elseif tab == "TRIPLE" then
                filter = function(r) return effectiveAuxCount(r) == 3 end
            else
                filter = function(_) return true end
            end
            local list = aggregateByLoadout(filter)
            local order = 0

            local function appendRow(text, color, fontSize)
                order = order + 1
                local lbl = Instance.new("TextLabel")
                lbl.Size = UDim2.new(1, -8, 0, 16)
                lbl.BackgroundTransparency = 1
                lbl.Text = text
                lbl.Font = Enum.Font.Code
                lbl.TextSize = fontSize or 12
                lbl.TextColor3 = color or Color3.fromRGB(220, 230, 220)
                lbl.TextXAlignment = Enum.TextXAlignment.Left
                lbl.LayoutOrder = order
                lbl.ZIndex = 32
                lbl.Parent = body
            end
            -- AutomaticSize.Y so the label only takes as much
            -- vertical space as the text actually needs. Was using
            -- fixed `lineH * (lines or 1)` which reserved 28px for
            -- 2-line wrap even when text fit in 1 line — leaving
            -- big empty boxes between rows in the modal. Per Matthew
            -- 2026-04-28: "spaces in boxes needs to go."
            local function appendWrapped(text, color, _lines, fontSize)
                order = order + 1
                local lbl = Instance.new("TextLabel")
                lbl.Size = UDim2.new(1, -8, 0, 0)
                lbl.AutomaticSize = Enum.AutomaticSize.Y
                lbl.BackgroundTransparency = 1
                lbl.Text = text
                lbl.Font = Enum.Font.Gotham
                lbl.TextSize = fontSize or 11
                lbl.TextColor3 = color or Color3.fromRGB(180, 200, 180)
                lbl.TextXAlignment = Enum.TextXAlignment.Left
                lbl.TextYAlignment = Enum.TextYAlignment.Top
                lbl.TextWrapped = true
                lbl.LayoutOrder = order
                lbl.ZIndex = 32
                lbl.Parent = body
            end
            local function appendSpacer(h)
                order = order + 1
                local sp = Instance.new("Frame")
                sp.Size = UDim2.new(1, -8, 0, h or 6)
                sp.BackgroundTransparency = 1
                sp.LayoutOrder = order
                sp.Parent = body
            end

            if #list == 0 then
                appendRow("(no " .. tab .. " runs in pool)",
                    Color3.fromRGB(150, 150, 150))
                return
            end

            -- Indent for the observation line so it visually aligns
            -- under the tower-name part of the combo line (after
            -- "1. " or "10. " prefix). Per Matthew 2026-04-28:
            -- "second line still needs moved in."
            local OBS_INDENT = "    "

            -- TOP 20 — comboObservation explains WHY this works.
            appendRow("TOP " .. math.min(20, #list),
                Color3.fromRGB(255, 220, 140))
            local topCount = math.min(20, #list)
            for i = 1, topCount do
                local b = list[i]
                appendRow(string.format("%2d. %s → %.2f (%d run%s)",
                    i, b.label, b.avgWave, b.runs,
                    b.runs == 1 and "" or "s"))
                appendWrapped(OBS_INDENT .. comboObservation(b.sample), nil, 2)
            end

            -- BOTTOM 10 — comboFAILUREObservation explains WHY
            -- this combo SUCKS, not why it works. Per Matthew
            -- 2026-04-28: bottom-tier framing should call out
            -- structural problems (too much buff / no kill power
            -- / weak solos / etc).
            if #list > 20 then
                appendSpacer(10)
                appendRow("BOTTOM 10",
                    Color3.fromRGB(255, 160, 160))
                local botStart = math.max(1, #list - 9)
                for i = botStart, #list do
                    local b = list[i]
                    appendRow(string.format("%2d. %s → %.2f (%d run%s)",
                        i, b.label, b.avgWave, b.runs,
                        b.runs == 1 and "" or "s"))
                    appendWrapped(OBS_INDENT .. comboFailureObservation(b.sample), nil, 2)
                end
            end
        end

        for i, tab in ipairs(TABS) do
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.fromOffset(96, 28)
            btn.LayoutOrder = i
            btn.BackgroundColor3 = Color3.fromRGB(50, 70, 50)
            btn.BorderSizePixel = 0
            btn.AutoButtonColor = false
            btn.Text = tab
            btn.Font = Enum.Font.FredokaOne
            btn.TextSize = 14
            btn.TextColor3 = Color3.fromRGB(220, 240, 220)
            btn.ZIndex = 32
            btn.Parent = tabBar
            do
                local c = Instance.new("UICorner")
                c.CornerRadius = UDim.new(0, 6)
                c.Parent = btn
            end
            tabBtns[tab] = btn
            btn.MouseButton1Click:Connect(function()
                activeTab = tab
                for tt, b in pairs(tabBtns) do
                    b.BackgroundColor3 = (tt == tab)
                        and Color3.fromRGB(120, 180, 120)
                        or Color3.fromRGB(50, 70, 50)
                end
                renderTab(tab)
            end)
        end
        -- Highlight default tab.
        tabBtns.ALL.BackgroundColor3 = Color3.fromRGB(120, 180, 120)
        renderTab(activeTab)

        local close = Instance.new("TextButton")
        close.AnchorPoint = Vector2.new(0.5, 1)
        close.Position = UDim2.new(0.5, 0, 1, -16)
        close.Size = UDim2.fromOffset(160, 32)
        close.BackgroundColor3 = Color3.fromRGB(80, 140, 200)
        close.BorderSizePixel = 0
        close.AutoButtonColor = false
        close.Text = "CLOSE"
        close.Font = Enum.Font.FredokaOne
        close.TextSize = 16
        close.TextColor3 = Color3.fromRGB(255, 255, 255)
        close.ZIndex = 32
        close.Parent = modal
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 6); c.Parent = close
        end
        close.MouseButton1Click:Connect(function() modal:Destroy() end)
    end

    -- ─────────────────────────────────────────────────────────
    -- rebuildOverallPatterns — renders the non-scrolling region
    -- below the OBS scroll. Per Matthew 2026-04-28:
    --   • Means line: D X.X | C X.X | S X.X [| Bal X.X]
    --     (Bal segment dropped when balanced bucket is empty.)
    --   • Top solo combo: best 1-aux loadout + sentence
    --   • Top duo combo: best 2-aux loadout + sentence
    --   • Top triple combo: best 3-aux loadout + sentence
    --   • MORE TOP COMBOS button → modal w/ tabs + top20/bot10
    -- ─────────────────────────────────────────────────────────
    local function rebuildOverallPatterns()
        for _, c in ipairs(overallFrame:GetChildren()) do
            if c:IsA("GuiObject") then c:Destroy() end
        end
        local layout = Instance.new("UIListLayout")
        layout.FillDirection = Enum.FillDirection.Vertical
        layout.Padding = UDim.new(0, 2)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = overallFrame

        local order = 0
        local function appendRow(text, color, fontSize, font)
            order = order + 1
            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.new(1, 0, 0, 14)
            lbl.BackgroundTransparency = 1
            lbl.Text = text
            lbl.Font = font or Enum.Font.Code
            lbl.TextSize = fontSize or 11
            lbl.TextColor3 = color or Color3.fromRGB(200, 215, 230)
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.LayoutOrder = order
            lbl.Parent = overallFrame
        end
        local function appendWrappedRow(text, color, lines)
            order = order + 1
            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.new(1, 0, 0, 14 * (lines or 1))
            lbl.BackgroundTransparency = 1
            lbl.Text = text
            lbl.Font = Enum.Font.Code
            lbl.TextSize = 11
            lbl.TextColor3 = color or Color3.fromRGB(200, 215, 230)
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.TextYAlignment = Enum.TextYAlignment.Top
            lbl.TextWrapped = true
            lbl.LayoutOrder = order
            lbl.Parent = overallFrame
        end

        local pool = state.cumulative
        if not pool or #pool == 0 then pool = state.recent or {} end
        if #pool < 1 then
            appendRow("(awaiting first run)",
                Color3.fromRGB(150, 150, 150))
            return
        end

        -- Compute role-mix means.
        local mixStats = {
            pureDps  = { count = 0, totalWave = 0 },
            pureCtrl = { count = 0, totalWave = 0 },
            pureSup  = { count = 0, totalWave = 0 },
            balanced = { count = 0, totalWave = 0 },
        }
        local roleByTower = TempTowers.RoleByTowerId
        for _, r in ipairs(pool) do
            local aux = r.auxIds or {}
            local rD, rC, rS = 0, 0, 0
            for _, id in ipairs(aux) do
                if not (id == "InfiniteStandard" and #aux >= 3) then
                    local role = roleByTower[id]
                    if role == "DPS" then rD = rD + 1
                    elseif role == "Control" then rC = rC + 1
                    elseif role == "Support" then rS = rS + 1
                    end
                end
            end
            local mix
            if rD > 0 and rC == 0 and rS == 0 then mix = "pureDps"
            elseif rC > 0 and rD == 0 and rS == 0 then mix = "pureCtrl"
            elseif rS > 0 and rD == 0 and rC == 0 then mix = "pureSup"
            elseif rD > 0 and rC > 0 then mix = "balanced"
            end
            if mix then
                mixStats[mix].count = mixStats[mix].count + 1
                mixStats[mix].totalWave = mixStats[mix].totalWave + (r.finalWave or 0)
            end
        end
        local function avgFor(bucket)
            local b = mixStats[bucket]
            if b.count == 0 then return nil end
            return b.totalWave / b.count
        end
        local dpsAvg, ctrlAvg, supAvg, balAvg =
            avgFor("pureDps"), avgFor("pureCtrl"), avgFor("pureSup"), avgFor("balanced")

        -- Build means line. Bal segment included only when the
        -- balanced bucket has data — per Matthew "Bal — drop
        -- entirely when no samples."
        local function fmtMean(label, v)
            if v then return string.format("%s %.1f", label, v) end
            return string.format("%s —", label)
        end
        local meansLine = string.format("%s | %s | %s",
            fmtMean("D", dpsAvg), fmtMean("C", ctrlAvg), fmtMean("S", supAvg))
        if balAvg then
            meansLine = meansLine .. string.format(" | Bal %.1f", balAvg)
        end
        appendRow(meansLine, Color3.fromRGB(180, 215, 230))

        -- Top solo / duo / triple combos.
        local function bestForCount(n)
            local best
            for _, r in ipairs(pool) do
                if effectiveAuxCount(r) == n then
                    if not best or (r.finalWave or 0) > (best.finalWave or 0) then
                        best = r
                    end
                end
            end
            return best
        end
        local function appendComboLine(name, r)
            if not r then
                appendRow(string.format("Top %s: (none yet)", name),
                    Color3.fromRGB(150, 150, 150))
                return
            end
            local line = string.format("Top %s: %s → %.2f (%s). %s",
                name, stripPower(r.label or "?"), r.finalWave or 0,
                r.testType or "?", comboObservation(r))
            appendWrappedRow(line, Color3.fromRGB(200, 220, 200), 2)
        end
        appendComboLine("solo",   bestForCount(1))
        appendComboLine("duo",    bestForCount(2))
        appendComboLine("triple", bestForCount(3))

        -- MORE TOP COMBOS button — opens the tabs modal.
        order = order + 1
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(180, 28)
        btn.BackgroundColor3 = Color3.fromRGB(80, 140, 200)
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = true
        btn.Text = "MORE TOP COMBOS"
        btn.Font = Enum.Font.FredokaOne
        btn.TextSize = 13
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.LayoutOrder = order
        btn.Parent = overallFrame
        do
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 6); c.Parent = btn
        end
        btn.MouseButton1Click:Connect(showMoreTopCombos)
    end

    -- Progress event: server fires per-run with { current, total, label }.
    -- The PREVIOUS run just completed → push it to recent if we have data.
    local progressRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteAutoRunProgress)
    progressRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" then return end
        local current = payload.current
        local total   = payload.total
        local label   = payload.label
        if type(current) ~= "number" or type(total) ~= "number" or type(label) ~= "string" then
            return
        end

        -- First progress event of this sweep: reset state + auto-show.
        -- Observations also clear here so each sweep gets a fresh
        -- run-vs-run delta narrative. Mid-sweep progress events do
        -- NOT touch observations (they only append on run-end now).
        if not state.sweepActive then
            state.sweepActive = true
            stopRunBtn.Visible = true
            stopLeftBtn.Visible = true
            stopRightBtn.Visible = true
            resetStopBtnToStage1()  -- new sweep → CONTINUOUS default
            state.recent = {}
            state.towerAgg = {}  -- reset tower stats for new sweep
            rebuildTowerStats()
            clearObservations()
        end
        state.total      = total
        state.currentIdx = current
        state.currentLabel = label
        gui.Enabled = true
    end)

    -- Per-run completion: server fires after each loadout's run
    -- ends. Accumulate per-tower aggregates + re-render the live
    -- tier list. Power is excluded — it's the Core (universal),
    -- not a comparable aux. Per Matthew 2026-04-26: "remove Power
    -- from the tier list. it's core."
    local runCompletedRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteRunCompleted)
    runCompletedRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" then return end
        local fw = payload.finalWave or 0
        local function bump(towerId)
            if not state.towerAgg[towerId] then
                state.towerAgg[towerId] = { runs = 0, totalWaves = 0 }
            end
            state.towerAgg[towerId].runs = state.towerAgg[towerId].runs + 1
            state.towerAgg[towerId].totalWaves = state.towerAgg[towerId].totalWaves + fw
        end
        if type(payload.auxIds) == "table" then
            -- Skip AcornSniper trio runs — it's the standardization
            -- anchor in all 28 trios, not a test of itself. Mirrors
            -- server's assembleTiers exclusion. Per Matthew
            -- 2026-04-26: "remove acornsniper trio runs from stats."
            local isTrio = #payload.auxIds >= 3
            for _, id in ipairs(payload.auxIds) do
                if not (id == "InfiniteStandard" and isTrio) then
                    bump(id)
                end
            end
        end

        -- Push to recent runs list too (was previously incomplete
        -- mid-sweep; this completion event makes it live-accurate).
        -- auxIds are preserved so the observations panel can filter
        -- by tower for per-combo commentary.
        table.insert(state.recent, {
            idx       = payload.idx or (#state.recent + 1),
            label     = payload.label or "?",
            finalWave = fw,
            testType  = payload.testType or "?",
            auxIds    = payload.auxIds or {},
        })
        -- Cap at last 30 to keep render cheap.
        while #state.recent > 30 do
            table.remove(state.recent, 1)
        end
        rebuildTowerStats()
        rebuildObservations()
        rebuildOverallPatterns()
    end)

    -- Done event: sweep finished. Backfill the recent list from the
    -- complete results payload (covers the case where the user
    -- closed + reopened the window mid-sweep and missed events).
    local doneRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteAutoRunDone)
    doneRemote.OnClientEvent:Connect(function(payload)
        state.sweepActive = false
        stopRunBtn.Visible = false
        stopLeftBtn.Visible = false
        stopRightBtn.Visible = false
        resetStopBtnToStage1()
        if type(payload) == "table" and type(payload.results) == "table" then
            state.recent = {}
            for i, r in ipairs(payload.results) do
                table.insert(state.recent, {
                    idx       = i,
                    label     = r.label or "?",
                    finalWave = r.finalWave or 0,
                    testType  = r.testType or "?",
                    auxIds    = r.auxIds or {},
                })
            end
        end
        rebuildObservations()
        rebuildOverallPatterns()
    end)

    -- Last-sweep cache: persists the previous sweep's data across
    -- server restarts so the monitor displays meaningful content
    -- IMMEDIATELY when opened (without requiring a fresh sweep
    -- to populate it). Per Matthew 2026-04-28: "save and reload
    -- the previous run on the automonitor even after program
    -- restart; only clear it on starting a new autorun."
    --
    -- Hydration sources, in order:
    --   1. Server lastSweepDataRemote response (DataStore-backed
    --      cumulative pool, persists across restarts).
    --   2. monitor:setup() / monitor:open() fires the request below.
    --   3. New-sweep first-progress event clears state.recent /
    --      state.towerAgg so each sweep starts fresh.
    local lastSweepReqRemote  = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteRequestLastSweep)
    local lastSweepDataRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteLastSweepData)
    lastSweepDataRemote.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" then return end
        -- Empty payload = post-BALANCE+ wipe or fresh server with
        -- no run history. Clear stale local state so the monitor
        -- shows "(waiting for first run...)" instead of yesterday's
        -- numbers. Skip during an active sweep — the live data is
        -- accurate even if cumulative is empty.
        if payload.empty then
            if not state.sweepActive then
                state.cumulative = {}
                state.recent = {}
                state.towerAgg = {}
                rebuildTowerStats()
                clearObservations()
                rebuildOverallPatterns()
            end
            return
        end
        if type(payload.results) ~= "table" then return end
        -- During an active sweep, state.recent / state.towerAgg are
        -- the live aggregator — DON'T overwrite them with the
        -- cumulative pool mid-sweep (we'd undo the live progress).
        -- The cumulative refresh runs at sweep-end via doneRemote.
        if state.sweepActive then
            -- Still update state.cumulative for the wave-breakdown
            -- modal's "last 5 runs mean" baseline.
            state.cumulative = {}
            for i, r in ipairs(payload.results) do
                table.insert(state.cumulative, {
                    idx       = i,
                    label     = r.label or "?",
                    finalWave = r.finalWave or 0,
                    testType  = r.testType or "?",
                    auxIds    = r.auxIds or {},
                })
            end
            return
        end
        -- Sweep idle: rebuild state.cumulative + state.recent +
        -- state.towerAgg from the persisted pool. Monitor displays
        -- the previous sweep's data exactly as it looked at sweep-
        -- end, regardless of whether the player just rejoined the
        -- server or has been idle in the swamp.
        state.cumulative = {}
        state.recent = {}
        state.towerAgg = {}
        for i, r in ipairs(payload.results) do
            local entry = {
                idx       = i,
                label     = r.label or "?",
                finalWave = r.finalWave or 0,
                testType  = r.testType or "?",
                auxIds    = r.auxIds or {},
            }
            table.insert(state.cumulative, entry)
            table.insert(state.recent, entry)
            -- Per-tower aggregate: same exclusion rule as
            -- runCompletedRemote (skip InfiniteStandard in trios —
            -- it's the standardization anchor, not a tested tower).
            local isTrio = #entry.auxIds >= 3
            for _, id in ipairs(entry.auxIds) do
                if not (id == "InfiniteStandard" and isTrio) then
                    if not state.towerAgg[id] then
                        state.towerAgg[id] = { runs = 0, totalWaves = 0 }
                    end
                    state.towerAgg[id].runs = state.towerAgg[id].runs + 1
                    state.towerAgg[id].totalWaves = state.towerAgg[id].totalWaves + entry.finalWave
                end
            end
        end
        rebuildTowerStats()
        rebuildObservations()
        rebuildOverallPatterns()
    end)

    -- Self-hydrate at setup so the monitor shows previous-sweep
    -- data the moment the player opens it (even without first
    -- visiting the admin panel). Server's response is cheap — just
    -- the cached cumulative pool — and idempotent.
    lastSweepReqRemote:FireServer()

    -- Track previous-run completion: when current advances, the
    -- prior run's stats are in (server stashes them in lastRunStats /
    -- the autoRun.results list, but those don't auto-stream). For
    -- live tracking we capture each progress event's PREVIOUS label
    -- as a placeholder; finalWave fills in via the autoRunDone or
    -- next-sweep request. To avoid empty placeholders, only push
    -- when we actually have the previous wave's number — which we
    -- get via state tracking on subsequent progress events. Sweep
    -- emits one final event with the LAST loadout's result via
    -- autoRunDone's `results` field (handled above), so the recent
    -- list is fully populated only at sweep end. Live partial
    -- tracking requires a server tick that includes finalWave per
    -- progress fire — deferred until that channel exists.

    return gui
end

function InfiniteMonitorWindow.setup(deps)
    if windowGui and windowGui.Parent then return end
    windowGui = buildWindow(deps)
end

function InfiniteMonitorWindow.open()
    if windowGui and windowGui.Parent then
        windowGui.Enabled = true
        -- Re-fetch the persisted cumulative pool on every open so
        -- the monitor reflects any post-setup BALANCE+ wipes /
        -- new sweeps that happened while it was hidden. Cheap —
        -- server's reply is just the cached pool. The handler
        -- bails on payload.empty so an empty pool doesn't clobber
        -- live state.
        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
        local req = ReplicatedStorage:FindFirstChild(Remotes.Names.InfiniteRequestLastSweep)
        if req then req:FireServer() end
    end
end

function InfiniteMonitorWindow.close()
    if windowGui and windowGui.Parent then
        windowGui.Enabled = false
    end
end

return InfiniteMonitorWindow
