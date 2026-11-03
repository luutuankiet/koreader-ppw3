--[[--
Synced reading list: one reading list shared by every device logged into the
same progress sync server. One menu entry opens the list: the cached copy at
once, then the server's copy. Tapping a book on this device opens it and asks
the progress sync plugin (the built-in one or "Progress sync serverless", see
syncedhistory_backend.lua) to pull its latest position.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local DocumentRegistry = require("document/documentregistry")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local PluginLoader = require("pluginloader")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local socket = require("socket")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local _ = require("gettext")

local Backend = require("syncedhistory_backend")
local Client = require("syncedhistory_client")
local DeviceId = require("syncedhistory_deviceid")
local Http = require("syncedhistory_http")
local ListView = require("syncedhistory_listview")
local LocalIndex = require("syncedhistory_localindex")

-- Give the progress sync a device id derived from this Kindle's serial, so a
-- restored settings file can't make two Kindles share one. This runs when the
-- file loads: PluginLoader:loadPlugins runs every plugin's main.lua before it
-- builds any instance, so KOSync:init, which copies device_id once per
-- instance, already sees the new id in the first file browser or book.
-- "syncedhistory_serial_path" points at a fake serial on the emulator; it is
-- unset on real devices, where /proc/usid is read.
-- Never let it stop the plugin from loading.
local ok_id, err_id = pcall(DeviceId.apply, {
    settings = G_reader_settings,
    md5 = md5,
    path = G_reader_settings:readSetting("syncedhistory_serial_path"),
    log = logger,
})
if not ok_id then logger.warn("syncedhistory: device id not set:", err_id) end

-- KOReader builds a new plugin instance each time it switches between the
-- file browser and a book, but loads this file once per run. Keeping the
-- index here makes "rescan at most once per session" mean once per run.
local index, client, settings
-- Path of the book opened from the list, until its reader is ready.
local pending_pull

-- One settings object for the whole plugin: two LuaSettings opened on the
-- same file would each flush their own copy and drop the other's keys.
local function getSettings()
    if not settings then
        settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/syncedhistory.lua")
    end
    return settings
end

-- Same test as DocumentRegistry:hasProvider, minus its per-file sidecar
-- lookup: a registered extension, or one the user associated with a
-- document provider. Images are skipped: a book is never a picture, and
-- cover images would only bloat the index.
local function makeIsDocument()
    local registered = DocumentRegistry.filetype_provider or {}
    local images = DocumentRegistry.image_ext or {}
    local associated = G_reader_settings:readSetting("provider") or {}
    return function(name)
        local suffix = LocalIndex.suffix(name)
        if images[suffix] then return false end
        return registered[suffix] == true or associated[suffix] ~= nil
    end
end

local function getIndex()
    if not index then
        index = LocalIndex.new{
            lfs = lfs,
            md5 = md5,
            settings = getSettings(),
            root = G_reader_settings:readSetting("home_dir"),
            is_document = makeIsDocument(),
            clock = socket.gettime,
        }
    end
    return index
end

-- The reader's ui while a book is open: both progress sync plugins are
-- doc-only, so ui.kosync and ui.kosyncserverless exist only then.
local live_ui

-- Is this progress sync plugin loaded? Its instance while a book is open,
-- otherwise whether PluginLoader enabled it at start-up (the file browser
-- never builds doc-only plugins, but they are still in enabled_plugins).
local function hasPlugin(name)
    if live_ui and live_ui[name] then return true end
    for _, plugin in ipairs(PluginLoader.enabled_plugins or {}) do
        if plugin.name == name then return true end
    end
    return false
end

local fallback_logged
local function logFallbackOnce(...)
    if fallback_logged then return end
    fallback_logged = true
    logger.warn(...)
end

-- The progress sync plugin chosen in "Synced reading list backend".
local function getBackend()
    return Backend.resolve(getSettings():readSetting(Backend.SETTING), hasPlugin, logFallbackOnce)
end

-- The chosen progress sync plugin's settings. Its live table while a book
-- is open (it may hold a login not flushed yet), otherwise its settings
-- file, or for the built-in one up to v2024.11 the "kosync" key of the
-- global reader settings.
local function readKosyncSettings()
    local backend = getBackend()
    local live = live_ui and live_ui[backend.module]
    if live and live.settings then return live.settings end
    local file = DataStorage:getSettingsDir() .. "/" .. backend.settings_file
    if lfs.attributes(file, "mode") ~= "file" then
        return backend.legacy_key and G_reader_settings:readSetting(backend.legacy_key)
    end
    return LuaSettings:open(file):readSetting("settings")
end

local function getClient()
    if not client then
        client = Client.new{
            kosync = readKosyncSettings,
            request = Http.new{
                scheduleIn = function(s, f) UIManager:scheduleIn(s, f) end,
                log = logger,
            },
            md5 = md5,
            json_decode = json.decode,
            json_encode = json.encode,
            settings = getSettings(),
            log = logger,
        }
    end
    return client
end

local SyncedHistory = WidgetContainer:extend{
    name = "syncedhistory",
    is_doc_only = false,
}

-- For later changes and for the on-device checks.
SyncedHistory.getIndex = getIndex
SyncedHistory.getClient = getClient
SyncedHistory.getBackend = getBackend

function SyncedHistory:init()
    self.ui.menu:registerToMainMenu(self)
end

-- Ask the chosen progress sync plugin to pull this book's position, through
-- its own "Pull progress from other devices" action. In KOReader v2026.07.1,
-- KOSync:onKOSyncPullProgress calls getProgress(true, true): it turns the
-- network on if needed and, being interactive, jumps to the server's
-- position without a prompt, whatever the "sync to a newer/older state"
-- settings say. The serverless clone's onKOSyncServerlessPullProgress does
-- the same. Each plugin answers only its own event, so with both enabled
-- only the chosen one pulls.
function SyncedHistory:pullProgress()
    local backend = getBackend()
    if not self.ui[backend.module] then
        UIManager:show(InfoMessage:new{
            text = backend == Backend.SERVERLESS
                and _("Progress sync serverless is disabled, so the position was not pulled.")
                or _("Progress sync is disabled, so the position was not pulled."),
            timeout = 3,
        })
        return
    end
    logger.info("syncedhistory: pulling progress with", backend.module, "for",
        self.ui.document and self.ui.document.file)
    self.ui:handleEvent(Event:new(backend.pull_event))
end

-- Every book open tells the server the book's file name, so other devices
-- can show it in their list. A book opened from the list also pulls its
-- position, after the reader has restored the local one.
function SyncedHistory:onReaderReady()
    live_ui = self.ui
    local file = self.ui.document and self.ui.document.file
    if file then getClient():pushDocument(file) end
    local pull = file ~= nil and file == pending_pull
    pending_pull = nil
    if pull then
        UIManager:nextTick(function() self:pullProgress() end)
    end
end

function SyncedHistory:onCloseDocument()
    live_ui = nil
end

-- filemanagerutil.openFile arrived after v2024.11. Without it, make the two
-- calls it makes for a book: switch documents in the reader, or open the
-- file from the file browser.
local function openBook(ui, path)
    if filemanagerutil.openFile then
        filemanagerutil.openFile(ui, path)
    elseif ui.document then
        ui:switchDocument(path)
    else
        ui:openFile(path)
    end
end

function SyncedHistory:openRow(menu, row)
    -- Look again: the file may have moved since the list was built. Any of
    -- the book's file names counts; the built-in sync then pulls by the
    -- opened file's own key.
    local path = row.document and ListView.localMatch(row, function(key) return getIndex():lookup(key) end)
    if not path then
        logger.info("syncedhistory: not on this device:", row.document)
        UIManager:show(InfoMessage:new{ text = _(ListView.NOT_FOUND), timeout = 3 })
        return
    end
    UIManager:close(menu)
    if self.ui.document and self.ui.document.file == path then
        -- Already open: no new reader to wait for.
        self:pullProgress()
        return
    end
    logger.info("syncedhistory: opening", path)
    pending_pull = path
    openBook(self.ui, path)
end

-- Books not on this device are hidden until the reader asks for them; the
-- choice is kept per device.
local function showMissing()
    return getSettings():isTrue("show_missing")
end

local function toggleShowMissing()
    getSettings():saveSetting("show_missing", not showMissing())
    getSettings():flush()
end

local function buildRows(list)
    return ListView.rows(list, {
        lookup = function(key) return getIndex():lookup(key) end,
        gettext = _,
    })
end

-- Each row's tap goes through item.callback (Menu:onMenuChoice). The menu
-- has no close_callback, so a tap never closes it by itself: a missing book
-- leaves the list open, and openRow closes it before opening a book.
-- state: list (the server list or its cached copy), rows (from buildRows),
-- status (subtitle tail), empty (text when the server list is empty or could
-- not be fetched), query (the search, nil when none; it lives only as long as
-- this list and is never saved).
function SyncedHistory:redrawList(menu, state)
    local view = ListView.view(state.rows, { show_missing = showMissing(), query = state.query })
    local items = {}
    for i, row in ipairs(view.rows) do
        row.callback = function() self:openRow(menu, row) end
        items[i] = row
    end
    local empty = ListView.emptyText(view, { empty = state.empty, gettext = _ })
    if empty then
        items[1] = { text = empty, select_enabled = false, dim = true }
    end
    -- itemnumber nil: switchItemTable goes back to page 1.
    menu:switchItemTable(nil, items, nil, nil, ListView.subtitle(view, { status = state.status, gettext = _ }))
end

-- Fetch the server list into the open list screen. The cached copy is shown
-- until the answer comes; a failed fetch keeps it and says so.
function SyncedHistory:fetchIntoList(menu, state)
    state.status = _(ListView.SYNCING)
    self:redrawList(menu, state)
    getClient():fetchList(function(list, info)
        if not UIManager:isWidgetShown(menu) then return end
        if info.fresh then
            state.status = _(ListView.SYNCED)
            state.empty = _(ListView.EMPTY)
        else
            state.status = _(info.message)
            state.empty = _(info.message)
            if info.reason then
                -- Not logged in, or the wrong matching method: say so plainly.
                UIManager:show(InfoMessage:new{ text = _(info.message) })
            end
        end
        state.list = list
        state.rows = buildRows(list)
        self:redrawList(menu, state)
    end)
end

-- "Refresh": look for books copied in since the last scan, whatever the
-- once-per-run limit says, then fetch the server list again.
function SyncedHistory:refreshList(menu, state)
    local keys = getIndex():rescan()
    logger.info("syncedhistory: refresh, local books:", keys)
    state.rows = buildRows(state.list)
    self:fetchIntoList(menu, state)
end

-- KOReader's on-screen keyboard dialog. Search sets the query and redraws;
-- Cancel leaves the list as it was.
function SyncedHistory:showSearch(menu, state)
    local dialog
    dialog = InputDialog:new{
        title = _("Search the synced reading list"),
        input = state.query or "",
        input_hint = _("Part of a book's name"),
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = ListView.cleanQuery(dialog:getInputText())
                    UIManager:close(dialog)
                    state.query = query
                    self:redrawList(menu, state)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- The title-bar menu: show or hide books not on this device, search, clear
-- the search while one is active, and refresh.
function SyncedHistory:showListMenu(menu, state)
    local dialog
    local buttons = {
        { {
            -- The marks CheckButton draws for a checkbox.
            text = (showMissing() and "✓ " or "□ ") .. _("Show books not on this device"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                toggleShowMissing()
                self:redrawList(menu, state)
            end,
        } },
        { {
            text = _("Search…"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                self:showSearch(menu, state)
            end,
        } },
    }
    if state.query then
        table.insert(buttons, { {
            text = _("Clear search"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                state.query = nil
                self:redrawList(menu, state)
            end,
        } })
    end
    table.insert(buttons, { {
        text = _(ListView.REFRESH),
        align = "left",
        callback = function()
            UIManager:close(dialog)
            self:refreshList(menu, state)
        end,
    } })
    dialog = ButtonDialog:new{ buttons = buttons }
    UIManager:show(dialog)
end

-- "Remove from list": confirm, delete every key of the book on the server,
-- then fetch the list again. A failed delete keeps the row and says so.
function SyncedHistory:removeRow(menu, state, row)
    UIManager:show(ConfirmBox:new{
        text = ListView.removeText(row, { gettext = _ }),
        ok_text = _(ListView.REMOVE),
        ok_callback = function()
            local keys = {}
            for i, a in ipairs(row.keys or { { document = row.document } }) do keys[i] = a.document end
            state.status = _(ListView.REMOVING)
            self:redrawList(menu, state)
            getClient():removeDocuments(keys, function(ok, info)
                if not ok then
                    UIManager:show(InfoMessage:new{ text = _(info.message) })
                end
                if UIManager:isWidgetShown(menu) then self:fetchIntoList(menu, state) end
            end)
        end,
    })
end

-- A long press on a row: the whole name (the list cuts it to one line) and
-- the rest of what the server knows. Open only for a book on this device,
-- through the same path as a tap; "Remove from list" for every book. The
-- empty-list row has no document and no pop-up.
function SyncedHistory:showDetails(menu, state, row)
    if not (row and row.document) then return end
    local dialog
    local buttons = {}
    if row.path then
        buttons[1] = {
            text = _("Open"),
            callback = function()
                UIManager:close(dialog)
                self:openRow(menu, row)
            end,
        }
    end
    buttons[#buttons + 1] = {
        text = _(ListView.REMOVE),
        callback = function()
            UIManager:close(dialog)
            self:removeRow(menu, state, row)
        end,
    }
    buttons[#buttons + 1] = {
        text = _("Close"),
        callback = function() UIManager:close(dialog) end,
    }
    dialog = ButtonDialog:new{
        title = ListView.details(row, { gettext = _ }),
        title_align = "left",
        buttons = { buttons },
    }
    UIManager:show(dialog)
end

--- The list screen: the cached copy at once, the server's copy when it comes.
function SyncedHistory:showList()
    local cached = getClient():cachedList()
    local state = {
        list = cached,
        rows = buildRows(cached),
        status = _(ListView.SYNCING),
        empty = _(ListView.SYNCING),
    }
    local menu = Menu:new{
        name = "syncedhistory_list",
        title = _(ListView.TITLE),
        subtitle = _(ListView.SYNCING),
        item_table = {},
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        single_line = true,
    }
    menu.onLeftButtonTap = function() self:showListMenu(menu, state) end
    -- MenuItem calls self.menu:onMenuHold(item, pos); the default does nothing.
    menu.onMenuHold = function(_menu, item)
        self:showDetails(menu, state, item)
        return true
    end
    self:redrawList(menu, state)
    UIManager:show(menu)
    self:fetchIntoList(menu, state)
end

local BACKEND_TEXT = {
    auto = _("Automatic (serverless when installed)"),
    kosync = _("Progress sync (built-in)"),
    serverless = _("Progress sync serverless"),
}

-- "Synced reading list backend": which plugin the list reads its login from and
-- asks to pull a position. Kept per device in syncedhistory.lua.
function SyncedHistory:backendMenu()
    local items = {}
    for i, choice in ipairs(Backend.CHOICES) do
        items[i] = {
            text = BACKEND_TEXT[choice],
            radio = true,
            checked_func = function()
                return Backend.choice(getSettings():readSetting(Backend.SETTING)) == choice
            end,
            callback = function()
                getSettings():saveSetting(Backend.SETTING, choice)
                getSettings():flush()
                fallback_logged = nil
                logger.info("syncedhistory: progress sync backend", choice, "->", getBackend().module)
            end,
        }
    end
    return {
        text_func = function()
            return _("Synced reading list backend") .. ": " .. _(getBackend().title)
        end,
        sub_item_table = items,
    }
end

function SyncedHistory:addToMainMenu(menu_items)
    menu_items.synced_reading_list = {
        text = _(ListView.TITLE),
        sorting_hint = "main",
        callback = function() self:showList() end,
    }
    menu_items.synced_reading_list_backend = self:backendMenu()
    menu_items.synced_reading_list_backend.sorting_hint = "tools"
end

return SyncedHistory
