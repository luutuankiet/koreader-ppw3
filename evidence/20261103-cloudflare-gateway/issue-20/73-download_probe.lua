-- Downloads public GitHub Release assets through the installer's own download
-- function (pluginpackages_core.lua Core.httpGet), with certificate checks on,
-- and compares each file's sha256 with the digest GitHub publishes for it.
--
-- Run inside koreader-emu, from the KOReader install folder, with the plugin
-- copied to /tmp/pp73 (not into plugins/, so the running KOReader is untouched):
--   docker cp pluginpackages.koplugin koreader-emu:/tmp/pp73
--   docker cp 73-download_probe.lua koreader-emu:/tmp/pp73/
--   docker exec koreader-emu sh -c 'cd /mnt/us/koreader && ./luajit /tmp/pp73/73-download_probe.lua'
require("setupkoenv")
package.path = "/tmp/pp73/?.lua;" .. package.path
-- socketutil loads the device module, which reads these globals; throwaway
-- copies so the running KOReader's settings are never touched.
G_defaults = require("luadefaults"):open("/tmp/pp73/defaults.lua")
G_reader_settings = require("luasettings"):open("/tmp/pp73/settings.lua")
local Core = require("pluginpackages_core")

-- Log every host whose certificate name is checked, to show the redirect
-- target is verified too, not only github.com.
local real_match = Core.hostMatches
Core.hostMatches = function(names, host)
    local ok = real_match(names, host)
    print(string.format("  tls name check: %s -> %s", host, tostring(ok)))
    return ok
end

local failures = 0
local function expect(cond, what)
    print((cond and "PASS " or "FAIL ") .. what)
    if not cond then failures = failures + 1 end
end

print("CA file: " .. Core.CA_FILE .. " exists=" .. tostring(io.open(Core.CA_FILE) ~= nil))

-- GitHub's API publishes a sha256 digest for each asset; these were read with
-- gh api repos/<owner>/<repo>/releases/latest on 2026-11-03.
local assets = {
    {
        url = "https://github.com/cli/cli/releases/download/v2.103.3/gh_2.103.3_checksums.txt",
        size = 1971,
        sha256 = "f756e7859d90dbb5e85aae5194206c37da220bec9bac23d3d659078a8e766fdc",
    },
    {
        url = "https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader_2026.07.1-1_armhf.deb",
        size = 28469960,
        sha256 = "4e9326f6c99c0df7fb0380645a0b96b8ec030095d021393f1c6983803211b6bc",
    },
}
for i, a in ipairs(assets) do
    local path = "/tmp/pp73/asset" .. i
    print("GET " .. a.url)
    local t0 = os.time()
    local ok, err = Core.httpGet(a.url, path)
    local f = io.open(path, "rb")
    local size = f and f:seek("end")
    if f then f:close() end
    local sum = ok and Core.sha256File(path)
    print(string.format("  result=%s err=%s size=%s sha256=%s seconds=%d",
        tostring(ok), tostring(err), tostring(size), tostring(sum), os.time() - t0))
    expect(ok == true and size == a.size and sum == a.sha256, "asset " .. i .. " downloaded, size and sha256 match")
    os.remove(path)
end

-- The index fetch path (string body) over https.
local body, err = Core.httpGet("https://raw.githubusercontent.com/koreader/koreader/master/README.md")
expect(type(body) == "string" and body:find("KOReader", 1, true) ~= nil,
    "string GET from raw.githubusercontent.com: " .. tostring(body and #body or err))

-- Certificate checks are really on: each of these must be refused.
for _, url in ipairs{
    "https://self-signed.badssl.com/",
    "https://untrusted-root.badssl.com/",
    "https://expired.badssl.com/",
    "https://wrong.host.badssl.com/",
} do
    local res, why = Core.httpGet(url)
    expect(res == nil, "refused " .. url .. ": " .. tostring(why))
end

-- Control: the same host family with a good certificate is accepted.
local res, why = Core.httpGet("https://badssl.com/")
expect(res ~= nil, "accepted https://badssl.com/: " .. tostring(res and #res or why))

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
