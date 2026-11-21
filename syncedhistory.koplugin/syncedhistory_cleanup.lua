--[[--
Which finished Google Drive books may be removed from this device.

Pure logic, no KOReader modules: main.lua gathers the facts (the server list,
the files in the GDrive folder and what each sidecar holds) and deletes what
this module returns.

    local Cleanup = require("syncedhistory_cleanup")
    local plan = Cleanup.decide{
        fresh = info.fresh,          -- the list was just fetched from the server
        list = list,                 -- rows from Client:fetchList
        files = { { path = "/GDrive/A.epub", name = "A.epub",
                    sidecar = Cleanup.facts(read) } },
        key_for = function(name) return md5(name) end,
        open_path = "/GDrive/B.epub", -- book open in the reader, or nil
    }
    -- plan.delete = { path, ... }; plan.skipped = { { path =, reason = } }
    -- plan.refused = reason when nothing at all may be removed
]]

local ListView = require("syncedhistory_listview")

local Cleanup = {}

Cleanup.MSG_ONE = "Removed 1 finished Drive doc"
Cleanup.MSG_MANY = "Removed %1 finished Drive docs"

-- Why a file stays. Logged as they are.
Cleanup.IN_LIST = "still in the reading list"
Cleanup.NOT_OPENED = "never opened on this device"
Cleanup.OPEN = "open in the reader"
Cleanup.ANNOTATED = "has highlights, notes or bookmarks"
Cleanup.NO_SIDECAR = "no reading data"

local function count(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _k in pairs(t) do n = n + 1 end
    return n
end

--[[--
What a sidecar says about a book.

@tparam function read function(key) -> the sidecar's value, or nil
@treturn table { opened = bool, annotations = number }
  opened: the reader saved a position or a percentage, which the Drive
  download never writes; annotations: highlights, notes and bookmarks, in the
  current "annotations" key or the older "highlight" and "bookmarks" keys
]]
function Cleanup.facts(read)
    local opened = type(read("percent_finished")) == "number"
        or type(read("last_xpointer")) == "string"
        or type(read("last_page")) == "number"
    local annotations = count(read("annotations"))
    if annotations == 0 then
        annotations = count(read("bookmarks"))
        local hl = read("highlight")
        if type(hl) == "table" then
            for _page, list in pairs(hl) do annotations = annotations + count(list) end
        end
    end
    return { opened = opened, annotations = annotations }
end

--[[--
Decide, file by file. Nothing is removed unless the list is fresh from the
server: a cached list or a failed fetch would make every book look finished.

@tparam table opts fresh, list, files, key_for, open_path (see the top)
@treturn table { delete = { path }, skipped = { { path, reason } }, refused = reason|nil }
]]
function Cleanup.decide(opts)
    local plan = { delete = {}, skipped = {} }
    if not opts.fresh then
        plan.refused = "the reading list was not fetched fresh from the server"
        return plan
    end
    if type(opts.list) ~= "table" then
        plan.refused = "no reading list"
        return plan
    end
    local listed = {}
    for _i, row in ipairs(opts.list) do
        for _j, a in ipairs(ListView.aliases(row)) do listed[a.document] = true end
    end
    for _i, f in ipairs(opts.files or {}) do
        local reason
        local side = f.sidecar
        if listed[opts.key_for(f.name)] then
            reason = Cleanup.IN_LIST
        elseif opts.open_path and f.path == opts.open_path then
            reason = Cleanup.OPEN
        elseif not side then
            reason = Cleanup.NO_SIDECAR
        elseif not side.opened then
            reason = Cleanup.NOT_OPENED
        elseif (side.annotations or 0) > 0 then
            reason = Cleanup.ANNOTATED
        end
        if reason then
            plan.skipped[#plan.skipped + 1] = { path = f.path, reason = reason }
        else
            plan.delete[#plan.delete + 1] = f.path
        end
    end
    return plan
end

--- The toast after `n` books were removed, or nil when none were.
function Cleanup.message(n, gettext)
    local _ = gettext or function(s) return s end
    if not n or n < 1 then return nil end
    if n == 1 then return _(Cleanup.MSG_ONE) end
    return (_(Cleanup.MSG_MANY):gsub("%%1", tostring(n)))
end

return Cleanup
