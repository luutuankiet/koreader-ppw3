-- Installs syncedhistory from the public GitHub manifest (empty host setting,
-- so Core.DEFAULT_INDEX) through the installer's own code: Core.httpGet with
-- certificate checks, parseIndex, prepare (size, sha256, version) and swapIn.
-- The plugins folder is a throwaway /tmp/pp20/plugins, so the running
-- KOReader in koreader-emu is untouched.
--   docker cp pluginpackages.koplugin koreader-emu:/tmp/pp20
--   docker cp 20-public-install.lua koreader-emu:/tmp/pp20/
--   docker exec koreader-emu sh -c 'cd /mnt/us/koreader && ./luajit /tmp/pp20/20-public-install.lua'
require("setupkoenv")
package.path = "/tmp/pp20/?.lua;" .. package.path
G_defaults = require("luadefaults"):open("/tmp/pp20/defaults.lua")
G_reader_settings = require("luasettings"):open("/tmp/pp20/settings.lua")
local Core = require("pluginpackages_core")
local rapidjson = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")

local failures = 0
local function expect(cond, what)
    print((cond and "PASS " or "FAIL ") .. what)
    if not cond then failures = failures + 1 end
end

local index_url, base = Core.indexLocation("")
print("index: " .. index_url)
local ok, err = Core.httpGet(index_url, "/tmp/pp20/index.json")
expect(ok, "manifest downloaded with TLS checks: " .. tostring(err))
local f = io.open("/tmp/pp20/index.json"); local body = f:read("*a"); f:close()
local plugins, perr = Core.parseIndex(rapidjson.decode(body))
expect(plugins ~= nil, "manifest parsed " .. tostring(perr))
local entry
for _, p in ipairs(plugins or {}) do
    print(string.format("  entry %s %s", p.name, p.version))
    if p.name == "syncedhistory" then entry = p end
end
expect(entry ~= nil, "syncedhistory listed")
local root = "/tmp/pp20/plugins"
lfs.mkdir(root)
local new_dir, e2 = Core.prepare(entry, { root = root, url = Core.packageUrl(entry, base), fetch = Core.httpGet })
expect(new_dir ~= nil, "prepare: downloaded, size and sha256 match, version " .. entry.version .. " " .. tostring(e2))
if new_dir then
    expect(Core.swapIn(root, entry.name, new_dir), "swapped into " .. root)
    expect(Core.readVersion(root .. "/syncedhistory.koplugin") == entry.version, "installed version reads " .. entry.version)
end
print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
