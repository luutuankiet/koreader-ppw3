--[[--
Pure logic for the "Downloaded files" screen: which files in the GDrive
folder are listed, the selection marks, and which paths are safe to delete.

Nothing here touches the disk. The caller passes directory entries in and
a `realpath` function (KOReader's `ffi/util`.realpath) for the safety check.

    local Files = require("gdriveepub_files")
    local list = Files.build(entries)            -- entries: { name, mode, size, modification }
    local sel = Files.newSelection()
    Files.toggle(sel, list[1].name)
    local plan = Files.planDelete(dir, Files.selectedNames(sel, list), open_path, realpath)
    -- plan.paths: resolved paths to delete; plan.skipped: { { name =, reason = } }
]]

local Files = {}

local DOT = " \194\183 "

--- A bare file name with nothing that could leave the folder: no path
--- separator, no `..`, no NUL, not empty.
function Files.isPlainName(name)
    if type(name) ~= "string" or name == "" or name == "." then return false end
    if name:find("..", 1, true) then return false end
    if name:find("[/\\%z]") then return false end
    return true
end

--- Only regular files the user would recognise: no hidden files (this also
--- skips the `.name.part` files of a download in progress), no folders
--- (so no `.sdr` sidecars), no names that fail `isPlainName`.
--- Newest first, then by name.
function Files.build(entries)
    local out = {}
    for _i, e in ipairs(entries or {}) do
        if e.mode == "file" and Files.isPlainName(e.name) and e.name:sub(1, 1) ~= "." then
            table.insert(out, { name = e.name, size = tonumber(e.size) or 0, modified = tonumber(e.modification) or 0 })
        end
    end
    table.sort(out, function(a, b)
        if a.modified ~= b.modified then return a.modified > b.modified end
        return a.name < b.name
    end)
    return out
end

local function size(n)
    if n >= 1024 * 1024 then return string.format("%.1f MB", n / (1024 * 1024)) end
    return string.format("%d KB", math.max(1, math.floor(n / 1024 + 0.5)))
end

--- "1.2 MB · 2026-11-15 10:20", the modified time shifted by `offset` seconds.
function Files.meta(entry, offset)
    return size(entry.size or 0) .. DOT .. os.date("!%Y-%m-%d %H:%M", (entry.modified or 0) + (offset or 0))
end

--- Row title with a check mark when selected.
function Files.label(entry, selected)
    return (selected and "\226\156\147 " or "") .. entry.name
end

-- Selection -------------------------------------------------------------

function Files.newSelection() return { set = {} } end

function Files.isSelected(sel, name) return sel.set[name] == true end

function Files.toggle(sel, name)
    if sel.set[name] then sel.set[name] = nil else sel.set[name] = true end
    return sel.set[name] == true
end

function Files.selectAll(sel, list)
    for _i, e in ipairs(list) do sel.set[e.name] = true end
end

function Files.clear(sel) sel.set = {} end

--- Selected names that are still in `list`, in list order.
function Files.selectedNames(sel, list)
    local out = {}
    for _i, e in ipairs(list) do
        if sel.set[e.name] then table.insert(out, e.name) end
    end
    return out
end

--- Drop marks for files no longer listed (after a delete or a refresh).
function Files.prune(sel, list)
    local keep = {}
    for _i, name in ipairs(Files.selectedNames(sel, list)) do keep[name] = true end
    sel.set = keep
end

function Files.subtitle(list, sel)
    local n, s = #list, #Files.selectedNames(sel, list)
    local text = n == 1 and "1 file" or (n .. " files")
    if s > 0 then text = text .. DOT .. s .. " selected" end
    return text
end

-- Delete safety ---------------------------------------------------------

local function stripSlash(p)
    if p == "/" then return "" end
    return (p:gsub("/+$", ""))
end

--- The resolved path of `name` if it sits directly inside `dir` after
--- resolving links, else nil and a reason: "bad_name", "no_dir",
--- "missing" or "outside".
function Files.resolveInside(dir, name, realpath)
    if not Files.isPlainName(name) then return nil, "bad_name" end
    local rdir = dir and realpath(dir)
    if not rdir then return nil, "no_dir" end
    rdir = stripSlash(rdir)
    local rp = realpath(rdir .. "/" .. name)
    if not rp then return nil, "missing" end
    local prefix = rdir .. "/"
    if rp:sub(1, #prefix) ~= prefix then return nil, "outside" end
    local rest = rp:sub(#prefix + 1)
    if rest == "" or rest:find("/", 1, true) then return nil, "outside" end
    return rp
end

--- Split the selected names into paths safe to delete and names skipped,
--- with the reason. The open document (`open_path`, may be nil) is skipped
--- with reason "open".
function Files.planDelete(dir, names, open_path, realpath)
    local plan = { paths = {}, names = {}, skipped = {} }
    local ropen = open_path and realpath(open_path)
    for _i, name in ipairs(names or {}) do
        local p, why = Files.resolveInside(dir, name, realpath)
        if p and ropen and p == ropen then p, why = nil, "open" end
        if p then
            table.insert(plan.paths, p)
            table.insert(plan.names, name)
        else
            table.insert(plan.skipped, { name = name, reason = why })
        end
    end
    return plan
end

-- Sidecars --------------------------------------------------------------

--- KOReader's sidecar folder beside a book: the path without its last
--- suffix plus `.sdr` (DocSettings:getSidecarDir with the "doc" location),
--- so `Book.epub` and `Book.pdf` share `Book.sdr`.
function Files.sidecarDir(path)
    return (path:match("(.*)%.") or path) .. ".sdr"
end

--- True when a sidecar folder holds no other book's metadata file
--- (`metadata.<ext>.lua`, or its `.old` backup), so it is safe to remove
--- whole after this book's own metadata was purged.
function Files.canPurgeSidecar(names)
    for _i, n in ipairs(names or {}) do
        if n:match("^metadata%..+%.lua$") or n:match("^metadata%..+%.lua%.old$") then return false end
    end
    return true
end

return Files
