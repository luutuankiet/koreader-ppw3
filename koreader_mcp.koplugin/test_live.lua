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
            send = function(_, data)
                local line = data:sub(1, -2)
                if line == Live.PING then
                    w.pings_raw = (w.pings_raw or 0) + 1
                    w.sent[#w.sent + 1] = { type = "ping" }
                else
                    w.sent[#w.sent + 1] = w.json.decode(line)
                end
                return #data
            end,
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
            if opts.connect then return opts.connect(w) end
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

-- WebSocket transport ---------------------------------------------------------------

local ws = require("ws")

-- RFC 6455 section 1.3: this nonce gives this key and this accept value.
local NONCE, KEY, ACCEPT = "the sample nonce", "dGhlIHNhbXBsZSBub25jZQ==", "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
local function fake_sha1(s)
    assert(s == KEY .. ws.GUID, "unexpected sha1 input")
    return "b37a4f2cc0624f1690f64606cf385945b2bec4ea"
end
local MASK = "\55\250\33\61"
local function random(n) return n == 16 and NONCE or MASK:sub(1, n) end

-- A connected socket as luasocket shows it with timeout 0: each receive(n) hands out the
-- next chunk the server sent, as a partial with "timeout"; false in the list is a drop.
local function fake_raw(reply_lines)
    local r = { lines = reply_lines or {}, chunks = {}, out = {} }
    function r:settimeout() end
    function r:send(d) self.out[#self.out + 1] = d; return #d end
    function r:receive(pattern)
        if pattern == "*l" then
            local l = table.remove(self.lines, 1)
            if l then return l end
            return nil, "closed"
        end
        local c = table.remove(self.chunks, 1)
        if c == nil then return nil, "timeout", "" end
        if c == false then return nil, "closed" end
        return nil, "timeout", c
    end
    function r:close() self.closed = true end
    -- Every frame the client wrote after the handshake, unmasked; asserts they were masked.
    function r:frames()
        local buf, frames = table.concat(self.out, "", 2), {}
        local pos = 1
        while pos <= #buf do
            assert(buf:byte(pos + 1) >= 0x80, "client frame not masked")
            local f, nxt = ws.decode_frame(buf, pos)
            assert(f, "client wrote a broken frame")
            frames[#frames + 1] = f
            pos = nxt
        end
        return frames
    end
    return r
end

local OK_101 = { "HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade",
    "Sec-WebSocket-Accept: " .. ACCEPT, "" }
local TARGET = ws.parse_url("ws://127.0.0.1:8787/device")

local function open_ws(raw)
    return ws.handshake(raw, { target = TARGET, bearer = "devkey", random = random, sha1_hex = fake_sha1 })
end

test("ws: base64 and the RFC accept value", function()
    eq(ws.base64("f"), "Zg=="); eq(ws.base64("fo"), "Zm8="); eq(ws.base64("foo"), "Zm9v")
    eq(ws.base64(NONCE), KEY)
    eq(ws.accept(KEY, fake_sha1), ACCEPT)
end)

test("ws: frames encode and decode at all three length sizes", function()
    for _, n in ipairs({ 0, 5, 125, 126, 300, 65535, 65536, 200000 }) do
        local payload = ("x"):rep(n)
        local bytes = ws.encode_frame(ws.OP_TEXT, payload)
        local f, nxt = ws.decode_frame(bytes)
        assert(f, "no frame for " .. n)
        eq(f.payload, payload); eq(f.opcode, ws.OP_TEXT); eq(f.fin, true); eq(nxt, #bytes + 1)
    end
    -- RFC 6455 5.7: an unmasked "Hello" from a server.
    local f = ws.decode_frame("\129\005Hello")
    eq(f.payload, "Hello")
end)

test("ws: a masked frame round-trips and does not carry the text in clear", function()
    local payload = '{"id":1,"result":{"ok":true}}'
    local bytes = ws.encode_frame(ws.OP_TEXT, payload, MASK)
    assert(not bytes:find("result", 1, true), "payload visible on the wire")
    eq(bytes:byte(2), 0x80 + #payload)
    eq(ws.decode_frame(bytes).payload, payload)
    -- RFC 6455 5.7: masked "Hello" with key 37 fa 21 3d.
    eq(ws.encode_frame(ws.OP_TEXT, "Hello", MASK), "\129\133\55\250\33\61\127\159\77\81\88")
end)

test("ws: decode waits for the rest of a frame", function()
    local bytes = ws.encode_frame(ws.OP_TEXT, ("y"):rep(300))
    for cut = 0, #bytes - 1 do eq(ws.decode_frame(bytes:sub(1, cut)), nil) end
    local _, err = ws.decode_frame("\129\127\1\0\0\0\0\0\0\0")
    eq(err, "frame too big")
end)

test("ws: handshake sends the bearer key and checks the accept value", function()
    local raw = fake_raw({ unpack(OK_101) })
    local conn = open_ws(raw)
    assert(conn, "no connection")
    local req = raw.out[1]
    assert(req:find("GET /device HTTP/1.1\r\n", 1, true), req)
    assert(req:find("Host: 127.0.0.1:8787\r\n", 1, true), req)
    assert(req:find("Authorization: Bearer devkey\r\n", 1, true), req)
    assert(req:find("Sec-WebSocket-Key: " .. KEY .. "\r\n", 1, true), req)
    assert(req:sub(-4) == "\r\n\r\n")
    local bad = fake_raw({ "HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Sec-WebSocket-Accept: nope", "" })
    local c2, err = open_ws(bad)
    eq(c2, nil); assert(err:find("Accept"), err)
end)

test("ws: a 401 is a rejection, not a dropped connection", function()
    local raw = fake_raw({ "HTTP/1.1 401 Unauthorized", "Content-Length: 0", "" })
    local conn, err, kind = open_ws(raw)
    eq(conn, nil); eq(kind, "rejected"); assert(err:find("401"), err)
end)

test("ws: a message read a byte at a time comes out whole, once", function()
    local raw = fake_raw({ unpack(OK_101) })
    local conn = open_ws(raw)
    local bytes = ws.encode_frame(ws.OP_TEXT, '{"type":"welcome"}')
    for i = 1, #bytes do raw.chunks[#raw.chunks + 1] = bytes:sub(i, i) end
    local got, calls = nil, 0
    while not got do
        calls = calls + 1
        local msg, err = conn:receive("*l")
        if msg then got = msg else eq(err, "timeout") end
        assert(calls <= #bytes, "never assembled")
    end
    eq(got, '{"type":"welcome"}'); eq(calls, #bytes)
    local _, err = conn:receive("*l"); eq(err, "timeout")
end)

test("ws: a fragmented message with a ping in the middle; the ping is answered", function()
    local raw = fake_raw({ unpack(OK_101) })
    local conn = open_ws(raw)
    raw.chunks = {
        ws.encode_frame(ws.OP_TEXT, '{"id":7,', nil, false)
            .. ws.encode_frame(ws.OP_PING, "hb")
            .. ws.encode_frame(ws.OP_CONT, '"method":', nil, false),
        ws.encode_frame(ws.OP_CONT, '"x"}'),
    }
    local msg, err = conn:receive("*l"); eq(msg, nil); eq(err, "timeout")
    msg = conn:receive("*l"); eq(msg, '{"id":7,"method":"x"}')
    local frames = raw:frames()
    eq(#frames, 1); eq(frames[1].opcode, ws.OP_PONG); eq(frames[1].payload, "hb")
end)

test("ws: a close frame or a dropped socket is an error", function()
    local raw = fake_raw({ unpack(OK_101) })
    local conn = open_ws(raw)
    raw.chunks = { ws.encode_frame(ws.OP_TEXT, "a") .. ws.encode_frame(ws.OP_CLOSE, "\3\233") }
    eq(conn:receive("*l"), "a")
    local msg, err = conn:receive("*l"); eq(msg, nil); assert(err:find("1001"), err)
    local raw2 = fake_raw({ unpack(OK_101) })
    local conn2 = open_ws(raw2)
    raw2.chunks = { false }
    msg, err = conn2:receive("*l"); eq(msg, nil); eq(err, "closed")
end)

test("ws transport: hello, welcome, a call and its reply, and the fixed ping", function()
    local raw
    local w = world({ connect = function()
        raw = fake_raw({ unpack(OK_101) })
        return open_ws(raw)
    end })
    w.live:start()
    eq(w.live.state, "greeting")
    local hello = w.json.decode(raw:frames()[1].payload)
    eq(hello.type, "hello"); eq(hello.name, "kindle")
    raw.chunks = { ws.encode_frame(ws.OP_TEXT, w.json.encode({ type = "welcome", name = "kindle" }))
        .. ws.encode_frame(ws.OP_TEXT, w.json.encode({ id = 3, method = "device_status", params = {} })) }
    w.step()
    eq(w.live.state, "online")
    local frames = raw:frames()
    eq(#frames, 2)
    local reply = w.json.decode(frames[2].payload)
    eq(reply.id, 3); eq(reply.result.method, "device_status")
    w.advance(61)
    frames = raw:frames()
    eq(frames[#frames].opcode, ws.OP_TEXT); eq(frames[#frames].payload, Live.PING)
    -- The pong is a plain message: it only keeps the link alive.
    raw.chunks = { ws.encode_frame(ws.OP_TEXT, Live.PONG) }
    w.step()
    eq(w.live.state, "online")
end)

test("raw TCP transport: the same session runs on JSON lines", function()
    local w = world(); w.live:start()
    eq(w.sent[1].type, "hello")
    w.feed({ type = "welcome" }); w.feed({ id = 1, method = "m" })
    w.step()
    eq(w.live.state, "online"); eq(w.sent[2].id, 1)
    w.advance(61); eq(w.pings_raw, 1)
end)

test("a rejected key ends a Kindle session at once, with no retry", function()
    local w = world({ connect = function() return nil, "gateway rejected the device key (HTTP 401)", "rejected" end })
    w.live:start()
    eq(w.live:isActive(), false); eq(#w.timers, 0); eq(w.connects, 1)
    assert(w.ended[1]:find("401"), w.ended[1])
end)

test("a rejected key in always mode waits 300 s between tries, never the short delays", function()
    local w = world({ always = true, connect = function() return nil, "rejected (HTTP 401)", "rejected" end })
    w.live:start()
    eq(w.live.state, "waiting"); eq(#w.timers, 1); eq(w.timers[1].delay, Live.REJECTED_DELAY)
    w.advance(3600)
    eq(w.connects, 1 + math.floor(3600 / Live.REJECTED_DELAY))
end)

test("gatewayTarget: a ws URL selects WebSocket, host:port raw TCP, settings beat config", function()
    local t = Live.gatewayTarget({}, {}, "192.168.1.19", 9990)
    eq(t.kind, "tcp"); eq(t.host, "192.168.1.19"); eq(t.port, 9990)
    t = Live.gatewayTarget({}, { gateway_url = "wss://kindle.example.com/device", gateway_key = "k" }, "h", 1)
    eq(t.kind, "ws"); eq(t.tls, true); eq(t.port, 443); eq(t.path, "/device"); eq(t.key, "k")
    eq(Live.httpOrigin(t), "https://kindle.example.com")
    t = Live.gatewayTarget({ host = "10.0.0.2", port = 9990 }, { gateway_url = "wss://x/device" }, "h", 1)
    eq(t.kind, "tcp"); eq(t.host, "10.0.0.2")
    t = Live.gatewayTarget({ url = "ws://127.0.0.1:8790/device", key = "s" }, { gateway_key = "c" }, "h", 1)
    eq(t.kind, "ws"); eq(t.tls, false); eq(t.port, 8790); eq(t.key, "s")
    eq(Live.httpOrigin(t), "http://127.0.0.1:8790")
    t = Live.gatewayTarget({}, { gateway_url = "", gateway_host = "127.0.0.1", gateway_port = 9990 }, "h", 1)
    eq(t.kind, "tcp"); eq(t.host, "127.0.0.1")
    eq(Live.gatewayTarget({ url = "http://nope" }, {}, "h", 1).kind, "tcp")
end)

print(string.format("%d tests, %d failures", count, failures))
os.exit(failures == 0 and 0 or 1)
