--[[--
Google Drive glue for the synced reading list, with no KOReader requires so
it runs under plain luajit in tests.

A book downloaded by the Google Drive plugin carries a record in its sidecar,
`gdriveepub_source = { id, modified, downloaded_at }`, where `modified` is the
Drive `modifiedTime` of the copy on disk. This module decides:
  - which Drive file a list row stands for (resolveId)
  - whether Drive holds a newer copy than the one on disk (isNewer)
  - what record a book found by name gets (backfillRecord)
  - the background backfill loop, one request at a time (backfill)
]]

local Drive = {}

Drive.KIND = "gdrive"
Drive.MSG_ASK = "Document not found. Download it from Google Drive?"
Drive.MSG_NONE = "This book was not found on Google Drive."
Drive.MSG_MANY = "Several Google Drive files have this name, so none was downloaded."
Drive.MSG_NOT_PAIRED = "Google Drive is not set up on this device."
Drive.MSG_FAILED = "Could not download the book from Google Drive."
Drive.MSG_CLASH = "Another Drive Doc already uses this name. The reading list keeps the first one."
Drive.MSG_DOWNLOADING = "Downloading from Google Drive…"
Drive.MSG_UPDATING = "A newer version is on Google Drive. Downloading it…"

-- Days since 1970-01-01 for a civil date (proleptic Gregorian), so parsing
-- never depends on the device's time zone.
local function daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

--- "2026-11-20T15:42:16.942Z" -> seconds since the epoch (fraction kept), or nil.
function Drive.isoToEpoch(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, sec, frac = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(%.?%d*)Z$")
    if not y then return nil end
    local t = daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
        + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
    if frac ~= "" and frac ~= "." then t = t + tonumber("0" .. frac) end
    return t
end

function Drive.epochToIso(t)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(t))
end

--- Is version `a` strictly newer than `b`? Both are ISO times; an unreadable
-- `b` counts as older than any readable `a`.
function Drive.isNewer(a, b)
    local ta, tb = Drive.isoToEpoch(a), Drive.isoToEpoch(b)
    if not ta then return false end
    if not tb then return true end
    return ta > tb
end

--- The Drive id the server holds for a list row, or nil.
function Drive.serverId(row)
    local src = type(row) == "table" and row.source
    if type(src) == "table" and src.kind == Drive.KIND
        and type(src.id) == "string" and src.id ~= "" then
        return src.id
    end
    return nil
end

--- The `source` sent with a document push for a local record, or nil.
function Drive.sourceFor(rec)
    if type(rec) ~= "table" or type(rec.id) ~= "string" or rec.id == "" then return nil end
    return { kind = Drive.KIND, id = rec.id, modified = type(rec.modified) == "string" and rec.modified or nil }
end

--- Does the server row point at another Drive file than `source`?
function Drive.clash(row, source)
    local id = Drive.serverId(row)
    return id ~= nil and source ~= nil and source.id ~= id
end

--[[--
Which Drive file a row stands for. The server's source first; otherwise a
search by the row's file name, which must give exactly one file.
`find(basename, cb)` is the Drive plugin's findByFileName.
`cb(item)` with item = {id, name?, kind?}, or `cb(nil, reason)` with reason
"none", "many", "no_name" or the plugin's error code.
]]
function Drive.resolve(row, find, cb)
    local id = Drive.serverId(row)
    if id then return cb({ id = id }) end
    local name = type(row) == "table" and row.filename
    if type(name) ~= "string" or name == "" then return cb(nil, "no_name") end
    find(name, function(ok, items)
        if not ok then return cb(nil, items) end
        if type(items) ~= "table" or #items == 0 then return cb(nil, "none") end
        if #items > 1 then return cb(nil, "many") end
        cb(items[1])
    end)
end

--- The record for a local book matched to Drive file `item` by name. When the
-- file on disk is older than Drive's copy, `modified` is the file's own time,
-- so the next version check sees Drive as newer and offers the update.
function Drive.backfillRecord(item, file_mtime, now)
    local drive_t = Drive.isoToEpoch(item.modifiedTime)
    local modified = item.modifiedTime
    if drive_t and type(file_mtime) == "number" and file_mtime < drive_t then
        modified = Drive.epochToIso(file_mtime)
    end
    return {
        id = item.id,
        modified = modified,
        downloaded_at = Drive.epochToIso(now or os.time()),
    }
end

--[[--
Give every local book without a record one, by an exact file name search,
one request at a time. A book with a record is never searched again; a book
with zero or several matches is skipped (and searched again next time).

opts:
  paths        list of local book paths
  readRecord   function(path) -> record or nil
  writeRecord  function(path, record)
  find         function(basename, cb) as the Drive plugin's findByFileName
  basename     function(path) -> file name
  mtime        function(path) -> seconds or nil
  push         function(path, record), optional, after a record is written
  log          optional { info, warn }
  next         optional function(f): run f later (UIManager:nextTick), so a
               long list never runs in one go
  done         optional function(stats), stats = {matched, skipped, failed}
]]
function Drive.backfill(opts)
    local log = opts.log or {}
    local info = log.info or function() end
    local later = opts.next or function(f) f() end
    local todo = {}
    for _, p in ipairs(opts.paths or {}) do
        if not opts.readRecord(p) then todo[#todo + 1] = p end
    end
    local stats = { matched = 0, skipped = 0, failed = 0 }
    local i = 0
    local function step()
        i = i + 1
        local path = todo[i]
        if not path then
            if opts.done then opts.done(stats) end
            return
        end
        local name = opts.basename(path)
        opts.find(name, function(ok, items)
            if not ok then
                stats.failed = stats.failed + 1
                info("syncedhistory: backfill search failed for", name, items)
                -- Not paired, or offline: the next books would fail the same way.
                if items == "not_paired" or items == "network" then
                    if opts.done then opts.done(stats) end
                    return
                end
            elseif type(items) ~= "table" or #items ~= 1 then
                stats.skipped = stats.skipped + 1
                info("syncedhistory: backfill skipped", name, "matches:", type(items) == "table" and #items or 0)
            else
                local rec = Drive.backfillRecord(items[1], opts.mtime(path))
                opts.writeRecord(path, rec)
                stats.matched = stats.matched + 1
                info("syncedhistory: backfill matched", name, rec.id, rec.modified)
                if opts.push then opts.push(path, rec) end
            end
            later(step)
        end)
    end
    if #todo == 0 then
        if opts.done then opts.done(stats) end
        return 0
    end
    step()
    return #todo
end

return Drive
