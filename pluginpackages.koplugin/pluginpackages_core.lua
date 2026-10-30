--[[--
Everything the plugin installer does on disk, with no UI, so it can be tested
against real archives and folders outside KOReader's UI loop.

An install has two halves. prepare() downloads, checks and unpacks into a stage
folder and never touches the installed plugin, so it can run in a subprocess
that is killed at any moment. swapIn() is the only part that changes the
installed plugin: a few renames that undo themselves if one fails.

The stage folder lives inside plugins/ because rename only works within one
filesystem; the Kindle's /tmp is a 64MB tmpfs and must not be used. KOReader's
plugin loader only looks at folders ending in ".koplugin", so neither the stage
nor ".koplugin.bak" is ever loaded.

Lua 5.1 only.
]]

local lfs = require("libs/libkoreader-lfs")

local Core = {}

Core.MANIFEST = ".package-files"
Core.STAGE = "pluginpackages.stage"

local function isDir(path) return lfs.attributes(path, "mode") == "directory" end
local function linkMode(path) return lfs.symlinkattributes(path, "mode") end

--- Recursive delete. Does not follow symlinks.
function Core.removeTree(path)
    local mode = linkMode(path)
    if not mode then return true end
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                local ok, err = Core.removeTree(path .. "/" .. entry)
                if not ok then return nil, err end
            end
        end
    end
    return os.remove(path)
end

local function makePath(path)
    if isDir(path) then return true end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then
        local ok, err = makePath(parent)
        if not ok then return nil, err end
    end
    return lfs.mkdir(path)
end

--- Paths of all files and symlinks under dir, relative to it.
function Core.listFiles(dir)
    local files = {}
    local function walk(rel)
        local full = rel == "" and dir or (dir .. "/" .. rel)
        for entry in lfs.dir(full) do
            if entry ~= "." and entry ~= ".." then
                local child = rel == "" and entry or (rel .. "/" .. entry)
                if linkMode(dir .. "/" .. child) == "directory" then
                    walk(child)
                else
                    files[#files + 1] = child
                end
            end
        end
    end
    walk("")
    table.sort(files)
    return files
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function copyFile(from, to)
    local target = lfs.symlinkattributes(from, "target")
    if target then
        os.remove(to)
        return lfs.link(target, to, true)
    end
    local src, err = io.open(from, "rb")
    if not src then return nil, err end
    local dst
    dst, err = io.open(to, "wb")
    if not dst then src:close(); return nil, err end
    local ok = true
    while ok do
        local chunk = src:read(65536)
        if not chunk then break end
        ok, err = dst:write(chunk)
    end
    src:close()
    local closed, close_err = dst:close()
    if not ok then return nil, err end
    if not closed then return nil, close_err end
    return true
end

-- Files the package brought into dir, or nil if no installer put it there.
local function readManifest(dir)
    local data = readFile(dir .. "/" .. Core.MANIFEST)
    if not data then return nil end
    local set = {}
    for line in data:gmatch("[^\n]+") do set[line] = true end
    set[Core.MANIFEST] = true
    return set
end

local function writeManifest(dir)
    local f, err = io.open(dir .. "/" .. Core.MANIFEST, "wb")
    if not f then return nil, err end
    f:write(table.concat(Core.listFiles(dir), "\n"), "\n")
    f:close()
    return true
end

local function asSet(list)
    local set = {}
    for _, v in ipairs(list) do set[v] = true end
    return set
end

--[[--
Copy files that belong to this device from one version of a plugin to another.

Packages deliberately leave out personal files such as the reader's account
configuration, and plugins keep state in their folder. A file is local if the
package that installed `from` did not bring it, and the package in `to` does
not bring it either. A folder with no manifest was put there by hand, so every
file in it counts as possibly local: keeping a stale file is harmless, losing
accounts is not. Copied, not moved, so the folder kept as .bak stays whole.
]]
function Core.carryLocalFiles(from, to)
    local from_manifest = readManifest(from)
    local from_package = from_manifest or { [Core.MANIFEST] = true }
    -- `to` with no manifest is a hand-deployed folder being rolled back to. If
    -- `from` has a manifest its local files are certain and newer, so they win;
    -- if neither has one, only fill in what `to` lacks.
    local to_package = readManifest(to) or (from_manifest and {} or asSet(Core.listFiles(to)))
    local carried = {}
    for _, rel in ipairs(Core.listFiles(from)) do
        if not from_package[rel] and not to_package[rel] then
            local parent = rel:match("^(.*)/[^/]+$")
            if parent then
                local ok, err = makePath(to .. "/" .. parent)
                if not ok then return nil, err end
            end
            local ok, err = copyFile(from .. "/" .. rel, to .. "/" .. rel)
            if not ok then return nil, rel .. ": " .. tostring(err) end
            carried[#carried + 1] = rel
        end
    end
    return carried
end

--- The version in a plugin folder's _meta.lua, read without running it.
function Core.readVersion(dir)
    local data = readFile(dir .. "/_meta.lua")
    return data and data:match("version%s*=%s*[\"']([^\"']+)[\"']") or nil
end

--- Negative, zero or positive, comparing dotted numbers ("0.10.0" > "0.9.1").
function Core.compareVersions(a, b)
    local next_a, next_b = tostring(a):gmatch("%d+"), tostring(b):gmatch("%d+")
    while true do
        local x, y = next_a(), next_b()
        if not x and not y then return 0 end
        local diff = (tonumber(x) or 0) - (tonumber(y) or 0)
        if diff ~= 0 then return diff end
    end
end

--- Decoded index.json to a list of checked entries. An entry that would make
-- a path out of hostile text is dropped: name and file become paths and URLs.
function Core.parseIndex(index)
    if type(index) ~= "table" or index.format ~= 1 or type(index.plugins) ~= "table" then
        return nil, "not a package index"
    end
    local plugins = {}
    for _, p in ipairs(index.plugins) do
        if type(p) == "table"
            and type(p.name) == "string" and p.name:match("^[%w_%-]+$")
            and type(p.file) == "string" and p.file:match("^[%w_%-][%w_.%-+]*$") and not p.file:find("..", 1, true)
            and type(p.version) == "string"
            and type(p.sha256) == "string" and p.sha256:match("^%x+$") and #p.sha256 == 64
            and type(p.size) == "number"
        then
            plugins[#plugins + 1] = p
        end
    end
    return plugins
end

function Core.sha256File(path)
    local sha2 = require("ffi/sha2")
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local update = sha2.sha256()
    while true do
        local chunk = f:read(65536)
        if not chunk then break end
        update(chunk)
    end
    f:close()
    return update()
end

local function shellQuote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

-- KOReader builds before about 2026 have no ffi/archiver, and unpack OTA
-- updates with their own bundled ./tar.
local function extractWithTar(archive, dest)
    local tried = {}
    for _, tar in ipairs{ "./tar", "tar" } do
        local cmd = string.format("%s -xzf %s -C %s 2>/dev/null", tar, shellQuote(archive), shellQuote(dest))
        local ret = os.execute(cmd)
        if ret == 0 or ret == true then return true end
        tried[#tried + 1] = tar
    end
    return nil, "cannot unpack with " .. table.concat(tried, " or ")
end

local function extractWithArchiver(Archiver, archive, dest, root)
    local arc = Archiver.Reader:new()
    local ok, err
    if arc:open(archive) then
        ok = true
        for entry in arc:iterate() do
            local path = entry.path
            local inside = path:sub(1, #root + 1) == root .. "/" or path == root
            if not inside or path:find("..", 1, true) or (entry.mode ~= "file" and entry.mode ~= "directory") then
                ok, err = nil, "unexpected entry in archive: " .. tostring(path)
                break
            end
            if not arc:extractToPath(path, dest .. "/" .. path) then break end
        end
        if arc.err then ok, err = nil, arc.err end
    else
        err = arc.err or "cannot open archive"
    end
    arc:close()
    return ok, err
end

--- Unpack a .tar.gz into the empty folder dest. Expected top entry is `root`.
function Core.extract(archive, dest, root, no_archiver)
    local has_archiver, Archiver = false, nil
    if not no_archiver then has_archiver, Archiver = pcall(require, "ffi/archiver") end
    if has_archiver then return extractWithArchiver(Archiver, archive, dest, root) end
    return extractWithTar(archive, dest)
end

--- The stage folder for a plugins root, created empty.
local function freshStage(root)
    local stage = root .. "/" .. Core.STAGE
    local ok, err = Core.removeTree(stage)
    if not ok then return nil, err end
    ok, err = lfs.mkdir(stage)
    if not ok then return nil, err end
    return stage
end

--[[--
Download, check and unpack a package into the stage. Touches nothing else.

@tparam table entry an entry from parseIndex
@tparam table opts
  root   plugins folder
  url    package URL
  fetch  function(url, path) -> true or nil, err
  no_archiver  (optional) use tar even where ffi/archiver exists
@treturn string the path of the unpacked plugin folder, or nil, err
]]
function Core.prepare(entry, opts)
    local stage, err = freshStage(opts.root)
    if not stage then return nil, err end
    local archive = stage .. "/" .. entry.file
    local ok
    ok, err = opts.fetch(opts.url, archive)
    if not ok then return nil, "download failed: " .. tostring(err) end
    local size = lfs.attributes(archive, "size")
    if size ~= entry.size then
        return nil, string.format("incomplete download: %s of %d bytes", tostring(size), entry.size)
    end
    local sum = Core.sha256File(archive)
    if sum ~= entry.sha256:lower() then return nil, "checksum mismatch" end

    local unpack_dir = stage .. "/unpacked"
    ok, err = lfs.mkdir(unpack_dir)
    if not ok then return nil, err end
    local root_name = entry.name .. ".koplugin"
    ok, err = Core.extract(archive, unpack_dir, root_name, opts.no_archiver)
    if not ok then return nil, "unpack failed: " .. tostring(err) end

    for name in lfs.dir(unpack_dir) do
        if name ~= "." and name ~= ".." and name ~= root_name then
            return nil, "unexpected top-level entry: " .. name
        end
    end
    local new_dir = unpack_dir .. "/" .. root_name
    if not isDir(new_dir) or not lfs.attributes(new_dir .. "/main.lua", "mode") then
        return nil, "archive holds no " .. root_name .. "/main.lua"
    end
    local version = Core.readVersion(new_dir)
    if version ~= entry.version then
        return nil, string.format("archive is version %s, index says %s", tostring(version), entry.version)
    end
    ok, err = writeManifest(new_dir)
    if not ok then return nil, err end
    os.remove(archive)
    return new_dir
end

local function rename(from, to, undo)
    local ok, err = os.rename(from, to)
    if not ok then return nil, err end
    undo[#undo + 1] = { to, from }
    return true
end

local function rewind(undo)
    for i = #undo, 1, -1 do os.rename(undo[i][1], undo[i][2]) end
end

--[[--
Put an unpacked plugin in place, keeping the current one as .bak. Any failure
puts every folder back where it was, and returns nil, err.

@tparam string root plugins folder
@tparam string name plugin name
@tparam string new_dir from prepare()
@tparam[opt] function rename_fn os.rename stand-in for tests
]]
function Core.swapIn(root, name, new_dir, rename_fn)
    local current = root .. "/" .. name .. ".koplugin"
    local bak = current .. ".bak"
    local old_bak = bak .. ".old"
    if isDir(current) then
        local ok, err = Core.carryLocalFiles(current, new_dir)
        if not ok then return nil, "cannot keep local files: " .. tostring(err) end
    end
    Core.removeTree(old_bak)
    local undo = {}
    local real_rename = os.rename
    if rename_fn then os.rename = rename_fn end
    local ok, err = true, nil
    if isDir(bak) then ok, err = rename(bak, old_bak, undo) end
    if ok and isDir(current) then ok, err = rename(current, bak, undo) end
    if ok then ok, err = rename(new_dir, current, undo) end
    os.rename = real_rename
    if not ok then
        rewind(undo)
        return nil, err
    end
    Core.removeTree(old_bak)
    Core.removeTree(root .. "/" .. Core.STAGE)
    return true
end

--- Swap .bak with the current folder. Rolling back twice returns to the start.
-- Local files follow, so settings changed since the upgrade are not lost.
function Core.rollback(root, name, rename_fn)
    local current = root .. "/" .. name .. ".koplugin"
    local bak = current .. ".bak"
    local swap = current .. ".swap"
    if not isDir(bak) then return nil, "nothing to roll back to" end
    local has_current = isDir(current)
    if has_current then
        local ok, err = Core.carryLocalFiles(current, bak)
        if not ok then return nil, "cannot keep local files: " .. tostring(err) end
    end
    local undo = {}
    local real_rename = os.rename
    if rename_fn then os.rename = rename_fn end
    local ok, err = true, nil
    if has_current then ok, err = rename(current, swap, undo) end
    if ok then ok, err = rename(bak, current, undo) end
    if ok and has_current then ok, err = rename(swap, bak, undo) end
    os.rename = real_rename
    if not ok then
        rewind(undo)
        return nil, err
    end
    return true
end

--- Names of plugins in root with a .bak folder.
function Core.listBackups(root)
    local names = {}
    for entry in lfs.dir(root) do
        local name = entry:match("^(.+)%.koplugin%.bak$")
        if name and isDir(root .. "/" .. entry) then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

return Core
