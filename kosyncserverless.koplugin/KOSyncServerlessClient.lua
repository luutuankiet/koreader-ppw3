--[[--
Progress sync client that tolerates a sleeping server.

Every request runs in a forked subprocess (kosyncserverless_http), so the UI
stays responsive while a cold server boots, and is retried by
kosyncserverless_retry (15 s per attempt, 3 attempts, 2 s then 5 s apart).
Same endpoints and headers as the built-in plugin's api.json.

Each call returns a handle: handle.cancel() abandons the request and makes
the callback fire right away with ok = false and res.err == "cancelled". The
callback fires exactly once either way.

    local client = KOSyncServerlessClient:new{ custom_url = url, username = u, userkey = k }
    local handle = client:push(item, function(ok, res) end)
    client:pull(digest, function(ok, body, res) end)

Tests inject request, scheduleIn and clock.
]]

local Retry = require("kosyncserverless_retry")

local DEFAULT_URL = "https://sync.koreader.rocks:443"
local ACCEPT = "application/vnd.koreader.v1+json"

local KOSyncServerlessClient = {
    custom_url = nil,
    username = nil,
    userkey = nil,
}

-- Shared by every client in this KOReader process: when the server last
-- answered anything (any HTTP status), on the clock below. Drives the
-- warm-up ping skip window.
KOSyncServerlessClient.last_reached = nil

function KOSyncServerlessClient:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function KOSyncServerlessClient:init()
    if not self.scheduleIn then
        local UIManager = require("ui/uimanager")
        self.scheduleIn = function(s, f) UIManager:scheduleIn(s, f) end
    end
    if not self.clock then
        self.clock = require("socket").gettime
    end
    if not self.request then
        self.request = require("kosyncserverless_http").new{
            scheduleIn = self.scheduleIn,
            log = require("logger"),
        }
    end
    local json = self.json or require("json")
    self.json_encode = self.json_encode or json.encode
    self.json_decode = self.json_decode or json.decode
    self.base_url = (self.custom_url and self.custom_url ~= "" and self.custom_url or DEFAULT_URL):gsub("/+$", "")
end

function KOSyncServerlessClient:headers(with_auth, username, userkey)
    local h = { accept = ACCEPT }
    if with_auth then
        h["x-auth-user"] = username or self.username
        h["x-auth-key"] = userkey or self.userkey
    end
    return h
end

function KOSyncServerlessClient:decode(res)
    if not res or not res.body or res.body == "" then return nil end
    local ok, value = pcall(self.json_decode, res.body)
    if ok and type(value) == "table" then return value end
    return nil
end

--- Seconds since the server last answered, or nil if never in this process.
function KOSyncServerlessClient:sinceReached()
    local t = KOSyncServerlessClient.last_reached
    if not t then return nil end
    return self.clock() - t
end

--- Low level: method, path, body table or nil, auth, success test, callback.
-- @treturn table retry handle { cancel = fn }
function KOSyncServerlessClient:call(spec, cb)
    local headers = self:headers(spec.auth, spec.username, spec.userkey)
    local body
    if spec.body then
        body = self.json_encode(spec.body)
        headers["content-type"] = "application/json"
    end
    return Retry.run{
        request = self.request,
        scheduleIn = self.scheduleIn,
        max_attempts = spec.max_attempts,
        req = { method = spec.method, url = self.base_url .. spec.path, headers = headers, body = body },
        is_success = spec.is_success,
        on_attempt = spec.on_attempt,
        on_response = function()
            KOSyncServerlessClient.last_reached = self.clock()
        end,
        done = function(ok, res, attempts)
            res.attempts = attempts
            cb(ok, res)
        end,
    }
end

--- Push one progress record. cb(ok, res): ok only on a 2xx answer;
-- res.status is nil after a transport failure, 401 on bad credentials.
-- opts.on_attempt(n) is called before each attempt.
function KOSyncServerlessClient:push(item, cb, opts)
    opts = opts or {}
    return self:call({
        method = "PUT", path = "/syncs/progress", auth = true,
        body = {
            document = item.document,
            metadata = item.metadata,
            progress = tostring(item.progress),
            percentage = item.percentage,
            device = item.device,
            device_id = item.device_id,
        },
        on_attempt = opts.on_attempt,
    }, cb)
end

--- Pull the progress of one document. cb(ok, body, res); body is the decoded
-- record (empty table when the server has none).
function KOSyncServerlessClient:pull(document, cb, opts)
    opts = opts or {}
    return self:call({
        method = "GET", path = "/syncs/progress/" .. tostring(document), auth = true,
        on_attempt = opts.on_attempt,
    }, function(ok, res)
        cb(ok, self:decode(res), res)
    end)
end

--- cb(ok, body, res); ok on 200.
function KOSyncServerlessClient:authorize(username, userkey, cb, opts)
    opts = opts or {}
    return self:call({
        method = "GET", path = "/users/auth", auth = true, username = username, userkey = userkey,
        is_success = function(res) return res.status == 200 end,
        on_attempt = opts.on_attempt,
    }, function(ok, res)
        cb(ok, self:decode(res), res)
    end)
end

--- cb(ok, body, res); ok on 201.
function KOSyncServerlessClient:register(username, userkey, cb, opts)
    opts = opts or {}
    return self:call({
        method = "POST", path = "/users/create",
        body = { username = username, password = userkey },
        is_success = function(res) return res.status == 201 end,
        on_attempt = opts.on_attempt,
    }, function(ok, res)
        cb(ok, self:decode(res), res)
    end)
end

--- Fire-and-forget warm-up: one GET /healthcheck, no retries, so a sleeping
-- server starts booting before the real request. Skipped when the server
-- answered within Retry.PING_SKIP_S.
-- @treturn bool whether a ping was sent
function KOSyncServerlessClient:ping(cb)
    local since = self:sinceReached()
    if (since and since < Retry.PING_SKIP_S) or KOSyncServerlessClient.ping_in_flight then
        return false
    end
    KOSyncServerlessClient.ping_in_flight = true
    self:call({
        method = "GET", path = "/healthcheck", max_attempts = 1,
        is_success = function(res) return res.status ~= nil end,
    }, function(ok, res)
        KOSyncServerlessClient.ping_in_flight = nil
        if cb then cb(ok, res) end
    end)
    return true
end

return KOSyncServerlessClient
