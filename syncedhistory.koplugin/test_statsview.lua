-- Tests for syncedhistory_statsview.lua. Run: luajit test_statsview.lua
local this_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = this_dir .. "/?.lua;" .. package.path
local Goals = require("syncedhistory_goals")
local StatsView = require("syncedhistory_statsview")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("ok    " .. name)
    else failed = failed + 1; print("FAIL  " .. name, detail or "") end
end

local now = os.time{ year = 2026, month = 11, day = 18, hour = 20 } -- a Wednesday
local function at(day, hour) return os.time{ year = 2026, month = 11, day = day, hour = hour } end
local rows = {
    { start_time = at(18, 9), duration = 1500, md5 = "a", book = "Alpha" },
    { start_time = at(17, 9), duration = 3600, md5 = "d", book = "Drive Doc" },
    { start_time = at(16, 9), duration = 3700, md5 = "r", book = "Remote Drive" },
}
local recs = StatsView.records(rows, { d = "gdrive" }, { r = "gdrive", d = "rss" })
check("kind: local beats remote, else book", recs[1].kind == "book" and recs[2].kind == "gdrive" and recs[3].kind == "gdrive")

local s = Goals.summary{ days = Goals.addRecords({}, recs), now = now, goal_min = 60 }
local strip = StatsView.strip(s)
check("strip shows today, to go, streak, week", strip:find("Today 25 / 60 min", 1, true)
    and strip:find("35 min to go", 1, true) and strip:find("2-day streak", 1, true)
    and strip:find("Week 2 h 26 min / 7 h 00 min", 1, true), strip)

local r = StatsView.rows(s, { week_offset = 0 })
check("rows: header + 7 days", r[1].text:find("Week 11-16", 1, true) and r[2].text:find("^Mon 11%-16") ~= nil, r[2].text)
check("met day has a check", r[2].text:find(StatsView.CHECK, 1, true) and not r[4].text:find(StatsView.CHECK, 1, true))
check("today is marked, future dimmed", r[4].text:find("(today)", 1, true) and r[5].dim == true)
check("this week has prev but no next", r[9].action == "prev" and r[10].action ~= "next")
local last = r[#r]
check("calendar row last", last.action == "calendar")
local joined = {}
for _i, x in ipairs(r) do joined[#joined + 1] = x.text end
joined = table.concat(joined, "\n")
check("month, kinds and top books", joined:find("This month: 2 h 26 min", 1, true)
    and joined:find("Books 25 min · Drive docs 2 h 01 min", 1, true) and joined:find("1. Remote Drive", 1, true), joined)
check("past week shows next", StatsView.rows(s, { week_offset = -1 })[10].action == "next")
check("calendar can be hidden", StatsView.rows(s, { calendar = false })[#r - 1].action ~= "calendar")

local met = Goals.summary{ days = Goals.addRecords({}, recs), now = at(17, 20), goal_min = 60 }
check("goal met text with streak", StatsView.goalMetText(met) == "Goal met today, 2-day streak", StatsView.goalMetText(met))
check("strip says goal met", StatsView.strip(met):find("goal met", 1, true) ~= nil)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
