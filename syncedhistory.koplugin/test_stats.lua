--[[--
Tests for syncedhistory_stats.lua against a fake server and a fake database.
Plain luajit, no KOReader:
  luajit test_stats.lua
]]

local this_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = this_dir .. "/?.lua;" .. package.path
local Stats = require("syncedhistory_stats")

local passed, failed = 0, 0
local function check(c, msg) if not c then error(msg or "check failed", 2) end end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end
local function test(name, f)
    local ok, err = pcall(f)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end

-- Tiny JSON stand-in: the fake server reads Lua tables directly.
local sent = {}
local function encode(v) sent[#sent + 1] = v; return "#" .. #sent end
local function decode(s) return sent[tonumber(s:sub(2))] end

local function fakeSettings()
    local t = {}
    return { readSetting = function(_, k) return t[k] end, saveSetting = function(_, k, v) t[k] = v end, flush = function() end, t = t }
end

-- A database of rows { rowid, document, ... }.
local function fakeDb(n)
    local db = { rows = {}, inserted = {} }
    for i = 1, n or 0 do
        db.rows[i] = { rowid = i, document = "d", title = "T", authors = "", page = i, start_time = 1000 + i, duration = 30, total_pages = 9 }
    end
    function db:maxRowid() return #self.rows end
    function db:readSince(mark, limit)
        local out = {}
        for _i, r in ipairs(self.rows) do if r.rowid > mark and #out < limit then out[#out + 1] = r end end
        return out
    end
    function db:insertRecords(recs)
        for _i, r in ipairs(recs) do
            self.inserted[#self.inserted + 1] = r
            self.rows[#self.rows + 1] = { rowid = #self.rows + 1, document = r.document, page = r.page,
                start_time = r.start_time, duration = r.duration, title = r.title, authors = r.authors }
        end
    end
    return db
end

-- A server holding `remote` records from another device, `pages` at a time.
local function fakeServer(remote, opts)
    opts = opts or {}
    local srv = { puts = {}, gets = {}, stored = {} }
    function srv.request(req, cb)
        if opts.fail then return cb({ err = "timeout" }) end
        if req.method == "PUT" then
            local body = decode(req.body)
            check(#body.records <= Stats.BATCH, "batch limit")
            srv.puts[#srv.puts + 1] = body
            for _i, r in ipairs(body.records) do srv.stored[#srv.stored + 1] = r end
            return cb({ status = 200, body = encode{ stored = #body.records, updated = 0, cursor = 1 } })
        end
        srv.gets[#srv.gets + 1] = req.url
        if req.url:match("/stats/kinds$") then
            return cb({ status = opts.kinds and 200 or 404, body = encode(opts.kinds or {}) })
        end
        local since = tonumber(req.url:match("since=(%d+)"))
        local out = {}
        for i = since + 1, math.min(#remote, since + 2) do
            local r = remote[i]; r.seq = i; out[#out + 1] = r
        end
        local nxt = since + #out
        cb({ status = 200, body = encode{ records = out, next = nxt, more = nxt < #remote } })
    end
    return srv
end

local CREDS = { server = "https://test", username = "u", userkey = "k" }
local function newSync(db, srv, settings, creds)
    local queue = {}
    local s = Stats.new{
        db = db, request = srv.request, json_encode = encode, json_decode = decode,
        credentials = function() return creds or CREDS end,
        device = function() return "Emu", "DEV 1" end,
        settings = settings or fakeSettings(),
        scheduleIn = function(_, f) queue[#queue + 1] = f end,
        flush = function() db.flushed = true end,
    }
    s.drain = function() while #queue > 0 do table.remove(queue, 1)() end end
    return s
end

local function remoteRows(n)
    local t = {}
    for i = 1, n do t[i] = { document = "r", title = "R", authors = "A", page = i, start_time = 5000 + i, duration = 40, total_pages = 3, device_id = "OTHER" } end
    return t
end

test("first sync uploads the whole history in batches of 1000", function()
    local db, srv = fakeDb(2500), fakeServer({})
    local s = newSync(db, srv)
    local result
    s:sync(function(ok, info) result = { ok = ok, info = info } end)
    s.drain()
    check(db.flushed, "flushed first")
    eq(#srv.puts, 3, "three requests")
    eq(#srv.puts[1].records, 1000, "full batch")
    eq(#srv.puts[3].records, 500, "rest")
    eq(srv.puts[1].device_id, "DEV 1", "device id sent")
    check(result.ok and result.info.uploaded == 2500, "done")
    eq(s:marks(CREDS).upload, 2500, "mark saved")
end)

test("pull pages through more=true, excludes own device, inserts, and is not sent back", function()
    local db, srv = fakeDb(1), fakeServer(remoteRows(5))
    local s = newSync(db, srv)
    local result
    s:sync(function(ok, info) result = info end)
    s.drain()
    eq(#db.inserted, 5, "inserted")
    eq(result.pulled, 5, "pulled")
    check(srv.gets[1]:match("exclude_device_id=DEV%%201"), "own device excluded, escaped: " .. srv.gets[1])
    local m = s:marks(CREDS)
    eq(m.cursor, 5, "cursor")
    eq(m.upload, 6, "mark moved past pulled rows")
    s:sync(); s.drain()
    eq(#srv.puts, 1, "nothing re-uploaded")
end)

test("a second sync sends only new rows and pulls since the cursor", function()
    local db, srv = fakeDb(3), fakeServer(remoteRows(2))
    local settings = fakeSettings()
    local s = newSync(db, srv, settings)
    s:sync(); s.drain()
    db.rows[#db.rows + 1] = { rowid = #db.rows + 1, document = "d", title = "T", authors = "", page = 99, start_time = 9999, duration = 10, total_pages = 9 }
    s:sync(); s.drain()
    eq(#srv.puts, 2, "two uploads")
    eq(#srv.puts[2].records, 1, "only the new row")
    check(srv.gets[#srv.gets - 1]:match("since=2"), "since the cursor")
end)

test("marks are kept per server and user", function()
    local db, srv = fakeDb(2), fakeServer({})
    local settings = fakeSettings()
    newSync(db, srv, settings):sync()
    local other = { server = "https://prod", username = "u", userkey = "k" }
    local s2 = newSync(db, srv, settings, other)
    eq(s2:marks(other).upload, 0, "fresh marks for another server")
    s2:sync()
    eq(#srv.puts, 2, "uploaded again to the other server")
end)

test("a failed request stops the sync and keeps the mark", function()
    local db = fakeDb(3)
    local s = newSync(db, fakeServer({}, { fail = true }))
    local ok_r, info_r
    s:sync(function(ok, info) ok_r, info_r = ok, info end)
    check(ok_r == false and info_r.reason:match("upload"), "stopped")
    eq(s:marks(CREDS).upload, 0, "mark kept")
    check(not s.running, "not left running")
end)

test("no login means no request", function()
    local srv = fakeServer({})
    local s = newSync(fakeDb(1), srv)
    s.credentials = function() return nil end
    local why
    s:sync(function(_, info) why = info.reason end)
    eq(why, "login", "reason")
    eq(#srv.puts + #srv.gets, 0, "no requests")
end)

test("server kinds are cached; a server without the route keeps the cache", function()
    local settings = fakeSettings()
    local s = newSync(fakeDb(0), fakeServer({}, { kinds = { abc = "gdrive", [1] = "x" } }), settings)
    s:sync()
    eq(s:remoteKinds().abc, "gdrive", "kept")
    eq(s:remoteKinds()[1], nil, "non-string key dropped")
    newSync(fakeDb(0), fakeServer({}), settings):sync()
    eq(s:remoteKinds().abc, "gdrive", "404 keeps the cache")
end)

test("bad pulled records are dropped", function()
    check(Stats.cleanRecord{ document = "d", page = 1, start_time = 2, duration = 3 }, "good")
    check(not Stats.cleanRecord{ document = "d", page = 1, start_time = 2 }, "no duration")
    check(not Stats.cleanRecord("x"), "not a table")
end)

test("a busy sync does not start twice", function()
    local s = newSync(fakeDb(0), { request = function() end })
    s:sync()
    local why
    s:sync(function(_, info) why = info.reason end)
    eq(why, "busy", "busy")
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
