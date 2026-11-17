--[[--
What the Google Drive list is showing, without KOReader: view (Recent or
Search), keywords, filters, sort, and the files loaded so far.

    local State = require("gdriveepub_state")
    local s = State.new()             -- Recent, sorted by opened
    State.setSearch(s, "dbt guide")   -- Search, sorted by updated
    State.setFilter(s, "modified_within", "1w")
    State.setSort(s, "name")
    State.params(s)                   -- query table for GET /api/files
    State.subtitle(s)                 -- "Search "dbt guide" · updated 1 week · by name"
    State.addPage(s, files, token)    -- after each answer; State.reset* clear them

Lua 5.1 only.
]]

local State = {}

State.PAGE_SIZE = 25

State.WITHIN = { "", "1d", "1w", "1m", "3m" }
State.WITHIN_LABEL = { [""] = "Any time", ["1d"] = "1 day", ["1w"] = "1 week", ["1m"] = "1 month", ["3m"] = "3 months" }
State.SORTS = { "viewed", "modified", "created", "name" }
State.SORT_LABEL = { viewed = "Opened", modified = "Updated", created = "Created", name = "Name" }

local function validWithin(v)
    return State.WITHIN_LABEL[v or ""] ~= nil
end

function State.new()
    local s = { view = "recent", q = nil, modified_within = "", created_within = "", sort = "viewed" }
    State.resetFiles(s)
    return s
end

function State.resetFiles(s)
    s.files, s.next_token, s.loaded = {}, nil, false
end

--- The default sort of a view: opened for Recent, updated for Search.
function State.defaultSort(view)
    return view == "search" and "modified" or "viewed"
end

function State.setRecent(s)
    s.view, s.q, s.sort = "recent", nil, State.defaultSort("recent")
    State.resetFiles(s)
end

--- Keywords trimmed; empty keywords go back to Recent. Returns the view.
function State.setSearch(s, q)
    q = type(q) == "string" and q:match("^%s*(.-)%s*$") or ""
    if q == "" then
        State.setRecent(s)
    else
        s.view, s.q, s.sort = "search", q, State.defaultSort("search")
        State.resetFiles(s)
    end
    return s.view
end

--- which = "modified_within" | "created_within"; value one of State.WITHIN.
function State.setFilter(s, which, value)
    assert(which == "modified_within" or which == "created_within", "bad filter " .. tostring(which))
    value = value or ""
    assert(validWithin(value), "bad filter value " .. tostring(value))
    s[which] = value
    State.resetFiles(s)
end

function State.clearFilters(s)
    s.modified_within, s.created_within = "", ""
    State.resetFiles(s)
end

function State.setSort(s, sort)
    assert(State.SORT_LABEL[sort], "bad sort " .. tostring(sort))
    s.sort = sort
    State.resetFiles(s)
end

--- Query parameters for GET /api/files; `page_token` for the next page.
function State.params(s, page_token)
    local p = { view = s.view, sort = s.sort, page_size = State.PAGE_SIZE }
    if s.view == "search" then p.q = s.q end
    if s.modified_within ~= "" then p.modified_within = s.modified_within end
    if s.created_within ~= "" then p.created_within = s.created_within end
    if page_token then p.page_token = page_token end
    return p
end

--- Append one answer's files, skipping ids already shown (a file can move
--- between pages when it is opened elsewhere in the meantime).
function State.addPage(s, files, token)
    local seen = {}
    for _, f in ipairs(s.files) do seen[f.id] = true end
    for _, f in ipairs(files or {}) do
        if not seen[f.id] then
            s.files[#s.files + 1] = f
            seen[f.id] = true
        end
    end
    s.next_token, s.loaded = token, true
end

function State.hasMore(s)
    return s.next_token ~= nil
end

function State.filterCount(s)
    return (s.modified_within ~= "" and 1 or 0) + (s.created_within ~= "" and 1 or 0)
end

--- One line saying what the list holds, for the title bar.
function State.subtitle(s)
    local bits = {}
    if s.view == "search" then
        bits[#bits + 1] = 'Search "' .. tostring(s.q) .. '"'
    else
        bits[#bits + 1] = "Recent"
    end
    if s.modified_within ~= "" then
        bits[#bits + 1] = "updated " .. State.WITHIN_LABEL[s.modified_within]
    end
    if s.created_within ~= "" then
        bits[#bits + 1] = "created " .. State.WITHIN_LABEL[s.created_within]
    end
    bits[#bits + 1] = "by " .. State.SORT_LABEL[s.sort]:lower()
    return table.concat(bits, " \194\183 ")
end

--- Number of screen pages for `n` loaded files at `per_page` rows, and
--- whether a further server page exists ("3+" in the footer).
function State.pageCount(n, per_page)
    if n <= 0 then return 1 end
    return math.ceil(n / per_page)
end

--- Footer text, "Page 2 of 3" or "Page 3 of 3+" when the server has more.
function State.pageLabel(page, pages, more)
    return string.format("Page %d of %d%s", page, pages, more and "+" or "")
end

return State
