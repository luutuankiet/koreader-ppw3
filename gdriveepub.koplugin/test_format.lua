-- Unit tests for gdriveepub_format.lua. Run: luajit test_format.lua
package.path = "./?.lua;" .. package.path
local F = require("gdriveepub_format")
local pass, fail = 0, 0
local function eq(a, b, what)
    if a == b then pass = pass + 1 else fail = fail + 1
        print("FAIL " .. what .. ": got " .. tostring(a) .. ", want " .. tostring(b)) end
end
local DOT = "\194\183"

eq(F.parseIso("1970-01-01T00:00:00Z"), 0, "epoch")
eq(F.parseIso("2026-11-15T10:20:30.123Z"), 1794738030, "fractional seconds")
eq(F.parseIso("2024-02-29T00:00:00Z") - F.parseIso("2024-02-28T00:00:00Z"), 86400, "leap day")
eq(F.parseIso("garbage"), nil, "bad iso"); eq(F.parseIso(nil), nil, "nil iso")

eq(F.date("2026-11-15T23:30:00Z", 0), "2026-11-15", "utc date")
eq(F.date("2026-11-15T23:30:00Z", 7 * 3600), "2026-11-16", "offset rolls day")
eq(F.dateTime("2026-11-15T23:30:00Z", 7 * 3600), "2026-11-16 06:30", "date time with offset")
eq(F.date(nil, 0), nil, "nil date")
eq(type(F.localOffset()), "number", "local offset is a number")

eq(F.kindLabel("pdf"), "PDF", "pdf label"); eq(F.kindLabel("epub"), "EPUB", "epub label")
eq(F.kindLabel("x"), "DOC", "fallback label")
local file = { name = "Guide", kind = "doc", modified_time = "2026-11-15T10:00:00Z", created_time = "2026-10-02T10:00:00Z" }
eq(F.metaLine(file, 0), "Updated 2026-11-15 " .. DOT .. " Created 2026-10-02 " .. DOT .. " DOC", "meta line")
eq(F.metaLine({ kind = "pdf" }, 0), "Updated ? " .. DOT .. " Created ? " .. DOT .. " PDF", "meta line unknown times")
local d = F.details(file, 0)
eq(d:find("Guide", 1, true) == 1, true, "details starts with title")
eq(d:find("Updated: 2026-11-15 10:00", 1, true) ~= nil, true, "details updated")
eq(d:find("Created: 2026-10-02 10:00", 1, true) ~= nil, true, "details created")
eq(d:find("downloads as EPUB", 1, true) ~= nil, true, "details doc note")

eq(F.size(nil), nil, "size nil"); eq(F.size(10), "1 KB", "size min 1 KB")
eq(F.size(3 * 1024 * 1024), "3.0 MB", "size MB")

eq(F.safeName('a/b\\c:d*e?f"g<h>i|j'), "a_b_c_d_e_f_g_h_i_j", "FAT32 chars")
eq(F.safeName("  ..dots and\tspace..  "), "dots and space", "trim dots and spaces")
eq(F.safeName(""), "Untitled", "empty name")
local long = string.rep("é", 100) -- 200 bytes
local cut = F.safeName(long)
eq(#cut <= F.MAX_NAME_BYTES, true, "cut to max bytes"); eq(#cut % 2, 0, "no split UTF-8 char")
eq(F.fileName({ name = "Report", kind = "doc" }), "Report.epub", "doc to epub")
eq(F.fileName({ name = "Paper.pdf", kind = "pdf" }), "Paper.pdf", "no double pdf")
eq(F.fileName({ name = "Book", kind = "epub" }), "Book.epub", "epub ext")
eq(F.joinPath("/mnt/us/", "/GDrive/", "a.epub"), "/mnt/us/GDrive/a.epub", "join path")

print(string.format("test_format: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
