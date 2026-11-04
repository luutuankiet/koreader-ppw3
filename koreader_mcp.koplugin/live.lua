--[[
A live-mode session: one connection dialled out to the gateway (raw TCP, or a WebSocket
through ws.lua), carrying tool calls.
Outside a session there is no socket and no timer. Everything that touches KOReader or the
network is passed in as `deps`, so test_live.lua runs this file on plain luajit.

deps:
  connect()            -> sock | nil, err, kind   sock has send, receive, settimeout, close;
                        kind "rejected" means the gateway turned the device key down.
                        A raw TCP socket carries JSON lines; ws.lua's connection carries one
                        message per text frame behind the same receive("*l") and send.
  schedule(seconds, fn) -> handle           unschedule(handle)
  now()                -> seconds
  json                 { encode, decode }
  dispatch(method, params) -> result, rpc_error
  deferred             optional { method = fn(params, done) }, done(result, rpc_error) replies later
  identity()           -> { name, id_hash, koreader_version, plugin_versions }
  battery()            -> percent | nil
  on_begin(), on_end(reason)                keep WiFi and the screen up, then put them back
  log(msg)
]]

local Live = {}
Live.__index = Live

Live.HEARTBEAT = 60        -- seconds between pings
Live.SILENCE = 150         -- a gateway silent this long has gone
Live.IDLE_LIMIT = 15 * 60  -- since the last agent command, or the start
Live.BATTERY_FLOOR = 30    -- percent
Live.FAST_POLL = 0.2       -- within FAST_WINDOW of an agent command
Live.SLOW_POLL = 2
Live.FAST_WINDOW = 10
Live.RETRY_DELAYS = { 5, 15, 60 }
Live.MAX_LINES_PER_TICK = 8
-- A wrong device key does not fix itself: an always-on session asks again this rarely.
Live.REJECTED_DELAY = 300
-- Byte-identical every time, so the Cloudflare gateway can answer it with
-- setWebSocketAutoResponse without waking up. Never build it from a table.
Live.PING = '{"type":"ping"}'
Live.PONG = '{"type":"pong"}'

-- always=true is the emulator: it never ends on idle or battery and never stops retrying.
function Live.new(deps, opts)
    return setmetatable({
        deps = deps,
        host = opts.host,
        port = opts.port,
        always = opts.always or false,
        state = "off",
        retries = 0,
    }, Live)
end

function Live:isActive() return self.state ~= "off" end

-- announce(ok, text) is for a session the user started: called once, with the name the
-- gateway accepted or with the first failure. Reconnects after that stay silent.
function Live:start(announce)
    if self:isActive() then return end
    local now = self.deps.now()
    self.last_command = now
    self.retries = 0
    self.last_error = nil
    self.name = nil
    self.announce = announce
    self.state = "connecting"
    self.deps.on_begin()
    self:_connect()
end

function Live:stop(reason)
    if not self:isActive() then return end
    self.announce = nil
    self:_drop()
    self:_cancel_timer()
    self.state = "off"
    self.deps.log("live mode ended: " .. tostring(reason))
    self.deps.on_end(reason)
end

-- The network came back: a session waiting out a retry delay tries now.
function Live:networkUp()
    if self.state == "waiting" then
        self:_cancel_timer()
        self:_connect()
    end
end

function Live:_cancel_timer()
    if self.timer then
        self.deps.unschedule(self.timer)
        self.timer = nil
    end
end

function Live:_after(seconds, fn)
    self:_cancel_timer()
    self.timer = self.deps.schedule(seconds, function()
        self.timer = nil
        fn()
    end)
end

function Live:_drop()
    if self.sock then
        pcall(self.sock.close, self.sock)
        self.sock = nil
    end
    self.partial = nil
end

function Live:_send(msg)
    return self:_send_text(self.deps.json.encode(msg))
end

function Live:_send_text(text)
    -- Non-blocking sockets lose the tail of a big reply, so sends wait.
    self.sock:settimeout(30)
    local ok, err = self.sock:send(text .. "\n")
    if self.sock then self.sock:settimeout(0) end
    return ok, err
end

function Live:_connect()
    self.state = "connecting"
    local sock, err, kind = self.deps.connect()
    if not sock and kind == "rejected" then return self:_rejected(err) end
    if not sock then return self:_lost("connect failed: " .. tostring(err)) end
    self.sock = sock
    local hello = self.deps.identity()
    hello.type = "hello"
    local ok, send_err = self:_send(hello)
    if not ok then return self:_lost("hello failed: " .. tostring(send_err)) end
    local now = self.deps.now()
    self.last_heard = now
    self.last_ping = now
    self.state = "greeting"
    self:_schedule_tick()
end

-- What the Connection status menu entry shows; see Live.statusText.
function Live:status()
    return { state = self.state, name = self.name, last_error = self.last_error, last_heard = self.last_heard }
end

function Live:_announce(ok, text)
    local announce = self.announce
    if not announce then return end
    self.announce = nil
    pcall(announce, ok, text)
end

function Live:_failed(reason)
    self.last_error = tostring(reason)
    self:_announce(false, self.last_error)
end

-- The connection is gone: wait and retry, or end once the delays run out.
function Live:_lost(reason)
    self:_failed(reason)
    self:_drop()
    self.deps.log("live mode connection lost: " .. tostring(reason))
    self.retries = self.retries + 1
    local delay = Live.RETRY_DELAYS[self.retries]
    if not delay then
        if not self.always then return self:stop("gateway unreachable") end
        delay = Live.RETRY_DELAYS[#Live.RETRY_DELAYS]
    end
    self.state = "waiting"
    self:_after(delay, function() self:_connect() end)
end

-- The gateway turned the device key down. On a Kindle the session ends, as for a refused
-- name; the emulator waits REJECTED_DELAY, never the short retry delays.
function Live:_rejected(reason)
    self:_failed(reason)
    self:_drop()
    self.deps.log("live mode rejected: " .. tostring(reason))
    if not self.always then return self:stop(reason) end
    self.state = "waiting"
    self:_after(Live.REJECTED_DELAY, function() self:_connect() end)
end

function Live:_schedule_tick()
    local recent = self.deps.now() - self.last_command < Live.FAST_WINDOW
    self:_after(recent and Live.FAST_POLL or Live.SLOW_POLL, function() self:_tick() end)
end

function Live:_tick()
    if not self.sock then return end
    local now = self.deps.now()
    if not self.always then
        if now - self.last_command >= Live.IDLE_LIMIT then return self:stop("idle") end
        local battery = self.deps.battery()
        if battery and battery < Live.BATTERY_FLOOR then return self:stop("battery low") end
    end
    for _ = 1, Live.MAX_LINES_PER_TICK do
        local line, err, partial = self.sock:receive("*l", self.partial)
        if line then
            self.partial = nil
            self.last_heard = self.deps.now()
            self:_handle(line)
            if not self.sock then return end -- handling ended the session or dropped the link
        elseif err == "timeout" then
            self.partial = partial
            break
        else
            return self:_lost(err)
        end
    end
    now = self.deps.now()
    if now - self.last_heard >= Live.SILENCE then return self:_lost("gateway silent") end
    if now - self.last_ping >= Live.HEARTBEAT then
        self.last_ping = now
        local ok, err = self:_send_text(Live.PING)
        if not ok then return self:_lost(err) end
    end
    self:_schedule_tick()
end

function Live:_handle(line)
    local ok, msg = pcall(self.deps.json.decode, line)
    if not ok or type(msg) ~= "table" then
        self.deps.log("live mode: dropping a line that is not JSON")
        return
    end
    if msg.type == "welcome" then
        self.state = "online"
        self.retries = 0
        self.last_error = nil
        self.name = msg.name
        self.deps.log("live mode online as " .. tostring(msg.name))
        self:_announce(true, tostring(msg.name))
    elseif msg.type == "refused" then
        -- A name clash will not clear by itself on a Kindle; the emulator keeps trying.
        if self.always then return self:_lost("refused: " .. tostring(msg.reason)) end
        self:_failed("refused: " .. tostring(msg.reason))
        self:stop("refused: " .. tostring(msg.reason))
    elseif msg.method then
        self:_call(msg)
    end
end

function Live:_reply(id, result, rpc_error)
    local reply = { id = id }
    if rpc_error then
        reply.error = rpc_error
    else
        reply.result = result == nil and {} or result
    end
    local sent, err = self:_send(reply)
    if not sent then self:_lost(err) end
end

function Live:_call(msg)
    self.last_command = self.deps.now()
    local params = msg.params or {}
    local deferred = self.deps.deferred and self.deps.deferred[msg.method]
    if deferred then
        -- Replies later from a UIManager task, while this loop keeps running. A reply
        -- whose connection has since gone is dropped: the gateway failed that call already.
        local sock, replied = self.sock, false
        local function done(result, rpc_error)
            if replied then return end
            replied = true
            if self.sock == sock then
                self.last_command = self.deps.now()
                self:_reply(msg.id, result, rpc_error)
            end
        end
        local ok, err = pcall(deferred, params, done)
        if not ok then done(nil, { code = -32603, message = tostring(err) }) end
        return
    end
    local ok, result, rpc_error = pcall(self.deps.dispatch, msg.method, params)
    if not ok then rpc_error = { code = -32603, message = tostring(result) } end
    self:_reply(msg.id, result, rpc_error)
end

-- What this device calls itself and proves itself with. The hash stands in for the serial,
-- which must never leave the device; only the last 4 characters appear, in the default name.
function Live.identity(opts)
    local serial = opts.serial
    if serial and serial ~= "" then
        return {
            name = opts.stored_name or opts.config_name or ("pw3-" .. serial:sub(-4)),
            id_hash = opts.sha256("koreader-ppw3:" .. serial):sub(1, 12),
        }
    end
    local name = opts.stored_name or opts.config_name or "koreader"
    return { name = name, id_hash = opts.sha256("config:" .. (opts.config_name or name)):sub(1, 12) }
end

--[[
Where to dial. stored holds the plugin settings (url, key, host, port), config the
config.lua values (gateway_url, gateway_key, gateway_host, gateway_port); stored wins.
A ws:// or wss:// URL selects WebSocket, anything else raw TCP host:port as before.
-> { kind = "ws", url, tls, host, port, path, key } | { kind = "tcp", host, port }
]]
function Live.gatewayTarget(stored, config, default_host, default_port)
    local function set(v) return type(v) == "string" and v ~= "" and v or nil end
    local url = set(stored.url)
    if not url and not stored.host then url = set(config.gateway_url) end
    local target = url and require("ws").parse_url(url)
    if target then
        target.kind = "ws"
        target.url = url
        target.key = set(stored.key) or set(config.gateway_key)
        return target
    end
    return {
        kind = "tcp",
        host = stored.host or config.gateway_host or default_host,
        port = tonumber(stored.port or config.gateway_port) or default_port,
    }
end

-- The HTTP origin of a WebSocket gateway, for the diagnostics inbox.
function Live.httpOrigin(target)
    local origin = (target.tls and "https://" or "http://") .. target.host
    if target.explicit_port then origin = origin .. ":" .. target.port end
    return origin
end

-- The Connection status text. status from Live:status(), now in seconds, address as typed.
function Live.statusText(status, now, address)
    local state, head = status.state
    if state == "online" then
        head = "Online as " .. tostring(status.name)
    elseif state == "connecting" or state == "greeting" then
        head = "Connecting…"
    elseif state == "waiting" then
        head = "Waiting to retry (last error: " .. tostring(status.last_error) .. ")"
    else
        head = status.last_error and ("Off (last error: " .. status.last_error .. ")") or "Off"
    end
    local lines = { head, "Gateway: " .. tostring(address) }
    if state ~= "off" and status.last_heard then
        lines[#lines + 1] = string.format("Last heard: %d s ago", math.max(0, now - status.last_heard))
    end
    return table.concat(lines, "\n")
end

-- The pop-up for the first failure of a session the user started.
function Live.failureText(err)
    local text = "Agent bridge could not connect: " .. tostring(err)
    if tostring(err):find("HTTP/%d%.%d 404") then
        text = text .. "\n\nThe gateway address must end in /device, for example wss://kindle.example.org/device."
    end
    return text
end

--[[
What the Gateway address prompt saves. A ws:// or wss:// URL with no path gets /device, the
path the gateway takes devices on; host:port still selects raw TCP.
-> { url } | { host, port } | nil
]]
function Live.parseAddress(text)
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    local target = require("ws").parse_url(text)
    if target then
        if target.path == "/" then text = text:gsub("/?$", "/device", 1) end
        return { url = text }
    end
    local host, port = text:match("^([%w%.%-]+):(%d+)$")
    if host then return { host = host, port = tonumber(port) } end
    return nil
end

function Live.validName(name)
    return type(name) == "string" and #name <= 32 and name:match("^[%w._-]+$") ~= nil
end

return Live
