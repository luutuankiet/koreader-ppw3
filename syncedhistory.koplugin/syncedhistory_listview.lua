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
    -- rows[i] = { text, mandatory, dim, document, filename, path, missing,
    --             percentage, device, timestamp, keys, local_document }

    local v = ListView.view(rows, { show_missing = false, query = "dune" })
    -- v.rows to show, v.total, v.on_device, v.matched, v.query
    ListView.subtitle(v, { status = "synced just now", gettext = _ })
    ListView.emptyText(v, { empty = "No books on the sync server yet.", gettext = _ })
    ListView.details(rows[1], { gettext = _, date = os.date }) -- long-press text
    ListView.removeText(rows[1], { gettext = _ })               -- confirm text

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
ListView.DETAIL_PROGRESS = "Progress: %1"
ListView.DETAIL_DEVICE = "Last device: %1"
ListView.DETAIL_PUSHED = "Last pushed: %1"
ListView.DETAIL_FOLDER = "Folder: %1"
ListView.NOT_HERE = "not on this device"
ListView.UNKNOWN_TIME = "unknown"
ListView.DATE_FORMAT = "%Y-%m-%d %H:%M"
ListView.REMOVE = "Remove from list"
ListView.REMOVE_CONFIRM = "Remove \"%1\" from the synced reading list?\n\nIts progress is deleted from the sync server for every device. A book still being read comes back with its next progress push."
ListView.REMOVE_CONFIRM_NAMES = "Remove \"%1\" from the synced reading list?\n\nIts progress is deleted from the sync server for every device, under all %2 file names it was saved as. A book still being read comes back with its next progress push."
ListView.REMOVING = "Removing..."
ListView.REFRESH = "Refresh"

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

--- "Kindle (99ED)": the device model and the last 4 characters of its
--- progress sync device id, which tell two devices of one model apart.
--- Just the model when the server sent no id.
function ListView.deviceLabel(device, device_id)
    if type(device_id) ~= "string" or #device_id < 4 then return device end
    return device .. " (" .. device_id:sub(-4) .. ")"
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
Every sync key of a server row, newest first: its aliases when the server
merged several file names into one book, else just its document.

@treturn table list of { document, filename }
]]
function ListView.aliases(row)
    local out = {}
    if type(row) ~= "table" then return out end
    if type(row.aliases) == "table" then
        for _i, a in ipairs(row.aliases) do
            if type(a) == "table" and type(a.document) == "string" and a.document ~= "" then
                out[#out + 1] = {
                    document = a.document,
                    filename = type(a.filename) == "string" and a.filename ~= "" and a.filename or nil,
                }
            end
        end
    end
    if #out == 0 and type(row.document) == "string" then
        out[1] = {
            document = row.document,
            filename = type(row.filename) == "string" and row.filename ~= "" and row.filename or nil,
        }
    end
    return out
end

--[[--
The local copy of a row: the first alias, newest first, whose key is in the
local index.

@tparam table row a server row, or a row from ListView.rows (keys kept)
@tparam function lookup function(document key) -> local path or nil
@treturn string|nil local path
@treturn string|nil the key that matched
@treturn string|nil that alias's file name as the server knows it
]]
function ListView.localMatch(row, lookup)
    local aliases = row and row.keys or ListView.aliases(row)
    for _i, a in ipairs(aliases) do
        local path = lookup(a.document)
        if path then return path, a.document, a.filename end
    end
    return nil
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
            local keys = ListView.aliases(row)
            local path, local_document, local_name = ListView.localMatch({ keys = keys }, opts.lookup)
            -- On this device: the name of the alias found here. Otherwise the
            -- newest name the server has.
            local name = type(row.filename) == "string" and row.filename ~= "" and row.filename or nil
            if path then name = local_name end
            local device = type(row.device) == "string" and row.device ~= "" and row.device or _(ListView.UNKNOWN_DEVICE)
            rows[#rows + 1] = {
                -- Progress pushed before this plugin carries no file name; the
                -- local copy, when there is one, still has it.
                text = name or (path and path:match("([^/]+)$")) or _(ListView.UNKNOWN),
                mandatory = table.concat({
                    ListView.percent(row.percentage),
                    ListView.deviceLabel(device, row.device_id),
                    path and _(ListView.ON_DEVICE) or _(ListView.MISSING),
                }, " · "),
                dim = path == nil or nil,
                document = row.document,
                filename = name,
                percentage = row.percentage,
                path = path,
                missing = path == nil,
                -- Every key of the book, for opening and for removing it.
                keys = keys,
                local_document = local_document,
                -- As the server sent them, for the long-press details.
                device = type(row.device) == "string" and row.device ~= "" and row.device or nil,
                timestamp = type(row.timestamp) == "number" and row.timestamp or nil,
                device_id = type(row.device_id) == "string" and row.device_id ~= "" and row.device_id or nil,
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

--[[--
The long-press pop-up's text for one row: the whole name, then one line each
for the percentage, the last device, when it was last pushed and the folder on
this device.

@tparam table row from ListView.rows
@tparam table opts
  gettext  translation function, default identity
  date     function(format, seconds) -> string, default os.date
@treturn string
]]
function ListView.details(row, opts)
    opts = opts or {}
    local _ = opts.gettext or identity
    local date = opts.date or os.date
    local pushed = row.timestamp and date(ListView.DATE_FORMAT, row.timestamp) or _(ListView.UNKNOWN_TIME)
    local folder = row.path and (row.path:match("^(.*)/[^/]*$") or row.path) or _(ListView.NOT_HERE)
    if folder == "" then folder = "/" end
    return table.concat({
        tostring(row.text),
        "",
        template(_(ListView.DETAIL_PROGRESS), ListView.percent(row.percentage)),
        template(_(ListView.DETAIL_DEVICE),
            ListView.deviceLabel(row.device or _(ListView.UNKNOWN_DEVICE), row.device_id)),
        template(_(ListView.DETAIL_PUSHED), pushed),
        template(_(ListView.DETAIL_FOLDER), folder),
    }, "\n")
end

--- The confirm text of "Remove from list"; it names the alias count when
-- the server merged several file names into the book.
function ListView.removeText(row, opts)
    opts = opts or {}
    local _ = opts.gettext or identity
    local n = type(row.keys) == "table" and #row.keys or 1
    if n > 1 then return template(_(ListView.REMOVE_CONFIRM_NAMES), tostring(row.text), n) end
    return template(_(ListView.REMOVE_CONFIRM), tostring(row.text))
end

return ListView
