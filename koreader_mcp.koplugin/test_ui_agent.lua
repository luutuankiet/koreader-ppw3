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

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
