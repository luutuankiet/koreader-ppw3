--[[--
Tests for syncedhistory_cleanup.lua and syncedhistory_tabs.lua. Plain luajit,
no KOReader:
  luajit test_cleanup.lua
]]

local this_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = this_dir .. "/?.lua;" .. package.path
local Cleanup = require("syncedhistory_cleanup")
local Tabs = require("syncedhistory_tabs")

local passed, failed = 0, 0
local function check(c, msg) if not c then error(msg or "check failed", 2) end end
local function test(name, f)
    local ok, err = pcall(f)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end

local function key(name) return "k:" .. name end
local read_done = { opened = true, annotations = 0 }
local function file(name, sidecar)
    return { path = "/G/" .. name, name = name, sidecar = sidecar }
end

test("only a fresh list may remove anything", function()
    local plan = Cleanup.decide{ fresh = false, list = {}, files = { file("A.epub", read_done) }, key_for = key }
    check(plan.refused and #plan.delete == 0, "cached list refused")
    plan = Cleanup.decide{ fresh = true, list = nil, files = { file("A.epub", read_done) }, key_for = key }
    check(plan.refused and #plan.delete == 0, "missing list refused")
end)

test("each rule keeps its book, with the reason", function()
    local list = { { document = "k:Listed.epub" },
                   { document = "k:New name.epub", aliases = { { document = "k:New name.epub" }, { document = "k:Old name.epub" } } } }
    local plan = Cleanup.decide{
        fresh = true, list = list, key_for = key, open_path = "/G/Open.epub",
        files = {
            file("Listed.epub", read_done),
            file("Old name.epub", read_done),
            file("Open.epub", read_done),
            file("Never.epub", { opened = false, annotations = 0 }),
            file("Noted.epub", { opened = true, annotations = 2 }),
            file("Bare.epub", nil),
            file("Done.epub", read_done),
        },
    }
    check(#plan.delete == 1 and plan.delete[1] == "/G/Done.epub", "only Done goes")
    local why = {}
    for _i, s in ipairs(plan.skipped) do why[s.path] = s.reason end
    check(why["/G/Listed.epub"] == Cleanup.IN_LIST, "listed")
    check(why["/G/Old name.epub"] == Cleanup.IN_LIST, "alias counts")
    check(why["/G/Open.epub"] == Cleanup.OPEN, "open")
    check(why["/G/Never.epub"] == Cleanup.NOT_OPENED, "never opened")
    check(why["/G/Noted.epub"] == Cleanup.ANNOTATED, "annotated")
    check(why["/G/Bare.epub"] == Cleanup.NO_SIDECAR, "no sidecar")
end)

test("sidecar facts: position or percentage means opened; annotations in any key", function()
    local function reader(t) return function(k) return t[k] end end
    check(not Cleanup.facts(reader{ gdriveepub_source = { id = "x" } }).opened, "download only")
    check(Cleanup.facts(reader{ percent_finished = 0.5 }).opened, "percent")
    check(Cleanup.facts(reader{ last_xpointer = "/body" }).opened, "xpointer")
    check(Cleanup.facts(reader{ last_page = 3 }).opened, "page")
    check(Cleanup.facts(reader{ annotations = { {}, {} } }).annotations == 2, "annotations")
    check(Cleanup.facts(reader{ annotations = {}, bookmarks = { {} }, highlight = { [3] = { {}, {} } } }).annotations == 3, "old keys")
end)

test("toast text", function()
    check(Cleanup.message(0) == nil, "none")
    check(Cleanup.message(1) == "Removed 1 finished Drive doc", "one")
    check(Cleanup.message(2) == "Removed 2 finished Drive docs", "two")
end)

local NOW = 1795255200
local DAY = 86400
local function row(text, age, device_id, p, extra)
    local r = { text = text, timestamp = age and NOW - age or nil, device_id = device_id, percentage = p }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

test("tabs split by age and by who pushed after the last visit", function()
    local rows = {
        row("mine recent", 2 * 3600, "ME", 0.3),
        row("theirs recent", 3600, "OTHER", 0.5),
        row("theirs before visit", 3 * DAY, "OTHER", 0.2),
        row("old done", 30 * DAY, "OTHER", 1.0),
        row("old reading", 40 * DAY, "ME", 0.4),
        row("no time", nil, "OTHER", 0.1),
    }
    local t = Tabs.split(rows, { now = NOW, device_id = "ME", last_seen = NOW - DAY })
    check(#t.new == 1 and t.new[1].text == "theirs recent", "new: other device after last visit")
    check(#t.recent == 3 and t.recent[1].text == "theirs recent" and t.recent[3].text == "theirs before visit", "recent newest first")
    check(#t.old == 3, "old count")
    check(t.old[1].text == "old reading" and t.old[2].text == "no time" and t.old[3].text == "old done", "finished last")
    check(rows[2].is_new and not rows[1].is_new, "is_new marked")
end)

test("never opened before: everything from other devices is new", function()
    local t = Tabs.split({ row("a", 100 * DAY, "OTHER", 0.1), row("b", 10, "ME", 0.1) }, { now = NOW, device_id = "ME" })
    check(#t.new == 1 and t.new[1].text == "a", "first visit")
end)

test("relative times", function()
    check(Tabs.relative(NOW - 10, NOW) == "just now", "now")
    check(Tabs.relative(NOW - 300, NOW) == "5m ago", "minutes")
    check(Tabs.relative(NOW - 2 * 3600, NOW) == "2h ago", "hours")
    check(Tabs.relative(NOW - 30 * 3600, NOW) == "yesterday", "yesterday")
    check(Tabs.relative(NOW - 3 * DAY, NOW) == "3 days ago", "days")
    check(Tabs.relative(NOW - 21 * DAY, NOW) == "3 weeks ago", "weeks")
    check(Tabs.relative(NOW - 90 * DAY, NOW) == "3 months ago", "months")
    check(Tabs.relative(NOW - 400 * DAY, NOW) == "1 year ago", "year")
    check(Tabs.relative(nil, NOW) == nil, "none")
end)

test("progress bar and row text", function()
    check(Tabs.bar(0.42):match(" 42%%$"), "percent")
    check(Tabs.bar(0.996) == "done", "done")
    check(Tabs.bar(nil):match(" 0%%$"), "nil")
    local r = row("Book.epub", 2 * 3600, "OTHER", 0.5, { is_new = true, missing = true, has_drive = true, device = "Kindle" })
    local text, right = Tabs.rowText(r, { now = NOW })
    check(text == Tabs.MARK_NEW .. " Book.epub \194\183 Kindle \194\183 2h ago", "row text: " .. text)
    check(right:find(Tabs.DRIVE, 1, true) == 1, "drive mark")
    local done = row("Done.epub", 9 * DAY, "ME", 1, { device = "Kindle" })
    text, right = Tabs.rowText(done, { now = NOW, title = function() return "Local title" end })
    check(text:find(Tabs.MARK_DONE .. " Local title", 1, true) == 1 and right == "done", "done row")
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
