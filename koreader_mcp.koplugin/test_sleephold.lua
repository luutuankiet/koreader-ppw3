-- Run with: luajit test_sleephold.lua   (from koreader_mcp.koplugin/)
package.path = "./?.lua;" .. package.path
local SleepHold = require("sleephold")

local failures, count = 0, 0
local function test(name, fn)
    count = count + 1
    local ok, err = pcall(fn)
    if not ok then failures = failures + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b) if a ~= b then error(tostring(a) .. " ~= " .. tostring(b), 2) end end

local function world(opts)
    opts = opts or {}
    local w = { cmds = {}, logs = {}, share = {}, presses = 0 }
    w.hold = SleepHold.new({
        is_kindle = opts.is_kindle ~= false,
        share = w.share,
        exec = function(cmd) w.cmds[#w.cmds + 1] = cmd end,
        log = function(msg) w.logs[#w.logs + 1] = msg end,
    })
    -- Stands in for KindlePowerD: toggleSuspend is the simulated power button press.
    w.powerd = {}
    function w.powerd:toggleSuspend()
        w.presses = w.presses + 1
        w.prop_at_press = w.cmds[#w.cmds]
    end
    return w
end

local HOLD = "lipc-set-prop com.lab126.powerd preventScreenSaver 1"
local RELEASE = "lipc-set-prop com.lab126.powerd preventScreenSaver 0"

test("a live session holds the screensaver off and pauses KOReader's auto-sleep, then gives both back", function()
    local w = world()
    w.hold:set(true)
    eq(w.cmds[1], HOLD); eq(w.share.pause_auto_suspend, true)
    w.hold:set(false)
    eq(w.cmds[2], RELEASE); eq(w.share.pause_auto_suspend, nil)
end)

test("a pause someone else set is left alone", function()
    local w = world()
    w.share.pause_auto_suspend = true
    w.hold:set(true); w.hold:set(false)
    eq(w.share.pause_auto_suspend, true)
end)

test("keepalive keeps the hold when the session ends", function()
    local w = world()
    w.hold:set(true)
    w.share.keepalive = true
    w.hold:set(false)
    eq(#w.cmds, 1)
end)

test("a sleep request releases the hold right before the power button press", function()
    local w = world()
    w.hold:wrap(w.powerd)
    w.hold:set(true)
    w.powerd:toggleSuspend()
    eq(w.presses, 1); eq(w.prop_at_press, RELEASE)
    w.powerd:toggleSuspend() -- a second request does not release twice
    eq(w.presses, 2); eq(#w.cmds, 2)
end)

test("on wake the hold comes back while the session is still on, once", function()
    local w = world()
    w.hold:wrap(w.powerd)
    w.hold:set(true)
    w.powerd:toggleSuspend()
    w.hold:resumed(true)
    eq(w.cmds[3], HOLD)
    w.hold:resumed(true)
    eq(#w.cmds, 3)
end)

test("on wake with the session over, nothing is held again", function()
    local w = world()
    w.hold:wrap(w.powerd)
    w.hold:set(true)
    w.powerd:toggleSuspend()
    w.hold:set(false) -- the session ended while asleep
    w.hold:resumed(false)
    eq(w.cmds[#w.cmds], RELEASE)
    for _, c in ipairs(w.cmds) do if c == HOLD then eq(c, w.cmds[1]) end end
end)

test("a wake without a release of ours, and a sleep with no session, touch nothing", function()
    local w = world()
    w.hold:wrap(w.powerd)
    w.hold:resumed(true)
    w.powerd:toggleSuspend()
    eq(#w.cmds, 0); eq(w.presses, 1)
end)

test("a keepalive hold is not released for sleep", function()
    local w = world()
    w.hold:wrap(w.powerd)
    w.hold:set(true)
    w.share.keepalive = true
    w.powerd:toggleSuspend()
    eq(#w.cmds, 1); eq(w.presses, 1)
end)

test("wrapping twice still presses once", function()
    local w = world()
    w.hold:wrap(w.powerd); w.hold:wrap(w.powerd)
    w.hold:set(true)
    w.powerd:toggleSuspend()
    eq(w.presses, 1); eq(#w.cmds, 2)
end)

test("not a Kindle: no command, no wrap", function()
    local w = world({ is_kindle = false })
    local before = w.powerd.toggleSuspend
    w.hold:wrap(w.powerd)
    eq(w.powerd.toggleSuspend, before)
    w.hold:set(true); w.hold:resumed(true); w.hold:set(false)
    eq(#w.cmds, 0); eq(w.share.pause_auto_suspend, nil)
end)

test("each release and re-hold is logged", function()
    local w = world()
    w.hold:wrap(w.powerd)
    w.hold:set(true)
    w.powerd:toggleSuspend()
    w.hold:resumed(true)
    local text = table.concat(w.logs, "\n")
    assert(text:find("released for sleep", 1, true), text)
    assert(text:find("held again after wake", 1, true), text)
end)

print(string.format("%d tests, %d failures", count, failures))
os.exit(failures == 0 and 0 or 1)
