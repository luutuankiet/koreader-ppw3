--[[--
Tests for syncedhistory_backend.lua, the "Synced reading list backend"
setting, and how main.lua uses it: which ui.<name> module it reads, which
settings file it reads with no book open, and which event pulls a position.
main.lua never loads this file.

main.lua is loaded here with every KOReader module it requires replaced by a
small fake, so these tests run the same with any LuaJIT or Lua 5.1 and with
KOReader's own luajit (--koreader only adds the real Event's handler names):
  luajit test_backend.lua
  cd /mnt/us/koreader && ./luajit <plugin dir>/test_backend.lua --koreader
]]

local mode = arg and arg[1] == "--koreader" and "koreader" or "standalone"

local this_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = this_dir .. "/?.lua;" .. package.path

if mode == "koreader" then
    require("setupkoenv")
end

local Backend = require("syncedhistory_backend")

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

local function loaded(set)
    return function(module) return set[module] == true end
end

-- Backend.resolve: the one place the choice is made.

test("choice: unset or unknown is auto", function()
    eq(Backend.choice(nil), "auto")
    eq(Backend.choice("bogus"), "auto")
    eq(Backend.choice("kosync"), "kosync")
    eq(Backend.choice("serverless"), "serverless")
    eq(Backend.DEFAULT, "auto")
end)

test("resolve auto: serverless when it is loaded", function()
    eq(Backend.resolve("auto", loaded{ kosyncserverless = true, kosync = true }), Backend.SERVERLESS)
    eq(Backend.resolve(nil, loaded{ kosyncserverless = true }), Backend.SERVERLESS, "unset is auto")
end)

test("resolve auto: built-in when serverless is not loaded", function()
    eq(Backend.resolve("auto", loaded{ kosync = true }), Backend.KOSYNC)
    eq(Backend.resolve("auto", loaded{}), Backend.KOSYNC, "neither loaded")
end)

test("resolve kosync: built-in even when serverless is loaded", function()
    eq(Backend.resolve("kosync", loaded{ kosyncserverless = true, kosync = true }), Backend.KOSYNC)
end)

test("resolve serverless: serverless when loaded, no log line", function()
    local lines = {}
    eq(Backend.resolve("serverless", loaded{ kosyncserverless = true },
        function(s) lines[#lines + 1] = s end), Backend.SERVERLESS)
    eq(#lines, 0, "log lines")
end)

test("resolve serverless not loaded: falls back to built-in and logs it", function()
    local lines = {}
    eq(Backend.resolve("serverless", loaded{ kosync = true },
        function(s) lines[#lines + 1] = s end), Backend.KOSYNC)
    eq(#lines, 1, "log lines")
    check(lines[1]:find("not loaded", 1, true), lines[1])
end)

test("the three things each backend decides", function()
    eq(Backend.KOSYNC.module, "kosync")
    eq(Backend.KOSYNC.settings_file, "kosync.lua")
    eq(Backend.KOSYNC.pull_event, "KOSyncPullProgress")
    eq(Backend.SERVERLESS.module, "kosyncserverless")
    eq(Backend.SERVERLESS.settings_file, "kosyncserverless.lua")
    eq(Backend.SERVERLESS.pull_event, "KOSyncServerlessPullProgress")
    eq(Backend.SERVERLESS.legacy_key, nil, "the clone has no legacy global key")
end)

test("fromSources: picks by which plugin folders exist", function()
    local files = {
        ["plugins/kosync.koplugin/main.lua"] = true,
        ["here/../kosyncserverless.koplugin/main.lua"] = true,
    }
    local function exists(p) return files[p] == true end
    local roots = { "plugins", "here/.." }
    local b, path = Backend.fromSources(nil, roots, exists)
    eq(b, Backend.SERVERLESS, "auto with serverless present")
    eq(path, "here/../kosyncserverless.koplugin/main.lua")
    b, path = Backend.fromSources("kosync", roots, exists)
    eq(b, Backend.KOSYNC)
    eq(path, "plugins/kosync.koplugin/main.lua")
    files["here/../kosyncserverless.koplugin/main.lua"] = nil
    b, path = Backend.fromSources("serverless", roots, exists)
    eq(b, Backend.KOSYNC, "serverless missing falls back")
    eq(path, "plugins/kosync.koplugin/main.lua")
end)

-- main.lua with fakes for every KOReader module it requires. Each call
-- loads a fresh copy, so its once-per-run state starts empty.

local FAKES = {
    "ui/widget/buttondialog", "ui/widget/confirmbox", "datastorage",
    "document/documentregistry", "ui/event", "ui/widget/infomessage",
    "ui/widget/inputdialog", "luasettings", "ui/widget/menu", "pluginloader",
    "ui/uimanager", "ui/widget/container/widgetcontainer", "json",
    "libs/libkoreader-lfs", "logger", "ffi/sha2", "socket",
    "apps/filemanager/filemanagerutil", "gettext", "ffi/util",
}
local OWN = {
    "syncedhistory_backend", "syncedhistory_client", "syncedhistory_deviceid",
    "syncedhistory_http", "syncedhistory_listview", "syncedhistory_localindex",
}

--[[
world:
  files     settings file name -> table of keys, under /settings
  enabled   list of plugin names PluginLoader enabled at start-up
  choice    the saved "progress_sync_backend", or nil
]]
-- The real modules and reader settings, put back by restore() before the
-- --koreader checks. The fakes stay in place between loadMain and the end
-- of each test: main.lua requires some modules lazily (Http.new needs
-- socket and ffi/util when the client is first built).
local saved, saved_g = {}, G_reader_settings
for _, name in ipairs(FAKES) do saved[name] = package.loaded[name] end
local function restore()
    for _, name in ipairs(FAKES) do package.loaded[name] = saved[name] end
    for _, name in ipairs(OWN) do package.loaded[name] = nil end
    G_reader_settings = saved_g
end

local function loadMain(world)

    local logs, shown = {}, {}
    local files = {}
    for name, t in pairs(world.files or {}) do files["/settings/" .. name] = t end
    files["/settings/syncedhistory.lua"] = { progress_sync_backend = world.choice }

    local function fakeSettings(data)
        return {
            readSetting = function(_, k) return data[k] end,
            saveSetting = function(_, k, v) data[k] = v end,
            isTrue = function(_, k) return data[k] == true end,
            flush = function() end,
        }
    end
    local function new(class, o) o = o or {}; return setmetatable(o, { __index = class }) end
    local widget = { new = new }
    local enabled = {}
    for i, name in ipairs(world.enabled or {}) do enabled[i] = { name = name } end

    local fakes = {
        ["ui/widget/buttondialog"] = widget,
        ["ui/widget/confirmbox"] = widget,
        ["datastorage"] = { getSettingsDir = function() return "/settings" end },
        ["document/documentregistry"] = {},
        ["ui/event"] = { new = function(_, name) return { name = name } end },
        ["ui/widget/infomessage"] = widget,
        ["ui/widget/inputdialog"] = widget,
        ["luasettings"] = { open = function(_, path)
            files[path] = files[path] or {}
            return fakeSettings(files[path])
        end },
        ["ui/widget/menu"] = widget,
        ["pluginloader"] = { enabled_plugins = enabled },
        ["ui/uimanager"] = {
            show = function(_, w) shown[#shown + 1] = w end,
            nextTick = function(_, f) f() end,
            scheduleIn = function() end,
        },
        ["ui/widget/container/widgetcontainer"] = { extend = function(_, o) return o end },
        ["json"] = { decode = function() return {} end, encode = function() return "{}" end },
        ["libs/libkoreader-lfs"] = { attributes = function(path, field)
            if files[path] and field == "mode" then return "file" end
        end },
        ["logger"] = {
            info = function(...) logs[#logs + 1] = table.concat({ ... }, " ") end,
            warn = function(...) logs[#logs + 1] = table.concat({ ... }, " ") end,
            dbg = function() end,
        },
        ["ffi/sha2"] = { md5 = function(s) return "md5<" .. s .. ">" end },
        ["socket"] = { gettime = function() return 0 end },
        ["apps/filemanager/filemanagerutil"] = {},
        ["gettext"] = function(s) return s end,
        ["ffi/util"] = {},
    }
    for name, fake in pairs(fakes) do package.loaded[name] = fake end
    for _, name in ipairs(OWN) do package.loaded[name] = nil end
    G_reader_settings = fakeSettings({ kosync = world.legacy })

    local ok, SyncedHistory = pcall(dofile, this_dir .. "/main.lua")
    assert(ok, SyncedHistory)
    return SyncedHistory, { logs = logs, shown = shown, files = files }
end

-- A reader ui with the given plugin instances, recording every event.
local function readerUi(modules)
    local ui = { document = { file = "/books/Dune.epub" }, events = {} }
    for name, settings in pairs(modules) do ui[name] = { settings = settings } end
    function ui:handleEvent(ev) self.events[#self.events + 1] = ev.name end
    return ui
end

local KOSYNC_FILE = { settings = { username = "from-kosync-file" } }
local SERVERLESS_FILE = { settings = { username = "from-serverless-file" } }

local function bookOpen(SyncedHistory, ui)
    local inst = setmetatable({ ui = ui }, { __index = SyncedHistory })
    inst:onReaderReady()
    return inst
end

local function settingsRead(SyncedHistory)
    return SyncedHistory.getClient().kosync()
end

test("main auto, serverless enabled, no book: serverless file", function()
    local SH = loadMain{ enabled = { "kosync", "kosyncserverless" },
        files = { ["kosync.lua"] = KOSYNC_FILE, ["kosyncserverless.lua"] = SERVERLESS_FILE } }
    eq(SH.getBackend().id, "serverless")
    eq(settingsRead(SH).username, "from-serverless-file")
end)

test("main auto, serverless not enabled, no book: kosync file", function()
    local SH = loadMain{ enabled = { "kosync" },
        files = { ["kosync.lua"] = KOSYNC_FILE, ["kosyncserverless.lua"] = SERVERLESS_FILE } }
    eq(SH.getBackend().id, "kosync")
    eq(settingsRead(SH).username, "from-kosync-file")
end)

test("main auto, book open: live table and event of the serverless plugin", function()
    local SH = loadMain{ enabled = { "kosync", "kosyncserverless" } }
    local ui = readerUi{ kosync = { username = "live-kosync" }, kosyncserverless = { username = "live-serverless" } }
    local inst = bookOpen(SH, ui)
    eq(settingsRead(SH).username, "live-serverless")
    inst:pullProgress()
    eq(#ui.events, 1, "one event")
    eq(ui.events[1], "KOSyncServerlessPullProgress")
end)

test("main auto, book open without serverless: built-in live table and event", function()
    local SH = loadMain{ enabled = { "kosync" } }
    local ui = readerUi{ kosync = { username = "live-kosync" } }
    local inst = bookOpen(SH, ui)
    eq(settingsRead(SH).username, "live-kosync")
    inst:pullProgress()
    eq(ui.events[1], "KOSyncPullProgress")
end)

test("main kosync chosen, both enabled: built-in everywhere", function()
    local SH = loadMain{ choice = "kosync", enabled = { "kosync", "kosyncserverless" },
        files = { ["kosync.lua"] = KOSYNC_FILE, ["kosyncserverless.lua"] = SERVERLESS_FILE } }
    eq(settingsRead(SH).username, "from-kosync-file", "no book")
    local ui = readerUi{ kosync = { username = "live-kosync" }, kosyncserverless = { username = "live-serverless" } }
    local inst = bookOpen(SH, ui)
    eq(settingsRead(SH).username, "live-kosync", "book open")
    inst:pullProgress()
    eq(ui.events[1], "KOSyncPullProgress")
end)

test("main kosync chosen, no kosync.lua: legacy global key", function()
    local SH = loadMain{ choice = "kosync", legacy = { username = "legacy" } }
    eq(settingsRead(SH).username, "legacy")
end)

test("main serverless chosen, enabled: serverless file and event", function()
    local SH = loadMain{ choice = "serverless", enabled = { "kosync", "kosyncserverless" },
        files = { ["kosync.lua"] = KOSYNC_FILE, ["kosyncserverless.lua"] = SERVERLESS_FILE } }
    eq(settingsRead(SH).username, "from-serverless-file")
    local ui = readerUi{ kosync = {}, kosyncserverless = {} }
    bookOpen(SH, ui):pullProgress()
    eq(ui.events[1], "KOSyncServerlessPullProgress")
end)

test("main serverless chosen, no serverless file: no legacy global fallback", function()
    local SH = loadMain{ choice = "serverless", enabled = { "kosyncserverless" },
        legacy = { username = "legacy" } }
    eq(settingsRead(SH), nil)
end)

test("main serverless chosen, not enabled: built-in, one log line", function()
    local SH, seen = loadMain{ choice = "serverless", enabled = { "kosync" },
        files = { ["kosync.lua"] = KOSYNC_FILE, ["kosyncserverless.lua"] = SERVERLESS_FILE } }
    eq(settingsRead(SH).username, "from-kosync-file")
    settingsRead(SH)
    local ui = readerUi{ kosync = {} }
    bookOpen(SH, ui):pullProgress()
    eq(ui.events[1], "KOSyncPullProgress")
    local n = 0
    for _, l in ipairs(seen.logs) do
        if l:find("not loaded", 1, true) then n = n + 1 end
    end
    eq(n, 1, "fallback logged once per run")
end)

test("main: chosen plugin disabled in the reader says so, no event", function()
    local SH, seen = loadMain{ choice = "kosync", enabled = { "kosyncserverless" } }
    local ui = readerUi{ kosyncserverless = {} }
    bookOpen(SH, ui):pullProgress()
    eq(#ui.events, 0, "no event")
    eq(#seen.shown, 1, "one message")
    check(seen.shown[1].text:find("Progress sync is disabled", 1, true), seen.shown[1].text)
end)

test("main: menu saves the choice and shows the resolved backend", function()
    local SH, seen = loadMain{ enabled = { "kosync" } }
    local inst = setmetatable({ ui = {} }, { __index = SH })
    local items = {}
    inst:addToMainMenu(items)
    local entry = items.synced_reading_list_backend
    check(entry and entry.sub_item_table, "backend menu entry")
    eq(#entry.sub_item_table, 3, "three choices")
    check(entry.sub_item_table[1].checked_func(), "auto checked by default")
    check(entry.text_func():find("Progress sync$"), entry.text_func())
    entry.sub_item_table[3].callback()
    eq(seen.files["/settings/syncedhistory.lua"].progress_sync_backend, "serverless", "saved")
    check(entry.sub_item_table[3].checked_func(), "serverless checked")
    check(not entry.sub_item_table[1].checked_func(), "auto unchecked")
    entry.sub_item_table[2].callback()
    eq(seen.files["/settings/syncedhistory.lua"].progress_sync_backend, "kosync", "saved")
end)

restore()

if mode == "koreader" then
    test("koreader: Event handler names of both pull events", function()
        local Event = require("ui/event")
        eq(Event:new(Backend.KOSYNC.pull_event).handler, "onKOSyncPullProgress")
        eq(Event:new(Backend.SERVERLESS.pull_event).handler, "onKOSyncServerlessPullProgress")
    end)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
