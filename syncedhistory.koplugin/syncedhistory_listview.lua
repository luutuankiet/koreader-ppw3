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

local function identity(s) return s end

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
                text = name or _(ListView.UNKNOWN),
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

return ListView
