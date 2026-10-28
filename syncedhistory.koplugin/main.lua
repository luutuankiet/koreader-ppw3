--[[--
Synced reading list: one reading list shared by every device logged into the
same progress sync server. This file is the scaffold; the list itself comes
in later changes.
]]

local DataStorage = require("datastorage")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local socket = require("socket")
local _ = require("gettext")
local T = require("ffi/util").template

local Client = require("syncedhistory_client")
local Http = require("syncedhistory_http")
local LocalIndex = require("syncedhistory_localindex")

-- KOReader builds a new plugin instance each time it switches between the
-- file browser and a book, but loads this file once per run. Keeping the
-- index here makes "rescan at most once per session" mean once per run.
local index, client, settings

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
-- otherwise its settings file.
local live_kosync
local function readKosyncSettings()
    if live_kosync and live_kosync.settings then return live_kosync.settings end
    local file = DataStorage:getSettingsDir() .. "/kosync.lua"
    if lfs.attributes(file, "mode") ~= "file" then return nil end
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

-- Every book open tells the server the book's file name, so other devices
-- can show it in their list.
function SyncedHistory:onReaderReady()
    live_kosync = self.ui.kosync
    local file = self.ui.document and self.ui.document.file
    if file then getClient():pushDocument(file) end
end

function SyncedHistory:onCloseDocument()
    live_kosync = nil
end

function SyncedHistory:addToMainMenu(menu_items)
    menu_items.synced_reading_list = {
        text = _("Synced reading list"),
        sorting_hint = "main",
        callback = function()
            local keys, ms = getIndex():timeScan()
            logger.info("syncedhistory: scanned", keys, "documents in", ms, "ms")
            local syncing = InfoMessage:new{ text = _("Syncing..."), timeout = 20 }
            UIManager:show(syncing)
            getClient():fetchList(function(list, info)
                UIManager:close(syncing)
                local text
                if info.fresh then
                    text = T(_("Synced reading list is not ready yet.\n%1 documents on this device.\n%2 books on the server."), keys, #list)
                elseif list and info.cached then
                    text = T(_("%1\n%2 books in the cached list.\n%3 documents on this device."), _(info.message), #list, keys)
                else
                    text = _(info.message)
                end
                UIManager:show(InfoMessage:new{ text = text })
            end)
        end,
    }
end

return SyncedHistory
