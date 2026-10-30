-- Run from a KOReader install folder, with its own luajit:
--   ./luajit /path/to/pluginpackages.koplugin/test_core.lua
-- Needs tar and gzip on PATH to build the test archives.
require("setupkoenv")
local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. package.path

local lfs = require("libs/libkoreader-lfs")
local Core = require("pluginpackages_core")

local failures, count = 0, 0
local function check(cond, what)
    count = count + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. what)
    end
end

local base = os.getenv("TEST_DIR") or ("/tmp/pp-test-" .. tostring(os.time()))
Core.removeTree(base)
lfs.mkdir(base)

local function write(path, content)
    local parent = path:match("^(.*)/[^/]+$")
    os.execute("mkdir -p '" .. parent .. "'")
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end
local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end
local function exists(path) return lfs.attributes(path, "mode") ~= nil end
local function meta(v) return 'local _ = require("gettext")\nreturn { name = "demo", version = "' .. v .. '" }\n' end

local n = 0
local function freshRoot()
    n = n + 1
    local root = base .. "/plugins" .. n
    lfs.mkdir(root)
    return root
end

-- Builds a package the way scripts/publish.sh does; returns an index entry.
local function buildPackage(name, version, files, top)
    n = n + 1
    local work = base .. "/build" .. n
    top = top or (name .. ".koplugin")
    write(work .. "/" .. top .. "/_meta.lua", meta(version))
    write(work .. "/" .. top .. "/main.lua", "return {} -- " .. version .. "\n")
    for rel, content in pairs(files or {}) do write(work .. "/" .. top .. "/" .. rel, content) end
    local file = name .. "-" .. version .. ".tar.gz"
    local archive = base .. "/" .. n .. "-" .. file
    assert(os.execute(string.format("tar -C '%s' --format=ustar -cf - '%s' | gzip -n > '%s'", work, top, archive)) == 0)
    return {
        name = name, version = version, file = file,
        size = lfs.attributes(archive, "size"),
        sha256 = Core.sha256File(archive),
    }, archive
end

local function copyTo(archive)
    return function(_, path) return os.execute(string.format("cp '%s' '%s'", archive, path)) == 0 end
end

local function install(root, entry, archive, extra)
    local new_dir, err = Core.prepare(entry, {
        root = root, url = "http://host/" .. entry.file,
        fetch = copyTo(archive),
        no_archiver = extra and extra.no_archiver,
    })
    if not new_dir then return nil, err end
    return Core.swapIn(root, entry.name, new_dir, extra and extra.rename)
end

for _, mode in ipairs{ "archiver", "tar" } do
    local no_archiver = mode == "tar"
    local has_archiver = pcall(require, "ffi/archiver")
    if no_archiver or has_archiver then
        -- Fresh install, then an upgrade that keeps the old one as .bak.
        local root = freshRoot()
        local e1, a1 = buildPackage("demo", "1.0.0", { ["sub/deep/mod.lua"] = "one" })
        local ok, err = install(root, e1, a1, { no_archiver = no_archiver })
        check(ok, mode .. " fresh install: " .. tostring(err))
        check(read(root .. "/demo.koplugin/sub/deep/mod.lua") == "one", mode .. " nested file unpacked")
        check(Core.readVersion(root .. "/demo.koplugin") == "1.0.0", mode .. " installed version")
        check(not exists(root .. "/" .. Core.STAGE), mode .. " stage removed after install")
        check(not exists(root .. "/demo.koplugin.bak"), mode .. " no .bak after fresh install")

        local e2, a2 = buildPackage("demo", "2.0.0", { ["sub/deep/mod.lua"] = "two" })
        ok, err = install(root, e2, a2, { no_archiver = no_archiver })
        check(ok, mode .. " upgrade: " .. tostring(err))
        check(Core.readVersion(root .. "/demo.koplugin") == "2.0.0", mode .. " upgraded version")
        check(Core.readVersion(root .. "/demo.koplugin.bak") == "1.0.0", mode .. " old version kept as .bak")
        check(read(root .. "/demo.koplugin/sub/deep/mod.lua") == "two", mode .. " upgraded file")
    end
end

-- The reader's accounts survive an upgrade of a folder deployed by hand: the
-- archive deliberately leaves these two files out.
do
    local root = freshRoot()
    write(root .. "/rssreader.koplugin/_meta.lua", meta("0.4.0"))
    write(root .. "/rssreader.koplugin/main.lua", "old")
    write(root .. "/rssreader.koplugin/rssreader_configuration.lua", "return {accounts='secret'}")
    write(root .. "/rssreader.koplugin/rssreader_local_defaults.lua", "return {local=true}")
    write(root .. "/rssreader.koplugin/state/cache/feeds.json", "{}")
    local e, a = buildPackage("rssreader", "0.4.1")
    local ok, err = install(root, e, a)
    check(ok, "rssreader upgrade: " .. tostring(err))
    check(Core.readVersion(root .. "/rssreader.koplugin") == "0.4.1", "rssreader upgraded")
    check(read(root .. "/rssreader.koplugin/rssreader_configuration.lua") == "return {accounts='secret'}",
        "credentials file carried across the swap")
    check(read(root .. "/rssreader.koplugin/rssreader_local_defaults.lua") == "return {local=true}",
        "local defaults carried across the swap")
    check(read(root .. "/rssreader.koplugin/state/cache/feeds.json") == "{}", "nested local state carried")
    check(read(root .. "/rssreader.koplugin.bak/rssreader_configuration.lua") == "return {accounts='secret'}",
        ".bak stays whole")
    check(read(root .. "/rssreader.koplugin/main.lua") ~= "old", "package file replaced, not carried")

    -- Credentials changed after the upgrade follow a rollback and a second one.
    write(root .. "/rssreader.koplugin/rssreader_configuration.lua", "return {accounts='changed'}")
    ok, err = Core.rollback(root, "rssreader")
    check(ok, "rollback: " .. tostring(err))
    check(Core.readVersion(root .. "/rssreader.koplugin") == "0.4.0", "rolled back")
    check(Core.readVersion(root .. "/rssreader.koplugin.bak") == "0.4.1", "newer version now .bak")
    check(read(root .. "/rssreader.koplugin/rssreader_configuration.lua") == "return {accounts='changed'}",
        "changed credentials follow the rollback")
    ok, err = Core.rollback(root, "rssreader")
    check(ok, "second rollback: " .. tostring(err))
    check(Core.readVersion(root .. "/rssreader.koplugin") == "0.4.1", "second rollback returns to the upgrade")
    check(read(root .. "/rssreader.koplugin/rssreader_configuration.lua") == "return {accounts='changed'}",
        "credentials intact after the second rollback")
end

-- A file an older package shipped and a newer one dropped is not carried, but
-- local files still are, once the folder came from the installer.
do
    local root = freshRoot()
    local e1, a1 = buildPackage("demo", "1.0.0", { ["removed.lua"] = "gone" })
    assert(install(root, e1, a1))
    write(root .. "/demo.koplugin/local.lua", "mine")
    local e2, a2 = buildPackage("demo", "2.0.0")
    local ok, err = install(root, e2, a2)
    check(ok, "upgrade with manifest: " .. tostring(err))
    check(not exists(root .. "/demo.koplugin/removed.lua"), "file dropped by the package is gone")
    check(read(root .. "/demo.koplugin/local.lua") == "mine", "local file kept")
end

-- Every way a package can be bad leaves the installed plugin untouched.
do
    local function assertUntouched(root, what)
        check(read(root .. "/demo.koplugin/main.lua") == "installed", what .. ": old plugin untouched")
        check(not exists(root .. "/demo.koplugin.bak"), what .. ": no .bak made")
    end
    local function installedRoot()
        local root = freshRoot()
        write(root .. "/demo.koplugin/_meta.lua", meta("1.0.0"))
        write(root .. "/demo.koplugin/main.lua", "installed")
        return root
    end
    local e, a = buildPackage("demo", "2.0.0")

    local root = installedRoot()
    local bad = {}
    for k, v in pairs(e) do bad[k] = v end
    bad.sha256 = string.rep("0", 64)
    local ok, err = install(root, bad, a)
    check(not ok and err == "checksum mismatch", "bad checksum refused: " .. tostring(err))
    assertUntouched(root, "bad checksum")

    root = installedRoot()
    local data = read(a)
    local half = base .. "/half.tar.gz"
    write(half, data:sub(1, math.floor(#data / 2)))
    ok, err = install(root, e, half)
    check(not ok and err:find("incomplete download", 1, true), "half download refused: " .. tostring(err))
    assertUntouched(root, "half download")

    -- A half file the index agrees with: only the unpacker can notice.
    root = installedRoot()
    local forged = {}
    for k, v in pairs(e) do forged[k] = v end
    forged.size = lfs.attributes(half, "size")
    forged.sha256 = Core.sha256File(half)
    ok, err = install(root, forged, half)
    check(not ok, "truncated archive refused by the unpacker")
    assertUntouched(root, "truncated archive")

    root = installedRoot()
    ok, err = Core.prepare(e, { root = root, url = "u", fetch = function() return nil, "connection refused" end })
    check(not ok and err:find("connection refused", 1, true), "failed download reported: " .. tostring(err))
    assertUntouched(root, "failed download")

    root = installedRoot()
    local we, wa = buildPackage("demo", "2.0.0", nil, "other.koplugin")
    ok, err = install(root, we, wa)
    check(not ok, "archive with the wrong top folder refused: " .. tostring(err))
    assertUntouched(root, "wrong top folder")

    -- Index and archive disagree on the version.
    root = installedRoot()
    local ve = {}
    for k, v in pairs(e) do ve[k] = v end
    ve.version = "3.0.0"
    ok, err = install(root, ve, a)
    check(not ok and err:find("index says", 1, true), "version mismatch refused: " .. tostring(err))
    assertUntouched(root, "version mismatch")
end

-- A rename failing partway puts every folder back.
do
    local real = os.rename
    local function failOn(nth)
        local calls = 0
        return function(from, to)
            calls = calls + 1
            if calls == nth then return nil, "injected failure" end
            return real(from, to)
        end
    end
    for nth = 1, 3 do
        local root = freshRoot()
        local e1, a1 = buildPackage("demo", "1.0.0")
        assert(install(root, e1, a1))
        local e2, a2 = buildPackage("demo", "2.0.0")
        assert(install(root, e2, a2))
        local e3, a3 = buildPackage("demo", "3.0.0")
        local ok, err = install(root, e3, a3, { rename = failOn(nth) })
        check(not ok and err == "injected failure", "swap failure " .. nth .. " reported: " .. tostring(err))
        check(os.rename == real, "os.rename restored")
        check(Core.readVersion(root .. "/demo.koplugin") == "2.0.0", "swap failure " .. nth .. ": current restored")
        check(Core.readVersion(root .. "/demo.koplugin.bak") == "1.0.0", "swap failure " .. nth .. ": .bak restored")

        ok, err = Core.rollback(root, "demo", failOn(nth))
        check(not ok and err == "injected failure", "rollback failure " .. nth .. " reported")
        check(Core.readVersion(root .. "/demo.koplugin") == "2.0.0", "rollback failure " .. nth .. ": current restored")
        check(Core.readVersion(root .. "/demo.koplugin.bak") == "1.0.0", "rollback failure " .. nth .. ": .bak restored")
    end

    local root = freshRoot()
    local ok, err = Core.rollback(root, "demo")
    check(not ok and err == "nothing to roll back to", "rollback without .bak refused")
end

-- The index is the only outside text that becomes paths.
do
    local good = { name = "a", version = "1", file = "a-1.tar.gz", size = 1, sha256 = string.rep("a", 64) }
    local function with(k, v)
        local e = {}
        for key, val in pairs(good) do e[key] = val end
        e[k] = v
        return e
    end
    local list = Core.parseIndex{ format = 1, plugins = {
        good,
        with("name", "../evil"), with("file", "../../evil.tar.gz"), with("file", "a/b.tar.gz"),
        with("file", "..tar.gz"), with("sha256", "abc"), with("size", "12"),
    } }
    check(#list == 1 and list[1] == good, "only the clean index entry survives, got " .. #list)
    check(Core.parseIndex{ format = 2, plugins = {} } == nil, "unknown index format refused")
    check(Core.parseIndex("x") == nil, "non-table index refused")
end

check(Core.compareVersions("0.10.0", "0.9.1") > 0, "numeric version compare")
check(Core.compareVersions("1.0", "1.0.0") == 0, "missing parts count as zero")
check(Core.compareVersions("0.4.0", "0.4.1") < 0, "older version sorts lower")

do
    local root = freshRoot()
    write(root .. "/a.koplugin.bak/main.lua", "")
    write(root .. "/b.koplugin/main.lua", "")
    local list = Core.listBackups(root)
    check(#list == 1 and list[1] == "a", "listBackups finds only .bak folders")
end

Core.removeTree(base)
print(string.format("%d checks, %d failed", count, failures))
os.exit(failures == 0 and 0 or 1)
