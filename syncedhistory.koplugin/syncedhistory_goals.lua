--[[--
Reading goal numbers for the synced reading list: day totals in local time,
the week and month against their targets, met days, streaks, the split by
kind and the top books. Pure Lua 5.1, no KOReader; the clock and the records
come from the caller.

A record is one page visit from KOReader's statistics database:
    { start_time = <epoch s>, duration = <s>, kind = "book"|"gdrive"|"rss", book = <title> }

    local days = Goals.addRecords({}, records)
    local s = Goals.summary{ days = days, now = os.time(), goal_min = 60 }
]]

local Goals = {}

Goals.DEFAULT_GOAL = 60       -- minutes a day
Goals.MIN_GOAL, Goals.MAX_GOAL, Goals.GOAL_STEP = 5, 600, 5
Goals.MONDAY, Goals.SUNDAY = 1, 7
Goals.KINDS = { "book", "gdrive", "rss" }
Goals.KIND_TITLES = { book = "Books", gdrive = "Drive docs", rss = "Articles" }

-- Local date of an epoch time, "YYYY-MM-DD".
function Goals.dayKey(t)
    return os.date("%Y-%m-%d", t)
end

-- Noon of the local day `n` days after the day of `t`. Noon keeps day
-- arithmetic clear of daylight saving jumps.
function Goals.shiftDay(t, n)
    local d = os.date("*t", t)
    return os.time{ year = d.year, month = d.month, day = d.day + (n or 0), hour = 12 }
end

-- Local midnight starting the day of `t`.
function Goals.midnight(t)
    local d = os.date("*t", t)
    return os.time{ year = d.year, month = d.month, day = d.day, hour = 0, min = 0, sec = 0 }
end

local function dayEntry(days, key)
    local e = days[key]
    if not e then
        e = { total = 0, kinds = {}, books = {} }
        days[key] = e
    end
    return e
end

--[[--
Add records into a day table, splitting a visit that crosses local midnight
between both days. Returns `days` keyed by Goals.dayKey.
]]
function Goals.addRecords(days, records)
    days = days or {}
    for _i, r in ipairs(records or {}) do
        local s, dur = tonumber(r.start_time), tonumber(r.duration)
        if s and dur and dur > 0 then
            local e = s + dur
            local kind = r.kind or "book"
            while s < e do
                local next_mid = Goals.midnight(Goals.shiftDay(s, 1))
                local chunk = math.min(e, next_mid) - s
                local entry = dayEntry(days, Goals.dayKey(s))
                entry.total = entry.total + chunk
                entry.kinds[kind] = (entry.kinds[kind] or 0) + chunk
                if r.book then entry.books[r.book] = (entry.books[r.book] or 0) + chunk end
                s = s + chunk
            end
        end
    end
    return days
end

-- Seconds of a day that count toward the goal. `counted` maps kind -> false
-- to leave a kind out; nil or missing means it counts.
function Goals.countable(entry, counted)
    if not entry then return 0 end
    if not counted then return entry.total end
    local n = 0
    for kind, secs in pairs(entry.kinds) do
        if counted[kind] ~= false then n = n + secs end
    end
    return n
end

local function met(days, key, goal_s, counted)
    return goal_s > 0 and Goals.countable(days[key], counted) >= goal_s
end

-- Days from 1 to 31 in the month of `t`.
function Goals.daysInMonth(t)
    local d = os.date("*t", t)
    return os.date("*t", os.time{ year = d.year, month = d.month + 1, day = 0, hour = 12 }).day
end

-- Noon of the first day of the week holding `t`; week_start 1 = Monday,
-- 7 = Sunday.
function Goals.weekStart(t, week_start)
    local wday = os.date("*t", t).wday            -- 1 = Sunday
    local iso = (wday + 5) % 7 + 1                -- 1 = Monday .. 7 = Sunday
    local back = (iso - (week_start or Goals.MONDAY)) % 7
    return Goals.shiftDay(t, -back)
end

--[[--
Everything the goal strip and the Stats tab show.

opts: days (from addRecords), now, goal_min, week_start, counted,
week_offset (0 = this week, -1 = last week).
]]
function Goals.summary(opts)
    local days, now = opts.days or {}, opts.now or os.time()
    local counted = opts.counted
    local goal_min = tonumber(opts.goal_min) or Goals.DEFAULT_GOAL
    local goal_s = goal_min * 60
    local today_key = Goals.dayKey(now)
    local today = Goals.countable(days[today_key], counted)
    local s = {
        goal = goal_min,
        today = today,
        pct = goal_s > 0 and math.floor(today * 100 / goal_s) or 0,
        met_today = met(days, today_key, goal_s, counted),
    }
    s.to_go = s.met_today and 0 or math.ceil((goal_s - today) / 60)

    -- Streak: consecutive met days ending today, or yesterday when today
    -- is not met yet.
    local n, t = 0, s.met_today and now or Goals.shiftDay(now, -1)
    while met(days, Goals.dayKey(t), goal_s, counted) do
        n = n + 1
        t = Goals.shiftDay(t, -1)
    end
    s.streak = n

    -- Best streak over every day loaded.
    local keys = {}
    for key in pairs(days) do
        if met(days, key, goal_s, counted) then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local best, run, prev = 0, 0, nil
    for _i, key in ipairs(keys) do
        local y, m, d = key:match("^(%d+)-(%d+)-(%d+)$")
        local noon = os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
        if prev and Goals.dayKey(Goals.shiftDay(prev, 1)) == key then run = run + 1 else run = 1 end
        prev = noon
        if run > best then best = run end
    end
    s.best_streak = best

    -- The week, from its first day, with the met days marked.
    local first = Goals.shiftDay(Goals.weekStart(now, opts.week_start), 7 * (opts.week_offset or 0))
    local week = { start = first, days = {}, total = 0, target = 7 * goal_min * 60 }
    for i = 0, 6 do
        local t_day = Goals.shiftDay(first, i)
        local key = Goals.dayKey(t_day)
        local secs = Goals.countable(days[key], counted)
        week.days[i + 1] = {
            key = key, time = t_day, secs = secs,
            met = met(days, key, goal_s, counted),
            future = key > today_key, today = key == today_key,
        }
        week.total = week.total + secs
    end
    s.week = week

    -- The month of `now`: total, target, met days, kinds and top books.
    local month_prefix = os.date("%Y-%m-", now)
    local month = { total = 0, target = Goals.daysInMonth(now) * goal_min * 60,
        met_days = 0, by_kind = {}, top_books = {} }
    local books = {}
    for key, entry in pairs(days) do
        if key:sub(1, #month_prefix) == month_prefix then
            month.total = month.total + Goals.countable(entry, counted)
            if met(days, key, goal_s, counted) then month.met_days = month.met_days + 1 end
            for kind, secs in pairs(entry.kinds) do
                month.by_kind[kind] = (month.by_kind[kind] or 0) + secs
            end
            for book, secs in pairs(entry.books) do books[book] = (books[book] or 0) + secs end
        end
    end
    for book, secs in pairs(books) do month.top_books[#month.top_books + 1] = { title = book, secs = secs } end
    table.sort(month.top_books, function(a, b)
        if a.secs ~= b.secs then return a.secs > b.secs end
        return a.title < b.title
    end)
    for i = #month.top_books, 4, -1 do month.top_books[i] = nil end
    s.month = month
    return s
end

-- Whole minutes, rounded down.
function Goals.minutes(secs)
    return math.floor((secs or 0) / 60)
end

-- "1 h 05 min" or "42 min".
function Goals.duration(secs)
    local m = Goals.minutes(secs)
    if m < 60 then return m .. " min" end
    return string.format("%d h %02d min", math.floor(m / 60), m % 60)
end

-- A text bar of `width` cells for a fraction 0..1 (over 1 is full).
function Goals.bar(frac, width)
    width = width or 10
    local filled = math.max(0, math.min(width, math.floor((frac or 0) * width + 0.5)))
    return string.rep("\226\150\136", filled) .. string.rep("\226\150\145", width - filled) -- █ ░
end

-- Clamp a daily goal to 5..600 in steps of 5.
function Goals.clampGoal(v)
    v = tonumber(v) or Goals.DEFAULT_GOAL
    v = math.floor(v / Goals.GOAL_STEP + 0.5) * Goals.GOAL_STEP
    return math.max(Goals.MIN_GOAL, math.min(Goals.MAX_GOAL, v))
end

return Goals
