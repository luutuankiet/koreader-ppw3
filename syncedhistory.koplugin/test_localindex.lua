--[[--
Tests for syncedhistory_localindex.lua. main.lua never loads this file.

Two ways to run it:

  1. Standalone, any LuaJIT or Lua 5.1, in-memory file system and a fake md5:
       luajit test_localindex.lua

  2. With KOReader's own luajit, real lfs, real md5 (ffi/sha2), real
     LuaSettings, on a temporary folder. Run from the KOReader install folder
     (the one holding setupkoenv.lua), passing an optional library folder to
     time a full scan of it (fails above 1000 ms):
       cd /mnt/us/koreader          # Kindle and emulator
       ./luajit <plugin dir>/test_localindex.lua --koreader [library folder]
     The key is checked against the progress sync plugin the setting picks
     (syncedhistory_backend.lua): SYNCEDHISTORY_BACKEND=auto (default),
     kosync or serverless. Its main.lua is looked for in plugins/ and next
     to this plugin's folder.
]]

local mode = arg and arg[1] == "--koreader" and "koreader" or "standalone"
local library = arg and arg[2]

-- Let require() find the module next to this file.
local this_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = this_dir .. "/?.lua;" .. package.path

local env = {}

if mode == "koreader" then
    require("setupkoenv")
    local lfs = require("libs/libkoreader-lfs")
    local md5 = require("ffi/sha2").md5
    local util = require("util")
    local base = os.getenv("TMPDIR") or "/tmp"
    local top = base .. "/syncedhistory-test-" .. tostring(os.time())
    assert(lfs.mkdir(top))
    env.lfs = lfs
    env.md5 = md5
    env.top = top
    env.clock = require("socket").gettime

    function env.mkdir_p(path)
        local acc = ""
        for part in path:gmatch("[^/]+") do
            acc = acc .. "/" .. part
            if not lfs.attributes(acc, "mode") then lfs.mkdir(acc) end
        end
    end
    function env.mkfile(path, mtime)
        env.mkdir_p(path:match("^(.*)/[^/]*$"))
        local f = assert(io.open(path, "w"))
        f:write("x")
        f:close()
        if mtime then assert(lfs.touch(path, mtime, mtime)) end
    end
    function env.rmfile(path) assert(os.remove(path)) end
    function env.newSettings(name)
        local LuaSettings = require("luasettings")
        return LuaSettings:open(top .. "/" .. name .. ".settings.lua")
    end

    -- The key the chosen progress sync plugin computes for a book at `path`
    -- with the file-name method. Loading all of its main.lua needs a
    -- running device layer, so cut <Class>:getFileNameDigest (and
    -- <Class>:getFileName, which v2024.11 does not have yet) out of the
    -- plugin's source and run that text with its own md5 and util. If the
    -- source has changed shape, fail loudly.
    local Backend = require("syncedhistory_backend")
    local function exists(path)
        local fh = io.open(path, "r")
        if fh then fh:close() return true end
        return false
    end
    local backend, source = Backend.fromSources(os.getenv("SYNCEDHISTORY_BACKEND"),
        { "plugins", this_dir .. "/.." }, exists, print)
    assert(source, backend.plugin_dir .. "/main.lua not found")
    local f = assert(io.open(source))
    local src = f:read("*a")
    f:close()
    local cls = backend.class
    local fn_name = src:match("\nfunction " .. cls .. ":getFileName%(%).-\nend\n") or ""
    local fn_digest = src:match("\nfunction " .. cls .. ":getFileNameDigest%(%).-\nend\n")
    assert(fn_digest, cls .. " getFileNameDigest not found in " .. source)
    local chunk = assert(loadstring("local " .. cls .. ", md5, util = ...\n" .. fn_name .. fn_digest))
    local Plugin = {}
    chunk(Plugin, md5, util)
    env.kosync_source = source .. ", " .. cls .. ":getFileNameDigest source text (backend "
        .. backend.id .. ")"
    function env.kosyncKey(path)
        local fake = setmetatable({ ui = { document = { file = path } } }, { __index = Plugin })
        return fake:getFileNameDigest()
    end
    function env.cleanup() os.execute("rm -rf '" .. top .. "'") end
else
    -- In-memory file system with the two lfs calls the module uses.
    local nodes = { ["/lib"] = { mode = "directory" } }
    local function parent(path) return path:match("^(.*)/[^/]*$") end
    local fake_lfs = {}
    function fake_lfs.attributes(path, field)
        local n = nodes[path]
        if not n then return nil end
        local attr = { mode = n.mode, modification = n.mtime or 0 }
        if field then return attr[field] end
        return attr
    end
    function fake_lfs.dir(path)
        local n = nodes[path]
        if not n or n.mode ~= "directory" then error("cannot open " .. path) end
        local names = { ".", ".." }
        for p in pairs(nodes) do
            if parent(p) == path then names[#names + 1] = p:match("([^/]*)$") end
        end
        local i = 0
        return function() i = i + 1; return names[i] end, nil
    end
    env.lfs = fake_lfs
    env.md5 = function(s) return "md5<" .. s .. ">" end
    env.top = "/lib"
    env.clock = os.clock
    env.kosync_source = "fake md5; run with --koreader for the real key check"
    function env.kosyncKey(path) return "md5<" .. path:match("([^/]*)$") .. ">" end
    function env.mkdir_p(path)
        local acc = ""
        for part in path:gmatch("[^/]+") do
            acc = acc .. "/" .. part
            nodes[acc] = nodes[acc] or { mode = "directory" }
        end
    end
    function env.mkfile(path, mtime)
        env.mkdir_p(parent(path))
        nodes[path] = { mode = "file", mtime = mtime or os.time() }
    end
    function env.rmfile(path) nodes[path] = nil end
    function env.newSettings()
        local store = {}
        return {
            readSetting = function(_, k) return store[k] end,
            saveSetting = function(_, k, v) store[k] = v end,
            flush = function() end,
        }
    end
    function env.cleanup() end
end

local LocalIndex = require("syncedhistory_localindex")

local passed, failed = 0, 0
local function check(cond, msg)
    if not cond then error(msg or "check failed", 2) end
end
local function test(name, fn)
    local root = env.top .. "/" .. name:gsub("[^%w]+", "_")
    env.mkdir_p(root)
    local ok, err = pcall(fn, root)
    if ok then
        passed = passed + 1
        print("ok    " .. name)
    else
        failed = failed + 1
        print("FAIL  " .. name .. ": " .. tostring(err))
    end
end
local function newIndex(root, settings)
    return LocalIndex.new{
        lfs = env.lfs, md5 = env.md5, root = root,
        settings = settings or env.newSettings(root:match("([^/]*)$")),
        clock = env.clock,
    }
end

print("mode: " .. mode .. "; progress sync key from: " .. env.kosync_source)

test("key matches the progress sync key for the same file", function(root)
    local path = root .. "/Some Author/The Book (12).epub"
    env.mkfile(path)
    local index = newIndex(root)
    local key = index:keyFor(path)
    check(key == env.kosyncKey(path), "keyFor " .. tostring(key) .. " ~= " .. tostring(env.kosyncKey(path)))
    check(index:keyFor("The Book (12).epub") == key, "bare name and full path disagree")
    index:rescan()
    check(index:lookup(key) == path, "scan did not store the book under the sync key")
    if mode == "koreader" then
        -- Independent vector: printf '%s' 'The Book (12).epub' | md5sum
        check(key == "256fde4613c277f49a4b1c8d54298d87", "key differs from md5sum of the name")
    end
end)

test("depth: 3 levels down is indexed, 4 is not", function(root)
    local three = root .. "/a/b/three.epub"
    local four = root .. "/a/b/c/four.epub"
    env.mkfile(root .. "/one.pdf")
    env.mkfile(three)
    env.mkfile(four)
    local index = newIndex(root)
    local found, keys = index:scan()
    check(found[index:keyFor(three)] ~= nil, "level 3 file missing")
    check(found[index:keyFor(root .. "/one.pdf")] ~= nil, "level 1 file missing")
    check(found[index:keyFor(four)] == nil, "level 4 file indexed")
    check(keys == 2, "expected 2 keys, got " .. keys)
end)

test("only documents; hidden entries and .sdr folders skipped", function(root)
    env.mkfile(root .. "/book.mobi")
    env.mkfile(root .. "/cover.jpg")
    env.mkfile(root .. "/script.lua")
    env.mkfile(root .. "/.hidden/secret.epub")
    env.mkfile(root .. "/book.sdr/inside.epub")
    local _, keys = newIndex(root):scan()
    check(keys == 1, "expected only book.mobi, got " .. keys .. " keys")
end)

test("stale cache entry triggers one rescan", function(root)
    local settings = env.newSettings("stale")
    local index = newIndex(root, settings)
    local key = index:keyFor("moved.epub")
    -- A cache from an earlier run pointing to where the book used to be.
    index.cache[key] = root .. "/old/moved.epub"
    local now = root .. "/new/moved.epub"
    env.mkfile(now)
    check(index:lookup(key) == now, "lookup did not find the moved book")
    check(index.scan_count == 1, "expected 1 scan, got " .. index.scan_count)
    check(index:lookup(key) == now, "second lookup lost the book")
    check(index.scan_count == 1, "hit after rescan scanned again")
    -- The fresh cache was saved.
    local reopened = newIndex(root, settings)
    check(reopened.cache[key] == now, "rescan did not persist the cache")
end)

test("second miss in the same session does not rescan", function(root)
    env.mkfile(root .. "/here.epub")
    local index = newIndex(root)
    check(index:lookup(index:keyFor("absent.epub")) == nil, "absent book found")
    check(index.scan_count == 1, "first miss should rescan once")
    -- A book that appears after the rescan stays unknown this session.
    env.mkfile(root .. "/late.epub")
    check(index:lookup(index:keyFor("late.epub")) == nil, "second miss rescanned")
    check(index:lookup(index:keyFor("absent.epub")) == nil, "absent book found")
    check(index.scan_count == 1, "expected 1 scan, got " .. index.scan_count)
    -- An explicit rescan still works.
    index:rescan()
    check(index:lookup(index:keyFor("late.epub")) == root .. "/late.epub", "explicit rescan missed late.epub")
end)

test("forced rescan picks up a book copied in after the automatic one", function(root)
    env.mkfile(root .. "/first.epub")
    local index = newIndex(root)
    local key = index:keyFor("copied later.epub")
    check(index:lookup(key) == nil, "found before it was copied")
    check(index.rescanned and index.scan_count == 1, "the miss did not use the automatic rescan")
    env.mkfile(root .. "/sub/copied later.epub")
    check(index:lookup(key) == nil, "a second automatic rescan ran")
    -- What the list's Refresh does.
    check(index:rescan() == 2, "rescan count")
    check(index.scan_count == 2, "forced rescan did not scan")
    check(index:lookup(key) == root .. "/sub/copied later.epub", "forced rescan missed the new book")
end)

test("duplicate name: the newer file wins", function(root)
    env.mkfile(root .. "/x/dup.epub", 1000000000)
    env.mkfile(root .. "/y/dup.epub", 1500000000)
    env.mkfile(root .. "/x/dup2.epub", 1500000000)
    env.mkfile(root .. "/y/dup2.epub", 1000000000)
    local index = newIndex(root)
    index:rescan()
    check(index:lookup(index:keyFor("dup.epub")) == root .. "/y/dup.epub", "dup.epub: older file won")
    check(index:lookup(index:keyFor("dup2.epub")) == root .. "/x/dup2.epub", "dup2.epub: older file won")
end)

test("cached path is used without scanning", function(root)
    local path = root .. "/kept.epub"
    env.mkfile(path)
    local settings = env.newSettings("kept")
    newIndex(root, settings):rescan()
    local index = newIndex(root, settings)
    check(index:lookup(index:keyFor(path)) == path, "cached path not returned")
    check(index.scan_count == 0, "cache hit scanned")
end)

test("timeScan returns count and milliseconds without touching the cache", function(root)
    env.mkfile(root .. "/a.epub")
    env.mkfile(root .. "/d/b.pdf")
    local index = newIndex(root)
    local keys, ms, files = index:timeScan()
    check(keys == 2 and files == 2, "expected 2 documents")
    check(type(ms) == "number" and ms >= 0, "bad ms")
    check(next(index.cache) == nil and index.scan_count == 0, "timeScan changed the cache")
end)

if library then
    local index = newIndex(library, { readSetting = function() end, saveSetting = function() end, flush = function() end })
    local keys, ms, files = index:timeScan()
    print(string.format("library scan: %s -> %d documents (%d files) in %.1f ms", library, keys, files, ms))
    if ms < 1000 then
        passed = passed + 1
        print("ok    library scan under 1 s")
    else
        failed = failed + 1
        print("FAIL  library scan took " .. ms .. " ms")
    end
end

env.cleanup()
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
