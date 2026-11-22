--[[--
Cross-device reading time: upload this device's KOReader statistics page
records to the progress sync server and merge other devices' records into the
local statistics database, so the goal numbers and KOReader's own calendar
see every device.

One sync, run only at a moment the reading list already uses the network:
1. flush the statistics plugin's in-memory page times (`flush`);
2. upload local rows past the upload mark, `BATCH` per request;
3. pull other devices' rows past the pull cursor until the server has no more;
4. move the upload mark past the pulled rows, so they are never sent back.
Each batch is its own request, with the next one scheduled through
`scheduleIn`, so the UI loop never runs thousands of rows in one go. Marks are
kept per server URL and username, so a test server never reuses prod marks.

    local sync = Stats.new{ db = db, request = request, credentials = fn, ... }
    sync:sync(function(ok, info) end)

Lua 5.1 only.
]]

local Stats = {}
Stats.__index = Stats

Stats.BATCH = 1000          -- records per upload, the server's limit
Stats.PULL_LIMIT = 500      -- records per pull
Stats.PAUSE = 0.5           -- seconds between batches
Stats.TIMEOUT = 20
Stats.MARKS = "stats_marks"
Stats.KINDS = "stats_kinds"
Stats.ACCEPT = "application/vnd.koreader.v1+json"

local function noop() end

--[[--
opts:
db           (required) see syncedhistory_statsdb.lua: maxRowid, readSince(mark, n), insertRecords(records)
request      (required) function(req, callback(res)), res = { status, body } or { err }
credentials  (required) function() -> { server, username, userkey } or nil
device       (required) function() -> name, device_id
json_encode, json_decode (required)
settings     (required) LuaSettings-like: readSetting, saveSetting, flush
scheduleIn   (required) function(seconds, f)
flush        (optional) function() writing pending page times to the database
log          (optional) logger
]]
function Stats.new(opts)
    local self = setmetatable({}, Stats)
    for k, v in pairs(opts) do self[k] = v end
    self.flush = self.flush or noop
    self.log = self.log or { info = noop, warn = noop, dbg = noop }
    return self
end

local function headers(creds, body)
    local h = {
        ["accept"] = Stats.ACCEPT,
        ["x-auth-user"] = creds.username,
        ["x-auth-key"] = creds.userkey,
    }
    if body then h["content-type"] = "application/json" end
    return h
end

local function markKey(creds) return creds.server .. "|" .. creds.username end

-- { upload = rowid, cursor = seq } for this server and user.
function Stats:marks(creds)
    local all = self.settings:readSetting(Stats.MARKS) or {}
    local m = all[markKey(creds)] or {}
    return { upload = tonumber(m.upload) or 0, cursor = tonumber(m.cursor) or 0 }
end

function Stats:saveMarks(creds, m)
    local all = self.settings:readSetting(Stats.MARKS) or {}
    all[markKey(creds)] = { upload = m.upload, cursor = m.cursor }
    self.settings:saveSetting(Stats.MARKS, all)
    self.settings:flush()
end

-- Kinds the server knows for documents: { [md5] = "gdrive" | "rss" }.
function Stats:remoteKinds()
    return self.settings:readSetting(Stats.KINDS) or {}
end

local function decode(self, res)
    if not (res and res.status == 200 and type(res.body) == "string") then return nil end
    local ok, v = pcall(self.json_decode, res.body)
    if ok and type(v) == "table" then return v end
end

local function num(v) return type(v) == "number" and v or tonumber(v) end
local function str(v) return type(v) == "string" and v or nil end

-- A pulled record with the fields the database needs, or nil.
function Stats.cleanRecord(r)
    if type(r) ~= "table" then return nil end
    local c = {
        document = str(r.document), title = str(r.title) or "", authors = str(r.authors) or "",
        page = num(r.page), start_time = num(r.start_time), duration = num(r.duration),
        total_pages = num(r.total_pages) or 0,
    }
    if not (c.document and c.page and c.start_time and c.duration) then return nil end
    return c
end

--[[--
Run one sync. `done(ok, info)`; info has uploaded, pulled, reason or status.
A sync already running makes this call a no-op that reports "busy".
]]
function Stats:sync(done)
    done = done or noop
    if self.running then return done(false, { reason = "busy" }) end
    local creds = self.credentials()
    if not creds then return done(false, { reason = "login" }) end
    self.running = true
    local info = { uploaded = 0, pulled = 0 }
    local function finish(ok, why)
        self.running = false
        info.reason = why
        if ok then self.last_sync = os.time() end
        self.log.info("syncedhistory: stats sync", ok and "done" or "stopped", why or "",
            "up", info.uploaded, "down", info.pulled)
        done(ok, info)
    end
    local ok_flush, err = pcall(self.flush)
    if not ok_flush then self.log.warn("syncedhistory: stats flush failed:", err) end
    local m = self:marks(creds)
    local name, device_id = self.device()

    local pull, kinds
    local function upload()
        local ok, rows = pcall(self.db.readSince, self.db, m.upload, Stats.BATCH)
        if not ok then return finish(false, "db: " .. tostring(rows)) end
        if #rows == 0 then return pull() end
        local records = {}
        for i, r in ipairs(rows) do
            records[i] = { document = r.document, title = r.title, authors = r.authors, page = r.page,
                start_time = r.start_time, duration = r.duration, total_pages = r.total_pages }
        end
        self.request({
            method = "PUT", url = creds.server .. "/stats/records", headers = headers(creds, true),
            timeout = Stats.TIMEOUT,
            body = self.json_encode{ device = name, device_id = device_id, records = records },
        }, function(res)
            if not decode(self, res) then
                info.status = res and res.status
                return finish(false, "upload " .. tostring(res and (res.status or res.err)))
            end
            info.uploaded = info.uploaded + #rows
            m.upload = rows[#rows].rowid
            self:saveMarks(creds, m)
            if #rows >= Stats.BATCH then self.scheduleIn(Stats.PAUSE, upload) else pull() end
        end)
    end

    pull = function()
        local url = string.format("%s/stats/records?since=%d&limit=%d", creds.server, m.cursor, Stats.PULL_LIMIT)
        if device_id then url = url .. "&exclude_device_id=" .. tostring(device_id):gsub("[^%w%-_%.~]",
            function(c) return string.format("%%%02X", c:byte()) end) end
        self.request({ method = "GET", url = url, headers = headers(creds), timeout = Stats.TIMEOUT }, function(res)
            local body = decode(self, res)
            if not body then
                info.status = res and res.status
                return finish(false, "pull " .. tostring(res and (res.status or res.err)))
            end
            local records = {}
            for _i, r in ipairs(type(body.records) == "table" and body.records or {}) do
                local c = Stats.cleanRecord(r)
                if c then records[#records + 1] = c end
            end
            if #records > 0 then
                -- Only rows inserted here may skip the upload: when this
                -- device wrote rows since the last upload, leave the mark
                -- and let them all go up next time (the server keeps one
                -- copy of each record).
                local ok_before, before = pcall(self.db.maxRowid, self.db)
                local ok, err2 = pcall(self.db.insertRecords, self.db, records)
                if not ok then return finish(false, "db: " .. tostring(err2)) end
                info.pulled = info.pulled + #records
                if ok_before and (before or 0) <= m.upload then
                    local ok_after, after = pcall(self.db.maxRowid, self.db)
                    if ok_after and after then m.upload = after end
                end
            end
            local nxt = num(body.next)
            if nxt and nxt > m.cursor then m.cursor = nxt end
            self:saveMarks(creds, m)
            if body.more == true and nxt then self.scheduleIn(Stats.PAUSE, pull) else kinds() end
        end)
    end

    kinds = function()
        self.request({ method = "GET", url = creds.server .. "/stats/kinds", headers = headers(creds),
            timeout = Stats.TIMEOUT }, function(res)
            local body = decode(self, res)
            if body then
                local clean = {}
                for k, v in pairs(body) do
                    if type(k) == "string" and type(v) == "string" then clean[k] = v end
                end
                self.settings:saveSetting(Stats.KINDS, clean)
                self.settings:flush()
            end
            finish(true)
        end)
    end

    upload()
end

return Stats
