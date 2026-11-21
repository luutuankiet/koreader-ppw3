-- Unit tests for gdriveepub_source.lua and the item parsing it relies on. Run: luajit test_source.lua
package.path = "./?.lua;" .. package.path
local Api = require("gdriveepub_api")
local Format = require("gdriveepub_format")
local Source = require("gdriveepub_source")
local pass, fail = 0, 0
local function eq(a, b, what)
    if a == b then pass = pass + 1 else fail = fail + 1
        print("FAIL " .. what .. ": got " .. tostring(a) .. ", want " .. tostring(b)) end
end

-- search words from a saved file name
eq(Source.searchQuery("Plan_ Q1_Q2 notes.epub"), "Plan Q1 Q2 notes", "underscores become word breaks, extension dropped")
eq(Source.searchQuery("Manual.pdf"), "Manual", "pdf extension dropped")

-- exact file-name matching
local items = {
    { id = "a", name = "Plan: Q1/Q2", kind = "doc" },  -- Plan_ Q1_Q2.epub
    { id = "b", name = "Plan Q1 Q2", kind = "doc" },   -- Plan Q1 Q2.epub
    { id = "c", name = "Plan: Q1/Q2", kind = "pdf" },  -- Plan_ Q1_Q2.pdf
    { id = "d", name = "Plan: Q1/Q2", kind = "doc" },  -- a second Doc with the same title
}
local m = Source.matchByFileName(items, "Plan_ Q1_Q2.epub", Format.fileName)
eq(#m, 2, "two docs map to the same name"); eq(m[1].id, "a", "first match"); eq(m[2].id, "d", "second match")
eq(#Source.matchByFileName(items, "plan_ q1_q2.epub", Format.fileName), 0, "case matters")
eq(#Source.matchByFileName(nil, "x.epub", Format.fileName), 0, "no items")

-- records
local r = Source.newRecord({ id = "a", modifiedTime = "2026-11-01T10:00:00.000Z" }, { ["x-modified-time"] = "2026-11-02T00:00:00.000Z" }, 0)
eq(r.id, "a", "record id"); eq(r.modified, "2026-11-02T00:00:00.000Z", "header wins")
eq(r.downloaded_at, "1970-01-01T00:00:00Z", "downloaded_at is UTC RFC 3339")
eq(Source.newRecord({ id = "a", modified_time = "M" }, { ["x-modified-time"] = "" }).modified, "M", "falls back to the item")

local store, flushed = {}, 0
local fake = {
    readSetting = function(_, k) return store[k] end,
    saveSetting = function(self, k, v) store[k] = v return self end,
    flush = function() flushed = flushed + 1 end,
}
eq(Source.read(fake), nil, "no record yet")
Source.write(fake, r)
eq(flushed, 1, "write flushes"); eq(Source.read(fake).id, "a", "record read back")
store[Source.KEY] = { modified = "x" }
eq(Source.read(fake), nil, "record without id ignored")

-- item parsing
local it = Api.item({ id = "x", name = "", kind = "pdf", modifiedTime = "T", trashed = true })
eq(it.name, "Untitled", "empty name"); eq(it.modifiedTime, "T", "modifiedTime"); eq(it.modified_time, "T", "same value")
eq(it.trashed, true, "trashed kept")
eq(Api.item({ id = "x", modified_time = "U" }).modifiedTime, "U", "list shape fills modifiedTime")
eq(Api.item({ name = "no id" }), nil, "no id")
eq(Api.infoRequest("https://s", "k", "a b").url, "https://s/api/files/a%20b", "info url")

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
