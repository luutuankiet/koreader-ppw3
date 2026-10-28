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
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local socket = require("socket")
local _ = require("gettext")
local T = require("ffi/util").template

local LocalIndex = require("syncedhistory_localindex")

-- KOReader builds a new plugin instance each time it switches between the
-- file browser and a book, but loads this file once per run. Keeping the
-- index here makes "rescan at most once per session" mean once per run.
local index

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
            settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/syncedhistory.lua"),
            root = G_reader_settings:readSetting("home_dir"),
            is_document = makeIsDocument(),
            clock = socket.gettime,
        }
    end
    return index
end

local SyncedHistory = WidgetContainer:extend{
    name = "syncedhistory",
    is_doc_only = false,
}

-- For later changes and for the on-device checks.
SyncedHistory.getIndex = getIndex

function SyncedHistory:init()
    self.ui.menu:registerToMainMenu(self)
end

function SyncedHistory:addToMainMenu(menu_items)
    menu_items.synced_reading_list = {
        text = _("Synced reading list"),
        sorting_hint = "main",
        callback = function()
            local keys, ms = getIndex():timeScan()
            logger.info("syncedhistory: scanned", keys, "documents in", ms, "ms")
            UIManager:show(InfoMessage:new{
                text = T(_("Synced reading list is not ready yet.\n%1 documents on this device."), keys),
            })
        end,
    }
end

return SyncedHistory
