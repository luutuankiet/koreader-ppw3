--[[--
Tests for syncedhistory_goals.lua. Plain luajit, no KOReader, any time zone:
  luajit test_goals.lua
]]

local this_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = this_dir .. "/?.lua;" .. package.path
local Goals = require("syncedhistory_goals")

local passed, failed = 0, 0
local function check(c, msg) if not c then error(msg or "check failed", 2) end end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end
local function test(name, f)
    local ok, err = pcall(f)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end

-- Local time on a given day. 2026-11-18 is a Wednesday.
local function at(y, m, d, h, mi) return os.time{ year = y, month = m, day = d, hour = h, min = mi or 0, sec = 0 } end
local NOW = at(2026, 11, 18, 20)
local function rec(t, mins, kind, book) return { start_time = t, duration = mins * 60, kind = kind, book = book or "A" } end

test("a visit crossing midnight is split between both days", function()
    local days = Goals.addRecords({}, { { start_time = at(2026, 11, 17, 23, 59), duration = 120, book = "A" } })
    eq(days["2026-11-17"].total, 60, "before midnight")
    eq(days["2026-11-18"].total, 60, "after midnight")
    eq(days["2026-11-18"].books.A, 60, "book split too")
end)

test("records without a duration are ignored", function()
    local days = Goals.addRecords({}, { { start_time = NOW, duration = 0 }, { start_time = NOW } })
    check(next(days) == nil, "nothing added")
end)

test("today, percent and minutes to go", function()
    local days = Goals.addRecords({}, { rec(at(2026, 11, 18, 8), 20), rec(at(2026, 11, 18, 9), 5) })
    local s = Goals.summary{ days = days, now = NOW, goal_min = 60 }
    eq(s.today, 25 * 60, "today")
    eq(s.pct, 41, "pct")
    eq(s.to_go, 35, "to go")
    check(not s.met_today, "not met")
end)

test("a met day has nothing to go and counts in the streak", function()
    local days = Goals.addRecords({}, {
        rec(at(2026, 11, 16, 8), 60), rec(at(2026, 11, 17, 8), 61), rec(at(2026, 11, 18, 8), 60),
    })
    local s = Goals.summary{ days = days, now = NOW, goal_min = 60 }
    check(s.met_today, "met")
    eq(s.to_go, 0, "to go")
    eq(s.streak, 3, "streak")
end)

test("an unmet today keeps the streak ending yesterday", function()
    local days = Goals.addRecords({}, { rec(at(2026, 11, 16, 8), 60), rec(at(2026, 11, 17, 8), 60), rec(at(2026, 11, 18, 8), 10) })
    eq(Goals.summary{ days = days, now = NOW, goal_min = 60 }.streak, 2, "streak")
end)

test("a missed day breaks the streak", function()
    local days = Goals.addRecords({}, { rec(at(2026, 11, 15, 8), 60), rec(at(2026, 11, 17, 8), 60) })
    eq(Goals.summary{ days = days, now = NOW, goal_min = 60 }.streak, 1, "streak")
end)

test("best streak is the longest run of met days", function()
    local recs = {}
    for d = 1, 4 do recs[#recs + 1] = rec(at(2026, 10, 28 + d, 8), 60) end  -- Oct 29 .. Nov 1
    recs[#recs + 1] = rec(at(2026, 11, 10, 8), 60)
    local s = Goals.summary{ days = Goals.addRecords({}, recs), now = NOW, goal_min = 60 }
    eq(s.best_streak, 4, "best across a month end")
    eq(s.streak, 0, "current")
end)

test("a short day never counts as met", function()
    local days = Goals.addRecords({}, { rec(at(2026, 11, 18, 8), 59) })
    local s = Goals.summary{ days = days, now = NOW, goal_min = 60 }
    check(not s.met_today and s.streak == 0 and s.best_streak == 0, "unmet")
end)

test("the week starts on Monday by default, with a 7 x goal target", function()
    local days = Goals.addRecords({}, { rec(at(2026, 11, 16, 8), 30), rec(at(2026, 11, 22, 8), 15), rec(at(2026, 11, 15, 8), 99) })
    local w = Goals.summary{ days = days, now = NOW, goal_min = 60 }.week
    eq(w.days[1].key, "2026-11-16", "Monday first")
    eq(w.days[7].key, "2026-11-22", "Sunday last")
    eq(w.total, 45 * 60, "total excludes the Sunday before")
    eq(w.target, 7 * 3600, "target")
    check(w.days[3].today and w.days[7].future and not w.days[1].future, "today and future")
end)

test("a Sunday start and paging back a week", function()
    local s = Goals.summary{ days = {}, now = NOW, goal_min = 60, week_start = Goals.SUNDAY, week_offset = -1 }
    eq(s.week.days[1].key, "2026-11-08", "previous Sunday-start week")
    eq(os.date("*t", s.week.days[1].time).wday, 1, "a Sunday")
end)

test("a Monday itself starts its own week", function()
    local s = Goals.summary{ days = {}, now = at(2026, 11, 16, 0, 30), goal_min = 60 }
    eq(s.week.days[1].key, "2026-11-16", "same day")
end)

test("month total, target, met days, kinds and top 3 books", function()
    local days = Goals.addRecords({}, {
        rec(at(2026, 11, 2, 8), 60, "book", "B1"),
        rec(at(2026, 11, 3, 8), 70, "gdrive", "Doc"),
        rec(at(2026, 11, 4, 8), 10, "rss", "Art"),
        rec(at(2026, 11, 5, 8), 5, "book", "B2"),
        rec(at(2026, 10, 31, 8), 500, "book", "Old"),
    })
    local m = Goals.summary{ days = days, now = NOW, goal_min = 60 }.month
    eq(m.total, 145 * 60, "total")
    eq(m.target, 30 * 3600, "November has 30 days")
    eq(m.met_days, 2, "met days")
    eq(m.by_kind.gdrive, 70 * 60, "drive")
    eq(m.by_kind.rss, 10 * 60, "rss")
    eq(#m.top_books, 3, "top 3")
    eq(m.top_books[1].title, "Doc", "first")
    eq(m.top_books[3].title, "Art", "third")
end)

test("kinds switched off do not count toward the goal", function()
    local days = Goals.addRecords({}, { rec(at(2026, 11, 18, 8), 50, "book"), rec(at(2026, 11, 18, 9), 20, "rss") })
    local s = Goals.summary{ days = days, now = NOW, goal_min = 60, counted = { rss = false } }
    eq(s.today, 50 * 60, "rss left out")
    check(not s.met_today, "not met without rss")
    check(Goals.summary{ days = days, now = NOW, goal_min = 60 }.met_today, "met with rss")
    eq(s.month.by_kind.rss, 20 * 60, "split still shows every kind")
end)

test("days in month and February", function()
    eq(Goals.daysInMonth(at(2028, 2, 10, 12)), 29, "leap")
    eq(Goals.daysInMonth(at(2026, 2, 10, 12)), 28, "plain")
    eq(Goals.daysInMonth(at(2026, 12, 31, 12)), 31, "December")
end)

test("formatting helpers", function()
    eq(Goals.duration(42 * 60 + 59), "42 min", "minutes")
    eq(Goals.duration(65 * 60), "1 h 05 min", "hours")
    eq(Goals.bar(0.5, 4), "\226\150\136\226\150\136\226\150\145\226\150\145", "half bar")
    eq(Goals.bar(2, 2), "\226\150\136\226\150\136", "full bar")
    eq(Goals.clampGoal(2), 5, "min")
    eq(Goals.clampGoal(999), 600, "max")
    eq(Goals.clampGoal(33), 35, "step")
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
