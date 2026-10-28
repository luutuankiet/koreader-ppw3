--[[--
Tests for syncedhistory_client.lua and syncedhistory_http.lua. main.lua never
loads this file. The HTTP layer is a fake: no test talks to a server.

Two ways to run it:

  1. Standalone, any LuaJIT or Lua 5.1, fake md5, fake JSON, in-memory settings:
       luajit test_client.lua

  2. With KOReader's own luajit, real md5 (ffi/sha2), real JSON, real
     LuaSettings, plus the subprocess transport with real fork and pipes.
     Run from the KOReader install folder (the one holding setupkoenv.lua):
       cd /opt/ko/lib/koreader          # emulator; /mnt/us/koreader on a Kindle
       ./luajit <plugin dir>/test_client.lua --koreader
]]

local mode = arg and arg[1] == "--koreader" and "koreader" or "standalone"

local this_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = this_dir .. "/?.lua;" .. package.path

local env = {}

if mode == "koreader" then
    require("setupkoenv")
    local json = require("json")
    env.md5 = require("ffi/sha2").md5
    env.json_decode = json.decode
    env.json_encode = json.encode
    local top = (os.getenv("TMPDIR") or "/tmp") .. "/syncedhistory-client-test-" .. tostring(os.time())
    assert(require("libs/libkoreader-lfs").mkdir(top))
    local n = 0
    function env.newSettings()
        n = n + 1
        return require("luasettings"):open(top .. "/s" .. n .. ".lua")
    end
    function env.reopen(s) return require("luasettings"):open(s.file) end
    function env.cleanup() os.execute("rm -rf '" .. top .. "'") end
else
    env.md5 = function(s) return "md5<" .. s .. ">" end
    -- A JSON stand-in: encode hands out a token, decode gives back the value.
    local store, n = {}, 0
    function env.json_encode(v) n = n + 1; local k = "json#" .. n; store[k] = v; return k end
    function env.json_decode(s)
        if store[s] == nil then error("not json: " .. tostring(s)) end
        return store[s]
    end
    function env.newSettings()
        local data = {}
        return {
            data = data,
            readSetting = function(_, k) return data[k] end,
            saveSetting = function(_, k, v) data[k] = v end,
            flush = function() end,
        }
    end
    function env.reopen(s) return s end
    function env.cleanup() end
end

local Client = require("syncedhistory_client")
local Http = require("syncedhistory_http")

local KEY = "0123456789abcdef0123456789abcdef" -- a fake user key
local GOOD = {
    custom_server = "https://sync.example.test/",
    username = "reader",
    userkey = KEY,
    checksum_method = 1,
}
local function copy(t, over)
    local r = {}
    for k, v in pairs(t) do r[k] = v end
    for k, v in pairs(over or {}) do r[k] = v end
    return r
end

-- Every log line of every test, to prove the user key never reaches the log.
local log_lines = {}
local function logAt(level)
    return function(...)
        local parts = { level }
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        log_lines[#log_lines + 1] = table.concat(parts, " ")
    end
end
local log = { info = logAt("info"), warn = logAt("warn"), dbg = logAt("dbg") }

-- A fake HTTP layer: records each request and answers with `reply`.
local function fakeHttp(reply)
    local fake = { calls = {} }
    fake.request = function(req, callback)
        fake.calls[#fake.calls + 1] = req
        if type(reply) == "function" then callback(reply(req)) else callback(reply) end
    end
    return fake
end

local function newClient(kosync, reply, settings)
    local http = fakeHttp(reply or { err = "not expected" })
    local client = Client.new{
        kosync = function() return kosync end,
        request = http.request,
        md5 = env.md5,
        json_decode = env.json_decode,
        json_encode = env.json_encode,
        settings = settings or env.newSettings(),
        log = log,
        clock = function() return 1700000000 end,
    }
    return client, http
end

local function listBody()
    if mode == "koreader" then
        return '[{"document":"aaa","percentage":0.5,"device":"Kindle","device_id":"d1","timestamp":200,"filename":"Dune.epub"},'
            .. '{"document":"bbb","percentage":0.1,"device":"Kobo","device_id":null,"timestamp":100,"filename":null}]'
    end
    return env.json_encode({
        { document = "aaa", percentage = 0.5, device = "Kindle", device_id = "d1", timestamp = 200, filename = "Dune.epub" },
        { document = "bbb", percentage = 0.1, device = "Kobo", timestamp = 100 },
    })
end

local passed, failed = 0, 0
local function check(cond, msg)
    if not cond then error(msg or "check failed", 2) end
end
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok    " .. name)
    else
        failed = failed + 1
        print("FAIL  " .. name .. ": " .. tostring(err))
    end
end

print("mode: " .. mode)

test("settings missing: login message, no request", function()
    local cases = {
        { "no kosync settings", nil },
        { "no server", copy(GOOD, { custom_server = false }) },
        { "server left at https://", copy(GOOD, { custom_server = "https://" }) },
        { "no user name", copy(GOOD, { username = false }) },
        { "no user key", copy(GOOD, { userkey = false }) },
    }
    for _, case in ipairs(cases) do
        local s = case[2]
        if s then for k, v in pairs(s) do if v == false then s[k] = nil end end end
        local client, http = newClient(s)
        local got_list, got_info
        client:fetchList(function(list, info) got_list, got_info = list, info end)
        check(got_info and got_info.reason == "login", case[1] .. ": reason " .. tostring(got_info and got_info.reason))
        check(got_info.message == Client.MSG_LOGIN, case[1] .. ": wrong message")
        check(got_list == nil, case[1] .. ": list without a cache")
        local pushed
        client:pushDocument("/books/Dune.epub", function(ok) pushed = ok end)
        check(pushed == false, case[1] .. ": push did not report the skip")
        check(#http.calls == 0, case[1] .. ": made " .. #http.calls .. " requests")
    end
end)

test("binary matching method: one-line warning, no request", function()
    for _, method in ipairs({ 0, false }) do
        local s = copy(GOOD, { checksum_method = method })
        if method == false then s.checksum_method = nil end -- kosync's default is 0
        local client, http = newClient(s)
        local got_info
        client:fetchList(function(_, info) got_info = info end)
        check(got_info.reason == "method", "reason " .. tostring(got_info.reason))
        check(got_info.message == Client.MSG_METHOD, "wrong message")
        check(not got_info.message:find("\n"), "warning is more than one line")
        client:pushDocument("/books/Dune.epub")
        check(#http.calls == 0, "made " .. #http.calls .. " requests")
    end
end)

test("fetch: built-in sync headers, 15 s timeout, list cached", function()
    local settings = env.newSettings()
    local client, http = newClient(GOOD, { status = 200, body = listBody() }, settings)
    local got_list, got_info
    client:fetchList(function(list, info) got_list, got_info = list, info end)
    check(#http.calls == 1, "expected 1 request")
    local req = http.calls[1]
    check(req.method == "GET", "method " .. tostring(req.method))
    check(req.url == "https://sync.example.test/syncs/list", "url " .. tostring(req.url))
    check(req.headers["accept"] == "application/vnd.koreader.v1+json", "accept header")
    check(req.headers["x-auth-user"] == "reader", "x-auth-user header")
    check(req.headers["x-auth-key"] == KEY, "x-auth-key header")
    check(req.timeout == 15, "timeout " .. tostring(req.timeout))
    check(got_info.fresh == true, "not fresh")
    check(#got_list == 2 and got_list[1].document == "aaa" and got_list[1].filename == "Dune.epub", "rows")
    check(got_list[2].device_id == nil and got_list[2].filename == nil, "null fields kept")
    local cached, at = Client.new{
        kosync = function() return GOOD end, request = function() end,
        md5 = env.md5, json_decode = env.json_decode, json_encode = env.json_encode,
        settings = env.reopen(settings),
    }:cachedList()
    check(cached and #cached == 2 and cached[2].document == "bbb", "list not saved")
    check(at == 1700000000, "fetched_at " .. tostring(at))
end)

test("fetch failure keeps the cached list and says so", function()
    local settings = env.newSettings()
    local ok_client = newClient(GOOD, { status = 200, body = listBody() }, settings)
    ok_client:fetchList()
    local failures = {
        { "timeout", { err = "timeout" } },
        { "server error", { status = 500, body = "oops" } },
        { "wrong key", { status = 401, body = "{}" } },
        { "not a list", { status = 200, body = "<html>" } },
        { "no answer", nil },
    }
    for _, f in ipairs(failures) do
        local client = newClient(GOOD, f[2] or function() return nil end, settings)
        local got_list, got_info
        client:fetchList(function(list, info) got_list, got_info = list, info end)
        check(got_info.cached == true and not got_info.fresh, f[1] .. ": not marked cached")
        check(got_info.message == Client.MSG_CACHED, f[1] .. ": wrong message")
        check(got_list and #got_list == 2 and got_list[1].document == "aaa", f[1] .. ": cached list lost")
    end
    local cached = newClient(GOOD, nil, settings):cachedList()
    check(cached and #cached == 2, "a failure overwrote the cache")
    -- With nothing cached yet.
    local client = newClient(GOOD, { err = "timeout" })
    local got_list, got_info
    client:fetchList(function(list, info) got_list, got_info = list, info end)
    check(got_list == nil and got_info.cached == false, "invented a cache")
    check(got_info.message == Client.MSG_NO_CACHE, "wrong no-cache message")
end)

test("push: PUT /syncs/documents with document and filename", function()
    local client, http = newClient(copy(GOOD, { custom_server = "https://sync.example.test" }), { status = 200, body = "{}" })
    local pushed
    client:pushDocument("/mnt/us/documents/Frank Herbert/Dune (3).epub", function(ok) pushed = ok end)
    check(pushed == true, "push not reported ok")
    check(#http.calls == 1, "expected 1 request")
    local req = http.calls[1]
    check(req.method == "PUT", "method " .. tostring(req.method))
    check(req.url == "https://sync.example.test/syncs/documents", "url " .. tostring(req.url))
    check(req.headers["content-type"] == "application/json", "content type")
    check(req.headers["x-auth-key"] == KEY and req.headers["accept"] == Client.ACCEPT, "auth headers")
    local body = env.json_decode(req.body)
    check(body.filename == "Dune (3).epub", "filename " .. tostring(body.filename))
    check(body.document == env.md5("Dune (3).epub"), "document is not md5(file name)")
    check(body.document == client:keyFor("/elsewhere/Dune (3).epub"), "document differs from keyFor")
    local keys = 0
    for _ in pairs(body) do keys = keys + 1 end
    check(keys == 2, "body has " .. keys .. " fields")
    if mode == "koreader" then
        -- Independent vector: printf '%s' 'Dune (3).epub' | md5sum
        check(body.document == "b2ec56454ac3388d40cef9b3a56f0d84", "document differs from md5sum of the name")
    end
end)

test("push failure is only logged", function()
    local client = newClient(GOOD, { status = 403, body = '{"code":2007}' })
    local before = #log_lines
    local pushed
    local ok = pcall(function()
        client:pushDocument("/books/Dune.epub", function(r) pushed = r end)
    end)
    check(ok, "push raised an error")
    check(pushed == false, "failure not reported")
    check(#log_lines > before and log_lines[#log_lines]:find("^warn"), "failure not logged")
end)

if mode == "koreader" then
    -- The subprocess transport, with the network part swapped for a stub
    -- that runs in the child. A tiny scheduler stands in for UIManager.
    local socket = require("socket")
    local function runLoop(pending)
        local queue = {}
        local function scheduleIn(s, f) queue[#queue + 1] = { at = socket.gettime() + s, f = f } end
        local start = socket.gettime()
        pending.scheduleIn = scheduleIn
        pending.start(scheduleIn)
        while #queue > 0 and socket.gettime() - start < 30 do
            table.sort(queue, function(a, b) return a.at < b.at end)
            local item = table.remove(queue, 1)
            local wait = item.at - socket.gettime()
            if wait > 0 then socket.sleep(wait) end
            item.f()
        end
        return socket.gettime() - start
    end

    test("subprocess transport returns the child's answer without blocking", function()
        local real = Http.blockingRequest
        Http.blockingRequest = function(req)
            socket.sleep(1)
            return { status = 200, body = req.method .. " " .. req.url .. "\nline two" }
        end
        local res, returned_after
        local elapsed = runLoop{ start = function(scheduleIn)
            local t0 = socket.gettime()
            Http.new{ scheduleIn = scheduleIn }({ method = "GET", url = "https://x.test/syncs/list", timeout = 15 },
                function(r) res = r end)
            returned_after = socket.gettime() - t0
        end }
        Http.blockingRequest = real
        check(returned_after < 0.5, "request blocked for " .. returned_after .. " s")
        check(res and res.status == 200, "status " .. tostring(res and res.status))
        check(res.body == "GET https://x.test/syncs/list\nline two", "body " .. tostring(res.body))
        check(elapsed >= 1, "answer came before the child finished")
    end)

    test("subprocess transport kills a stuck child after the timeout", function()
        local real, grace = Http.blockingRequest, Http.GRACE
        Http.blockingRequest = function() socket.sleep(20); return { status = 200, body = "late" } end
        Http.GRACE = 0
        local res
        local elapsed = runLoop{ start = function(scheduleIn)
            Http.new{ scheduleIn = scheduleIn }({ method = "GET", url = "https://x.test/", timeout = 1 },
                function(r) res = r end)
        end }
        Http.blockingRequest, Http.GRACE = real, grace
        check(res and res.err == "timeout", "expected timeout, got " .. tostring(res and (res.err or res.status)))
        check(elapsed < 5, "took " .. elapsed .. " s")
    end)

    test("subprocess transport reports a network error", function()
        local res
        runLoop{ start = function(scheduleIn)
            -- Port 9 on localhost: nothing listens, the child gets "connection refused".
            Http.new{ scheduleIn = scheduleIn }({ method = "GET", url = "http://127.0.0.1:9/", timeout = 5 },
                function(r) res = r end)
        end }
        check(res and res.err and not res.status, "expected an error, got " .. tostring(res and res.status))
    end)
end

test("the user key never reaches the log", function()
    check(#log_lines > 0, "nothing was logged")
    for _, line in ipairs(log_lines) do
        check(not line:find(KEY, 1, true), "user key logged: " .. line:sub(1, 40))
    end
end)

env.cleanup()
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
