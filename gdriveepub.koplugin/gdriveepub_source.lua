--[[--
Where a downloaded book came from, without KOReader.

Every download records its Drive file in the book's sidecar under
`gdriveepub_source`, so another plugin (the synced reading list) can find a
book's Drive file again and tell whether the Doc changed since:

    { id = "<drive file id>", modified = "<RFC 3339 modifiedTime>",
      downloaded_at = "2026-11-21T08:30:00Z" }

The sidecar is reached through a DocSettings-shaped object passed in, so the
tests can stub it. Lua 5.1 only.
]]

local Source = {}

Source.KEY = "gdriveepub_source"

--- Search words for the server's `/api/files?view=search&q=` from a file name
--- made by Format.fileName: the extension dropped and the `_` that safeName put
--- in place of / \ : * ? " < > | turned back into word breaks.
function Source.searchQuery(basename)
    local s = tostring(basename or "")
    s = s:gsub("%.[%w]+$", "")
    s = s:gsub("_", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return s
end

--- The items whose Format.fileName equals `basename` byte for byte.
function Source.matchByFileName(items, basename, fileName)
    local out = {}
    for _, item in ipairs(items or {}) do
        if fileName(item) == basename then out[#out + 1] = item end
    end
    return out
end

--- The record for a finished download: `modified` prefers the download's
--- X-Modified-Time header, then the item's own modifiedTime.
function Source.newRecord(item, headers, now)
    local modified = headers and headers["x-modified-time"]
    if not modified or modified == "" then modified = item.modifiedTime or item.modified_time end
    return {
        id = item.id,
        modified = modified,
        downloaded_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now or os.time()),
    }
end

--- `settings` is an opened DocSettings (or the open book's doc_settings).
function Source.read(settings)
    local rec = settings:readSetting(Source.KEY)
    if type(rec) ~= "table" or type(rec.id) ~= "string" or rec.id == "" then return nil end
    return rec
end

function Source.write(settings, rec)
    settings:saveSetting(Source.KEY, rec)
    settings:flush()
end

return Source
