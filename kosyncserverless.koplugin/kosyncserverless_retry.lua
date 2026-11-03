--[[--
Retry policy for a sync server that may be asleep (Cloud Run scaled to zero).

A real cold start measured 19.3 s. Each attempt waits up to TIMEOUT_S, and a
failed attempt is retried after BACKOFF_S[n] seconds, so three attempts cover
a cold start of about 50 s. Every timing number of the plugin lives here.

    local handle = Retry.run{
        request = request,           -- function(req, cb) -> cancel (kosyncserverless_http)
        scheduleIn = scheduleIn,     -- function(seconds, fn)
        req = { method = "GET", url = url, headers = h },
        on_attempt = function(n) end,             -- optional, before each attempt
        on_response = function(res) end,          -- optional, every answer with a status
        done = function(ok, res, attempts) end,   -- fires exactly once
    }
    handle.cancel() -- done(false, { err = "cancelled" }) now, unless done already fired

Lua 5.1 only.
]]

local Retry = {
    TIMEOUT_S = 15,       -- per attempt
    MAX_ATTEMPTS = 3,
    BACKOFF_S = { 2, 5 }, -- wait before attempt 2, before attempt 3
    PING_SKIP_S = 600,    -- no warm-up ping when the server answered this recently
    DEBOUNCE_S = 25,      -- automatic push or pull at most this often (upstream value)
    SLEEP_CAP_S = 30,     -- a held sleep goes ahead after this long, push or not
}

--- A transport error or a server-side failure is worth another attempt; any
-- other answer (2xx, 401, 4xx) is final.
function Retry.retryable(res)
    local s = res and res.status
    if not s then return true end
    return s >= 500 or s == 408 or s == 429
end

function Retry.is_2xx(res)
    return res and res.status ~= nil and res.status >= 200 and res.status < 300
end

--- Runs req with retries. See the module comment.
-- @treturn table handle { cancel = function() -> bool, attempts = function() -> n }
function Retry.run(opts)
    assert(opts.request and opts.scheduleIn and opts.req and opts.done, "Retry.run: missing option")
    local is_success = opts.is_success or Retry.is_2xx
    local max_attempts = opts.max_attempts or Retry.MAX_ATTEMPTS
    local finished = false
    local attempt = 0
    local cancel_request = nil

    local function finish(ok, res)
        if finished then return end
        finished = true
        cancel_request = nil
        opts.done(ok, res, attempt)
    end

    local start_attempt
    start_attempt = function()
        if finished then return end
        attempt = attempt + 1
        if opts.on_attempt then opts.on_attempt(attempt) end
        local req = {}
        for k, v in pairs(opts.req) do req[k] = v end
        req.timeout = req.timeout or Retry.TIMEOUT_S
        cancel_request = opts.request(req, function(res)
            if finished then return end
            cancel_request = nil
            res = res or { err = "no answer" }
            if res.status and opts.on_response then opts.on_response(res) end
            if is_success(res) then
                finish(true, res)
            elseif attempt < max_attempts and Retry.retryable(res) then
                local wait = Retry.BACKOFF_S[attempt] or Retry.BACKOFF_S[#Retry.BACKOFF_S]
                opts.scheduleIn(wait, start_attempt)
            else
                finish(false, res)
            end
        end)
    end

    start_attempt()

    return {
        cancel = function()
            if finished then return false end
            if cancel_request then cancel_request() end
            finish(false, { err = "cancelled" })
            return true
        end,
        attempts = function() return attempt end,
        finished = function() return finished end,
    }
end

return Retry
