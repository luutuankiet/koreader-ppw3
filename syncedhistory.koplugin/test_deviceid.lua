--[[--
Tests for syncedhistory_deviceid.lua. main.lua never loads this file. The
serial is a fake file in a temporary folder; /proc/usid is never read.

Two ways to run it:

  1. Standalone, any LuaJIT or Lua 5.1, fake md5, in-memory settings:
       luajit test_deviceid.lua

  2. With KOReader's own luajit, real md5 (ffi/sha2) and real LuaSettings,
     which also checks the derived id against one computed outside KOReader.
     Run from the KOReader install folder (the one holding setupkoenv.lua):
       cd /mnt/us/koreader          # Kindle and emulator
       ./luajit <plugin dir>/test_deviceid.lua --koreader
]]

local mode = arg and arg[1] == "--koreader" and "koreader" or "standalone"

local this_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = this_dir .. "/?.lua;" .. package.path

local SERIAL = "G090FAKESERIAL01" -- fake, 16 characters like a PW3's
-- md5("kosync:G090FAKESERIAL01"), uppercase, computed with Python's hashlib.
local SERIAL_ID = "326F5DD53167B52A5208AE50047812E8"
local OLD_ID = "3C6A84AA41A545BB9917DDF53D8599ED"

local env = {}
local top = (os.getenv("TMPDIR") or "/tmp") .. "/syncedhistory-deviceid-test-" .. tostring(os.time())
os.execute("mkdir -p '" .. top .. "'")

if mode == "koreader" then
    require("setupkoenv")
    env.md5 = require("ffi/sha2").md5
    local n = 0
    function env.newSettings(data)
        n = n + 1
        local s = require("luasettings"):open(top .. "/s" .. n .. ".lua")
        for k, v in pairs(data or {}) do s:saveSetting(k, v) end
        s:flush()
        return s
    end
    function env.reopen(s) return require("luasettings"):open(s.file) end
    function env.flushes() return nil end
else
    env.md5 = function(s) return "md5<" .. s .. ">" end
    local flushes = 0
    function env.newSettings(data)
        local d = {}
        for k, v in pairs(data or {}) do d[k] = v end
        return {
            data = d,
            readSetting = function(_, k) return d[k] end,
            saveSetting = function(_, k, v) d[k] = v end,
            flush = function() flushes = flushes + 1 end,
        }
    end
    function env.reopen(s) return s end
    function env.flushes() return flushes end
end

local DeviceId = require("syncedhistory_deviceid")

local function writeFile(name, content)
    local path = top .. "/" .. name
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
    return path
end

local log_lines = {}
local log = { info = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    log_lines[#log_lines + 1] = table.concat(parts, " ")
end }

local expected = mode == "koreader" and SERIAL_ID or ("md5<kosync:" .. SERIAL .. ">"):upper()

local passed, failed = 0, 0
local function eq(a, b, msg)
    if a ~= b then
        error((msg or "values differ") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
    end
end
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok    " .. name)
    else
        failed = failed + 1
        print("FAIL  " .. name .. ": " .. tostring(err))
    end
end

print("mode: " .. mode)

test("a serial file sets the derived id and flushes it", function()
    local path = writeFile("usid", SERIAL .. "\n") -- /proc/usid ends in a newline
    local s = env.newSettings{ device_id = OLD_ID, other = "kept" }
    local before = env.flushes()
    eq(DeviceId.apply{ settings = s, md5 = env.md5, path = path, log = log }, "changed")
    eq(s:readSetting("device_id"), expected)
    if before then eq(env.flushes(), before + 1, "one flush") end
    local again = env.reopen(s)
    eq(again:readSetting("device_id"), expected, "on disk after the flush")
    eq(again:readSetting("other"), "kept", "other settings untouched")
end)

test("the real md5 gives the id computed outside KOReader", function()
    if mode ~= "koreader" then print("      (skipped: standalone)"); return end
    eq(DeviceId.derive(SERIAL, env.md5), SERIAL_ID)
end)

test("a second run is a no-op: no write, no flush", function()
    local path = writeFile("usid2", SERIAL)
    local s = env.newSettings{ device_id = expected }
    local before = env.flushes()
    eq(DeviceId.apply{ settings = s, md5 = env.md5, path = path, log = log }, "same")
    eq(s:readSetting("device_id"), expected)
    if before then eq(env.flushes(), before, "no flush") end
end)

test("a missing serial file leaves the setting untouched", function()
    local s = env.newSettings{ device_id = OLD_ID }
    local before = env.flushes()
    eq(DeviceId.apply{ settings = s, md5 = env.md5, path = top .. "/no-such-file", log = log }, "no_serial")
    eq(s:readSetting("device_id"), OLD_ID)
    if before then eq(env.flushes(), before, "no flush") end
end)

test("an empty or blank serial file leaves the setting untouched", function()
    for i, content in ipairs({ "", " \n" }) do
        local s = env.newSettings{ device_id = OLD_ID }
        eq(DeviceId.apply{ settings = s, md5 = env.md5, path = writeFile("empty" .. i, content), log = log },
            "no_serial", "content " .. string.format("%q", content))
        eq(s:readSetting("device_id"), OLD_ID)
    end
end)

test("no device id yet: the derived one is set", function()
    local s = env.newSettings()
    eq(DeviceId.apply{ settings = s, md5 = env.md5, path = writeFile("usid3", SERIAL), log = log }, "changed")
    eq(s:readSetting("device_id"), expected)
end)

test("the serial never reaches the log; the id's last 4 characters do", function()
    eq(#log_lines > 0, true, "nothing was logged")
    for _, line in ipairs(log_lines) do
        eq(line:find(SERIAL, 1, true), nil, "serial logged: " .. line)
        eq(line:find(expected, 1, true), nil, "whole id logged: " .. line)
    end
    eq(log_lines[1]:sub(-4), expected:sub(-4))
end)

os.execute("rm -rf '" .. top .. "'")
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
