-- Run with: luajit test_live.lua   (from koreader_mcp.koplugin/)
package.path = "./?.lua;" .. package.path
local Live = require("live")

local failures, count = 0, 0
local function test(name, fn)
    count = count + 1
    local ok, err = pcall(fn)
    if not ok then failures = failures + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b) if a ~= b then error(tostring(a) .. " ~= " .. tostring(b), 2) end end

-- The codec only has to carry a table through a string.
local function fake_json()
    local store = {}
    return {
        encode = function(t) store[#store + 1] = t; return "#" .. #store end,
        decode = function(s) local t = store[tonumber(s:match("^#(%d+)$"))]; if not t then error("bad") end; return t end,
    }
end

local function world(opts)
    opts = opts or {}
    local w = { t = 0, timers = {}, sent = {}, ended = {}, began = 0, battery = 100, connects = 0, inbox = {}, connect_ok = true }
    w.json = fake_json()
    w.feed = function(msg) w.inbox[#w.inbox + 1] = w.json.encode(msg) end
    local function new_sock()
        return {
            settimeout = function() end,
            close = function(s) s.closed = true end,
            send = function(_, data) w.sent[#w.sent + 1] = w.json.decode(data:sub(1, -2)); return #data end,
            receive = function()
                if w.read_error then return nil, w.read_error end
                local line = table.remove(w.inbox, 1)
                if line then return line end
                return nil, "timeout", ""
            end,
        }
    end
    w.live = Live.new({
        connect = function()
            w.connects = w.connects + 1
            if not w.connect_ok then return nil, "refused" end
            w.sock = new_sock()
            return w.sock
        end,
        schedule = function(s, fn) local h = { at = w.t + s, fn = fn, delay = s }; w.timers[#w.timers + 1] = h; return h end,
        unschedule = function(h) for i, x in ipairs(w.timers) do if x == h then table.remove(w.timers, i) end end end,
        now = function() return w.t end,
        json = w.json,
        dispatch = opts.dispatch or function(m, p) return { method = m, params = p } end,
        identity = function() return { name = "kindle", id_hash = "abc" } end,
        battery = function() return w.battery end,
        on_begin = function() w.began = w.began + 1 end,
        on_end = function(r) w.ended[#w.ended + 1] = r end,
        log = function() end,
    }, { host = "gw", port = 1, always = opts.always })
    -- Run the only timer there should ever be, after moving the clock to it.
    w.step = function()
        assert(#w.timers == 1, "expected exactly one timer, have " .. #w.timers)
        local h = table.remove(w.timers)
        w.t = h.at
        h.fn()
        return h.delay
    end
    w.advance = function(seconds)
        local stop = w.t + seconds
        while #w.timers == 1 and w.timers[1].at <= stop do w.step() end
        if w.t < stop then w.t = stop end
    end
    return w
end

test("a session that never starts uses no socket and no timer", function()
    local w = world()
    eq(#w.timers, 0); eq(w.connects, 0); eq(w.live:isActive(), false)
end)

test("start says hello, then stop leaves no socket and no timer", function()
    local w = world()
    w.live:start()
    eq(w.began, 1); eq(w.sent[1].type, "hello"); eq(w.sent[1].name, "kindle")
    eq(#w.timers, 1)
    local sock = w.sock
    w.live:stop("user")
    eq(#w.timers, 0); eq(sock.closed, true); eq(w.ended[1], "user"); eq(w.live:isActive(), false)
end)

test("a deferred call replies later, and not at all once its connection has gone", function()
    local w = world(); w.live:start()
    local pending
    w.live.deps.deferred = { ui_act = function(_, done) pending = done end }
    w.feed({ id = 9, method = "ui_act" })
    w.step()
    eq(#w.sent, 1) -- only the hello: the reply waits
    pending({ ok = true })
    eq(w.sent[2].id, 9); eq(w.sent[2].result.ok, true)
    pending({ ok = false }) -- a second call to done is ignored
    eq(#w.sent, 2)
    w.feed({ id = 10, method = "ui_act" })
    w.step()
    w.read_error = "closed"
    w.step()
    pending({ ok = true })
    eq(#w.sent, 2)
end)

test("a tool call is dispatched and answered with its id", function()
    local w = world(); w.live:start()
    w.feed({ type = "welcome", name = "kindle" })
    w.feed({ id = 7, method = "read_files", params = { path = "/x" } })
    w.step()
    eq(w.live.state, "online")
    local reply = w.sent[#w.sent]
    eq(reply.id, 7); eq(reply.result.method, "read_files"); eq(reply.result.params.path, "/x")
end)

test("a dispatch error and a crash in a handler both come back as errors", function()
    local w = world({ dispatch = function(m)
        if m == "bad" then return nil, { code = -32601, message = "nope" } end
        error("boom")
    end })
    w.live:start()
    w.feed({ id = 1, method = "bad" }); w.feed({ id = 2, method = "crash" })
    w.step()
    eq(w.sent[2].error.code, -32601)
    eq(w.sent[3].id, 2); assert(w.sent[3].error.message:find("boom"))
    eq(w.live:isActive(), true)
end)

test("polls fast just after an agent command, slowly otherwise", function()
    local w = world(); w.live:start()
    eq(w.timers[1].delay, Live.FAST_POLL)
    w.advance(Live.FAST_WINDOW + 1)
    eq(w.timers[1].delay, Live.SLOW_POLL)
    w.feed({ id = 1, method = "x" })
    w.step()
    eq(w.timers[1].delay, Live.FAST_POLL)
end)

test("a heartbeat goes out every 60 s, and gateway silence counts as a drop", function()
    local w = world(); w.live:start()
    w.feed({ type = "welcome" })
    w.advance(61)
    local pings = 0
    for _, m in ipairs(w.sent) do if m.type == "ping" then pings = pings + 1 end end
    eq(pings, 1)
    while w.live.state ~= "waiting" do w.step() end
    assert(w.t >= Live.SILENCE and w.t < Live.SILENCE + Live.SLOW_POLL + 1, "dropped at " .. w.t)
end)

test("idle for 15 minutes since the last command ends the session", function()
    local w = world(); w.live:start()
    for _ = 1, 20 do w.advance(50); w.feed({ type = "pong" }) end
    eq(w.live:isActive(), false); eq(w.ended[1], "idle"); eq(#w.timers, 0)
end)

test("a command resets the idle clock", function()
    local w = world(); w.live:start()
    for _ = 1, 17 do w.advance(50); w.feed({ type = "pong" }) end
    w.feed({ id = 1, method = "x" })
    for _ = 1, 6 do w.advance(50); w.feed({ type = "pong" }) end
    assert(w.t > Live.IDLE_LIMIT)
    eq(w.live:isActive(), true)
end)

test("battery under 30% ends the session", function()
    local w = world(); w.live:start()
    w.battery = 29
    w.step()
    eq(w.ended[1], "battery low")
end)

test("retries after 5, 15 and 60 s, then ends; a fresh failure count after welcome", function()
    local w = world(); w.live:start()
    w.feed({ type = "welcome" }); w.step(); eq(w.live.retries, 0)
    w.connect_ok = false
    w.read_error = "closed"
    w.step()
    eq(w.timers[1].delay, 5)
    w.read_error = nil
    eq(w.step(), 5); eq(w.timers[1].delay, 15)
    eq(w.step(), 15); eq(w.timers[1].delay, 60)
    eq(w.step(), 60)
    eq(w.live:isActive(), false); eq(w.ended[1], "gateway unreachable"); eq(#w.timers, 0)
end)

test("the network coming back retries at once, with one timer", function()
    local w = world(); w.connect_ok = false; w.live:start()
    eq(w.live.state, "waiting")
    w.connect_ok = true
    w.live:networkUp()
    eq(w.live.state, "greeting"); eq(#w.timers, 1)
end)

test("a refused name ends a Kindle session", function()
    local w = world(); w.live:start()
    w.feed({ type = "refused", reason = "taken" })
    w.step()
    eq(w.live:isActive(), false); assert(w.ended[1]:find("taken")); eq(#w.timers, 0)
end)

test("always mode ignores idle and battery, and never stops retrying", function()
    local w = world({ always = true }); w.live:start()
    w.battery = 1
    for _ = 1, 30 do w.advance(50); w.feed({ type = "pong" }) end
    eq(w.live:isActive(), true); eq(w.live.state, "greeting")
    w.connect_ok = false; w.read_error = "closed"
    w.advance(5 * 60)
    eq(w.live.state, "waiting"); eq(w.timers[1].delay, 60); eq(#w.ended, 0)
end)

test("identity: hash from the serial, name from its last 4; the serial never appears", function()
    local seen
    local id = Live.identity({ serial = "G090ABCD12345678", sha256 = function(s) seen = s; return "0123456789abcdef" end })
    eq(id.name, "pw3-5678"); eq(id.id_hash, "0123456789ab"); eq(seen, "koreader-ppw3:G090ABCD12345678")
    assert(not id.id_hash:find("G090"))
    eq(Live.identity({ serial = "G0905678", stored_name = "den", sha256 = function() return "ff" end }).name, "den")
end)

test("identity: no serial falls back to the configured name", function()
    local id = Live.identity({ config_name = "emu", sha256 = function(s) return s end })
    eq(id.name, "emu"); eq(id.id_hash, ("config:emu"):sub(1, 12))
end)

test("validName matches what the gateway accepts", function()
    eq(Live.validName("pw3-1234_a.b"), true)
    eq(Live.validName("a b"), false); eq(Live.validName(""), false); eq(Live.validName(("x"):rep(33)), false)
end)

print(string.format("%d tests, %d failures", count, failures))
os.exit(failures == 0 and 0 or 1)
