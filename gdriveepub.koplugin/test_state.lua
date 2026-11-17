-- Unit tests for gdriveepub_state.lua. Run: luajit test_state.lua
package.path = "./?.lua;" .. package.path
local S = require("gdriveepub_state")
local pass, fail = 0, 0
local function eq(a, b, what)
    if a == b then pass = pass + 1 else fail = fail + 1
        print("FAIL " .. what .. ": got " .. tostring(a) .. ", want " .. tostring(b)) end
end
local DOT = " \194\183 "

local s = S.new()
eq(s.view, "recent", "starts on recent"); eq(s.sort, "viewed", "recent sorts by opened")
local p = S.params(s)
eq(p.view, "recent", "params view"); eq(p.q, nil, "no q on recent"); eq(p.page_size, 25, "page size")
eq(p.modified_within, nil, "no empty filter param")
eq(S.subtitle(s), "Recent" .. DOT .. "by opened", "recent subtitle")

eq(S.setSearch(s, "  dbt guide "), "search", "search view"); eq(s.q, "dbt guide", "q trimmed")
eq(s.sort, "modified", "search sorts by updated"); eq(S.params(s).q, "dbt guide", "q param")
eq(S.setSearch(s, "   "), "recent", "blank search goes recent")

S.setFilter(s, "modified_within", "1w"); S.setFilter(s, "created_within", "3m")
eq(S.filterCount(s), 2, "two filters"); eq(S.params(s).created_within, "3m", "created param")
eq(S.subtitle(s), "Recent" .. DOT .. "updated 1 week" .. DOT .. "created 3 months" .. DOT .. "by opened", "filter subtitle")
eq(pcall(S.setFilter, s, "modified_within", "2y"), false, "bad filter value")
eq(pcall(S.setFilter, s, "size", "1d"), false, "bad filter name")
S.clearFilters(s); eq(S.filterCount(s), 0, "filters cleared")

S.setSort(s, "name"); eq(S.params(s).sort, "name", "sort param")
eq(pcall(S.setSort, s, "size"), false, "bad sort")
eq(S.params(s, "TOK").page_token, "TOK", "page token param")

S.addPage(s, { { id = "a" }, { id = "b" } }, "T1")
eq(#s.files, 2, "first page"); eq(S.hasMore(s), true, "has more"); eq(s.loaded, true, "loaded")
S.addPage(s, { { id = "b" }, { id = "c" } }, nil)
eq(#s.files, 3, "dedupe by id"); eq(S.hasMore(s), false, "no more")
S.setSort(s, "created"); eq(#s.files, 0, "sort change resets files"); eq(s.loaded, false, "not loaded")

eq(S.pageCount(0, 6), 1, "empty is one page"); eq(S.pageCount(13, 6), 3, "page count rounds up")
eq(S.pageLabel(2, 3, true), "Page 2 of 3+", "label with more"); eq(S.pageLabel(1, 1, false), "Page 1 of 1", "label")

print(string.format("test_state: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
