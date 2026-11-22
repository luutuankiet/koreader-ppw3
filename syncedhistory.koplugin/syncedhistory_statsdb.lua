--[[--
KOReader's statistics database (settings/statistics.sqlite3, schema of
statistics.koplugin v2026.07.1), as the stats sync and the goal numbers need
it. Each call opens and closes its own connection, like the statistics
plugin does.

    local db = StatsDb.new{ open = function() return SQ3.open(path) end }

Lua 5.1 only.
]]

local StatsDb = {}
StatsDb.__index = StatsDb

function StatsDb.new(opts)
    return setmetatable({ open = opts.open }, StatsDb)
end

local function withConn(self, f)
    local conn = self.open()
    local ok, a = pcall(f, conn)
    conn:close()
    if not ok then error(a, 0) end
    return a
end

local function rows(conn, sql, ...)
    local stmt = conn:prepare(sql)
    if select("#", ...) > 0 then stmt:bind(...) end
    local out = {}
    while true do
        local row = stmt:step()
        if not row then break end
        local copy = {}
        for i = 1, #row do copy[i] = row[i] end
        out[#out + 1] = copy
    end
    stmt:close()
    return out
end

local function n(v) return tonumber(v) end

-- Highest page_stat_data rowid, 0 when empty.
function StatsDb:maxRowid()
    return withConn(self, function(conn)
        local r = rows(conn, "SELECT COALESCE(MAX(rowid), 0) FROM page_stat_data")
        return n(r[1][1]) or 0
    end)
end

-- Up to `limit` page records with rowid > mark, oldest rowid first. Rows of
-- books without an md5, or with no duration, are scanned but not returned;
-- `out.last` is the last rowid scanned (so the mark can pass skipped rows)
-- and `out.full` is true when the scan hit `limit` (more may follow).
function StatsDb:readSince(mark, limit)
    limit = limit or 1000
    return withConn(self, function(conn)
        local out = {}
        local scanned = rows(conn, [[
            SELECT p.rowid, b.md5, b.title, b.authors, p.page, p.start_time, p.duration, p.total_pages
            FROM page_stat_data p LEFT JOIN book b ON b.id = p.id_book
            WHERE p.rowid > ? ORDER BY p.rowid LIMIT ?]], mark or 0, limit)
        for _i, r in ipairs(scanned) do
            local duration = n(r[7]) or 0
            if r[2] and r[2] ~= "" and duration > 0 then
                out[#out + 1] = { rowid = n(r[1]), document = r[2], title = r[3] or "", authors = r[4] or "",
                    page = n(r[5]), start_time = n(r[6]), duration = duration, total_pages = n(r[8]) or 0 }
            end
        end
        if #scanned > 0 then out.last = n(scanned[#scanned][1]) end
        out.full = #scanned >= limit
        return out
    end)
end

--[[--
Merge pulled records: find or create the book on (title, authors, md5), insert
each page record, keep the longer duration on conflict (as
ReaderStatistics.onSync does), then refresh the touched books' totals.
]]
function StatsDb:insertRecords(records)
    return withConn(self, function(conn)
        conn:exec("BEGIN;")
        local ok, err = pcall(function()
            local find = conn:prepare("SELECT id FROM book WHERE title = ? AND authors = ? AND md5 = ?")
            local add_book = conn:prepare([[INSERT INTO book (title, authors, notes, last_open, highlights,
                pages, series, language, md5, total_read_time, total_read_pages)
                VALUES (?, ?, 0, ?, 0, ?, 'N/A', 'N/A', ?, 0, 0)]])
            local add_page = conn:prepare([[INSERT INTO page_stat_data (id_book, page, start_time, duration, total_pages)
                VALUES (?, ?, ?, ?, ?) ON CONFLICT(id_book, page, start_time) DO UPDATE SET
                duration = MAX(duration, excluded.duration)]])
            local ids, touched = {}, {}
            for _i, r in ipairs(records) do
                local key = r.title .. "\0" .. r.authors .. "\0" .. r.document
                local id = ids[key]
                if not id then
                    local row = find:reset():bind(r.title, r.authors, r.document):step()
                    id = row and n(row[1])
                    if not id then
                        add_book:reset():bind(r.title, r.authors, r.start_time, r.total_pages, r.document):step()
                        row = find:reset():bind(r.title, r.authors, r.document):step()
                        id = n(row[1])
                    end
                    ids[key] = id
                end
                touched[id] = true
                add_page:reset():bind(id, r.page, r.start_time, r.duration, r.total_pages):step()
            end
            find:close(); add_book:close(); add_page:close()
            for id in pairs(touched) do
                conn:exec(string.format([[UPDATE book SET (total_read_pages, total_read_time) =
                    (SELECT count(DISTINCT page), sum(duration) FROM page_stat_data WHERE id_book = %d),
                    last_open = MAX(last_open, (SELECT MAX(start_time) FROM page_stat_data WHERE id_book = %d))
                    WHERE id = %d]], id, id, id))
            end
        end)
        if not ok then
            pcall(conn.exec, conn, "ROLLBACK;")
            error(err, 0)
        end
        conn:exec("COMMIT;")
        return #records
    end)
end

-- Page records starting at or after `since`: { start_time, duration, md5, title }.
function StatsDb:readFrom(since)
    return withConn(self, function(conn)
        local out = {}
        for i, r in ipairs(rows(conn, [[SELECT p.start_time, p.duration, b.md5, b.title
            FROM page_stat_data p JOIN book b ON b.id = p.id_book
            WHERE p.start_time >= ? AND p.duration > 0]], since or 0)) do
            out[i] = { start_time = n(r[1]), duration = n(r[2]), md5 = r[3], book = r[4] or "" }
        end
        return out
    end)
end

return StatsDb
