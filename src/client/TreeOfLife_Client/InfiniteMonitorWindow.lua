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
    gui.DisplayOrder = 64  -- above admin panel (65) for stacking; both modal range
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
    -- Width 420 (was 380) for longer 3-tower combination strings.
    -- Height 640 (was 540) for the new 3-line-per-combo
    -- observations block. Per Matthew 2026-04-26: "make the
    -- winder bigger to acommodate."
    panel.Size = UDim2.fromOffset(420, 640)
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

    -- STOP-RUN button — two-stage per Matthew 2026-04-27:
    --   stage 1 ("STOP AT END"): clears the continuous-sweep flag
    --     so the CURRENT sweep finishes (capturing all run stats)
    --     but no next sweep starts. Button morphs to "STOP NOW".
    --   stage 2 ("STOP NOW"): aborts the in-flight run immediately
    --     (legacy abort behavior).
    -- Hidden when no sweep is active; resets to stage 1 on each
    -- new sweep start.
    local stopRunBtn = Instance.new("TextButton")
    stopRunBtn.AnchorPoint = Vector2.new(1, 0)
    stopRunBtn.Position = UDim2.new(1, -48, 0, 8)
    stopRunBtn.Size = UDim2.fromOffset(120, 28)
    stopRunBtn.BackgroundColor3 = Color3.fromRGB(220, 130, 60)  -- orange (stage 1)
    stopRunBtn.BorderSizePixel = 0
    stopRunBtn.AutoButtonColor = true
    stopRunBtn.Text = "STOP AT END"
    stopRunBtn.Font = Enum.Font.FredokaOne
    stopRunBtn.TextSize = 14
    stopRunBtn.TextColor3 = Color3.fromRGB(255, 240, 235)
    stopRunBtn.ZIndex = 5
    stopRunBtn.Visible = false  -- only visible while a sweep is active
    stopRunBtn.Parent = panel
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = stopRunBtn
    end
    local stopRunRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteStopRun)
    -- Stage tracker: "atEnd" = stage 1 (STOP AT END), "now" = stage 2 (STOP NOW).
    local stopStage = "atEnd"
    local function resetStopBtnToStage1()
        stopStage = "atEnd"
        stopRunBtn.Text = "STOP AT END"
        stopRunBtn.BackgroundColor3 = Color3.fromRGB(220, 130, 60)
    end
    local function morphStopBtnToStage2()
        stopStage = "now"
        stopRunBtn.Text = "STOP NOW"
        stopRunBtn.BackgroundColor3 = Color3.fromRGB(220, 50, 50)  -- redder = scarier
    end
    stopRunBtn.MouseButton1Click:Connect(function()
        stopRunRemote:FireServer({ mode = stopStage })
        if stopStage == "atEnd" then
            morphStopBtnToStage2()
        end
        -- "now" click: server tears down the run; the autoRunDone
        -- event resets the button + hides it.
    end)

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

    local towerStatsScroll = Instance.new("ScrollingFrame")
    towerStatsScroll.Size = UDim2.new(1, -24, 0, 216)
    towerStatsScroll.Position = UDim2.fromOffset(12, 72)
    towerStatsScroll.BackgroundTransparency = 1
    towerStatsScroll.BorderSizePixel = 0
    towerStatsScroll.ScrollBarThickness = 4
    towerStatsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    towerStatsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    towerStatsScroll.Parent = panel
    do
        local layout = Instance.new("UIListLayout")
        layout.FillDirection = Enum.FillDirection.Vertical
        layout.Padding = UDim.new(0, 1)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = towerStatsScroll
    end

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
    }

    -- Compute per-role tier letters from current towerAgg. Sorts
    -- each role's towers by avgWave desc then buckets into S/A/B/
    -- C/D/F (top 1/6 = S, etc.). Returns flat list ordered by
    -- role then rank, with role + tier baked in.
    local TIER_NAMES = { "S", "A", "B", "C", "D", "F" }
    local function computeProspectiveTiers()
        local byRole = { DPS = {}, Control = {}, Support = {} }
        for towerId, agg in pairs(state.towerAgg) do
            if agg.runs > 0 then
                local role = TempTowers.RoleByTowerId[towerId] or "DPS"
                table.insert(byRole[role], {
                    towerId = towerId,
                    avgWave = agg.totalWaves / agg.runs,
                    runs    = agg.runs,
                    role    = role,
                })
            end
        end
        for _, list in pairs(byRole) do
            table.sort(list, function(a, b) return a.avgWave > b.avgWave end)
            local n = #list
            for i, e in ipairs(list) do
                local tierIdx = math.min(6, math.max(1, math.ceil(i * 6 / math.max(1, n))))
                e.tier = TIER_NAMES[tierIdx]
            end
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
        title.Text = towerId .. " — wave breakdown"
        title.Font = Enum.Font.FredokaOne
        title.TextSize = 16
        title.TextColor3 = Color3.fromRGB(180, 255, 200)
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.ZIndex = 31
        title.Parent = modal
        local close = Instance.new("TextButton")
        close.AnchorPoint = Vector2.new(1, 0)
        close.Position = UDim2.new(1, -10, 0, 10)
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

        for i, r in ipairs(hits) do
            local entry = Instance.new("TextLabel")
            entry.Size = UDim2.new(1, -8, 0, 16)
            entry.BackgroundTransparency = 1
            local label = stripPower(r.label or "?")
            entry.Text = string.format(
                "  wave %5.2f  (%-8s)  %s",
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
        for _, c in ipairs(towerStatsScroll:GetChildren()) do
            if c:IsA("GuiObject") then c:Destroy() end
        end
        local tiers = computeProspectiveTiers()
        local layoutOrder = 0
        for _, role in ipairs({"DPS", "Control", "Support"}) do
            local list = tiers[role] or {}
            if #list > 0 then
                -- Role header.
                layoutOrder = layoutOrder + 1
                local header = Instance.new("TextLabel")
                header.Size = UDim2.new(1, -8, 0, 16)
                header.BackgroundTransparency = 1
                header.Text = role:upper()
                header.Font = Enum.Font.GothamBold
                header.TextSize = 11
                header.TextColor3 = ROLE_COLORS[role] or Color3.fromRGB(220, 220, 220)
                header.TextXAlignment = Enum.TextXAlignment.Left
                header.LayoutOrder = layoutOrder
                header.Parent = towerStatsScroll

                for _, e in ipairs(list) do
                    layoutOrder = layoutOrder + 1
                    -- Row is now a TextButton so the entire row is
                    -- clickable. Per Matthew 2026-04-27: "make the
                    -- tower names clickable on this window, and
                    -- open up the stats for all the waves it's
                    -- been [in]." Click → showWaveStats(towerId)
                    -- modal listing every run containing this tower.
                    local row = Instance.new("TextButton")
                    row.Size = UDim2.new(1, -8, 0, 16)
                    row.BackgroundColor3 = Color3.fromRGB(40, 50, 40)
                    row.BackgroundTransparency = 1
                    row.AutoButtonColor = false
                    row.Text = ""
                    row.LayoutOrder = layoutOrder
                    row.Parent = towerStatsScroll
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

                    local tierLbl = Instance.new("TextLabel")
                    tierLbl.Size = UDim2.fromOffset(16, 16)
                    tierLbl.BackgroundTransparency = 1
                    tierLbl.Text = e.tier or "?"
                    tierLbl.Font = Enum.Font.FredokaOne
                    tierLbl.TextSize = 12
                    tierLbl.TextColor3 = TIER_COLORS[e.tier] or Color3.fromRGB(200, 200, 200)
                    tierLbl.TextXAlignment = Enum.TextXAlignment.Center
                    tierLbl.Parent = row

                    local nameLbl = Instance.new("TextLabel")
                    nameLbl.Size = UDim2.new(1, -90, 1, 0)
                    nameLbl.Position = UDim2.fromOffset(20, 0)
                    nameLbl.BackgroundTransparency = 1
                    nameLbl.Text = e.towerId
                    nameLbl.Font = Enum.Font.GothamBold
                    nameLbl.TextSize = 11
                    nameLbl.TextColor3 = Color3.fromRGB(220, 220, 220)
                    nameLbl.TextXAlignment = Enum.TextXAlignment.Left
                    nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
                    nameLbl.Parent = row

                    local statsLbl = Instance.new("TextLabel")
                    statsLbl.AnchorPoint = Vector2.new(1, 0)
                    statsLbl.Size = UDim2.fromOffset(76, 16)
                    statsLbl.Position = UDim2.new(1, -2, 0, 0)
                    statsLbl.BackgroundTransparency = 1
                    statsLbl.Text = string.format("%5.2f / %d", e.avgWave, e.runs)
                    statsLbl.Font = Enum.Font.Code
                    statsLbl.TextSize = 10
                    statsLbl.TextColor3 = Color3.fromRGB(160, 180, 160)
                    statsLbl.TextXAlignment = Enum.TextXAlignment.Right
                    statsLbl.Parent = row
                end
            end
        end
        if layoutOrder == 0 then
            local empty = Instance.new("TextLabel")
            empty.Size = UDim2.new(1, -8, 0, 24)
            empty.BackgroundTransparency = 1
            empty.Text = "  (waiting for first run...)"
            empty.Font = Enum.Font.Gotham
            empty.TextSize = 11
            empty.TextColor3 = Color3.fromRGB(140, 140, 140)
            empty.TextXAlignment = Enum.TextXAlignment.Left
            empty.Parent = towerStatsScroll
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
    local observationsTitle = Instance.new("TextLabel")
    observationsTitle.Size = UDim2.new(1, -24, 0, 18)
    observationsTitle.Position = UDim2.fromOffset(12, 296)
    observationsTitle.BackgroundTransparency = 1
    observationsTitle.Text = "OBSERVATIONS"
    observationsTitle.Font = Enum.Font.FredokaOne
    observationsTitle.TextSize = 13
    observationsTitle.TextColor3 = Color3.fromRGB(180, 200, 255)
    observationsTitle.TextXAlignment = Enum.TextXAlignment.Left
    observationsTitle.Parent = panel

    local observationsScroll = Instance.new("ScrollingFrame")
    observationsScroll.Size = UDim2.new(1, -24, 0, 322)
    observationsScroll.Position = UDim2.fromOffset(12, 318)
    observationsScroll.BackgroundTransparency = 1
    observationsScroll.BorderSizePixel = 0
    observationsScroll.ScrollBarThickness = 4
    observationsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    observationsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    observationsScroll.Parent = panel
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

    -- Verdict against the cohort median (live in state.towerAgg).
    -- Within ±0.7 wave = AVG; above/below threshold = ABOVE/BELOW.
    -- Threshold = 0.7 because finalWave is fractional (0.99 max
    -- per wave) — anything < 1 wave gap is statistical noise.
    local function verdictForCohort(towerAvg, slateMedian)
        local diff = towerAvg - slateMedian
        if math.abs(diff) <= 0.7 then return "AVG",   Color3.fromRGB(180, 220, 180), diff end
        if diff > 0                then return "ABOVE", Color3.fromRGB(120, 220, 240), diff end
        return "BELOW", Color3.fromRGB(255, 180, 80), diff
    end

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

    -- Rebuild the observations panel from the last 3 completed
    -- runs in state.recent. Layout per combo (4 lines + spacer):
    --   1. Header: "Tower1 + Tower2 → wave N.NN (TestType)"
    --      (failure line moved up onto the header line per
    --       Matthew 2026-04-27.)
    --   2-4. 3 commentary lines explaining WHY this combo landed
    --        where it did (cohort comparison + per-tower role
    --        thoughts + synergy / failure-mode note).
    local function rebuildObservations()
        clearObservations()
        local recent = state.recent
        if #recent == 0 then return end
        local startIdx = math.max(1, #recent - 2)
        local order = 0
        local median = computeSlateMedian()

        for i = startIdx, #recent do
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

            -- Header line: combo # + name + wave outcome combined.
            -- Run number moved here from the now-removed RECENT
            -- RUNS section per Matthew 2026-04-27.
            order = order + 1
            appendObsLine(string.format("#%d  %s  →  wave %.2f (%s)",
                r.idx or 0, label, fw, testType),
                outcomeColor, order, Enum.Font.GothamBold)

            -- Build the 3 commentary lines. The "why" is rooted in
            -- (a) cohort comparison (did this run beat the median
            -- for these towers?), (b) per-tower archetype thoughts
            -- (what each tower brings to the combo), and (c) a
            -- failure-mode hint (what test type they died on +
            -- what that signals about the loadout).
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

            -- Line 1: how this run compares to the combo's track
            -- record + slate median.
            local runVsCombo = fw - comboAvg
            local runVsMedian = fw - median
            local cohortLine
            if comboRuns < 2 then
                cohortLine = string.format(
                    "First read on this combo (%+.1f vs slate median %.1f).",
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
            order = order + 1
            appendObsLine("  " .. cohortLine,
                Color3.fromRGB(180, 200, 220), order)

            -- Compute role mix and synergy phrasing once for the
            -- 3-line summary below. Per Matthew 2026-04-27: "give
            -- each observation three lines and have it just be a
            -- summary statement. don't have each line be a
            -- separate thing." Each line reads as a flowing
            -- sentence rather than a label:value pair.
            local nDps, nCtrl, nSup = 0, 0, 0
            for _, id in ipairs(auxIds) do
                if not (id == "InfiniteStandard" and #auxIds >= 3) then
                    local role = TempTowers.RoleByTowerId[id]
                    if role == "DPS" then nDps = nDps + 1
                    elseif role == "Control" then nCtrl = nCtrl + 1
                    elseif role == "Support" then nSup = nSup + 1
                    end
                end
            end
            local mixDesc
            if nDps + nCtrl + nSup == 0 then
                mixDesc = "no role data"
            elseif nDps > 0 and nCtrl > 0 then
                mixDesc = "DPS + Control mix — slow extends DPS uptime"
            elseif nCtrl == 0 and nSup == 0 then
                mixDesc = "pure DPS — burst focus, no crowd control"
            elseif nDps == 0 and nSup == 0 then
                mixDesc = "pure Control — utility blend, no kill power"
            else
                mixDesc = "mixed roles"
            end

            local failureSentence
            if testType == "Solo" then
                failureSentence = "Died on Solo wave — single-target DPS overwhelmed"
            elseif testType == "AOE" then
                failureSentence = "Died on AOE swarm — splash + slow density needed"
            elseif testType == "Combined" then
                failureSentence = "Died on Combined wave — target priority broke down"
            else
                failureSentence = "Died on " .. testType .. " wave"
            end

            -- Summary line 1: where it landed + who carried.
            order = order + 1
            local landingPhrase
            if comboRuns < 2 then
                landingPhrase = string.format("First read at %.2f", fw)
            elseif math.abs(runVsCombo) < 1.0 then
                landingPhrase = string.format("On-trend at %.2f (vs avg %.2f)", fw, comboAvg)
            elseif runVsCombo > 0 then
                landingPhrase = string.format("Above track at %.2f (+%.1f vs avg)", fw, runVsCombo)
            else
                landingPhrase = string.format("Below track at %.2f (%.1f vs avg)", fw, runVsCombo)
            end
            local carryPhrase
            if #ranked >= 1 then
                local top = ranked[1]
                local v, _, d = verdictForCohort(top.avg, median)
                carryPhrase = string.format("%s carries (%s, cohort %+.1f)",
                    top.id, v, d)
            else
                carryPhrase = "no carry data"
            end
            appendObsLine(string.format("  %s — %s.",
                landingPhrase, carryPhrase),
                Color3.fromRGB(180, 215, 230), order)

            -- Summary line 2: composition / synergy statement.
            order = order + 1
            appendObsLine(string.format("  Mix %dD/%dC — %s.",
                nDps, nCtrl, mixDesc),
                Color3.fromRGB(200, 200, 240), order)

            -- Summary line 3: failure-mode statement.
            order = order + 1
            appendObsLine("  " .. failureSentence .. ".",
                Color3.fromRGB(220, 180, 160), order)

            order = order + 1
            appendObsSpacer(order)
        end

        -- ─────────────────────────────────────────────────────
        -- OVERALL PATTERNS — 3 summary lines about high-level
        -- trends across all completed runs in state.recent.
        -- Per Matthew 2026-04-27: "add an overall observation of
        -- three lines at the bottom that talks about high level
        -- patterns noticed, i.e. slow is strong, a balanced
        -- combo is good, etc."
        -- ─────────────────────────────────────────────────────
        if #recent >= 3 then
            -- Bucket runs by role mix to see which composition
            -- is performing best.
            local mixStats = {
                balanced = { count = 0, totalWave = 0 },
                pureDps  = { count = 0, totalWave = 0 },
                pureCtrl = { count = 0, totalWave = 0 },
            }
            local failureCounts = { Solo = 0, Combined = 0, AOE = 0 }
            for _, r in ipairs(recent) do
                local aux = r.auxIds or {}
                local rD, rC = 0, 0
                for _, id in ipairs(aux) do
                    if not (id == "InfiniteStandard" and #aux >= 3) then
                        local role = TempTowers.RoleByTowerId[id]
                        if role == "DPS" then rD = rD + 1
                        elseif role == "Control" then rC = rC + 1
                        end
                    end
                end
                local mix
                if rD > 0 and rC > 0 then mix = "balanced"
                elseif rD > 0 and rC == 0 then mix = "pureDps"
                elseif rC > 0 and rD == 0 then mix = "pureCtrl"
                end
                if mix then
                    mixStats[mix].count = mixStats[mix].count + 1
                    mixStats[mix].totalWave = mixStats[mix].totalWave + (r.finalWave or 0)
                end
                local tt = r.testType or "?"
                if failureCounts[tt] ~= nil then
                    failureCounts[tt] = failureCounts[tt] + 1
                end
            end
            local function avgFor(bucket)
                local b = mixStats[bucket]
                if b.count == 0 then return nil end
                return b.totalWave / b.count
            end
            local balAvg, dpsAvg, ctrlAvg = avgFor("balanced"), avgFor("pureDps"), avgFor("pureCtrl")

            -- Top / bottom cumulative tower (across all towerAgg).
            local topTower, botTower = nil, nil
            local topAvg, botAvg = -math.huge, math.huge
            for tid, agg in pairs(state.towerAgg) do
                if agg.runs > 0 then
                    local a = agg.totalWaves / agg.runs
                    if a > topAvg then topAvg = a; topTower = tid end
                    if a < botAvg then botAvg = a; botTower = tid end
                end
            end

            -- Most-common failure type.
            local maxFailType, maxFailCount = "?", 0
            for tt, n in pairs(failureCounts) do
                if n > maxFailCount then maxFailCount = n; maxFailType = tt end
            end

            order = order + 1
            appendObsLine("OVERALL PATTERNS",
                Color3.fromRGB(255, 220, 140), order, Enum.Font.GothamBold)

            -- Line 1: best role mix.
            order = order + 1
            local mixLine
            if balAvg and dpsAvg and ctrlAvg then
                if balAvg > dpsAvg and balAvg > ctrlAvg then
                    mixLine = string.format("Balanced DPS+Control wins (avg %.1f vs DPS %.1f / Control %.1f) — slow + damage compounds.",
                        balAvg, dpsAvg, ctrlAvg)
                elseif dpsAvg > balAvg then
                    mixLine = string.format("Pure DPS leads (avg %.1f vs balanced %.1f) — burst beats utility here.",
                        dpsAvg, balAvg)
                else
                    mixLine = string.format("Pure Control leads (avg %.1f vs balanced %.1f) — slow stacking carries.",
                        ctrlAvg, balAvg)
                end
            elseif balAvg then
                mixLine = string.format("Balanced DPS+Control combos avg %.1f — utility + damage pairing trending.", balAvg)
            else
                mixLine = "Insufficient data for role-mix pattern (need balanced + pure samples)."
            end
            appendObsLine("  " .. mixLine,
                Color3.fromRGB(180, 215, 230), order)

            -- Line 2: dominant failure mode.
            order = order + 1
            local failLine
            if maxFailCount > 0 then
                local pct = math.floor(maxFailCount / #recent * 100)
                if maxFailType == "Solo" then
                    failLine = string.format("%d%% of runs die on Solo waves — single-target DPS is the bottleneck.", pct)
                elseif maxFailType == "AOE" then
                    failLine = string.format("%d%% of runs die on AOE waves — splash density underrepresented.", pct)
                elseif maxFailType == "Combined" then
                    failLine = string.format("%d%% of runs die on Combined waves — target priority crumbling at mixed loads.", pct)
                else
                    failLine = string.format("%d%% failures clustered on %s waves.", pct, maxFailType)
                end
            else
                failLine = "Failure-mode distribution still gathering."
            end
            appendObsLine("  " .. failLine,
                Color3.fromRGB(220, 180, 160), order)

            -- Line 3: standout towers.
            order = order + 1
            local standLine
            if topTower and botTower and topTower ~= botTower then
                standLine = string.format("%s carries (avg %.1f); %s lags (avg %.1f) — gap %.1f waves.",
                    topTower, topAvg, botTower, botAvg, topAvg - botAvg)
            elseif topTower then
                standLine = string.format("%s leading (avg %.1f).", topTower, topAvg)
            else
                standLine = "No tower-level standouts yet."
            end
            appendObsLine("  " .. standLine,
                Color3.fromRGB(200, 200, 240), order)
        end
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
            resetStopBtnToStage1()  -- new sweep → STOP AT END default
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
    end)

    -- Done event: sweep finished. Backfill the recent list from the
    -- complete results payload (covers the case where the user
    -- closed + reopened the window mid-sweep and missed events).
    local doneRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteAutoRunDone)
    doneRemote.OnClientEvent:Connect(function(payload)
        state.sweepActive = false
        stopRunBtn.Visible = false
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
    end)

    -- Last-sweep cache: when the window opens (user clicks MONITOR
    -- after a previous sweep ended), populate from cached data.
    local lastSweepDataRemote = ReplicatedStorage:WaitForChild(Remotes.Names.InfiniteLastSweepData)
    lastSweepDataRemote.OnClientEvent:Connect(function(payload)
        if not gui.Enabled then return end
        if type(payload) ~= "table" or payload.empty then return end
        if type(payload.results) ~= "table" then return end
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
        if not state.sweepActive then
            rebuildObservations()
        end
    end)

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
    end
end

function InfiniteMonitorWindow.close()
    if windowGui and windowGui.Parent then
        windowGui.Enabled = false
    end
end

return InfiniteMonitorWindow
