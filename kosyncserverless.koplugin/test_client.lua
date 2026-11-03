--[[--
Tests for the cold-start tolerant client: retry and backoff scheduling, the
exactly-once callback and cancel, the warm-up ping skip window, the queue
dropping an entry only after a confirmed success, and main.lua stamping the
debounce time only on success. The clock, scheduler and subprocess runner are
fakes; nothing touches the network.

Run from a KOReader install folder with its luajit:
    cd /mnt/us/koreader && ./luajit /path/to/kosyncserverless.koplugin/test_client.lua
]]

local this_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = this_dir .. "/?.lua;" .. package.path
require("setupkoenv")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("ok   " .. name)
    else failed = failed + 1; print("FAIL " .. name .. (detail ~= nil and ("  " .. tostring(detail)) or "")) end
end

-- Fake time and scheduler.
local now = 1000
local tasks = {}
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
local function clock() return now end

-- Fake subprocess runner: answers each request after `delay` seconds with the
-- next scripted result; records the start time of every attempt.
local function fakeRequest(script)
    local r = { calls = {}, killed = 0 }
    r.fn = function(req, cb)
        local n = #r.calls + 1
        r.calls[n] = { at = now, req = req }
        local step = script[n] or script[#script]
        local alive = true
        local answer = function() if alive then alive = false; cb(step.res) end end
        scheduleIn(step.delay or 0.5, answer)
        return function() if alive then alive = false; r.killed = r.killed + 1 end end
    end
    return r
end
local function reset() tasks = {}; now = 1000 end

local Retry = require("kosyncserverless_retry")
local Client = require("KOSyncServerlessClient")
local function newClient(req)
    return Client:new{ custom_url = "http://h:1/", username = "u", userkey = "k",
        request = req.fn, scheduleIn = scheduleIn, clock = clock }
end
local ITEM = { document = "d1", progress = "p", percentage = 0.5, device = "emu", device_id = "id" }

-- 1. Constants in one place.
check("constants 15 s x 3, backoff 2 then 5", Retry.TIMEOUT_S == 15 and Retry.MAX_ATTEMPTS == 3
    and Retry.BACKOFF_S[1] == 2 and Retry.BACKOFF_S[2] == 5 and Retry.PING_SKIP_S == 600)

-- 2. Success on attempt 1, 2, 3; delays 2 then 5.
for want = 1, 3 do
    reset()
    local script = {}
    for i = 1, want - 1 do script[i] = { delay = 15, res = { err = "timeout" } } end
    script[want] = { delay = 0.3, res = { status = 200, body = "{}" } }
    local r = fakeRequest(script)
    local fired, got_ok, got_res = 0, nil, nil
    newClient(r):push(ITEM, function(ok, res) fired = fired + 1; got_ok, got_res = ok, res end)
    advance(100)
    check("success on attempt " .. want, fired == 1 and got_ok == true and #r.calls == want
        and got_res.attempts == want, #r.calls)
    if want == 3 then
        check("attempt 2 starts 2 s after attempt 1 failed", r.calls[2].at - r.calls[1].at == 17, r.calls[2].at - r.calls[1].at)
        check("attempt 3 starts 5 s after attempt 2 failed", r.calls[3].at - r.calls[2].at == 20, r.calls[3].at - r.calls[2].at)
        check("each attempt gets a 15 s timeout", r.calls[1].req.timeout == 15 and r.calls[3].req.timeout == 15)
    end
end

-- 3. Give up after 3; 5xx retried; 401 not retried.
reset()
local r = fakeRequest({ { delay = 1, res = { status = 503 } } })
local fired, got_ok, got_res = 0, nil, nil
newClient(r):push(ITEM, function(ok, res) fired = fired + 1; got_ok, got_res = ok, res end)
advance(200)
check("gives up after 3 attempts on 503", fired == 1 and got_ok == false and #r.calls == 3 and got_res.status == 503)
reset()
r = fakeRequest({ { delay = 1, res = { status = 401, body = '{"message":"Unauthorized"}' } } })
fired = 0
newClient(r):push(ITEM, function(ok, res) fired = fired + 1; got_ok, got_res = ok, res end)
advance(200)
check("no retry on 401", fired == 1 and got_ok == false and #r.calls == 1 and got_res.status == 401)

-- 4. Request shape.
reset()
r = fakeRequest({ { res = { status = 200, body = "{}" } } })
newClient(r):push(ITEM, function() end)
advance(1)
local q = r.calls[1].req
check("push is PUT /syncs/progress", q.method == "PUT" and q.url == "http://h:1/syncs/progress", q.url)
check("push headers", q.headers.accept == "application/vnd.koreader.v1+json" and q.headers["x-auth-user"] == "u"
    and q.headers["x-auth-key"] == "k" and q.headers["content-type"] == "application/json")
check("push body is JSON with progress as string", q.body:find('"progress":"p"', 1, true) ~= nil, q.body)
reset()
r = fakeRequest({ { res = { status = 200, body = '{"percentage":0.25,"progress":"x"}' } } })
local pulled
newClient(r):pull("abc", function(ok, body) pulled = body end)
advance(1)
check("pull is GET /syncs/progress/<doc> and decodes", r.calls[1].req.url == "http://h:1/syncs/progress/abc"
    and pulled and pulled.percentage == 0.25)

-- 5. Cancel: during an attempt and during the backoff; callback exactly once.
reset()
r = fakeRequest({ { delay = 15, res = { err = "timeout" } } })
fired = 0
local h = newClient(r):push(ITEM, function(ok, res) fired = fired + 1; got_ok, got_res = ok, res end)
advance(5)
check("cancel during attempt returns true", h.cancel() == true)
check("cancel during attempt fires once with cancelled", fired == 1 and got_ok == false and got_res.err == "cancelled")
check("cancel kills the subprocess", r.killed == 1)
advance(100)
check("nothing fires after cancel", fired == 1 and #r.calls == 1)
check("second cancel is a no-op", h.cancel() == false and fired == 1)
reset()
r = fakeRequest({ { delay = 15, res = { err = "timeout" } } })
fired = 0
h = newClient(r):push(ITEM, function(ok, res) fired = fired + 1; got_ok, got_res = ok, res end)
advance(16) -- attempt 1 failed at 15, attempt 2 due at 17
h.cancel()
advance(100)
check("cancel during backoff: once, no further attempt", fired == 1 and got_res.err == "cancelled" and #r.calls == 1)
reset()
r = fakeRequest({ { delay = 1, res = { status = 200 } } })
fired = 0
h = newClient(r):push(ITEM, function() fired = fired + 1 end)
advance(5)
check("cancel after success is a no-op", h.cancel() == false and fired == 1)

-- 6. Warm-up ping skip window.
reset()
Client.last_reached = nil
r = fakeRequest({ { delay = 1, res = { status = 200, body = '{"state":"OK"}' } } })
local c = newClient(r)
check("ping sent when never reached", c:ping() == true)
check("ping skipped while one is in flight", c:ping() == false)
advance(2)
check("ping is GET /healthcheck with accept header", r.calls[1].req.url == "http://h:1/healthcheck"
    and r.calls[1].req.headers.accept == "application/vnd.koreader.v1+json" and #r.calls == 1)
advance(599 - 2)
check("ping skipped within 10 min of an answer", c:ping() == false and #r.calls == 1)
advance(5)
check("ping sent again after 10 min", c:ping() == true)
advance(2)
Client.last_reached = nil
r = fakeRequest({ { delay = 1, res = { err = "connection refused" } } })
c = newClient(r)
c:ping(); advance(2)
check("ping is a single attempt and a failure does not open the window",
    #r.calls == 1 and Client.last_reached == nil and c:ping() == true)
advance(2)
r = fakeRequest({ { delay = 1, res = { status = 401 } } })
newClient(r):push(ITEM, function() end); advance(2)
check("any answer from the server opens the window", Client.last_reached ~= nil and newClient(r):ping() == false)

-- 7. Queue: drop on confirmed success only.
local Queue = require("KOSyncServerlessQueue")
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/kss-queue-" .. tostring(os.time())
os.execute("mkdir -p " .. dir)
Queue.path = dir .. "/queue.lua"
Queue:clear()
Queue:push({ document = "a", progress = "1", percentage = 0.1 })
Queue:push({ document = "b", progress = "2", percentage = 0.2 })
local sent_docs = {}
local result
Queue:drainAsync(function(item, cb) table.insert(sent_docs, item.document); cb(false) end,
    function(sent, remaining) result = { sent, remaining } end)
check("failed drain keeps every entry", Queue:count() == 2 and result[1] == 0 and result[2] == 2 and #sent_docs == 1)
local pending_cb
Queue:drainAsync(function(item, cb) pending_cb = cb end, function(s, rem) result = { s, rem } end)
check("entry kept while its send is in flight", Queue:count() == 2)
check("second drain refused while one runs", Queue:drainAsync(function() end) == false)
pending_cb(true)
check("entry dropped after confirmed success", Queue:count() == 1 and Queue:load()[1].document == "b")
pending_cb(false)
check("first failure stops the drain", Queue:count() == 1 and result[1] == 1 and result[2] == 1)
Queue:drainAsync(function(item, cb) cb(true) end, function(s, rem) result = { s, rem } end)
check("later successful drain sends the rest", Queue:count() == 0 and result[1] == 1 and result[2] == 0)

-- 8. main.lua: debounce stamped only on success, failure queued.
local function stubModule(name, value) package.loaded[name] = value end
local shown = {}
stubModule("ui/uimanager", {
    scheduleIn = function(_, s, f) scheduleIn(s, f) end, unschedule = function(_, f) unschedule(f) end,
    nextTick = function(_, f) scheduleIn(0, f) end, show = function(_, w) table.insert(shown, w) end,
    close = function() end, getElapsedTimeSinceBoot = function() return require("ui/time").s(now) end,
    getTopmostVisibleWidget = function() end,
})
local function widget() return { new = function(_, o) return o or {} end, extend = function(_, o) return o end } end
for _, m in ipairs{ "ui/widget/confirmbox", "ui/widget/infomessage", "ui/widget/inputdialog",
                    "ui/widget/multiinputdialog", "ui/widget/notification", "ui/widget/container/widgetcontainer" } do
    stubModule(m, widget())
end
stubModule("dispatcher", { registerAction = function() end })
stubModule("ui/event", { new = function() return {} end })
stubModule("device", setmetatable({ model = "emu" }, { __index = function() return function() return false end end }))
stubModule("ui/network/manager", { willRerunWhenOnline = function() return false end, isOnline = function() return true end })
local Main = assert(loadfile(this_dir .. "/main.lua"))()
local script = { { delay = 1, res = { err = "timeout" } } }
local fake = fakeRequest(script)
local function plugin()
    local p = setmetatable({}, { __index = Main })
    p.settings = { username = "u", userkey = "k" }
    p.push_timestamp, p.pull_timestamp, p.device_id = 0, 0, "id"
    p.newClient = function() return newClient(fake) end
    p.currentProgressItem = function() return { document = "doc", progress = "p", percentage = 0.5 } end
    p.getDocumentDigest = function() return "doc" end
    p.ui = { document = {} }
    return p
end
reset()
Queue:clear()
local p = plugin()
now = 100
p:updateProgress(false, false)
advance(60)
check("failed auto push does not stamp the debounce time", p.push_timestamp == 0)
check("failed auto push is queued", Queue:count() == 1 and Queue:load()[1].document == "doc")
local calls_before = #fake.calls
p:updateProgress(false, false)
advance(1)
check("next auto push is not debounced after a failure", #fake.calls == calls_before + 1)
advance(60)
script[1] = { delay = 1, res = { status = 200, body = "{}" } }
p:updateProgress(false, false)
advance(5)
check("successful auto push stamps the debounce time", p.push_timestamp == require("ui/time").s(now - 5 + 1))
check("success drains the queue", Queue:count() == 0)
calls_before = #fake.calls
p:updateProgress(false, false)
advance(1)
check("auto push within 25 s of a success is debounced", #fake.calls == calls_before)
script[1] = { delay = 1, res = { err = "timeout" } }
local q2 = plugin()
q2:getProgress(false, false)
advance(60)
check("failed auto pull does not stamp the debounce time", q2.pull_timestamp == 0)
local fires, cb_ok = 0, nil
local hh = q2:pushNow(function(ok) fires = fires + 1; cb_ok = ok end)
advance(3)
hh.cancel()
advance(60)
check("pushNow: cancel fires the callback once with false", fires == 1 and cb_ok == false)
check("pushNow: cancelled push is queued", Queue:count() >= 1)
q2.settings.userkey = nil
fires = 0
local hn = q2:pushNow(function(ok, res) fires = fires + 1; cb_ok = res.err end)
check("pushNow: not logged in fires once right away", fires == 1 and cb_ok == "not logged in" and hn.cancel() == false)
Queue:clear()
os.execute("rm -rf " .. dir)

print(string.format("\n%d passed, %d failed (client)", passed, failed))
os.exit(failed == 0 and 0 or 1)
