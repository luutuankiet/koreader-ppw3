--[[--
Tests for push before sleep (kosyncserverless_sleep.lua): which sleeps are
held, suspend called exactly once on confirm, failure or the 30 s cap, the cap
cancelling the push, input frozen during the hold only, and a sleep that the
device started on its own during a hold never triggering a second suspend.
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
    local r = { suspends = {}, done = {}, input = {}, cancels = 0 }
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
        suspend = function(reason) table.insert(r.suspends, { reason = reason, t = now }) end,
        scheduleIn = scheduleIn, unschedule = unschedule,
        set_ignore_input = function(b) table.insert(r.input, b) end,
        on_done = function(reason) table.insert(r.done, reason) end,
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

print(passed .. " passed, " .. failed .. " failed")
os.exit(failed == 0 and 0 or 1)
