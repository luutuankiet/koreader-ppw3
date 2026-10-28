--[[--
Synced reading list: one reading list shared by every device logged into the
same progress sync server. One menu entry opens the list: the cached copy at
once, then the server's copy. Tapping a book on this device opens it and asks
the built-in progress sync to pull its latest position.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local DocumentRegistry = require("document/documentregistry")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local socket = require("socket")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local _ = require("gettext")

local Client = require("syncedhistory_client")
local Http = require("syncedhistory_http")
local ListView = require("syncedhistory_listview")
local LocalIndex = require("syncedhistory_localindex")

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

-- The built-in progress sync settings. Its live table when it is loaded (it
-- only is while a book is open, and it may hold a login not flushed yet),
-- otherwise its settings file, or up to v2024.11 the "kosync" key of the
-- global reader settings.
local live_kosync
local function readKosyncSettings()
    if live_kosync and live_kosync.settings then return live_kosync.settings end
    local file = DataStorage:getSettingsDir() .. "/kosync.lua"
    if lfs.attributes(file, "mode") ~= "file" then return G_reader_settings:readSetting("kosync") end
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

function SyncedHistory:init()
    self.ui.menu:registerToMainMenu(self)
end

-- Ask the built-in progress sync to pull this book's position, through its
-- own "Pull progress from other devices" action. In KOReader v2026.07.1,
-- KOSync:onKOSyncPullProgress calls getProgress(true, true): it turns the
-- network on if needed and, being interactive, jumps to the server's
-- position without a prompt, whatever the "sync to a newer/older state"
-- settings say.
function SyncedHistory:pullProgress()
    if not self.ui.kosync then
        UIManager:show(InfoMessage:new{
            text = _("Progress sync is disabled, so the position was not pulled."),
            timeout = 3,
        })
        return
    end
    logger.info("syncedhistory: pulling progress for", self.ui.document and self.ui.document.file)
    self.ui:handleEvent(Event:new("KOSyncPullProgress"))
end

-- Every book open tells the server the book's file name, so other devices
-- can show it in their list. A book opened from the list also pulls its
-- position, after the reader has restored the local one.
function SyncedHistory:onReaderReady()
    live_kosync = self.ui.kosync
    local file = self.ui.document and self.ui.document.file
    if file then getClient():pushDocument(file) end
    local pull = file ~= nil and file == pending_pull
    pending_pull = nil
    if pull then
        UIManager:nextTick(function() self:pullProgress() end)
    end
end

function SyncedHistory:onCloseDocument()
    live_kosync = nil
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
    -- Look again: the file may have moved since the list was built.
    local path = row.document and getIndex():lookup(row.document)
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
-- state: rows (from buildRows), status (subtitle tail), empty (text when the
-- server list is empty or could not be fetched), query (the search, nil when
-- none; it lives only as long as this list and is never saved).
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

-- The title-bar menu: show or hide books not on this device, search, and
-- clear the search while one is active.
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
    dialog = ButtonDialog:new{ buttons = buttons }
    UIManager:show(dialog)
end

-- A long press on a row: the whole name (the list cuts it to one line) and
-- the rest of what the server knows. Open only for a book on this device,
-- through the same path as a tap. The empty-list row has no document and no
-- pop-up.
function SyncedHistory:showDetails(menu, row)
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
    local state = {
        rows = buildRows(getClient():cachedList()),
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
        self:showDetails(menu, item)
        return true
    end
    self:redrawList(menu, state)
    UIManager:show(menu)
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
        state.rows = buildRows(list)
        self:redrawList(menu, state)
    end)
end

function SyncedHistory:addToMainMenu(menu_items)
    menu_items.synced_reading_list = {
        text = _(ListView.TITLE),
        sorting_hint = "main",
        callback = function() self:showList() end,
    }
end

return SyncedHistory
