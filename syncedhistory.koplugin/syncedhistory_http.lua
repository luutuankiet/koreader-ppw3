--[[--
Non-blocking HTTP for the synced reading list, inside KOReader.

The built-in progress sync only avoids blocking when KOReader runs the Turbo
I/O loop, which is off unless DUSE_TURBO_LIB is set (defaults.lua), so its
requests normally block with 2 to 5 s timeouts. A cold start of the sync
server takes about 11.5 s, and blocking that long would freeze the screen.
So each request runs in a forked subprocess, the way KOReader's own
background work does it (ReaderThumbnail, Trapper:dismissableRunInSubprocess):
the child does a plain blocking LuaSocket request, writes the result to a
pipe and exits; the parent polls the pipe from the UI loop.

    local Http = require("syncedhistory_http")
    local request = Http.new{ scheduleIn = function(s, f) UIManager:scheduleIn(s, f) end }
    request({ method = "GET", url = url, headers = h, timeout = 15 }, function(res)
        -- res.status (number or nil), res.body (string or nil), res.err (string or nil)
    end)

Lua 5.1 only.
]]

local Http = {}

Http.POLL_INTERVAL = 0.25 -- seconds between looks at the pipe
Http.GRACE = 5            -- seconds past the request timeout before the child is killed

--- Blocking request with KOReader's LuaSocket. Runs in the child process,
-- and directly in checks that have no UI loop.
-- @treturn table { status = number|nil, body = string|nil, err = string|nil }
function Http.blockingRequest(req)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    local timeout = req.timeout or 15
    socketutil:set_timeout(timeout, timeout)
    local ok, code, _, status = pcall(function()
        local headers = {}
        for k, v in pairs(req.headers or {}) do headers[k] = v end
        local source
        if req.body then
            headers["content-length"] = tostring(#req.body)
            source = ltn12.source.string(req.body)
        end
        return socket.skip(1, http.request{
            url = req.url,
            method = req.method or "GET",
            headers = headers,
            source = source,
            sink = socketutil.table_sink(sink),
        })
    end)
    socketutil:reset_timeout()
    if not ok then
        return { err = tostring(code) }
    end
    if type(code) ~= "number" then
        return { err = tostring(code or status or "request failed") }
    end
    return { status = code, body = table.concat(sink) }
end

-- Child to parent wire format: "<status>\n<body>" or "E\n<error>".
local function encode(res)
    if res.status then return tostring(res.status) .. "\n" .. (res.body or "") end
    return "E\n" .. tostring(res.err)
end

local function decode(data)
    if not data or data == "" then return { err = "no answer from subprocess" } end
    local head, rest = data:match("^([^\n]*)\n(.*)$")
    if head == "E" then return { err = rest } end
    local status = tonumber(head)
    if not status then return { err = "bad answer from subprocess" } end
    return { status = status, body = rest }
end

Http._encode, Http._decode = encode, decode

--[[--
Create a request function.

@tparam table opts
  scheduleIn  (required) function(seconds, fn), UIManager:scheduleIn
  ffiutil     (optional) defaults to require("ffi/util")
  clock       (optional) function() -> seconds, defaults to socket.gettime
  log         (optional) KOReader's logger
@treturn function request(req, callback)
]]
function Http.new(opts)
    assert(opts and opts.scheduleIn, "Http.new: scheduleIn is required")
    local ffiutil = opts.ffiutil or require("ffi/util")
    local clock = opts.clock or require("socket").gettime
    local log = opts.log

    return function(req, callback)
        local pid, fd = ffiutil.runInSubProcess(function(_, child_write_fd)
            ffiutil.writeToFD(child_write_fd, encode(Http.blockingRequest(req)), true)
        end, true)
        if not pid then
            if log then log.warn("syncedhistory: cannot start request:", fd) end
            callback({ err = "cannot start subprocess" })
            return
        end
        local deadline = clock() + (req.timeout or 15) + Http.GRACE
        local function poll()
            local ready = ffiutil.getNonBlockingReadSize(fd) ~= 0
            local done = ffiutil.isSubProcessDone(pid)
            if ready or done then
                -- readAllFromFD reads to the end and closes the fd.
                local res = decode(ffiutil.readAllFromFD(fd))
                if not done then
                    -- Reap it later so it does not stay a zombie.
                    opts.scheduleIn(1, function() ffiutil.isSubProcessDone(pid) end)
                end
                callback(res)
            elseif clock() > deadline then
                ffiutil.terminateSubProcess(pid)
                ffiutil.readAllFromFD(fd)
                callback({ err = "timeout" })
            else
                opts.scheduleIn(Http.POLL_INTERVAL, poll)
            end
        end
        opts.scheduleIn(Http.POLL_INTERVAL, poll)
    end
end

return Http
