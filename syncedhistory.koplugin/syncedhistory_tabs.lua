--[[--
The reading list's three tabs and the text of each row. Pure logic, no
KOReader modules.

    local Tabs = require("syncedhistory_tabs")
    local t = Tabs.split(rows, { now = os.time(), device_id = "ABC", last_seen = 1795000000 })
    -- t.new, t.recent, t.old: rows from ListView.rows, newest first; in t.old
    -- finished books come last. Every row gets row.is_new.
    Tabs.relative(ts, now)          -- "2h ago", "yesterday", "3 weeks ago"
    Tabs.bar(0.42)                  -- "████░░░░░░ 42%", "done" when finished
]]

local Tabs = {}

Tabs.NEW = "new"
Tabs.RECENT = "recent"
Tabs.OLD = "old"
Tabs.ORDER = { Tabs.NEW, Tabs.RECENT, Tabs.OLD }
Tabs.TITLES = { new = "New", recent = "Recent", old = "Old" }

Tabs.WEEK = 7 * 24 * 3600
Tabs.FINISHED = 0.99

Tabs.MARK_NEW = "\226\151\143"      -- ●
Tabs.MARK_DONE = "\226\156\147"     -- ✓
Tabs.DRIVE = "\226\172\135 Drive"   -- ⬇ Drive
Tabs.DONE = "done"
Tabs.JUST_NOW = "just now"
Tabs.YESTERDAY = "yesterday"
Tabs.EMPTY = {
    new = "Nothing new from your other devices.",
    recent = "Nothing read in the last 7 days.",
    old = "Nothing older than 7 days.",
}

local function identity(s) return s end

function Tabs.finished(row)
    return type(row.percentage) == "number" and row.percentage >= Tabs.FINISHED
end

local function ts(row) return type(row.timestamp) == "number" and row.timestamp or 0 end

local function newestFirst(a, b)
    if ts(a) ~= ts(b) then return ts(a) > ts(b) end
    return tostring(a.text) < tostring(b.text)
end

--[[--
Split rows into the tabs.

@tparam table rows from ListView.rows
@tparam table opts
  now        seconds
  device_id  this device's progress sync id
  last_seen  when the list was last left on this device, nil when never
@treturn table { new, recent, old }
  new: the latest push came from another device after last_seen. Recent: pushed
  in the last 7 days. Old: the rest, finished books last. A New book is in
  Recent or Old as well.
]]
function Tabs.split(rows, opts)
    local now = opts.now or os.time()
    local seen = opts.last_seen or 0
    local out = { new = {}, recent = {}, old = {} }
    for _i, row in ipairs(rows or {}) do
        row.is_new = row.device_id ~= nil and row.device_id ~= opts.device_id
            and ts(row) > seen or nil
        if row.is_new then out.new[#out.new + 1] = row end
        if row.timestamp and now - row.timestamp <= Tabs.WEEK then
            out.recent[#out.recent + 1] = row
        else
            out.old[#out.old + 1] = row
        end
    end
    table.sort(out.new, newestFirst)
    table.sort(out.recent, newestFirst)
    table.sort(out.old, function(a, b)
        local fa, fb = Tabs.finished(a), Tabs.finished(b)
        if fa ~= fb then return fb end
        return newestFirst(a, b)
    end)
    return out
end

local function plural(n, unit, _)
    return string.format(_("%d " .. unit .. (n == 1 and "" or "s") .. " ago"), n)
end

--- "just now", "5m ago", "2h ago", "yesterday", "3 days ago", "2 weeks ago",
--- "4 months ago", "1 year ago"; nil when there is no time.
function Tabs.relative(t, now, gettext)
    local _ = gettext or identity
    if type(t) ~= "number" then return nil end
    local d = (now or os.time()) - t
    if d < 60 then return _(Tabs.JUST_NOW) end
    if d < 3600 then return string.format(_("%dm ago"), math.floor(d / 60)) end
    if d < 86400 then return string.format(_("%dh ago"), math.floor(d / 3600)) end
    local days = math.floor(d / 86400)
    if days == 1 then return _(Tabs.YESTERDAY) end
    if days < 14 then return plural(days, "day", _) end
    if days < 60 then return plural(math.floor(days / 7), "week", _) end
    if days < 365 then return plural(math.floor(days / 30), "month", _) end
    return plural(math.floor(days / 365), "year", _)
end

--- A ten-cell bar and the percentage, rounded down; "done" when finished.
function Tabs.bar(p, gettext)
    local _ = gettext or identity
    if type(p) ~= "number" or p ~= p then p = 0 end
    if p >= Tabs.FINISHED then return _(Tabs.DONE) end
    if p < 0 then p = 0 end
    local filled = math.floor(p * 10)
    return string.rep("\226\150\136", filled) .. string.rep("\226\150\145", 10 - filled)
        .. " " .. math.floor(p * 100) .. "%"
end

--[[--
The text of a row and its right-hand text.

@tparam table row from ListView.rows, after Tabs.split
@tparam table opts now, title (function(row) -> local title or nil),
  device (function(row) -> device label), gettext
@treturn string text: name, then device and time after a middle dot
  (Menu turns every newline into a space, so a line break cannot be used)
@treturn string mandatory: the bar, or "⬇ Drive" for a missing Drive book
]]
function Tabs.rowText(row, opts)
    local _ = opts.gettext or identity
    local name = opts.title and opts.title(row) or row.text
    local marks = (row.is_new and Tabs.MARK_NEW .. " " or "")
        .. (Tabs.finished(row) and Tabs.MARK_DONE .. " " or "")
    local second = { opts.device and opts.device(row) or row.device }
    second[#second + 1] = Tabs.relative(row.timestamp, opts.now, _)
    local mandatory = Tabs.bar(row.percentage, _)
    if row.missing and row.has_drive then
        mandatory = _(Tabs.DRIVE) .. "  " .. mandatory
    end
    return marks .. name .. " \194\183 " .. table.concat(second, " \194\183 "), mandatory
end

return Tabs
