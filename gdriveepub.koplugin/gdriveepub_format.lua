--[[--
Text and file names for the Google Drive list, without KOReader.

    local Format = require("gdriveepub_format")
    Format.parseIso("2026-11-15T08:30:00.000Z")        -- seconds since epoch (UTC)
    Format.date("2026-11-15T08:30:00.000Z", offset)     -- "2026-11-15" in local time
    Format.metaLine(file, offset)  -- "Updated 2026-11-15 · Created 2026-10-02 · DOC"
    Format.details(file, offset)   -- whole title and every timestamp, for long-press
    Format.fileName(file)          -- "Quarterly notes.epub", safe on FAT32
    Format.joinPath("/mnt/us/documents", "GDrive", name)

`offset` is the local time zone's distance from UTC in seconds
(Format.localOffset() works it out); every function takes it so tests can
pin it.

Lua 5.1 only.
]]

local Format = {}

Format.KIND_LABEL = { doc = "DOC", pdf = "PDF", epub = "EPUB" }
Format.KIND_EXT = { doc = "epub", pdf = "pdf", epub = "epub" }
Format.MAX_NAME_BYTES = 150

-- LuaJIT and Lua 5.1 have no \u{} escape: spell the middle dot out.
Format.DOT = " " .. string.char(0xC2, 0xB7) .. " "

local function daysFromCivil(y, m, d)
    -- Howard Hinnant's days_from_civil: days since 1970-01-01, no os.time.
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function civilFromDays(z)
    z = z + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then y = y + 1 end
    return y, m, d
end

--- Seconds since the epoch for an ISO 8601 time ("Z" or "+hh:mm"), or nil.
function Format.parseIso(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, sec, rest = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$")
    if not y then
        y, mo, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
        if not y then return nil end
        h, mi, sec, rest = "0", "0", "0", "Z"
    end
    rest = rest:gsub("^%.%d+", "")
    local offset = 0
    if rest == "Z" or rest == "" then
        offset = 0
    else
        local sign, oh, om = rest:match("^([+-])(%d%d):?(%d%d)$")
        if not sign then return nil end
        offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
    end
    y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
    if mo < 1 or mo > 12 or d < 1 or d > 31 then return nil end
    return daysFromCivil(y, mo, d) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec) - offset
end

--- The local zone's offset from UTC in seconds, right now.
function Format.localOffset(now)
    now = now or os.time()
    local l, u = os.date("*t", now), os.date("!*t", now)
    l.isdst = false
    return os.time(l) - os.time(u)
end

local function parts(epoch, offset)
    local t = epoch + (offset or 0)
    local days = math.floor(t / 86400)
    local secs = t - days * 86400
    local y, m, d = civilFromDays(days)
    return y, m, d, math.floor(secs / 3600), math.floor((secs % 3600) / 60)
end

--- "2026-11-15" in local time, or nil when the time is missing or bad.
function Format.date(iso, offset)
    local e = Format.parseIso(iso)
    if not e then return nil end
    local y, m, d = parts(e, offset)
    return string.format("%04d-%02d-%02d", y, m, d)
end

--- "2026-11-15 08:30" in local time, or nil.
function Format.dateTime(iso, offset)
    local e = Format.parseIso(iso)
    if not e then return nil end
    local y, m, d, h, mi = parts(e, offset)
    return string.format("%04d-%02d-%02d %02d:%02d", y, m, d, h, mi)
end

function Format.kindLabel(kind)
    return Format.KIND_LABEL[kind] or "DOC"
end

--- Second line of a row: "Updated 2026-11-15 · Created 2026-10-02 · DOC".
function Format.metaLine(file, offset)
    local bits = {}
    local u, c = Format.date(file.modified_time, offset), Format.date(file.created_time, offset)
    bits[#bits + 1] = "Updated " .. (u or "?")
    bits[#bits + 1] = "Created " .. (c or "?")
    bits[#bits + 1] = Format.kindLabel(file.kind)
    return table.concat(bits, Format.DOT)
end

--- "1.2 MB", "40 KB", or nil for Google Docs (no size until exported).
function Format.size(n)
    if type(n) ~= "number" then return nil end
    if n >= 1024 * 1024 then return string.format("%.1f MB", n / (1024 * 1024)) end
    return string.format("%d KB", math.max(1, math.floor(n / 1024 + 0.5)))
end

--- Long-press text: the whole title, then one line per fact.
function Format.details(file, offset)
    local lines = { file.name, "" }
    local function add(label, value) lines[#lines + 1] = label .. ": " .. (value or "unknown") end
    add("Updated", Format.dateTime(file.modified_time, offset))
    add("Created", Format.dateTime(file.created_time, offset))
    if file.viewed_time then add("Opened", Format.dateTime(file.viewed_time, offset)) end
    local kind = Format.kindLabel(file.kind)
    if file.kind == "doc" then kind = kind .. " (Google Doc, downloads as EPUB)" end
    add("Type", kind)
    local sz = Format.size(file.size)
    if sz then add("Size", sz) end
    return table.concat(lines, "\n")
end

-- Cut a UTF-8 string to at most n bytes without splitting a character.
local function utf8Cut(s, n)
    if #s <= n then return s end
    local cut = n
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut)
end
Format._utf8Cut = utf8Cut

--- A file name safe on the Kindle's FAT32 storage: no / \ : * ? " < > |,
--- no control characters, no leading or trailing dots and spaces, at most
--- MAX_NAME_BYTES bytes before the extension.
function Format.safeName(name)
    local s = tostring(name or "")
    s = s:gsub("[%c]", " "):gsub('[/\\:%*%?"<>|]', "_")
    s = s:gsub("%s+", " ")
    s = s:gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    s = utf8Cut(s, Format.MAX_NAME_BYTES)
    s = s:gsub("[%s%.]+$", "")
    if s == "" then s = "Untitled" end
    return s
end

--- "<safe title>.<ext>": Google Docs become .epub, PDF and EPUB keep theirs.
function Format.fileName(file)
    local ext = Format.KIND_EXT[file.kind] or "epub"
    local base = Format.safeName(file.name)
    -- A Drive PDF named "report.pdf" must not become "report.pdf.pdf".
    local lower = base:lower()
    if lower:sub(-(#ext + 1)) == "." .. ext and #base > #ext + 1 then
        base = base:sub(1, #base - #ext - 1)
    end
    return base .. "." .. ext
end

function Format.joinPath(...)
    local out = {}
    for i, p in ipairs({ ... }) do
        p = tostring(p)
        if i > 1 then p = p:gsub("^/+", "") end
        if i < select("#", ...) then p = p:gsub("/+$", "") end
        if p ~= "" then out[#out + 1] = p end
    end
    return table.concat(out, "/")
end

return Format
