--[[
Keeps a Kindle awake for a live session, and still lets the owner put it to sleep.

A session sets powerd's preventScreenSaver, so powerd's idle timeout cannot put the device to
sleep under an agent, and pauses KOReader's own AutoSuspend. powerd then also ignores the
simulated power button press KOReader sleeps with (KindlePowerD:toggleSuspend), so a Sleep the
owner asked for would do nothing. wrap() releases the hold right before that press, after any
other plugin's delay on UIManager:suspend; resumed() puts it back on wake if the session is
still on. Not a Kindle: every call is a no-op.

deps:
  is_kindle   boolean
  share       KOReader's pluginshare table (keepalive, pause_auto_suspend)
  exec(cmd)   runs a shell command
  log(msg)
]]

local SleepHold = {}
SleepHold.__index = SleepHold

local function prop(held)
    return "lipc-set-prop com.lab126.powerd preventScreenSaver " .. (held and "1" or "0")
end

function SleepHold.new(deps)
    return setmetatable({ deps = deps, held = false, released_for_sleep = false }, SleepHold)
end

-- A live session began (true) or ended (false).
function SleepHold:set(held)
    local deps = self.deps
    if not deps.is_kindle then return end
    self.released_for_sleep = false
    if held then
        deps.exec(prop(true))
        self.held = true
        -- Only undo a pause this set: AutoTurn and KeepAlive set it too.
        if not deps.share.pause_auto_suspend then
            deps.share.pause_auto_suspend = true
            self.paused = true
        end
        return
    end
    self.held = false
    if self.paused then
        deps.share.pause_auto_suspend = nil
        self.paused = nil
    end
    -- KeepAlive holds the same property: leave it to KeepAlive.
    if deps.share.keepalive then return end
    deps.exec(prop(false))
end

-- The owner asked for sleep and KOReader is about to press the power button.
function SleepHold:releaseForSleep()
    if not self.held then return end
    if self.deps.share.keepalive then
        self.deps.log("screensaver hold kept for sleep: KeepAlive is on")
        return
    end
    self.deps.exec(prop(false))
    self.held = false
    self.released_for_sleep = true
    self.deps.log("screensaver hold released for sleep")
end

-- The device woke up. active: the live session is still on.
function SleepHold:resumed(active)
    if not self.released_for_sleep then return end
    self.released_for_sleep = false
    if not active then return end
    self.deps.exec(prop(true))
    self.held = true
    self.deps.log("screensaver hold held again after wake")
end

-- powerd is Device:getPowerDevice(). On a Kindle, UIManager.event_handlers.Suspend calls its
-- toggleSuspend, the last step before powerd; UIManager:suspend only schedules that handler.
function SleepHold:wrap(powerd)
    if not self.deps.is_kindle or not powerd or rawget(powerd, "_sleephold_original") then return end
    local original = powerd.toggleSuspend
    if not original then return end
    powerd._sleephold_original = original
    local hold = self
    powerd.toggleSuspend = function(pd, ...)
        pcall(hold.releaseForSleep, hold)
        return original(pd, ...)
    end
end

return SleepHold
