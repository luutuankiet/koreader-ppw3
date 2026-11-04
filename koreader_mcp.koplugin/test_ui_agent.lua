-- Run with: luajit test_ui_agent.lua (from this folder). Needs no KOReader.
package.path = "./?.lua;" .. package.path
local ui = require("ui_agent")

local fails = 0
local function check(name, cond)
    if not cond then
        fails = fails + 1
        print("FAIL " .. name)
    else
        print("ok   " .. name)
    end
end

-- references
local store = ui.newStore()
local a, b, c = {}, {}, {}
local s1 = store:add({ a })
local s2 = store:add({ b })
check("older of the last two resolves", store:resolve(s1 .. "_1") == a)
check("newest resolves", store:resolve(s2 .. "_1") == b)
local s3 = store:add({ c })
local w, err = store:resolve(s1 .. "_1")
check("third-oldest is stale", w == nil and err:find("stale reference", 1, true) ~= nil)
check("still resolves after a new snapshot", store:resolve(s2 .. "_1") == b and store:resolve(s3 .. "_1") == c)
w, err = store:resolve("seven")
check("malformed is refused", w == nil and err:find("bad reference", 1, true) ~= nil)
w, err = store:resolve(s3 .. "_9")
check("missing index is reported", w == nil and err:find("no widget", 1, true) ~= nil)

-- describe
local noop = function() end
local kind, text, state = ui.describe({ item = { text = "Wi-Fi", checked = true, sub_item_table = {} }, menu = {}, onTapSelect = noop })
check("main menu item", kind == "item" and text == "Wi-Fi" and state[1] == "checked" and state[2] == "submenu")
kind, text, state = ui.describe({ item = { text_func = function() return "Dyn" end, enabled_func = function() return false end }, menu = {}, onTapSelect = noop })
check("item text_func and disabled", kind == "item" and text == "Dyn" and state[1] == "disabled")
kind, text = ui.describe({ entry = { text = "Book", mandatory = "12%" }, onTapSelect = noop })
check("list row with right column", kind == "row" and text == "Book | 12%")
kind, text, state = ui.describe({ onTapCheckButton = noop, text = "Show all", checked = true })
check("check button", kind == "check" and text == "Show all" and state[1] == "checked")
kind, text, state = ui.describe({ onTapSelectButton = noop, text = "OK", enabled = false })
check("disabled button", kind == "button" and text == "OK" and state[1] == "disabled")
kind, text = ui.describe({ addChars = noop, charlist = {}, hint = "Search" })
check("empty input shows its hint", kind == "input" and text == "hint: Search")
check("plain container is not listed", ui.describe({}) == nil)

-- walk
local dimen = { x = 0, y = 0, w = 10, h = 10 }
local tree = {
    { text = "Title" },
    { text = "Title" },
    { { onTapSelectButton = noop, text = "OK", dimen = dimen, { text = "OK label" } } },
    { onTapSelectButton = noop, text = "No size" },
}
tree[5] = tree -- a cycle must not hang
local nodes = ui.walk(tree)
check("adjacent duplicate text collapses, button keeps its label to itself, sizeless button skipped",
    #nodes == 2 and nodes[1].text == "Title" and nodes[2].kind == "button" and nodes[2].text == "OK")

-- isIdle: a fake UIManager, loaded before ui_agent first asks for it
local filemanager = { name = "filemanager", covers_fullscreen = true }
local list = { name = "list", covers_fullscreen = true }
local popup = { name = "popup" }
local fakeUI = { _task_queue = {}, _refresh_stack = {}, _dirty = {},
    _window_stack = { { widget = filemanager }, { widget = list } } }
package.loaded["ui/uimanager"] = fakeUI
check("idle with nothing dirty", ui.isIdle() == true)
fakeUI._dirty = { [list] = true }
check("busy when the top fullscreen window is dirty", ui.isIdle() == false)
-- Closing one fullscreen window and showing another in the same tick leaves the
-- window underneath dirty; _repaint never reaches it, so it stays dirty.
fakeUI._dirty = { [filemanager] = true }
check("idle when only a window under a fullscreen one is dirty", ui.isIdle() == true)
fakeUI._window_stack[3] = { widget = popup }
fakeUI._dirty = { [filemanager] = true, [popup] = true }
check("busy when a window above the fullscreen one is dirty", ui.isIdle() == false)
fakeUI._dirty = { [{}] = true }
check("idle when the dirty widget is not on the window stack", ui.isIdle() == true)
fakeUI._window_stack = { { widget = popup } }
fakeUI._dirty = { [popup] = true }
check("busy when no window covers the screen and one is dirty", ui.isIdle() == false)

-- unchecked: a checkable row or check button that is off says so
kind, text, state = ui.describe({ item = { text = "Auto sync", checked_func = function() return false end }, menu = {}, onTapSelect = noop })
check("checkable item that is off is unchecked", kind == "item" and state[1] == "unchecked")
kind, text, state = ui.describe({ item = { text = "Auto sync", checked = false }, menu = {}, onTapSelect = noop })
check("item with checked = false is unchecked", state[1] == "unchecked")
kind, text, state = ui.describe({ item = { text = "About" }, menu = {}, onTapSelect = noop })
check("item that is not checkable has no check state", #state == 0)
kind, text, state = ui.describe({ onTapCheckButton = noop, text = "Show all" })
check("check button that is off is unchecked", kind == "check" and state[1] == "unchecked")

-- read_log: the ring with sequence numbers as markers
io.write = function() end -- the capture forwards here; keep test output readable
ui.installLogCapture()
local base = ui.logMark()
io.write("") -- an empty write adds nothing
for i = 1, 5 do io.write("line " .. i .. (i % 2 == 0 and " even" or "") .. "\n") end
local r = ui.readLog({ since = base })
check("read_log since a marker returns the new lines and the latest marker",
    r.marker == base + 5 and #r.lines == 5 and r.lines[1] == "line 1" and r.truncated == false)
r = ui.readLog({ since = base, grep = "even" })
check("read_log grep keeps matching lines only", #r.lines == 2 and r.lines[2] == "line 4 even")
r = ui.readLog({ max_lines = 2 })
check("read_log without since returns the last max_lines", #r.lines == 2 and r.lines[2] == "line 5" and r.truncated == false)
r = ui.readLog({ since = r.marker })
check("read_log at the latest marker returns nothing", #r.lines == 0 and r.marker == base + 5)
for i = 1, ui.LOG_KEEP + 3 do io.write("flood " .. i .. "\n") end
r = ui.readLog({ since = base, max_lines = 5000 })
check("read_log since a marker that fell out of the ring is truncated",
    r.truncated == true and #r.lines == ui.LOG_KEEP and r.lines[#r.lines] == "flood " .. (ui.LOG_KEEP + 3))
r = ui.readLog({ since = r.marker - 10, max_lines = 3 })
check("read_log cut by max_lines keeps the newest and says truncated", #r.lines == 3 and r.truncated == true
    and r.lines[3] == "flood " .. (ui.LOG_KEEP + 3))

-- ui_wait and power_button: a fake clock and task queue on the fake UIManager
local clock, queue = 0, {}
ui.now = function() return clock end
fakeUI.scheduleIn = function(_, s, fn) queue[#queue + 1] = { at = clock + s, fn = fn } end
local function runQueue(limit)
    for _ = 1, limit or 1000 do
        if #queue == 0 then return end
        table.sort(queue, function(x, y) return x.at < y.at end)
        local t = table.remove(queue, 1)
        clock = math.max(clock, t.at)
        t.fn()
    end
end
local dialog = { name = "dialog", { text = "Waking sync server..." } }
fakeUI._window_stack = { { widget = filemanager }, { widget = dialog } }
fakeUI._dirty = {}

local got
ui.wait({ text = "waking SYNC" }, function(res, e) got = { res = res, err = e } end)
check("ui_wait matches present text at once, case-insensitively",
    got and got.res.matched == true and got.res.waited == 0 and got.res.snapshot.window == "dialog")

got = nil
ui.wait({ text = "Waking sync", exact = true, timeout = 2 }, function(res) got = res end)
runQueue()
check("ui_wait exact needs the whole text and times out otherwise",
    got and got.matched == false and got.waited >= 2 and got.waited < 2.5)

got = nil
clock = 0
ui.wait({ text = "waking", gone = true, timeout = 10 }, function(res) got = res end)
check("ui_wait gone keeps polling while the text is there", got == nil and #queue == 1 and ui.own_tasks[queue[1].fn])
clock = 1.2
dialog[1] = { text = "Progress has been pushed." }
runQueue()
check("ui_wait gone matches once the text disappears", got and got.matched == true and got.waited >= 1.2 and got.waited < 2)

got = nil
ui.wait({ text = "never", timeout = 999 }, function(res) got = res end)
runQueue()
check("ui_wait timeout is clamped to 60 s", got and got.matched == false and got.waited >= 60 and got.waited < 61)
got = nil
ui.wait({ text = "" }, function(res, e) got = { res = res, err = e } end)
check("ui_wait without text is refused", got and got.res == nil and got.err.code == -32602)

-- power_button
local calls = {}
local device = { screen_saver_mode = false, screen_saver_lock = false }
package.loaded["device"] = device
fakeUI.event_handlers = {}
fakeUI.suspend = function() calls[#calls + 1] = "suspend" end
fakeUI.event_handlers.Resume = function() calls[#calls + 1] = "resume" end
queue = {}
got = nil
ui.powerButton({}, function(res) got = res end)
check("power_button replies before acting", got and got.action == "suspend" and got.screen_saver_mode == false and #calls == 0)
runQueue()
check("power_button suspends on the next tick when awake", calls[1] == "suspend")

calls, got = {}, nil
device.screen_saver_mode = true
ui.powerButton({}, function(res) got = res end)
runQueue()
check("power_button resumes when asleep", got.action == "resume" and got.screen_saver_mode == true and calls[1] == "resume")

calls, got = {}, nil
fakeUI.event_handlers.PowerRelease = function() calls[#calls + 1] = "power_release" end
ui.powerButton({}, function(res) got = res end)
runQueue()
check("power_button uses PowerRelease when the platform has it", got.action == "resume" and calls[1] == "power_release" and #calls == 1)

calls, got = {}, nil
device.screen_saver_lock = true
ui.powerButton({}, function(res) got = res end)
runQueue()
check("power_button does nothing while the screen saver is locked",
    got.action == "locked" and got.screen_saver_mode == true and #calls == 0)

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
