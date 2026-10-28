--[[--
Rows of the synced reading list screen.

Turns the server list (or its cached copy) into Menu items: newest first,
with the file name, percentage, last device and whether the book is on this
device. No KOReader dependency, so it runs outside KOReader:

    local ListView = require("syncedhistory_listview")
    local rows = ListView.rows(list, {
        lookup = function(key) return index:lookup(key) end, -- path or nil
        gettext = _,                                          -- optional
    })
    -- rows[i] = { text, mandatory, dim, document, filename, path, missing }

    local v = ListView.view(rows, { show_missing = false, query = "dune" })
    -- v.rows to show, v.total, v.on_device, v.matched, v.query
    ListView.subtitle(v, { status = "synced just now", gettext = _ })
    ListView.emptyText(v, { empty = "No books on the sync server yet.", gettext = _ })

Lua 5.1 only.
]]

local ListView = {}

ListView.TITLE = "Synced reading list"
ListView.UNKNOWN = "unknown book"
ListView.NOT_FOUND = "Document not found."
ListView.ON_DEVICE = "on this device"
ListView.MISSING = "missing"
ListView.UNKNOWN_DEVICE = "unknown device"
ListView.SYNCING = "Syncing..."
ListView.EMPTY = "No books on the sync server yet."
ListView.SYNCED = "synced just now"
ListView.NONE_HERE = "None of your synced books are on this device. Show all from the title-bar menu."
ListView.NO_MATCH = "No book matches \"%1\"."
ListView.COUNT_HERE = "%1 of %2 on this device"
ListView.COUNT_ALL = "%1 books"
ListView.COUNT_FOUND = "\"%1\": %2 found"

local function identity(s) return s end

-- KOReader's ffi/util template, minus the dependency: %1, %2 ... in order.
local function template(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
end

--- The search as typed, trimmed; nil when there is nothing to search for.
function ListView.cleanQuery(q)
    if type(q) ~= "string" then return nil end
    q = q:match("^%s*(.-)%s*$")
    return q ~= "" and q or nil
end
local cleanQuery = ListView.cleanQuery

--- "42%" for 0.42; "0%" for nil. Rounded down, so 99.6% never reads 100%.
function ListView.percent(p)
    if type(p) ~= "number" or p ~= p then return "0%" end
    if p < 0 then p = 0 elseif p > 1 then p = 1 end
    return string.format("%d%%", math.floor(p * 100 + 1e-9))
end

-- Newest first by timestamp; rows without one go last; ties keep the
-- server's order, which is newest first too.
local function sortNewestFirst(list)
    local sorted = {}
    for i, row in ipairs(list) do
        sorted[i] = { row = row, pos = i }
    end
    table.sort(sorted, function(a, b)
        local ta, tb = a.row.timestamp, b.row.timestamp
        if type(ta) ~= "number" then ta = -math.huge end
        if type(tb) ~= "number" then tb = -math.huge end
        if ta ~= tb then return ta > tb end
        return a.pos < b.pos
    end)
    return sorted
end

--[[--
Build the Menu rows.

@tparam table|nil list rows from Client:fetchList or Client:cachedList
@tparam table opts
  lookup   (required) function(document key) -> local path or nil
  gettext  (optional) translation function, default identity
@treturn table rows, newest first
]]
function ListView.rows(list, opts)
    assert(opts and opts.lookup, "ListView.rows: lookup is required")
    local _ = opts.gettext or identity
    local rows = {}
    if type(list) ~= "table" then return rows end
    for _i, entry in ipairs(sortNewestFirst(list)) do
        local row = entry.row
        if type(row) == "table" and type(row.document) == "string" then
            local path = opts.lookup(row.document)
            local name = type(row.filename) == "string" and row.filename ~= "" and row.filename or nil
            local device = type(row.device) == "string" and row.device ~= "" and row.device or _(ListView.UNKNOWN_DEVICE)
            rows[#rows + 1] = {
                -- Progress pushed before this plugin carries no file name; the
                -- local copy, when there is one, still has it.
                text = name or (path and path:match("([^/]+)$")) or _(ListView.UNKNOWN),
                mandatory = table.concat({
                    ListView.percent(row.percentage),
                    device,
                    path and _(ListView.ON_DEVICE) or _(ListView.MISSING),
                }, " · "),
                dim = path == nil or nil,
                document = row.document,
                filename = name,
                percentage = row.percentage,
                path = path,
                missing = path == nil,
            }
        end
    end
    return rows
end

--[[--
What the list shows: the filter, then the search, over rows from ListView.rows.

@tparam table rows from ListView.rows, newest first
@tparam table opts
  show_missing  show books not on this device too
  query         part of a book's shown name, any case; plain text, not a pattern
@treturn table { rows, total, on_device, matched, query }; rows keep their order,
  matched is the number of rows shown
]]
function ListView.view(rows, opts)
    opts = opts or {}
    local query = cleanQuery(opts.query)
    local needle = query and query:lower()
    local shown, on_device = {}, 0
    for _i, row in ipairs(rows) do
        if not row.missing then on_device = on_device + 1 end
        if (opts.show_missing or not row.missing)
            and (not needle or tostring(row.text):lower():find(needle, 1, true)) then
            shown[#shown + 1] = row
        end
    end
    return {
        rows = shown,
        total = #rows,
        on_device = on_device,
        matched = #shown,
        query = query,
        show_missing = opts.show_missing and true or false,
    }
end

--[[--
The list's subtitle: the counts, then the sync status.

@tparam table view from ListView.view
@tparam table opts
  status   the sync status, default "synced just now"; an offline or error
           message replaces it
  gettext  translation function, default identity
]]
function ListView.subtitle(view, opts)
    opts = opts or {}
    local _ = opts.gettext or identity
    local counts
    if view.query then
        counts = template(_(ListView.COUNT_FOUND), view.query, view.matched)
    elseif view.show_missing then
        counts = template(_(ListView.COUNT_ALL), view.total)
    else
        counts = template(_(ListView.COUNT_HERE), view.on_device, view.total)
    end
    return counts .. " · " .. (opts.status or _(ListView.SYNCED))
end

--[[--
The greyed row's text when the view shows no rows, else nil.

@tparam table view from ListView.view
@tparam table opts
  empty    text when the server list itself is empty (or could not be
           fetched), default "No books on the sync server yet."
  gettext  translation function, default identity
]]
function ListView.emptyText(view, opts)
    if view.matched > 0 then return nil end
    opts = opts or {}
    local _ = opts.gettext or identity
    if view.total == 0 then return opts.empty or _(ListView.EMPTY) end
    -- The filter hid everything: there was nothing for a search to find.
    if not view.show_missing and view.on_device == 0 then return _(ListView.NONE_HERE) end
    return template(_(ListView.NO_MATCH), view.query)
end

return ListView
