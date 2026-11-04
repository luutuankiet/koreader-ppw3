--[[--
Tests for push before sleep (kosyncserverless_sleep.lua): which sleeps are
held, suspend called exactly once on confirm, failure or the 30 s cap, the cap
cancelling the push, input frozen during the hold only, a sleep that the
device started on its own during a hold never triggering a second suspend, and
the "saving before sleep" message: shown only when the push is still running
after Sleep.MESSAGE_DELAY_S, and closed before suspend on every finish path.
Uses fakes for the scheduler and the push; also runs the real retry policy
(kosyncserverless_retry.lua) under the hold with a fake request.

Run with luajit (KOReader's or any): luajit test_sleep.lua
]]

local this_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = this_dir .. "/?.lua;" .. package.path

local Retry = require("kosyncserverless_retry")
local Sleep = require("kosyncserverless_sleep")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("ok   " .. name)
    else failed = failed + 1; print("FAIL " .. name .. (detail ~= nil and ("  " .. tostring(detail)) or "")) end
end

local now, tasks
local function reset() now = 0; tasks = {} end
local function scheduleIn(s, f) table.insert(tasks, { t = now + s, f = f }) end
local function unschedule(f)
    for i = #tasks, 1, -1 do if tasks[i].f == f then table.remove(tasks, i) end end
end
local function advance(dt)
    local target = now + dt
    while true do
        local best
        for i, t in ipairs(tasks) do
            if t.t <= target and (not best or t.t < tasks[best].t) then best = i end
        end
        if not best then break end
        local t = table.remove(tasks, best)
        now = t.t
        t.f()
    end
    now = target
end

-- A hold around a fake push the test answers by hand.
local function setup(extra)
    reset()
    local r = { suspends = {}, done = {}, input = {}, cancels = 0, shows = {}, closes = {}, log = {} }
    local push_cb
    local opts = {
        push = function(cb)
            push_cb = cb
            if extra and extra.sync_answer ~= nil then cb(extra.sync_answer, {}) end
            return { cancel = function()
                r.cancels = r.cancels + 1
                if push_cb then local c = push_cb; push_cb = nil; c(false, { err = "cancelled" }) end
                return true
            end }
        end,
        suspend = function(reason)
            table.insert(r.suspends, { reason = reason, t = now }); table.insert(r.log, "suspend")
        end,
        scheduleIn = scheduleIn, unschedule = unschedule,
        set_ignore_input = function(b) table.insert(r.input, b) end,
        on_done = function(reason) table.insert(r.done, reason) end,
        show_message = function() table.insert(r.shows, now); table.insert(r.log, "show") end,
        close_message = function(will_suspend)
            table.insert(r.closes, { t = now, will_suspend = will_suspend }); table.insert(r.log, "close")
        end,
    }
    r.hold = Sleep.hold(opts)
    r.answer = function(ok) local c = push_cb; push_cb = nil; c(ok, { status = ok and 200 or nil }) end
    return r
end

-- should_hold
local base = { auto_sync = true, logged_in = true, has_document = true, wifi_on = true, connected = true }
local function with(k, v) local t = {}; for a, b in pairs(base) do t[a] = b end; t[k] = v; return t end
check("hold when online with a book", Sleep.should_hold(base) == true)
for _, k in ipairs({ "wifi_on", "connected", "has_document", "logged_in", "auto_sync" }) do
    local h, why = Sleep.should_hold(with(k, false))
    check("no hold when " .. k .. " is false (" .. why .. ")", h == false)
end
check("cap is 30 s", Retry.SLEEP_CAP_S == 30)

-- confirmed push
do
    local r = setup()
    check("input frozen at start", r.input[1] == true and #r.input == 1)
    advance(12)
    check("no suspend while the push runs", #r.suspends == 0)
    r.answer(true)
    check("suspend once on confirm", #r.suspends == 1 and r.suspends[1].reason == "confirmed")
    check("suspend right after confirm, at 12 s", r.suspends[1].t == 12)
    check("input released before suspend", r.input[2] == false and #r.input == 2)
    advance(60)
    check("cap does not fire after confirm", #r.suspends == 1 and r.cancels == 0)
    check("on_done once", #r.done == 1 and r.done[1] == "confirmed")
end

-- cap
do
    local r = setup()
    advance(29.9)
    check("no suspend before 30 s", #r.suspends == 0)
    advance(0.2)
    check("suspend once at the cap", #r.suspends == 1 and r.suspends[1].reason == "cap" and r.suspends[1].t == 30)
    check("cap cancels the push", r.cancels == 1)
    advance(100)
    check("still one suspend after the cap", #r.suspends == 1 and #r.done == 1)
end

-- failed push (all attempts gave up before the cap)
do
    local r = setup()
    advance(20)
    r.answer(false)
    check("suspend once on failure", #r.suspends == 1 and r.suspends[1].reason == "failed")
    advance(30)
    check("no second suspend at the cap", #r.suspends == 1 and r.cancels == 0)
end

-- push answers synchronously (not logged in or no book)
do
    local r = setup({ sync_answer = false })
    check("synchronous answer: one suspend at once", #r.suspends == 1 and r.suspends[1].t == 0)
    check("synchronous answer: cap unscheduled", #tasks == 0)
end

-- device slept by itself during the hold
do
    local r = setup()
    advance(5)
    r.hold.external_suspend()
    check("external: no suspend call", #r.suspends == 0)
    check("external: input released", r.input[2] == false)
    check("external: push keeps running", r.cancels == 0)
    r.answer(true)
    advance(60)
    check("external: never suspends later", #r.suspends == 0 and #r.done == 1 and r.done[1] == "external")
end

-- real retry policy under the hold: a server that never answers
do
    reset()
    local requests, killed = 0, 0
    local function request(req, cb)
        requests = requests + 1
        local t = function() cb({ err = "timeout" }) end
        scheduleIn(req.timeout, t)
        return function() killed = killed + 1; unschedule(t) end
    end
    local suspends, queued = {}, 0
    Sleep.hold{
        push = function(cb)
            return Retry.run{ request = request, scheduleIn = scheduleIn, req = { url = "x" },
                done = function(ok, res) if not ok then queued = queued + 1 end; cb(ok, res) end }
        end,
        suspend = function(reason) table.insert(suspends, { reason = reason, t = now }) end,
        scheduleIn = scheduleIn, unschedule = unschedule,
    }
    advance(120)
    -- attempt 1 at 0 s (times out 15), attempt 2 at 17 s (would time out 32)
    check("retry: 2 attempts started before the cap", requests == 2, requests)
    check("retry: one suspend, at 30 s by the cap", #suspends == 1 and suspends[1].reason == "cap" and suspends[1].t == 30)
    check("retry: in-flight attempt killed", killed == 1)
    check("retry: progress queued once", queued == 1)
    check("retry: no attempt after the cap", requests == 2)
end

-- real retry policy: cold server answering at 12 s
do
    reset()
    local function request(req, cb)
        local t = function() cb({ status = 200 }) end
        scheduleIn(12, t)
        return function() unschedule(t) end
    end
    local suspends = {}
    Sleep.hold{
        push = function(cb)
            return Retry.run{ request = request, scheduleIn = scheduleIn, req = { url = "x" }, done = cb }
        end,
        suspend = function(reason) table.insert(suspends, { reason = reason, t = now }) end,
        scheduleIn = scheduleIn, unschedule = unschedule,
    }
    advance(120)
    check("cold 12 s: one suspend at 12 s", #suspends == 1 and suspends[1].reason == "confirmed" and suspends[1].t == 12)
end

-- "saving before sleep" message
check("message delay is 1 s", Sleep.MESSAGE_DELAY_S == 1)

do
    local r = setup()
    advance(0.5)
    r.answer(true)
    advance(60)
    check("fast push: no message shown", #r.shows == 0 and #r.closes == 0)
    check("fast push: message timer cancelled", #tasks == 0)
end

do
    local r = setup({ sync_answer = true })
    advance(60)
    check("synchronous answer: no message", #r.shows == 0 and #tasks == 0)
end

do
    local r = setup()
    advance(0.99)
    check("slow push: nothing before the delay", #r.shows == 0)
    advance(0.02)
    check("slow push: message shown at 1 s", #r.shows == 1 and r.shows[1] == 1)
    advance(10)
    check("slow push: shown once", #r.shows == 1 and #r.closes == 0)
    r.answer(true)
    check("confirmed: message closed once", #r.closes == 1 and r.closes[1].will_suspend == true)
    check("confirmed: close before suspend", r.log[2] == "close" and r.log[3] == "suspend", table.concat(r.log, ","))
    advance(60)
    check("confirmed: no reopen", #r.shows == 1 and #r.closes == 1)
end

do
    local r = setup()
    advance(5)
    r.answer(false)
    check("failed: close before suspend", #r.closes == 1 and table.concat(r.log, ",") == "show,close,suspend",
        table.concat(r.log, ","))
end

do
    local r = setup()
    advance(31)
    check("cap: close before suspend", #r.closes == 1 and table.concat(r.log, ",") == "show,close,suspend",
        table.concat(r.log, ","))
    check("cap: no tasks left", #tasks == 0)
end

do
    local r = setup()
    advance(3)
    r.hold.external_suspend()
    check("external: message closed, no suspend", #r.closes == 1 and r.closes[1].will_suspend == false
        and #r.suspends == 0)
    r.answer(true)
    advance(60)
    check("external: no reopen", #r.shows == 1 and #r.closes == 1)
end

do
    local r = setup()
    advance(0.5)
    r.hold.external_suspend()
    advance(60)
    check("external before delay: never shown, timer cancelled", #r.shows == 0 and #r.closes == 0 and #tasks == 0)
end

print(passed .. " passed, " .. failed .. " failed")
os.exit(failed == 0 and 0 or 1)
