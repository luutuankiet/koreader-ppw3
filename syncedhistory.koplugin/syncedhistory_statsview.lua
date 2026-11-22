--[[--
Text of the goal strip, the Stats tab rows and the goal-met message, from a
Goals.summary. Pure Lua 5.1, no KOReader.

    local text = StatsView.strip(summary, _)
    local rows = StatsView.rows(summary, { gettext = _, week_offset = 0 })
    -- rows[i] = { text, action = nil|"prev"|"next"|"calendar", dim }
]]

local Goals = require("syncedhistory_goals")

local StatsView = {}

StatsView.CHECK = "\226\156\147"   -- ✓
StatsView.FIRE = "\240\159\148\165" -- 🔥 (KOReader's fonts may not draw it, so not used)
StatsView.DOT = " \194\183 "        -- " · "

local function id(s) return s end

-- "Today 23 / 60 min ████░░░░░░ 38% · 37 min to go · 3-day streak · Week 2 h 10 min / 7 h 00 min"
function StatsView.strip(s, gettext)
    local _ = gettext or id
    local parts = {
        string.format("%s %d / %d min %s %d%%", _("Today"), Goals.minutes(s.today), s.goal,
            Goals.bar(s.today / math.max(1, s.goal * 60), 8), s.pct),
    }
    if s.met_today then
        parts[#parts + 1] = _("goal met") .. " " .. StatsView.CHECK
    else
        parts[#parts + 1] = string.format(_("%d min to go"), s.to_go)
    end
    if (s.streak or 0) > 0 then parts[#parts + 1] = string.format(_("%d-day streak"), s.streak) end
    if s.week then
        parts[#parts + 1] = string.format("%s %s / %s", _("Week"), Goals.duration(s.week.total),
            Goals.duration(s.week.target))
    end
    return table.concat(parts, StatsView.DOT)
end

local DAY_NAMES = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }

local function dayName(day, gettext)
    local y, m, d = day.key:match("^(%d+)-(%d+)-(%d+)$")
    local wday = tonumber(os.date("%w", os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }))
    return gettext(DAY_NAMES[wday == 0 and 7 or wday]) .. " " .. day.key:sub(6)
end

--[[--
The Stats tab: the week's days, week paging, the month against its target,
days met and best streak, time by kind and the top books, "Open calendar".
opts: gettext, week_offset (0 = this week), calendar (false hides the row).
]]
function StatsView.rows(s, opts)
    opts = opts or {}
    local _ = opts.gettext or id
    local goal_s = math.max(1, s.goal * 60)
    local out = {}
    local function add(text, action, dim) out[#out + 1] = { text = text, action = action, dim = dim } end
    local w = s.week
    local first, last = w.days[1].key, w.days[#w.days].key
    add(string.format("%s %s – %s: %s / %s", _("Week"), first:sub(6), last:sub(6),
        Goals.duration(w.total), Goals.duration(w.target)), nil, true)
    for _i, day in ipairs(w.days) do
        local text = string.format("%s  %s  %s", dayName(day, _), Goals.bar(day.secs / goal_s, 10),
            day.future and "–" or Goals.duration(day.secs))
        if day.met then text = text .. "  " .. StatsView.CHECK end
        if day.today then text = text .. "  (" .. _("today") .. ")" end
        add(text, nil, day.future)
    end
    add("◀ " .. _("Previous week"), "prev")
    if (opts.week_offset or 0) < 0 then add(_("Next week") .. " ▶", "next") end
    local m = s.month
    add(string.format("%s: %s / %s (%d%%)", _("This month"), Goals.duration(m.total), Goals.duration(m.target),
        math.floor(m.total * 100 / math.max(1, m.target))))
    add(string.format(_("Days met: %d · best streak: %d days"), m.met_days, s.best_streak or 0))
    local kinds = {}
    for _i, kind in ipairs(Goals.KINDS) do
        local secs = m.by_kind[kind]
        if secs and secs > 0 then kinds[#kinds + 1] = _(Goals.KIND_TITLES[kind]) .. " " .. Goals.duration(secs) end
    end
    if #kinds > 0 then add(table.concat(kinds, StatsView.DOT)) end
    for i, b in ipairs(m.top_books) do
        add(string.format("%d. %s · %s", i, b.title ~= "" and b.title or _("Untitled"), Goals.duration(b.secs)))
    end
    if opts.calendar ~= false then add(_("Open calendar"), "calendar") end
    return out
end

-- "Goal met today, 3-day streak"
function StatsView.goalMetText(s, gettext)
    local _ = gettext or id
    if (s.streak or 0) > 1 then
        return string.format(_("Goal met today, %d-day streak"), s.streak)
    end
    return _("Goal met today")
end

-- A record's kind: this device's sidecars first, then the server's list, else a book.
function StatsView.kindOf(md5, local_kinds, remote_kinds)
    return (local_kinds and local_kinds[md5]) or (remote_kinds and remote_kinds[md5]) or "book"
end

-- StatsDb:readFrom rows -> Goals records.
function StatsView.records(rows, local_kinds, remote_kinds)
    local out = {}
    for i, r in ipairs(rows) do
        out[i] = { start_time = r.start_time, duration = r.duration, book = r.book,
            kind = StatsView.kindOf(r.md5, local_kinds, remote_kinds) }
    end
    return out
end

return StatsView
