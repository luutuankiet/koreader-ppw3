--[[--
Local file index for the synced reading list.

Maps a sync key to a local path. The key is md5(file name), with no folder,
which is what KOReader's built-in progress sync sends when its document
matching method is set to "file name" (kosync.koplugin/main.lua,
KOSync:getFileNameDigest and KOSync:getFileName).

Every dependency is injected, so the module runs outside KOReader:

    local LocalIndex = require("syncedhistory_localindex")
    local index = LocalIndex.new{
        lfs = require("libs/libkoreader-lfs"),
        md5 = require("ffi/sha2").md5,
        settings = LuaSettings:open(path),   -- optional
        root = "/mnt/us/documents",          -- optional
    }
    local path = index:lookup(key)            -- path or nil

Lua 5.1 only.
]]

local LocalIndex = {}
LocalIndex.__index = LocalIndex

LocalIndex.DEFAULT_ROOT = "/mnt/us/documents"
-- A file directly in the root is level 1, root/a/b/book.epub is level 3.
LocalIndex.MAX_DEPTH = 3
LocalIndex.SETTINGS_KEY = "local_index"

-- Fallback extension list, used only when no is_document function is
-- injected (tests, or a KOReader build without DocumentRegistry). The
-- document types KOReader v2026.07.1 registers in frontend/document/*.lua,
-- without the image and source-code types. KOReader registers no provider
-- for azw3, so it is not listed.
LocalIndex.DOCUMENT_EXTENSIONS = {
    azw = true, cbr = true, cbt = true, cbz = true, chm = true, djvu = true,
    doc = true, docm = true, docx = true, epub = true, epub3 = true,
    fb2 = true, fb3 = true, htm = true, html = true, htmlz = true,
    md = true, mobi = true, odt = true, pdb = true, pdf = true, prc = true,
    rtf = true, tcr = true, txt = true, xhtml = true, xps = true, zip = true,
}

--- File name with no folder, the same way KOReader's util.splitFilePathName
-- does it (everything after the last "/").
function LocalIndex.basename(path)
    if path == nil or path == "" then return "" end
    if not path:find("/", 1, true) then return path end
    local _, name = path:match("(.*/)(.*)")
    return name
end

--- Lowercased suffix after the last dot, like util.getFileNameSuffix.
function LocalIndex.suffix(name)
    local s = name:match("%.([^%.]*)$")
    return s and s:lower() or ""
end

function LocalIndex.defaultIsDocument(name)
    return LocalIndex.DOCUMENT_EXTENSIONS[LocalIndex.suffix(name)] == true
end

--[[--
Create an index.

@tparam table opts
  lfs          (required) table with dir(path) and attributes(path)
  md5          (required) function(string) -> lowercase hex digest
  settings     (optional) object with readSetting(k), saveSetting(k, v), flush()
  root         (optional) folder to scan, defaults to DEFAULT_ROOT
  max_depth    (optional) defaults to MAX_DEPTH
  is_document  (optional) function(file_name) -> bool
  clock        (optional) function() -> seconds as a number, for timeScan
]]
function LocalIndex.new(opts)
    assert(opts and opts.lfs, "LocalIndex.new: lfs is required")
    assert(opts.md5, "LocalIndex.new: md5 is required")
    local root = opts.root
    if root == nil or root == "" then root = LocalIndex.DEFAULT_ROOT end
    if #root > 1 then root = root:gsub("/+$", "") end
    local self = setmetatable({
        lfs = opts.lfs,
        md5 = opts.md5,
        settings = opts.settings,
        root = root,
        max_depth = opts.max_depth or LocalIndex.MAX_DEPTH,
        is_document = opts.is_document or LocalIndex.defaultIsDocument,
        clock = opts.clock or os.clock,
        cache = {},
        rescanned = false, -- one automatic rescan per session
        scan_count = 0,    -- full scans run by rescan(), for tests and logs
    }, LocalIndex)
    if self.settings then
        local saved = self.settings:readSetting(LocalIndex.SETTINGS_KEY)
        if type(saved) == "table" then self.cache = saved end
    end
    return self
end

--- The sync key for a file name or a full path.
function LocalIndex:keyFor(path_or_name)
    return self.md5(LocalIndex.basename(path_or_name))
end

function LocalIndex:isFile(path)
    return path ~= nil and self.lfs.attributes(path, "mode") == "file"
end

--[[--
Walk the root and return a fresh map without touching the cache.

@treturn table key -> { path = string, mtime = number }
@treturn int number of distinct keys
@treturn int number of document files seen (duplicates included)
]]
function LocalIndex:scan()
    local lfs = self.lfs
    local md5 = self.md5
    local is_document = self.is_document
    local max_depth = self.max_depth
    local found, keys, files = {}, 0, 0

    local function walk(dir, level)
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok or not iter then return end
        for name in iter, dir_obj do
            -- Skip ".", "..", hidden entries.
            if name:sub(1, 1) ~= "." then
                local path = dir == "/" and ("/" .. name) or (dir .. "/" .. name)
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    -- *.sdr folders hold KOReader and Kindle metadata, never books.
                    if level < max_depth and not name:find("%.sdr$") then
                        walk(path, level + 1)
                    end
                elseif attr and attr.mode == "file" and is_document(name) then
                    files = files + 1
                    local key = md5(name)
                    local mtime = attr.modification or 0
                    local prev = found[key]
                    if not prev then
                        keys = keys + 1
                        found[key] = { path = path, mtime = mtime }
                    elseif mtime > prev.mtime
                        or (mtime == prev.mtime and path < prev.path) then
                        -- Same name in two folders: the newer file wins; on a
                        -- tie, the smaller path, so the result never depends
                        -- on directory order.
                        found[key] = { path = path, mtime = mtime }
                    end
                end
            end
        end
    end

    walk(self.root, 1)
    return found, keys, files
end

--- Scan now, replace the cache and save it. Counts as this session's rescan.
-- @treturn int number of distinct keys
function LocalIndex:rescan()
    local found, keys = self:scan()
    local cache = {}
    for key, entry in pairs(found) do
        cache[key] = entry.path
    end
    self.cache = cache
    self.rescanned = true
    self.scan_count = self.scan_count + 1
    if self.settings then
        self.settings:saveSetting(LocalIndex.SETTINGS_KEY, cache)
        self.settings:flush()
    end
    return keys
end

--[[--
Local path for a sync key.

Cached path if the file is still there; otherwise one rescan per session;
otherwise nil (the caller shows "document not found").
]]
function LocalIndex:lookup(key)
    if key == nil then return nil end
    local path = self.cache[key]
    if self:isFile(path) then return path end
    if not self.rescanned then
        self:rescan()
        path = self.cache[key]
        if self:isFile(path) then return path end
    end
    return nil
end

--- Time a full scan without changing the cache.
-- @treturn int distinct keys
-- @treturn number milliseconds
-- @treturn int document files seen
function LocalIndex:timeScan()
    local t0 = self.clock()
    local _, keys, files = self:scan()
    local ms = (self.clock() - t0) * 1000
    return keys, ms, files
end

return LocalIndex
