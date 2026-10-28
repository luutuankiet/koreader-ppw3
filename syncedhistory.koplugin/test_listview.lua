--[[--
Tests for syncedhistory_listview.lua and for the KOReader calls main.lua
relies on to show the list, open a book and pull its position. main.lua
never loads this file.

Two ways to run it:

  1. Standalone, any LuaJIT or Lua 5.1: the row building only.
       luajit test_listview.lua

  2. With KOReader's own luajit: also checks, against the installed KOReader,
     that the built-in progress sync's pull action and the Menu, UIManager and
     filemanagerutil calls main.lua uses are there and behave as main.lua
     expects. Run from the KOReader install folder (the one holding
     setupkoenv.lua):
       cd /mnt/us/koreader          # Kindle and emulator
       ./luajit plugins/syncedhistory.koplugin/test_listview.lua --koreader
]]

local mode = arg and arg[1] == "--koreader" and "koreader" or "standalone"

local this_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = this_dir .. "/?.lua;" .. package.path

if mode == "koreader" then
    require("setupkoenv")
end

local ListView = require("syncedhistory_listview")

local passed, failed = 0, 0
local function check(cond, msg)
    if not cond then error(msg or "check failed", 2) end
end
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

local function lookupFrom(map)
    local calls = {}
    return function(key)
        calls[#calls + 1] = key
        return map[key]
    end, calls
end

test("percent: rounding and bounds", function()
    eq(ListView.percent(0.42), "42%")
    eq(ListView.percent(0.996), "99%", "never rounds up to 100%")
    eq(ListView.percent(1), "100%")
    eq(ListView.percent(0), "0%")
    eq(ListView.percent(nil), "0%")
    eq(ListView.percent(0 / 0), "0%", "NaN")
    eq(ListView.percent(-0.5), "0%")
    eq(ListView.percent(7), "100%")
    eq(ListView.percent(0.29), "29%", "no float drift below the true value")
end)

test("rows: newest first, whatever the input order", function()
    local lookup = lookupFrom({})
    local rows = ListView.rows({
        { document = "old", timestamp = 100 },
        { document = "new", timestamp = 300 },
        { document = "mid", timestamp = 200 },
    }, { lookup = lookup })
    eq(#rows, 3)
    eq(rows[1].document, "new")
    eq(rows[2].document, "mid")
    eq(rows[3].document, "old")
end)

test("rows: no timestamp goes last, ties keep server order", function()
    local rows = ListView.rows({
        { document = "none" },
        { document = "a", timestamp = 5 },
        { document = "b", timestamp = 5 },
    }, { lookup = lookupFrom({}) })
    eq(rows[1].document, "a")
    eq(rows[2].document, "b")
    eq(rows[3].document, "none")
end)

test("rows: on this device vs missing", function()
    local lookup, calls = lookupFrom({ here = "/mnt/us/documents/Dune.epub" })
    local rows = ListView.rows({
        { document = "here", filename = "Dune.epub", percentage = 0.42, device = "Kindle", timestamp = 2 },
        { document = "gone", filename = "Emma.epub", percentage = 0.1, device = "Phone", timestamp = 1 },
    }, { lookup = lookup })
    eq(#calls, 2, "one lookup per row")
    eq(rows[1].text, "Dune.epub")
    eq(rows[1].mandatory, "42% · Kindle · on this device")
    eq(rows[1].path, "/mnt/us/documents/Dune.epub")
    eq(rows[1].missing, false)
    eq(rows[1].dim, nil)
    eq(rows[2].mandatory, "10% · Phone · missing")
    eq(rows[2].path, nil)
    eq(rows[2].missing, true)
    eq(rows[2].dim, true, "missing rows are greyed")
end)

test("rows: no file name or device on the server", function()
    local rows = ListView.rows({
        { document = "x", timestamp = 1 },
        { document = "y", filename = "", device = "", timestamp = 0 },
    }, { lookup = lookupFrom({}) })
    eq(rows[1].text, "unknown book")
    eq(rows[1].filename, nil)
    eq(rows[1].mandatory, "0% · unknown device · missing")
    eq(rows[2].text, "unknown book")
end)

test("rows: no file name from the server, but on this device: local file name", function()
    local rows = ListView.rows({ { document = "k", percentage = 0.32, device = "Kindle", timestamp = 1 } }, {
        lookup = lookupFrom({ k = "/lib/sub/Local Name.epub" }),
    })
    eq(rows[1].text, "Local Name.epub")
    eq(rows[1].filename, nil)
    eq(rows[1].mandatory, "32% · Kindle · on this device")
end)

test("rows: translated through gettext", function()
    local rows = ListView.rows({ { document = "x", timestamp = 1 } }, {
        lookup = lookupFrom({}),
        gettext = function(s) return "<" .. s .. ">" end,
    })
    eq(rows[1].text, "<unknown book>")
    eq(rows[1].mandatory, "0% · <unknown device> · <missing>")
end)

test("rows: nil list, bad rows and missing lookup", function()
    eq(#ListView.rows(nil, { lookup = lookupFrom({}) }), 0)
    eq(#ListView.rows({ "junk", { percentage = 1 }, { document = 5 } }, { lookup = lookupFrom({}) }), 0)
    check(not pcall(ListView.rows, {}, {}), "lookup is required")
end)

test("rows: input list is left untouched", function()
    local list = { { document = "a", timestamp = 1 }, { document = "b", timestamp = 2 } }
    ListView.rows(list, { lookup = lookupFrom({}) })
    eq(list[1].document, "a")
    eq(list[2].document, "b")
end)

if mode == "koreader" then
    local function readFile(path)
        local f = assert(io.open(path, "r"), "cannot open " .. path)
        local s = f:read("*a")
        f:close()
        return s
    end
    local function functionBody(src, name)
        local start = src:find("function " .. name:gsub("[%.%:]", "%%%0") .. "%(", 1)
        check(start, name .. " not found")
        local stop = src:find("\nend\n", start, true)
        return src:sub(start, stop)
    end
    local kosync = readFile("plugins/kosync.koplugin/main.lua")

    test("koreader: KOSyncPullProgress calls getProgress(true, true)", function()
        local body = functionBody(kosync, "KOSync:onKOSyncPullProgress")
        check(body:find("self:getProgress%(true, true%)"), "pull action body changed:\n" .. body)
    end)

    -- main.lua's readKosyncSettings reads one of these two places.
    test("koreader: kosync keeps its settings in kosync.lua or the reader settings", function()
        check(kosync:find('"/kosync.lua"', 1, true) or kosync:find('G_reader_settings:readSetting("kosync"', 1, true),
            "kosync settings moved")
    end)

    test("koreader: an interactive pull jumps without a prompt", function()
        local body = functionBody(kosync, "KOSync:getProgress")
        local branch = body:match("if interactive then%s*\n%s*%-%-[^\n]*\n%s*%-%-[^\n]*\n%s*self:syncToProgress%(body%.progress%)")
        check(branch, "interactive branch no longer calls syncToProgress first")
        check(body:find("NetworkMgr:willRerunWhenOnline", 1, true), "pull no longer turns the network on")
    end)

    test("koreader: Menu routes a tap to item.callback and takes a subtitle", function()
        local menu_src = readFile("frontend/ui/widget/menu.lua")
        check(functionBody(menu_src, "Menu:onMenuSelect"):find("self:onMenuChoice%(item%)"),
            "onMenuSelect no longer goes through onMenuChoice")
        check(functionBody(menu_src, "Menu:onMenuChoice"):find("item%.callback%(%)"),
            "onMenuChoice no longer calls item.callback")
        check(menu_src:find("function Menu:switchItemTable%(new_title, new_item_table, itemnumber, itemmatch, new_subtitle%)"),
            "switchItemTable signature changed")
    end)

    -- Read as source: requiring UIManager outside a running KOReader needs
    -- the device and the reader settings.
    test("koreader: UIManager, filemanagerutil and Event calls exist", function()
        local ui = readFile("frontend/ui/uimanager.lua")
        check(ui:find("function UIManager:isWidgetShown(widget)", 1, true), "UIManager:isWidgetShown")
        check(ui:find("function UIManager:nextTick(", 1, true), "UIManager:nextTick")
        -- main.lua's openBook: filemanagerutil.openFile, or before it existed
        -- (v2024.11) ReaderUI:switchDocument and FileManager:openFile.
        local fmu = readFile("frontend/apps/filemanager/filemanagerutil.lua")
        if not fmu:find("function filemanagerutil.openFile(ui, file, caller_pre_callback, no_dialog)", 1, true) then
            check(not fmu:find("function filemanagerutil.openFile(", 1, true), "filemanagerutil.openFile signature changed")
            check(readFile("frontend/apps/reader/readerui.lua"):find("function ReaderUI:switchDocument(new_file", 1, true),
                "ReaderUI:switchDocument")
            check(readFile("frontend/apps/filemanager/filemanager.lua"):find("function FileManager:openFile(file", 1, true),
                "FileManager:openFile")
        end
        local ev = require("ui/event"):new("KOSyncPullProgress")
        eq(ev.handler, "onKOSyncPullProgress", "event handler name")
    end)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
