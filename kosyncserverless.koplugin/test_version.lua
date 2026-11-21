-- Tests for kosyncserverless_version.lua: luajit test_version.lua
local this_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = this_dir .. "/?.lua;" .. package.path
local Version = require("kosyncserverless_version")

local passed, failed = 0, 0
local function test(name, f)
    local ok, err = pcall(f)
    if ok then passed = passed + 1; print("ok    " .. name) else failed = failed + 1; print("FAIL  " .. name .. ": " .. tostring(err)) end
end

local OLD, NEW = "2026-11-20T15:42:16.942Z", "2026-11-21T10:00:00Z"

test("parses ISO times in UTC", function()
    assert(Version.toEpoch("2026-11-21T10:00:00Z") == 1795255200)
    assert(Version.toEpoch("nope") == nil)
end)

test("same or newer server version, or unknown: pull as usual", function()
    assert(Version.decide(NEW, NEW, 1, 2) == "pull")
    assert(Version.decide(OLD, NEW, 1, 2) == "pull")
    assert(Version.decide(NEW, nil, 1, 2) == "pull")
    assert(Version.decide(nil, OLD, 1, 2) == "pull")
end)

test("older server version: newest timestamp wins", function()
    assert(Version.decide(NEW, OLD, 200, 100) == "percent")
    assert(Version.decide(NEW, OLD, 100, 200) == "keep_local")
end)

test("version from a sidecar record", function()
    assert(Version.fromRecord({ id = "x", modified = NEW }) == NEW)
    assert(Version.fromRecord({ id = "x" }) == nil)
    assert(Version.fromRecord(nil) == nil)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
