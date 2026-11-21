--[[--
Tests for syncedhistory_drive.lua. Plain luajit, no KOReader:
  luajit test_drive.lua
]]

local this_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = this_dir .. "/?.lua;" .. package.path
local Drive = require("syncedhistory_drive")

local passed, failed = 0, 0
local function check(c, msg) if not c then error(msg or "check failed", 2) end end
local function test(name, f)
    local ok, err = pcall(f)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end

test("ISO times parse in UTC, fraction kept", function()
    check(Drive.isoToEpoch("1970-01-01T00:00:00Z") == 0, "epoch")
    check(Drive.isoToEpoch("2026-11-21T10:00:00Z") == 1795255200, "date")
    check(Drive.isoToEpoch("2026-11-21T10:00:00.5Z") == 1795255200.5, "fraction")
    check(Drive.isoToEpoch("yesterday") == nil, "garbage")
    check(Drive.epochToIso(1795255200) == "2026-11-21T10:00:00Z", "round trip")
end)

test("isNewer compares times, not strings", function()
    check(Drive.isNewer("2026-11-21T10:00:00.100Z", "2026-11-21T10:00:00Z"), "fraction newer")
    check(not Drive.isNewer("2026-11-21T10:00:00Z", "2026-11-21T10:00:00Z"), "equal")
    check(Drive.isNewer("2026-11-21T10:00:00Z", nil), "no local version")
    check(not Drive.isNewer(nil, "2026-11-21T10:00:00Z"), "no drive version")
end)

test("resolve: server source first, then exactly one name match", function()
    local got
    Drive.resolve({ source = { kind = "gdrive", id = "S1" }, filename = "A.epub" },
        function() error("searched") end, function(item) got = item end)
    check(got.id == "S1", "server id")
    local function finder(items) return function(_, cb) cb(true, items) end end
    local reason
    Drive.resolve({ filename = "A.epub" }, finder({}), function(i, r) got, reason = i, r end)
    check(got == nil and reason == "none", "zero")
    Drive.resolve({ filename = "A.epub" }, finder({ { id = 1 }, { id = 2 } }), function(i, r) got, reason = i, r end)
    check(got == nil and reason == "many", "several")
    Drive.resolve({ filename = "A.epub" }, finder({ { id = "X" } }), function(i) got = i end)
    check(got.id == "X", "one")
    Drive.resolve({ filename = "A.epub" }, function(_, cb) cb(false, "network") end, function(i, r) got, reason = i, r end)
    check(got == nil and reason == "network", "error code")
end)

test("clash only for another gdrive id", function()
    check(Drive.clash({ source = { kind = "gdrive", id = "A" } }, { id = "B" }), "different")
    check(not Drive.clash({ source = { kind = "gdrive", id = "A" } }, { id = "A" }), "same")
    check(not Drive.clash({}, { id = "A" }), "none on server")
end)

test("backfill record: older file on disk is marked out of date", function()
    local item = { id = "X", modifiedTime = "2026-11-21T10:00:00Z" }
    local t = Drive.isoToEpoch(item.modifiedTime)
    check(Drive.backfillRecord(item, t + 5).modified == item.modifiedTime, "newer file")
    check(Drive.backfillRecord(item, t).modified == item.modifiedTime, "equal file")
    local old = Drive.backfillRecord(item, t - 3600)
    check(old.modified == "2026-11-21T09:00:00Z", "older file: " .. tostring(old.modified))
    check(Drive.isNewer(item.modifiedTime, old.modified), "next check must see Drive newer")
end)

test("backfill: one request at a time, only books without a record", function()
    local records = { ["/b/Has.epub"] = { id = "H" } }
    local answers = {
        ["One.epub"] = { { id = "1", modifiedTime = "2026-01-01T00:00:00Z" } },
        ["Two.epub"] = { { id = "2a" }, { id = "2b" } },
        ["None.epub"] = {},
    }
    local searched, in_flight, max_flight, pushed, stats = {}, 0, 0, {}, nil
    local pending = {}
    Drive.backfill{
        paths = { "/b/Has.epub", "/b/One.epub", "/b/Two.epub", "/b/None.epub" },
        readRecord = function(p) return records[p] end,
        writeRecord = function(p, r) records[p] = r end,
        basename = function(p) return p:match("[^/]+$") end,
        mtime = function() return 1800000000 end,
        find = function(name, cb)
            searched[#searched + 1] = name
            in_flight = in_flight + 1
            if in_flight > max_flight then max_flight = in_flight end
            pending[#pending + 1] = function() in_flight = in_flight - 1; cb(true, answers[name]) end
        end,
        push = function(p) pushed[#pushed + 1] = p end,
        done = function(s) stats = s end,
    }
    while #pending > 0 do table.remove(pending, 1)() end
    check(#searched == 3, "searched " .. #searched)
    check(max_flight == 1, "requests overlapped")
    check(records["/b/One.epub"].id == "1", "match not written")
    check(records["/b/Two.epub"] == nil and records["/b/None.epub"] == nil, "guessed a record")
    check(#pushed == 1 and pushed[1] == "/b/One.epub", "push")
    check(stats.matched == 1 and stats.skipped == 2, "stats")
end)

test("backfill stops when Drive is not paired", function()
    local calls, stats = 0, nil
    Drive.backfill{
        paths = { "/b/A.epub", "/b/B.epub" },
        readRecord = function() return nil end,
        writeRecord = function() error("wrote") end,
        basename = function(p) return p end,
        mtime = function() return 0 end,
        find = function(_, cb) calls = calls + 1; cb(false, "not_paired") end,
        done = function(s) stats = s end,
    }
    check(calls == 1 and stats.failed == 1, "kept going")
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
