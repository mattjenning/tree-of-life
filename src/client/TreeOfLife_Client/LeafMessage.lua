--[[
    LeafMessage.lua — Falling-leaf flavor text. Server fires LeafMessage
    with `{ text, duration, static? }`. The text drifts downward with a
    gentle sway + rotation (the "feather effect"); `static = true`
    suppresses the motion when the surrounding visual beat already
    implies falling — e.g. the rope-ladder drop after a map-1 boss
    defeat, where the ladder itself is what's falling and competing
    motion would muddle the read.

    QUEUEING (per Matthew's 2026-04-25 playtest):
      Multiple messages firing in quick succession used to overlap
      mid-screen — the pickle-lord-rises tip AND the map-3 boss-flight
      narration both fired within ~1s and the player saw them stacked
      on top of each other, unreadable. We now QUEUE messages: at most
      one visible at a time; the next one starts as soon as the previous
      finishes its full lifecycle (drift + fade).

    PRIORITY (later same playtest):
      A message can carry `priority = true`. When such a payload
      arrives we:
        • flush the pending queue (drop any not-yet-shown leaves)
        • fast-forward the currently-visible leaf (collapse the rest
          of its lifecycle into ~0.25s of rapid fade)
      Used by the Pickle Lord cinematic ("something ancient
      approaches…") so the entrance line lands the instant the
      cinematic starts — even if a mundane leaf (e.g. the temp-tower
      reward tip) is still mid-drift from a few seconds earlier.

    setup(deps) captures:
      deps.playerGui
      deps.ReplicatedStorage
      deps.Remotes
      deps.RunService
      deps.IS_MOBILE
]]

local LeafMessage = {}

-- Set by setup() so other client modules (HubOpening, etc.) can
-- queue a leaf locally without a server roundtrip. Mirrors the
-- payload shape of the LeafMessage remote.
local _queueLocal = nil
function LeafMessage.queue(payload)
    if _queueLocal then _queueLocal(payload) end
end

function LeafMessage.setup(deps)
    local playerGui         = deps.playerGui
    local ReplicatedStorage = deps.ReplicatedStorage
    local Remotes           = deps.Remotes
    local RunService        = deps.RunService
    local IS_MOBILE         = deps.IS_MOBILE

    -- Queue of pending message payloads. Items are added on remote
    -- receive; drained one at a time by playNext. activePlayer is the
    -- currently-running task.spawn so we never start a second one
    -- while the current message is still on screen.
    -- activeFastForward: set true by the priority path to make the
    -- currently-visible leaf collapse its remaining lifecycle into a
    -- short fade. The showOne loop reads + clears the flag.
    local queue = {}
    local activePlayer = nil
    local activeFastForward = false

    -- Render one message lifecycle, blocking the calling task until
    -- the message has finished its drift + fade. The remote handler
    -- spawns ONE long-lived task that drains the queue sequentially —
    -- so this is just the "show one and wait" body.
    local function showOne(payload)
        local text = payload and payload.text or ""
        local duration = payload and payload.duration or 6
        local staticMode = payload and payload.static == true
        if text == "" then return end
        -- Mobile-first: strip any RichText hotkey-accent tags so the message
        -- reads cleanly on iPad (player has no keyboard to act on a hotkey).
        if IS_MOBILE then
            text = text:gsub("<font[^>]*>", ""):gsub("</font>", "")
        end

        local gui = Instance.new("ScreenGui")
        gui.Name = "ToL_LeafMsg"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 220
        gui.Parent = playerGui

        local startY = staticMode and 0.15 or 0.05
        local endY   = staticMode and 0.15 or 0.40

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(0.8, 0, 0, 60)
        label.AnchorPoint = Vector2.new(0.5, 0)
        label.Position = UDim2.fromScale(0.5, startY)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.FredokaOne
        label.TextSize = 26
        label.TextColor3 = Color3.fromRGB(240, 250, 220)
        label.TextStrokeColor3 = Color3.fromRGB(20, 40, 10)
        label.TextStrokeTransparency = 0.2
        -- RichText enabled so server-fired messages can highlight specific
        -- characters (e.g. hotkey hints like "<font color='#ffdd55'>G</font>").
        label.RichText = true
        label.Text = text
        label.TextWrapped = true
        label.Parent = gui

        -- Heartbeat loop: drifts downward with sway+tilt (unless static),
        -- and fades out over the last 30% of the duration. Yields the
        -- spawning task until the message's full life elapses so the
        -- queue drainer doesn't pop the next entry early.
        --
        -- Fast-forward: if a priority payload arrives mid-show,
        -- activeFastForward gets set true and we COMPRESS `duration`
        -- so the loop's t passes 0.7 immediately and the full life
        -- ends in ~0.25s of rapid fade. We also bias t into the fade
        -- window manually for the first frame so there's no flash of
        -- full-opacity text before the fade kicks in.
        local startedAt = os.clock()
        activeFastForward = false  -- reset for each leaf
        while true do
            if activeFastForward then
                -- Collapse remaining lifecycle: end of life is now
                -- 0.25s from now, sitting fully in the fade window.
                local remaining = 0.25
                duration = (os.clock() - startedAt) + remaining
                activeFastForward = false
            end
            local elapsed = os.clock() - startedAt
            local t = math.clamp(elapsed / duration, 0, 1)
            if not staticMode then
                local y = startY + (endY - startY) * t
                local sway = math.sin(elapsed * 1.8) * 0.04
                label.Position = UDim2.fromScale(0.5 + sway, y)
                label.Rotation = math.sin(elapsed * 1.2) * 6
            end
            if t > 0.7 then
                local fadeT = (t - 0.7) / 0.3
                label.TextTransparency = fadeT
                label.TextStrokeTransparency = 0.2 + fadeT * 0.8
            end
            if elapsed >= duration + 0.05 then break end
            RunService.Heartbeat:Wait()
        end
        if gui.Parent then gui:Destroy() end
    end

    local function startDrainer()
        if activePlayer then return end
        activePlayer = task.spawn(function()
            while #queue > 0 do
                local next_ = table.remove(queue, 1)
                showOne(next_)
                -- Tiny breathing room between messages so they're
                -- clearly separate beats rather than back-to-back.
                task.wait(0.25)
            end
            activePlayer = nil
        end)
    end

    -- Shared queue-handling logic used by BOTH the remote receiver
    -- and the public LeafMessage.queue() helper. Exposing this as
    -- _queueLocal lets sibling client modules (HubOpening, etc.)
    -- render leaves without a server roundtrip.
    local function enqueue(payload)
        if not payload or not payload.text or payload.text == "" then return end
        if payload.priority then
            -- Priority leaf: drop anything already queued (we don't
            -- want pre-cinematic chatter showing AFTER the entrance
            -- line) and trigger fast-forward on whatever's currently
            -- on screen so this message can pop in within ~0.25s.
            for i = #queue, 1, -1 do
                queue[i] = nil
            end
            if activePlayer then
                activeFastForward = true
            end
        end
        table.insert(queue, payload)
        startDrainer()
    end
    _queueLocal = enqueue

    ReplicatedStorage:WaitForChild(Remotes.Names.LeafMessage).OnClientEvent:Connect(enqueue)
end

return LeafMessage
