--[[--
Push before sleep: hold a sleep that KOReader starts itself until the server
confirms the reading position, or until Retry.SLEEP_CAP_S, whichever is first.

Pure logic with injected side effects, so the exactly-once rule can be tested
without KOReader (test_sleep.lua).

    local hold = Sleep.hold{
        push = function(cb) return handle end,  -- cb(ok, res) once; handle.cancel()
        suspend = function(reason) end,          -- the real sleep; called at most once
        scheduleIn = function(s, fn) end,
        unschedule = function(fn) end,
        set_ignore_input = function(bool) end,   -- optional
        cap_s = 30,                              -- optional, default Retry.SLEEP_CAP_S
        on_done = function(reason) end,          -- optional; "confirmed", "failed", "cap", "external"
        show_message = function() end,           -- optional; push still running after MESSAGE_DELAY_S
        close_message = function(will_suspend) end, -- optional; once, only if shown, before suspend
    }
    hold.external_suspend() -- the device went to sleep on its own: release, never suspend

Lua 5.1 only.
]]

local Retry = require("kosyncserverless_retry")

local Sleep = {}

-- A push that answers within this many seconds never shows the "saving
-- before sleep" message, so a warm server does not flash it.
Sleep.MESSAGE_DELAY_S = 1

--- Whether a sleep request should wait for a push.
-- Only cheap state checks: never call anything that can turn Wi-Fi on.
-- @treturn bool hold
-- @treturn string why, for the log
function Sleep.should_hold(s)
    if not s.auto_sync then return false, "auto sync off" end
    if not s.logged_in then return false, "not logged in" end
    if not s.has_document then return false, "no book open" end
    if not s.wifi_on then return false, "wifi off" end
    if not s.connected then return false, "wifi not connected" end
    return true, "push first"
end

function Sleep.hold(opts)
    assert(opts.push and opts.suspend and opts.scheduleIn and opts.unschedule, "Sleep.hold: missing option")
    local set_ignore_input = opts.set_ignore_input or function() end
    local finished = false
    local capped = false
    local handle = nil
    local cap_task
    local message_shown = false

    local function message_task()
        if finished or message_shown then return end
        message_shown = true
        if opts.show_message then opts.show_message() end
    end

    local function finish(reason, do_suspend)
        if finished then return end
        finished = true
        opts.unschedule(cap_task)
        opts.unschedule(message_task)
        -- before suspend, so the screensaver is not covered by the message
        if message_shown then
            message_shown = false
            if opts.close_message then opts.close_message(do_suspend) end
        end
        set_ignore_input(false)
        if do_suspend then opts.suspend(reason) end
        if opts.on_done then opts.on_done(reason) end
    end

    cap_task = function()
        if finished then return end
        capped = true
        -- cancel makes push queue the progress for the next network connect
        if handle then handle.cancel() end
        finish("cap", true)
    end

    set_ignore_input(true)
    opts.scheduleIn(opts.cap_s or Retry.SLEEP_CAP_S, cap_task)
    if opts.show_message then opts.scheduleIn(Sleep.MESSAGE_DELAY_S, message_task) end
    handle = opts.push(function(ok)
        if capped then return end
        finish(ok and "confirmed" or "failed", true)
    end)

    return {
        external_suspend = function()
            -- powerd slept without us (power button or cover during the
            -- hold): calling suspend now would toggle the device awake.
            -- The push keeps running in the background.
            finish("external", false)
        end,
        finished = function() return finished end,
    }
end

return Sleep
