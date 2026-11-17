--[[--
Non-blocking HTTP for the Google Drive plugin, inside KOReader.

Same pattern as kosyncserverless_http.lua: the server sleeps when idle and
a cold start takes 10 to 20 s, so each request runs in a forked subprocess
(ffiutil.runInSubProcess) doing a plain blocking LuaSocket request, and the
UI loop polls its pipe. Two additions:

- `req.sink_path`: the body is streamed to that file by the child and never
  held in memory. On a 2xx answer the file is kept; on any other answer the
  first 4 KB are read back as `res.body` (the JSON error) and the file is
  deleted.
- `res.headers`: the answer's headers (lower-case names).

    local Http = require("gdriveepub_http")
    local request = Http.new{ scheduleIn = function(s, f) UIManager:scheduleIn(s, f) end }
    local cancel = request({ url = u, headers = h, timeout = 30, sink_path = p }, function(res)
        -- res.status, res.body, res.headers, res.err
    end)

Lua 5.1 only.
]]

local Http = {}

Http.POLL_INTERVAL = 0.25
Http.GRACE = 5
Http.ERROR_BODY_MAX = 4096

--- Blocking request; runs in the child process.
function Http.blockingRequest(req)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local block = req.timeout or 30
    local total = req.total_timeout or block
    local sink, chunks, fh
    if req.sink_path then
        local err
        fh, err = io.open(req.sink_path, "wb")
        if not fh then return { err = "cannot write " .. tostring(req.sink_path) .. ": " .. tostring(err) } end
        sink = socketutil.file_sink and socketutil.file_sink(fh) or ltn12.sink.file(fh)
    else
        chunks = {}
        sink = socketutil.table_sink(chunks)
    end
    socketutil:set_timeout(block, total)
    local ok, code, headers, status = pcall(function()
        local h = {}
        for k, v in pairs(req.headers or {}) do h[k] = v end
        local source
        if req.body then
            h["content-length"] = tostring(#req.body)
            source = ltn12.source.string(req.body)
        end
        return socket.skip(1, http.request{
            url = req.url, method = req.method or "GET", headers = h, source = source, sink = sink,
        })
    end)
    socketutil:reset_timeout()
    -- ltn12.sink.file closes the handle at the end of the body; make sure.
    if fh then pcall(fh.close, fh) end
    if not ok or type(code) ~= "number" then
        if req.sink_path then os.remove(req.sink_path) end
        return { err = tostring(not ok and code or (code or status or "request failed")) }
    end
    local res = { status = code, headers = headers or {} }
    if req.sink_path then
        if code < 200 or code >= 300 then
            local f = io.open(req.sink_path, "rb")
            if f then res.body = f:read(Http.ERROR_BODY_MAX); f:close() end
            os.remove(req.sink_path)
        end
    else
        res.body = table.concat(chunks)
    end
    return res
end

-- Child to parent wire format: JSON of the result table.
function Http.new(opts)
    assert(opts and opts.scheduleIn, "Http.new: scheduleIn is required")
    local ffiutil = opts.ffiutil or require("ffi/util")
    local json = opts.json or require("json")
    local clock = opts.clock or require("socket").gettime
    return function(req, callback)
        local pid, fd = ffiutil.runInSubProcess(function(_, child_write_fd)
            local okr, res = pcall(Http.blockingRequest, req)
            if not okr then res = { err = tostring(res) } end
            local h = {}
            for k, v in pairs(res.headers or {}) do h[tostring(k):lower()] = tostring(v) end
            res.headers = h
            ffiutil.writeToFD(child_write_fd, json.encode(res), true)
        end, true)
        if not pid then
            callback({ err = "cannot start subprocess" })
            return function() end
        end
        local finished = false
        local function finish(res)
            if finished then return end
            finished = true
            callback(res)
        end
        local deadline = clock() + (req.total_timeout or req.timeout or 30) + Http.GRACE
        local function reap() opts.scheduleIn(1, function() ffiutil.isSubProcessDone(pid) end) end
        local function poll()
            if finished then return end
            local ready = ffiutil.getNonBlockingReadSize(fd) ~= 0
            local done = ffiutil.isSubProcessDone(pid)
            if ready or done then
                local data = ffiutil.readAllFromFD(fd)
                if not done then reap() end
                local okd, res = pcall(json.decode, data or "")
                if not okd or type(res) ~= "table" then res = { err = "no answer from subprocess" } end
                finish(res)
            elseif clock() > deadline then
                ffiutil.terminateSubProcess(pid)
                ffiutil.readAllFromFD(fd)
                reap()
                if req.sink_path then os.remove(req.sink_path) end
                finish({ err = "timeout" })
            else
                opts.scheduleIn(Http.POLL_INTERVAL, poll)
            end
        end
        opts.scheduleIn(Http.POLL_INTERVAL, poll)
        return function()
            if finished then return end
            finished = true
            ffiutil.terminateSubProcess(pid)
            ffiutil.readAllFromFD(fd)
            reap()
            if req.sink_path then os.remove(req.sink_path) end
        end
    end
end

return Http
