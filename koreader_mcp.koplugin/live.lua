--[[
A live-mode session: one TCP connection dialled out to the gateway, carrying tool calls.
Outside a session there is no socket and no timer. Everything that touches KOReader or the
network is passed in as `deps`, so test_live.lua runs this file on plain luajit.

deps:
  connect(host, port)  -> sock | nil, err   sock has send, receive, settimeout, close
  schedule(seconds, fn) -> handle           unschedule(handle)
  now()                -> seconds
  json                 { encode, decode }
  dispatch(method, params) -> result, rpc_error
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

function Live:start()
    if self:isActive() then return end
    local now = self.deps.now()
    self.last_command = now
    self.retries = 0
    self.state = "connecting"
    self.deps.on_begin()
    self:_connect()
end

function Live:stop(reason)
    if not self:isActive() then return end
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
    -- Non-blocking sockets lose the tail of a big reply, so sends wait.
    self.sock:settimeout(30)
    local ok, err = self.sock:send(self.deps.json.encode(msg) .. "\n")
    if self.sock then self.sock:settimeout(0) end
    return ok, err
end

function Live:_connect()
    self.state = "connecting"
    local sock, err = self.deps.connect(self.host, self.port)
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

-- The connection is gone: wait and retry, or end once the delays run out.
function Live:_lost(reason)
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
        local ok, err = self:_send({ type = "ping" })
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
        self.deps.log("live mode online as " .. tostring(msg.name))
    elseif msg.type == "refused" then
        -- A name clash will not clear by itself on a Kindle; the emulator keeps trying.
        if self.always then return self:_lost("refused: " .. tostring(msg.reason)) end
        self:stop("refused: " .. tostring(msg.reason))
    elseif msg.method then
        self:_call(msg)
    end
end

function Live:_call(msg)
    self.last_command = self.deps.now()
    local ok, result, rpc_error = pcall(self.deps.dispatch, msg.method, msg.params or {})
    local reply = { id = msg.id }
    if not ok then
        reply.error = { code = -32603, message = tostring(result) }
    elseif rpc_error then
        reply.error = rpc_error
    else
        reply.result = result == nil and {} or result
    end
    local sent, err = self:_send(reply)
    if not sent then self:_lost(err) end
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

function Live.validName(name)
    return type(name) == "string" and #name <= 32 and name:match("^[%w._-]+$") ~= nil
end

return Live
