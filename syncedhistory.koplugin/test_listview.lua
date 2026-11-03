--[[--
Tests for syncedhistory_listview.lua and for the KOReader calls main.lua
relies on to show the list, open a book and pull its position. main.lua
never loads this file.

Two ways to run it:

  1. Standalone, any LuaJIT or Lua 5.1: the row building only.
       luajit test_listview.lua

  2. With KOReader's own luajit: also checks, against the installed KOReader,
     that the progress sync plugin's pull action and the Menu, UIManager and
     filemanagerutil calls main.lua uses are there and behave as main.lua
     expects. Run from the KOReader install folder (the one holding
     setupkoenv.lua):
       cd /mnt/us/koreader          # Kindle and emulator
       ./luajit plugins/syncedhistory.koplugin/test_listview.lua --koreader
     The progress sync checks follow the plugin the setting picks
     (syncedhistory_backend.lua): SYNCEDHISTORY_BACKEND=auto (default),
     kosync or serverless. Its main.lua is looked for in plugins/ and next
     to this plugin's folder.
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

local function mergedRow()
    return {
        document = "new", filename = "Steve Jobs - Walter Isaacson.epub", percentage = 0.37,
        device = "Kindle", timestamp = 5,
        aliases = {
            { document = "new", filename = "Steve Jobs - Walter Isaacson.epub" },
            { document = "old", filename = "Walter Isaacson - Steve Jobs.epub" },
        },
    }
end

test("aliases: the newer name local", function()
    local lookup = lookupFrom({ new = "/lib/Steve Jobs - Walter Isaacson.epub" })
    local r = ListView.rows({ mergedRow() }, { lookup = lookup })[1]
    eq(r.path, "/lib/Steve Jobs - Walter Isaacson.epub")
    eq(r.local_document, "new")
    eq(r.text, "Steve Jobs - Walter Isaacson.epub")
    eq(r.mandatory, "37% · Kindle · on this device")
    eq(#r.keys, 2, "both keys kept for removing")
end)

test("aliases: only the older name local shows that name", function()
    local lookup, calls = lookupFrom({ old = "/lib/Walter Isaacson - Steve Jobs.epub" })
    local r = ListView.rows({ mergedRow() }, { lookup = lookup })[1]
    eq(r.path, "/lib/Walter Isaacson - Steve Jobs.epub")
    eq(r.local_document, "old")
    eq(r.text, "Walter Isaacson - Steve Jobs.epub", "the local alias's name")
    eq(r.missing, false)
    eq(calls[1], "new", "newest alias looked up first")
    -- The alias has no file name on the server: the local file's name.
    local row = mergedRow()
    row.aliases[2].filename = nil
    r = ListView.rows({ row }, { lookup = lookup })[1]
    eq(r.text, "Walter Isaacson - Steve Jobs.epub")
end)

test("aliases: neither name local", function()
    local lookup, calls = lookupFrom({})
    local r = ListView.rows({ mergedRow() }, { lookup = lookup })[1]
    eq(r.path, nil)
    eq(r.missing, true)
    eq(r.text, "Steve Jobs - Walter Isaacson.epub", "the newest name")
    eq(#calls, 2, "every alias looked up")
end)

test("aliases: none from an older server, the document alone", function()
    local lookup, calls = lookupFrom({ solo = "/lib/Emma.epub" })
    local r = ListView.rows({ { document = "solo", filename = "Emma.epub" } }, { lookup = lookup })[1]
    eq(r.path, "/lib/Emma.epub")
    eq(#calls, 1)
    eq(#r.keys, 1)
    eq(r.keys[1].document, "solo")
    -- An empty aliases list counts as none.
    r = ListView.rows({ { document = "solo", aliases = {} } }, { lookup = lookup })[1]
    eq(r.keys[1].document, "solo")
end)

test("localMatch: on a built row, looks again across every alias", function()
    local r = ListView.rows({ mergedRow() }, { lookup = lookupFrom({}) })[1]
    -- The file appeared since the list was built, under the older name.
    local path, key = ListView.localMatch(r, lookupFrom({ old = "/lib/W.epub" }))
    eq(path, "/lib/W.epub")
    eq(key, "old")
end)

test("removeText: names the file-name count only for a merged book", function()
    local rows = ListView.rows({ mergedRow(), { document = "solo", filename = "Emma.epub", timestamp = 1 } },
        { lookup = lookupFrom({}) })
    local merged, single = ListView.removeText(rows[1]), ListView.removeText(rows[2])
    check(merged:find("all 2 file names", 1, true), merged)
    check(merged:find("Steve Jobs - Walter Isaacson.epub", 1, true), merged)
    check(not single:find("file names", 1, true), single)
    check(single:find("next progress push", 1, true), "no word on a book still being read")
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

-- Newest first: two books here, two elsewhere, interleaved.
local function sampleRows()
    return ListView.rows({
        { document = "a", filename = "Head First Design Patterns.epub", timestamp = 4 },
        { document = "b", filename = "Dune.epub", timestamp = 3 },
        { document = "c", filename = "Design of Everyday Things.pdf", timestamp = 2 },
        { document = "d", filename = "Emma (100%) [draft].epub", timestamp = 1 },
    }, { lookup = lookupFrom({ a = "/l/a.epub", d = "/l/d.epub" }) })
end
local function docs(view)
    local out = {}
    for i, row in ipairs(view.rows) do out[i] = row.document end
    return table.concat(out, ",")
end

test("view: filter on keeps only books on this device, in order", function()
    local v = ListView.view(sampleRows(), { show_missing = false })
    eq(docs(v), "a,d")
    eq(v.total, 4)
    eq(v.on_device, 2)
    eq(v.matched, 2)
    eq(v.query, nil)
    eq(docs(ListView.view(sampleRows())), "a,d", "filter is on by default")
end)

test("view: filter off shows every row, in order", function()
    local v = ListView.view(sampleRows(), { show_missing = true })
    eq(docs(v), "a,b,c,d")
    eq(v.on_device, 2)
    eq(v.matched, 4)
end)

test("view: search within the filter, any case", function()
    local v = ListView.view(sampleRows(), { show_missing = false, query = "DESIGN" })
    eq(docs(v), "a", "c matches but is not on this device")
    eq(v.matched, 1)
    eq(v.query, "DESIGN")
    eq(docs(ListView.view(sampleRows(), { show_missing = true, query = "design" })), "a,c")
end)

test("view: search is plain text, not a Lua pattern", function()
    local rows = sampleRows()
    eq(docs(ListView.view(rows, { query = "(100%)" })), "d")
    eq(docs(ListView.view(rows, { query = "[draft]" })), "d")
    eq(docs(ListView.view(rows, { query = "%" })), "d")
    eq(docs(ListView.view(rows, { show_missing = true, query = "." })), "a,b,c,d", "dot matches only dots")
    eq(docs(ListView.view(rows, { show_missing = true, query = "e.p" })), "", "dot is not a wildcard")
end)

test("view: blank search is no search", function()
    local v = ListView.view(sampleRows(), { show_missing = true, query = "   " })
    eq(v.query, nil)
    eq(v.matched, 4)
    eq(ListView.view(sampleRows(), { query = "  dune " }).query, "dune", "trimmed")
end)

test("subtitle: each form", function()
    local rows = sampleRows()
    eq(ListView.subtitle(ListView.view(rows, { show_missing = false })), "2 of 4 on this device · synced just now")
    eq(ListView.subtitle(ListView.view(rows, { show_missing = true })), "4 books · synced just now")
    eq(ListView.subtitle(ListView.view(rows, { show_missing = true, query = "design" })), "\"design\": 2 found · synced just now")
    eq(ListView.subtitle(ListView.view(rows, { query = "%1 (x)" })), "\"%1 (x)\": 0 found · synced just now",
        "search text is not a template")
    eq(ListView.subtitle(ListView.view(rows, {}), { status = "Offline: showing the last list." }),
        "2 of 4 on this device · Offline: showing the last list.")
end)

test("subtitle and empty text: translated through gettext", function()
    local g = function(s) return "<" .. s .. ">" end
    local v = ListView.view(sampleRows(), {})
    eq(ListView.subtitle(v, { gettext = g }), "<2 of 4 on this device> · <synced just now>")
    eq(ListView.emptyText(ListView.view({}, {}), { gettext = g }), "<No books on the sync server yet.>")
end)

test("emptyText: the three empty cases, and nil when rows show", function()
    eq(ListView.emptyText(ListView.view(sampleRows(), {})), nil)
    eq(ListView.emptyText(ListView.view({}, {})), "No books on the sync server yet.")
    eq(ListView.emptyText(ListView.view({}, {}), { empty = "Offline." }), "Offline.")
    local elsewhere = ListView.rows({ { document = "x", filename = "X.epub", timestamp = 1 } },
        { lookup = lookupFrom({}) })
    eq(ListView.emptyText(ListView.view(elsewhere, { show_missing = false })),
        "None of your synced books are on this device. Show all from the title-bar menu.")
    eq(ListView.emptyText(ListView.view(elsewhere, { show_missing = false, query = "x" })),
        "None of your synced books are on this device. Show all from the title-bar menu.",
        "nothing for the search to find")
    eq(ListView.emptyText(ListView.view(sampleRows(), { query = "zzz" })), "No book matches \"zzz\".")
    eq(ListView.emptyText(ListView.view(sampleRows(), { query = "50%" })), "No book matches \"50%\".")
end)

-- A fixed clock: the test runs the same in any time zone.
local function fakeDate(fmt, t)
    return fmt .. "@" .. tostring(t)
end

test("rows: keep the server's device and timestamp for the details", function()
    local rows = ListView.rows({
        { document = "a", device = "Kindle", timestamp = 1700000000 },
        { document = "b", device = "", timestamp = "soon" },
    }, { lookup = lookupFrom({}) })
    eq(rows[1].device, "Kindle")
    eq(rows[1].timestamp, 1700000000)
    eq(rows[2].device, nil, "empty device is no device")
    eq(rows[2].timestamp, nil, "a timestamp that is not a number is none")
end)

test("details: a book on this device", function()
    local long = "A Very Long Book Name That The List Cuts Off Somewhere Around Here, Volume 2.epub"
    local rows = ListView.rows({
        { document = "a", filename = long, percentage = 0.426, device = "Kindle PW3", timestamp = 1700000000 },
    }, { lookup = lookupFrom({ a = "/mnt/us/documents/Series/x.epub" }) })
    eq(ListView.details(rows[1], { date = fakeDate }), table.concat({
        long,
        "",
        "Progress: 42%",
        "Last device: Kindle PW3",
        "Last pushed: %Y-%m-%d %H:%M@1700000000",
        "Folder: /mnt/us/documents/Series",
    }, "\n"))
end)

test("details: a missing book, no timestamp, no device", function()
    local rows = ListView.rows({ { document = "a", filename = "Gone.pdf" } }, { lookup = lookupFrom({}) })
    eq(ListView.details(rows[1], { date = fakeDate }), table.concat({
        "Gone.pdf",
        "",
        "Progress: 0%",
        "Last device: unknown device",
        "Last pushed: unknown",
        "Folder: not on this device",
    }, "\n"))
end)

test("rows and details: the last 4 characters of the device id tell two Kindles apart", function()
    local rows = ListView.rows({
        { document = "a", percentage = 0.5, device = "KindlePaperWhite3", device_id = "3C6A84AA41A545BB9917DDF53D8599ED", timestamp = 2 },
        { document = "b", percentage = 0.5, device = "KindlePaperWhite3", device_id = "", timestamp = 1 },
        { document = "c", device_id = "AB12" },
    }, { lookup = lookupFrom({ a = "/mnt/us/documents/a.epub" }) })
    eq(rows[1].mandatory, "50% · KindlePaperWhite3 (99ED) · on this device")
    eq(rows[1].device_id, "3C6A84AA41A545BB9917DDF53D8599ED")
    eq(rows[2].mandatory, "50% · KindlePaperWhite3 · missing", "empty id: model only")
    eq(rows[2].device_id, nil)
    eq(rows[3].mandatory, "0% · unknown device (AB12) · missing")
    local text = ListView.details(rows[1], { date = fakeDate })
    check(text:find("\nLast device: KindlePaperWhite3 %(99ED%)\n"), "details carry the tail:\n" .. text)
    eq(ListView.deviceLabel("Kindle", "abc"), "Kindle", "an id under 4 characters is not shown")
    eq(ListView.deviceLabel("Kindle", nil), "Kindle")
end)

test("details: translated, a book at the root, and the real os.date", function()
    local rows = ListView.rows({ { document = "a", timestamp = 0, percentage = 1 } },
        { lookup = lookupFrom({ a = "/book.epub" }) })
    local text = ListView.details(rows[1], { gettext = function(s) return "<" .. s .. ">" end })
    check(text:find("^book%.epub\n"), "local file name when the server has none:\n" .. text)
    check(text:find("\n<Progress: 100%>\n", 1, true), "template filled:\n" .. text)
    check(text:find("\n<Folder: />$"), "root folder is /:\n" .. text)
    check(text:find("\n<Last pushed: %d%d%d%d%-%d%d%-%d%d %d%d:%d%d>\n"), "os.date used:\n" .. text)
end)

-- main.lua keeps cleanQuery's result as the list's search: nil means no
-- search, so no "Clear search" entry.
test("cleanQuery trims the search and turns a blank one into none", function()
    eq(ListView.cleanQuery("  Dune "), "Dune")
    eq(ListView.cleanQuery("a b"), "a b", "inner spaces kept")
    eq(ListView.cleanQuery(""), nil)
    eq(ListView.cleanQuery("   "), nil)
    eq(ListView.cleanQuery(nil), nil)
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
    local Backend = require("syncedhistory_backend")
    local function exists(path)
        local fh = io.open(path, "r")
        if fh then fh:close() return true end
        return false
    end
    local backend, source = Backend.fromSources(os.getenv("SYNCEDHISTORY_BACKEND"),
        { "plugins", this_dir .. "/.." }, exists, print)
    print("progress sync backend: " .. backend.id .. ", source: " .. tostring(source))
    local kosync = readFile(assert(source, backend.plugin_dir .. "/main.lua not found"))
    local cls = backend.class

    test("koreader: " .. backend.pull_event .. " calls getProgress(true, true)", function()
        local body = functionBody(kosync, cls .. ":on" .. backend.pull_event)
        check(body:find("self:getProgress%(true, true%)"), "pull action body changed:\n" .. body)
    end)

    -- main.lua's readKosyncSettings reads one of these places.
    test("koreader: " .. backend.module .. " keeps its settings in " .. backend.settings_file
        .. " under the key settings", function()
        local in_file = kosync:find('"/' .. backend.settings_file .. '"', 1, true)
        local legacy = backend.legacy_key
            and kosync:find('G_reader_settings:readSetting("' .. backend.legacy_key .. '"', 1, true)
        check(in_file or legacy, backend.module .. " settings moved")
        check(kosync:find('readSetting("settings"', 1, true), "settings no longer under the key settings")
        check(kosync:find('name = "' .. backend.module .. '"', 1, true), "plugin name is not " .. backend.module)
        check(kosync:find("is_doc_only = true", 1, true), "no longer doc-only: main.lua's hasPlugin relies on it")
    end)

    test("koreader: an interactive pull jumps without a prompt", function()
        local body = functionBody(kosync, cls .. ":getProgress")
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

    -- main.lua's title-bar menu: a left icon whose tap calls the menu's
    -- onLeftButtonTap, and a ButtonDialog with a left-aligned button.
    test("koreader: Menu takes a left title-bar icon and calls onLeftButtonTap", function()
        local menu_src = readFile("frontend/ui/widget/menu.lua")
        check(menu_src:find("left_icon = self.title_bar_left_icon,", 1, true), "title_bar_left_icon no longer used")
        check(menu_src:find("left_icon_tap_callback = function() self:onLeftButtonTap() end", 1, true),
            "left icon tap no longer calls onLeftButtonTap")
        check(io.open("resources/icons/mdlight/appbar.menu.svg", "r"), "icon appbar.menu missing")
        check(readFile("frontend/ui/widget/button.lua"):find('align = "center", -- or "left"', 1, true),
            "Button align changed")
    end)

    -- main.lua's long press: Menu calls onMenuHold(item) on the menu
    -- instance, and the pop-up is a ButtonDialog whose title wraps.
    test("koreader: Menu calls onMenuHold(item); ButtonDialog title wraps", function()
        local menu_src = readFile("frontend/ui/widget/menu.lua")
        check(menu_src:find("function Menu:onMenuHold(item", 1, true), "Menu:onMenuHold(item) missing")
        check(menu_src:find("self.menu:onMenuHold(self.entry", 1, true),
            "MenuItem hold no longer calls menu:onMenuHold(entry)")
        local bd = readFile("frontend/ui/widget/buttondialog.lua")
        local title = bd:match("TextBoxWidget:new{%s*text = self%.title,.-}")
        check(title, "ButtonDialog title is no longer a TextBoxWidget")
        check(title:find("alignment = self.title_align", 1, true), "ButtonDialog title_align")
    end)

    -- main.lua's showSearch: an InputDialog with a Cancel (id "close") and an
    -- enter-default Search button, the keyboard shown, the text read back.
    test("koreader: InputDialog calls used by the search box exist", function()
        local src = readFile("frontend/ui/widget/inputdialog.lua")
        check(src:find("function InputDialog:getInputText()", 1, true), "InputDialog:getInputText")
        check(src:find("function InputDialog:onShowKeyboard(", 1, true), "InputDialog:onShowKeyboard")
        check(src:find("btn.is_enter_default", 1, true), "is_enter_default")
        check(src:find('self.button_table:getButtonById("close")', 1, true), "button id close")
        check(src:find("input_hint", 1, true), "input_hint")
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
        local Event = require("ui/event")
        eq(Event:new("KOSyncPullProgress").handler, "onKOSyncPullProgress", "event handler name")
        eq(Event:new("KOSyncServerlessPullProgress").handler, "onKOSyncServerlessPullProgress",
            "serverless event handler name")
    end)

    -- main.lua's hasPlugin: with no book open, a doc-only plugin has no
    -- ui.<name>, but PluginLoader keeps it in enabled_plugins under its name.
    test("koreader: PluginLoader lists enabled plugins by name", function()
        local src = readFile("frontend/pluginloader.lua")
        check(src:find("table.insert(self.enabled_plugins, plugin_module)", 1, true), "enabled_plugins")
        check(src:find("plugin_module.name = v.name", 1, true), "plugin name")
        check(src:find("if self.enabled_plugins then return self.enabled_plugins", 1, true),
            "loadPlugins no longer keeps enabled_plugins")
    end)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
