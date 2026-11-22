--[[
Tests for syncedhistory_statsdb.lua against a real SQLite file with the
statistics plugin schema. Needs KOReader's luajit and its ljsqlite3, so run
from a KOReader install folder:

    cd /mnt/us/koreader            # Kindle, emulator, or any unpacked KOReader
    ./luajit <plugin dir>/test_statsdb.lua
]]

local this_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = this_dir .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
pcall(require, "setupkoenv")
local SQ3 = require("lua-ljsqlite3/init")
local StatsDb = require("syncedhistory_statsdb")

local path = os.tmpname() .. ".sqlite3"
os.remove(path)

-- Schema copied from statistics.koplugin v2026.07.1 (createDB).
local conn = SQ3.open(path)
conn:exec([[
CREATE TABLE book (id integer PRIMARY KEY autoincrement, title text, authors text, notes integer,
    last_open integer, highlights integer, pages integer, series text, language text, md5 text,
    total_read_time integer, total_read_pages integer);
CREATE UNIQUE INDEX book_title_authors_md5 ON book(title, authors, md5);
CREATE TABLE page_stat_data (id_book integer, page integer NOT NULL DEFAULT 0,
    start_time integer NOT NULL DEFAULT 0, duration integer NOT NULL DEFAULT 0,
    total_pages integer NOT NULL DEFAULT 0, UNIQUE (id_book, page, start_time),
    FOREIGN KEY(id_book) REFERENCES book(id));
CREATE INDEX page_stat_data_start_time ON page_stat_data(start_time);
INSERT INTO book (title, authors, notes, last_open, highlights, pages, series, language, md5,
    total_read_time, total_read_pages) VALUES ('Local Book', 'Ann', 0, 100, 0, 300, 'N/A', 'en', 'md5local', 0, 0);
INSERT INTO book (title, authors, notes, last_open, highlights, pages, series, language, md5,
    total_read_time, total_read_pages) VALUES ('No Md5', 'Bob', 0, 100, 0, 10, 'N/A', 'en', NULL, 0, 0);
INSERT INTO page_stat_data VALUES (1, 1, 1000, 30, 300);
INSERT INTO page_stat_data VALUES (1, 2, 1030, 0, 300);
INSERT INTO page_stat_data VALUES (2, 1, 1100, 20, 10);
INSERT INTO page_stat_data VALUES (1, 3, 1200, 40, 300);
]])
conn:close()

local db = StatsDb.new{ open = function() return SQ3.open(path) end }
local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name, detail or "") end
end

check("maxRowid", db:maxRowid() == 4, db:maxRowid())

local r = db:readSince(0, 1000)
check("readSince skips no-md5 and zero duration", #r == 2, #r)
check("readSince fields", r[1].document == "md5local" and r[1].title == "Local Book" and r[1].authors == "Ann"
    and r[1].page == 1 and r[1].start_time == 1000 and r[1].duration == 30 and r[1].total_pages == 300)
check("readSince last scanned", r.last == 4 and r.full == false, tostring(r.last))

local w = db:readSince(1, 2)
check("readSince window of skipped rows is empty but reports last", #w == 0 and w.last == 3 and w.full == true,
    #w .. " " .. tostring(w.last))
local e = db:readSince(4, 10)
check("readSince past end", #e == 0 and e.last == nil and e.full == false)

-- Pulled: one row for the existing book (conflict, longer duration wins),
-- one shorter conflict (kept), and a new book.
local pulled = {
    { document = "md5local", title = "Local Book", authors = "Ann", page = 1, start_time = 1000, duration = 50, total_pages = 300 },
    { document = "md5local", title = "Local Book", authors = "Ann", page = 3, start_time = 1200, duration = 10, total_pages = 300 },
    { document = "md5other", title = "Other", authors = "", page = 5, start_time = 5000, duration = 60, total_pages = 99 },
    { document = "md5other", title = "Other", authors = "", page = 6, start_time = 5060, duration = 70, total_pages = 99 },
}
check("insertRecords count", db:insertRecords(pulled) == 4)
check("insertRecords adds only new rows", db:maxRowid() == 6, db:maxRowid())
check("insertRecords is idempotent", db:insertRecords(pulled) == 4 and db:maxRowid() == 6, db:maxRowid())

conn = SQ3.open(path)
local function one(sql)
    local stmt = conn:prepare(sql)
    local row = stmt:step()
    local out = row and { tonumber(row[1]) or row[1], tonumber(row[2]) or row[2], tonumber(row[3]) or row[3] }
    stmt:close()
    return out
end
check("conflict keeps longer duration", one("SELECT duration FROM page_stat_data WHERE id_book = 1 AND page = 1")[1] == 50)
check("conflict keeps existing longer", one("SELECT duration FROM page_stat_data WHERE id_book = 1 AND page = 3")[1] == 40)
local b = one("SELECT id, total_read_time, total_read_pages FROM book WHERE md5 = 'md5other'")
check("new book created with totals", b and b[2] == 130 and b[3] == 2, b and (b[2] .. "/" .. b[3]))
local l = one("SELECT total_read_time, total_read_pages, last_open FROM book WHERE md5 = 'md5local'")
check("existing book totals refreshed", l[1] == 90 and l[2] == 3 and l[3] == 1200, table.concat(l, "/"))
check("one book per key", one("SELECT count(*) FROM book")[1] == 3)
conn:close()

local f = db:readFrom(1100)
local total = 0
for _i, x in ipairs(f) do total = total + x.duration end
check("readFrom filters by start and duration", #f == 4 and total == 40 + 20 + 60 + 70, #f .. " " .. total)
local has_book = false
for _i, x in ipairs(f) do if x.md5 == "md5other" and x.book == "Other" then has_book = true end end
check("readFrom carries md5 and title", has_book)

local ok = pcall(db.insertRecords, db, { { document = "x", title = "T", authors = "A", page = 1,
    start_time = 1, duration = 1, total_pages = 1 }, { document = "x" } })
check("bad record rolls back", not ok and db:maxRowid() == 6, db:maxRowid())

os.remove(path)
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
