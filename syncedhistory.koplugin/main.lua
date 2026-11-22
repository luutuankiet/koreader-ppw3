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
local Dispatcher = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local PluginLoader = require("pluginloader")
local NetworkMgr = require("ui/network/manager")
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
local Cleanup = require("syncedhistory_cleanup")
local Tabs = require("syncedhistory_tabs")
local Client = require("syncedhistory_client")
local DeviceId = require("syncedhistory_deviceid")
local Http = require("syncedhistory_http")
local Drive = require("syncedhistory_drive")
local ListView = require("syncedhistory_listview")
local LocalIndex = require("syncedhistory_localindex")
local Goals = require("syncedhistory_goals")
local Stats = require("syncedhistory_stats")
local StatsDb = require("syncedhistory_statsdb")
local StatsView = require("syncedhistory_statsview")

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
-- A book reopened after a Drive update: { path, percent (0..1), push }.
local pending_percent
-- Last Drive version check per path (seconds), so one open never checks twice.
local version_checked = {}
-- The background backfill runs at most once per run.
local backfill_started

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

-- Cross-device reading time (syncedhistory_stats.lua), over KOReader's own
-- statistics database. Synced only at the list's network moments, never by
-- turning Wi-Fi on and never per page turn.
local stats
local function getStats()
    if not stats then
        local SQ3 = require("lua-ljsqlite3/init")
        local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
        stats = Stats.new{
            db = StatsDb.new{ open = function() return SQ3.open(path) end },
            request = Http.new{
                scheduleIn = function(s, f) UIManager:scheduleIn(s, f) end,
                log = logger,
            },
            credentials = function() return (getClient():credentials()) end,
            device = function()
                local Device = require("device")
                return G_reader_settings:readSetting("device_name") or Device.model,
                    G_reader_settings:readSetting("device_id")
            end,
            json_encode = json.encode,
            json_decode = json.decode,
            settings = getSettings(),
            scheduleIn = function(s, f) UIManager:scheduleIn(s, f) end,
            flush = function()
                local st = live_ui and live_ui.statistics
                if st and st.insertDB then st:insertDB() end
            end,
            kindOf = function(md5)
                local kinds = getSettings():readSetting("stats_local_kinds")
                return kinds and kinds[md5]
            end,
            log = logger,
        }
    end
    return stats
end

-- Sync reading time, only when the network is already up.
local function syncStats(done)
    if not NetworkMgr:isOnline() then
        if done then done(false, { reason = "offline" }) end
        return
    end
    local ok, err = pcall(function() getStats():sync(done) end)
    if not ok then
        logger.warn("syncedhistory: stats sync failed:", err)
        if done then done(false, { reason = tostring(err) }) end
    end
end

local GOAL, WEEK_START, COUNTED, SHOW_STRIP = "stats_goal_min", "stats_week_start", "stats_counted", "stats_show_strip"
local LOCAL_KINDS, GOAL_MET_SHOWN = "stats_local_kinds", "goal_met_shown"

local function goalMin() return Goals.clampGoal(getSettings():readSetting(GOAL) or Goals.DEFAULT_GOAL) end
local function weekStart() return getSettings():readSetting(WEEK_START) or Goals.MONDAY end
local function stripShown() return getSettings():readSetting(SHOW_STRIP) ~= false end

-- Day totals of the last 400 days from the local statistics database, which
-- holds other devices' time once synced. Read on screen open, not per redraw.
local function loadDays()
    local ok, rows = pcall(function() return getStats().db:readFrom(os.time() - 400 * 86400) end)
    if not ok then
        logger.warn("syncedhistory: reading stats failed:", rows)
        return nil
    end
    local recs = StatsView.records(rows, getSettings():readSetting(LOCAL_KINDS), getStats():remoteKinds())
    return Goals.addRecords({}, recs)
end

local function goalSummary(days, week_offset)
    return Goals.summary{ days = days or {}, now = os.time(), goal_min = goalMin(), week_start = weekStart(),
        counted = getSettings():readSetting(COUNTED), week_offset = week_offset or 0 }
end

local function openCalendar()
    UIManager:broadcastEvent(Event:new("ShowCalendarView"))
end

local SyncedHistory = WidgetContainer:extend{
    name = "syncedhistory",
    is_doc_only = false,
}

-- For later changes and for the on-device checks.
SyncedHistory.getIndex = getIndex
SyncedHistory.getStats = function() return getStats() end
SyncedHistory.getClient = getClient
SyncedHistory.getBackend = getBackend

-- A gesture or quick menu action, in the file browser and in a book.
function SyncedHistory:onDispatcherRegisterActions()
    Dispatcher:registerAction("synced_reading_list", {
        category = "none",
        event = "ShowSyncedReadingList",
        title = _(ListView.TITLE),
        general = true,
    })
end

function SyncedHistory:onShowSyncedReadingList()
    self:showList()
    return true
end

function SyncedHistory:init()
    self:onDispatcherRegisterActions()
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

-- The Google Drive plugin's headless API, or nil when it is not enabled.
local function driveApi(ui)
    local g = ui and ui.gdriveepub
    return g and g.api or nil
end

local function showText(text)
    UIManager:show(InfoMessage:new{ text = _(text), timeout = 3 })
end

-- Tell the server a book's file name, and its Drive source when it has one.
-- A server row naming another Drive file keeps it, and the reader is told.
local function pushDocument(ui, path)
    local api = driveApi(ui)
    local source = api and Drive.sourceFor(api.readRecord(path))
    getClient():pushDocument(path, function(_, info)
        if info and info.clash then showText(Drive.MSG_CLASH) end
    end, source)
end

-- Every book open tells the server the book's file name, so other devices
-- can show it in their list. A book opened from the list also pulls its
-- position, after the reader has restored the local one. A book reopened
-- after a Drive update goes to its old percentage and pushes it.
function SyncedHistory:onReaderReady()
    live_ui = self.ui
    local file = self.ui.document and self.ui.document.file
    if file then pushDocument(self.ui, file) end
    local ds = self.ui.doc_settings
    local md5sum = ds and ds:readSetting("partial_md5_checksum")
    if md5sum and ds:readSetting("gdriveepub_source") then
        local kinds = getSettings():readSetting(LOCAL_KINDS) or {}
        if kinds[md5sum] ~= "gdrive" then
            kinds[md5sum] = "gdrive"
            getSettings():saveSetting(LOCAL_KINDS, kinds)
            getSettings():flush()
        end
    end
    UIManager:scheduleIn(3, function() syncStats() end)
    local pull = file ~= nil and file == pending_pull
    pending_pull = nil
    local at = pending_percent and file == pending_percent.path and pending_percent
    pending_percent = nil
    if at then
        UIManager:nextTick(function()
            self.ui:handleEvent(Event:new("GotoPercent", at.percent * 100))
            if at.push and self.ui.kosyncserverless then
                UIManager:scheduleIn(1, function()
                    if self.ui.kosyncserverless then self.ui.kosyncserverless:pushNow() end
                end)
            end
        end)
    elseif pull then
        UIManager:nextTick(function() self:pullProgress() end)
    end
end

-- Is Drive's copy of `path` newer than the one on disk? Downloads it when it
-- is. cb(new_path) after a download, cb(nil) otherwise. Quiet on errors.
local function updateFromDrive(api, path, rec, cb)
    version_checked[path] = os.time()
    api.info(rec.id, function(ok, item)
        if not ok or type(item) ~= "table" or item.trashed
            or not Drive.isNewer(item.modifiedTime, rec.modified) then
            if not ok then logger.info("syncedhistory: version check failed:", item) end
            return cb(nil)
        end
        logger.info("syncedhistory: newer on Drive:", path, rec.modified, "->", item.modifiedTime)
        local note = InfoMessage:new{ text = _(Drive.MSG_UPDATING) }
        UIManager:show(note)
        api.download(item, function(ok2, new_path)
            UIManager:close(note)
            if not ok2 then
                logger.warn("syncedhistory: update download failed:", new_path)
                return cb(nil)
            end
            getIndex():remember(new_path)
            cb(new_path)
        end)
    end)
end

-- Only when online, never turning WiFi on, and once per book per minute.
local function shouldCheck(api, path)
    if not api or not api.isPaired() or not NetworkMgr:isOnline() then return nil end
    if os.time() - (version_checked[path] or 0) < 60 then return nil end
    return api.readRecord(path)
end

-- For the progress sync's manual push and pull: when Drive holds a newer
-- version of the open book, download it, reopen it at the current
-- percentage and push from there. done(true) then, done(false) otherwise.
function SyncedHistory:checkDriveVersion(done)
    local file = self.ui.document and self.ui.document.file
    local api = driveApi(self.ui)
    local rec = file and shouldCheck(api, file)
    if not rec then return done(false) end
    local doc = self.ui.document
    local percent = doc.info.has_pages and self.ui.paging:getLastPercent() or self.ui.rolling:getLastPercent()
    updateFromDrive(api, file, rec, function(new_path)
        if not new_path then return done(false) end
        pending_percent = { path = new_path, percent = percent or 0, push = true }
        done(true)
        self.ui:switchDocument(new_path)
    end)
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
    local api = driveApi(self.ui)
    if not path then
        logger.info("syncedhistory: not on this device:", row.document)
        if not api then
            UIManager:show(InfoMessage:new{ text = _(ListView.NOT_FOUND), timeout = 3 })
            return
        end
        UIManager:show(ConfirmBox:new{
            text = _(Drive.MSG_ASK),
            ok_text = _("Download"),
            ok_callback = function() self:downloadRow(menu, row, api) end,
        })
        return
    end
    local rec = shouldCheck(api, path)
    if rec then
        updateFromDrive(api, path, rec, function(new_path)
            self:openPath(menu, new_path or path, new_path ~= nil)
        end)
        return
    end
    self:openPath(menu, path)
end

-- Download a row's book from Drive into the GDrive folder under the same
-- file name (so its sync key, and its progress, stay the same), then open it.
function SyncedHistory:downloadRow(menu, row, api)
    if NetworkMgr:willRerunWhenOnline(function() self:downloadRow(menu, row, api) end) then return end
    if not api.isPaired() then return showText(Drive.MSG_NOT_PAIRED) end
    local note = InfoMessage:new{ text = _(Drive.MSG_DOWNLOADING) }
    UIManager:show(note)
    local function fail(reason)
        UIManager:close(note)
        logger.info("syncedhistory: no Drive download for", row.filename, reason)
        if reason == "none" or reason == "no_name" or reason == "not_found" then
            showText(Drive.MSG_NONE)
        elseif reason == "many" then
            showText(Drive.MSG_MANY)
        elseif reason == "not_paired" then
            showText(Drive.MSG_NOT_PAIRED)
        else
            showText(Drive.MSG_FAILED)
        end
    end
    local function fetch(item)
        api.download(item, function(ok, path)
            if not ok then return fail(path) end
            UIManager:close(note)
            getIndex():remember(path)
            logger.info("syncedhistory: downloaded", path)
            self:openPath(menu, path)
        end)
    end
    Drive.resolve(row, api.findByFileName, function(item, reason)
        if not item then return fail(reason) end
        if item.name then return fetch(item) end
        -- Only the id came from the server: ask Drive for the name and kind.
        api.info(item.id, function(ok, full)
            if not ok then return fail(full) end
            if type(full) ~= "table" or full.trashed then return fail("none") end
            fetch(full)
        end)
    end)
end

-- Open a local book from the list and pull its synced position. `reload`:
-- the file on disk was just replaced, so reopen it even when it is open.
function SyncedHistory:openPath(menu, path, reload)
    UIManager:close(menu)
    if reload and self.ui.document and self.ui.document.file == path then
        pending_pull = path
        self.ui:switchDocument(path)
        return
    end
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
-- What a book's sidecar says (Cleanup.facts), or nil when it has none.
local function sidecarFacts(path)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or not DocSettings:hasSidecarFile(path) then return nil end
    local ds = DocSettings:open(path)
    return Cleanup.facts(function(k) return ds:readSetting(k) end), ds
end

-- Remove finished Drive books: in the GDrive folder, gone from a list just
-- fetched from the server, opened here, not open now, no annotations (see
-- syncedhistory_cleanup.lua). Only after a manual sync or when the list opens.
local function cleanupDrive(ui, list, info)
    local api = driveApi(ui)
    if not (api and api.deleteBook and api.folder) then return end
    local folder = api.folder()
    if not folder or lfs.attributes(folder, "mode") ~= "directory" then return end
    local is_document = makeIsDocument()
    local files = {}
    for name in lfs.dir(folder) do
        local path = folder .. "/" .. name
        if name:sub(1, 1) ~= "." and is_document(name) and lfs.attributes(path, "mode") == "file" then
            files[#files + 1] = { path = path, name = name, sidecar = sidecarFacts(path) }
        end
    end
    local doc = (ui and ui.document) or (live_ui and live_ui.document)
    local plan = Cleanup.decide{
        fresh = info and info.fresh,
        list = list,
        files = files,
        key_for = function(n) return getClient():keyFor(n) end,
        open_path = doc and doc.file,
    }
    if plan.refused then
        logger.info("syncedhistory: cleanup skipped:", plan.refused)
        return
    end
    for _i, skip in ipairs(plan.skipped) do
        logger.info("syncedhistory: cleanup keeps", skip.path, "-", skip.reason)
    end
    local removed = 0
    for _i, path in ipairs(plan.delete) do
        local ok, why = api.deleteBook(path)
        if ok then
            removed = removed + 1
            logger.info("syncedhistory: cleanup removed", path)
        else
            logger.warn("syncedhistory: cleanup could not remove", path, why)
        end
    end
    local text = Cleanup.message(removed, _)
    if text then UIManager:show(InfoMessage:new{ text = text, timeout = 3 }) end
end

-- After a manual push or pull through the serverless progress sync.
function SyncedHistory:onManualSyncDone()
    local ui = self.ui
    getClient():fetchList(function(list, info) cleanupDrive(ui, list, info) end)
    syncStats()
end

-- A book's title from its sidecar, read once per path per run.
local titles = {}
local function localTitle(row)
    if not row.path then return row.name end
    if titles[row.path] == nil then
        local _f, ds = sidecarFacts(row.path)
        local props = ds and ds:readSetting("doc_props")
        local t = type(props) == "table" and props.title
        titles[row.path] = type(t) == "string" and t ~= "" and t or false
    end
    return titles[row.path] or row.name
end

local LAST_SEEN = "list_last_seen"

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
    -- The search looks at the name only, not the device and time.
    for _i, row in ipairs(state.rows) do
        row.name = row.name or row.text
        row.text = row.name
    end
    local view = ListView.view(state.rows, { show_missing = showMissing(), query = state.query })
    local now = os.time()
    local tabs = Tabs.split(view.rows, {
        now = now,
        device_id = G_reader_settings:readSetting("device_id"),
        last_seen = state.last_seen,
    })
    state.counts = { new = #tabs.new, recent = #tabs.recent, old = #tabs.old }
    if state.tab == Tabs.STATS then return self:redrawStats(menu, state) end
    local items = {}
    for i, row in ipairs(tabs[state.tab]) do
        row.text, row.mandatory = Tabs.rowText(row, {
            now = now,
            title = localTitle,
            device = function(r)
                return ListView.deviceLabel(r.device or _(ListView.UNKNOWN_DEVICE), r.device_id)
            end,
            gettext = _,
        })
        row.callback = function() self:openRow(menu, row) end
        items[i] = row
    end
    local empty = ListView.emptyText(view, { empty = state.empty, gettext = _ })
    if not empty and #items == 0 then empty = _(Tabs.EMPTY[state.tab]) end
    if empty then
        items[1] = { text = empty, select_enabled = false, dim = true }
    end
    self:addStrip(menu, state, items)
    local subtitle = _(Tabs.TITLES[state.tab]) .. " · "
        .. ListView.subtitle(view, { status = state.status, gettext = _ })
    -- itemnumber nil: switchItemTable goes back to page 1.
    menu:switchItemTable(nil, items, nil, nil, subtitle)
end

-- The goal strip, first row of every tab; a tap opens the Stats tab.
function SyncedHistory:addStrip(menu, state, items)
    if not stripShown() or not state.summary then return end
    table.insert(items, 1, {
        text = StatsView.strip(state.summary, _),
        bold = true,
        callback = function()
            -- The strip is about this week: show it, not a week paged to earlier.
            state.tab = Tabs.STATS
            state.week_offset = 0
            self:redrawList(menu, state)
        end,
    })
end

function SyncedHistory:redrawStats(menu, state)
    local items = {}
    if not state.days then
        items[1] = { text = _("Reading statistics are not available."), select_enabled = false, dim = true }
    else
        local s = goalSummary(state.days, state.week_offset)
        for i, r in ipairs(StatsView.rows(s, { gettext = _, week_offset = state.week_offset })) do
            local item = { text = r.text, dim = r.dim }
            if r.action == "prev" or r.action == "next" then
                item.callback = function()
                    state.week_offset = (state.week_offset or 0) + (r.action == "prev" and -1 or 1)
                    self:redrawList(menu, state)
                end
            elseif r.action == "calendar" then
                item.callback = function() openCalendar(self.ui) end
            else
                item.select_enabled = false
            end
            items[i] = item
        end
    end
    self:addStrip(menu, state, items)
    local subtitle = _(Tabs.TITLES[Tabs.STATS]) .. " · " .. (state.stats_status or "")
    menu:switchItemTable(nil, items, nil, nil, subtitle)
end

-- Goal numbers from the local database, then the goal-met message, once a
-- day and only when the list opens.
function SyncedHistory:loadGoals(state)
    state.days = loadDays()
    state.summary = state.days and goalSummary(state.days) or nil
    local s = state.summary
    local today = Goals.dayKey(os.time())
    if s and s.met_today and state.opening and getSettings():readSetting(GOAL_MET_SHOWN) ~= today then
        getSettings():saveSetting(GOAL_MET_SHOWN, today)
        getSettings():flush()
        UIManager:show(InfoMessage:new{ text = StatsView.goalMetText(s, _), timeout = 4 })
    end
end

-- Sync reading time with the list's own fetch, then recompute the numbers.
function SyncedHistory:syncStatsIntoList(menu, state)
    state.stats_status = _(ListView.SYNCING)
    syncStats(function(ok, info)
        state.stats_status = ok and _(ListView.SYNCED)
            or (info and info.reason == "offline" and _("offline") or _("not synced"))
        if not UIManager:isWidgetShown(menu) then return end
        if ok and ((info.pulled or 0) > 0 or (info.uploaded or 0) > 0) or state.tab == Tabs.STATS then
            self:loadGoals(state)
            state.opening = nil
            self:redrawList(menu, state)
        end
        state.opening = nil
    end)
end

-- Fetch the server list into the open list screen. The cached copy is shown
-- until the answer comes; a failed fetch keeps it and says so.
function SyncedHistory:fetchIntoList(menu, state)
    state.status = _(ListView.SYNCING)
    self:redrawList(menu, state)
    self:syncStatsIntoList(menu, state)
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
        if state.cleanup then
            state.cleanup = nil
            cleanupDrive(self.ui, list, info)
        end
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
    local tab_row = {}
    for i, tab in ipairs(Tabs.ALL) do
        local n = state.counts and state.counts[tab]
        tab_row[i] = {
            text = (state.tab == tab and "✓ " or "") .. _(Tabs.TITLES[tab])
                .. (n and " (" .. n .. ")" or ""),
            callback = function()
                UIManager:close(dialog)
                state.tab = tab
                self:redrawList(menu, state)
            end,
        }
    end
    local buttons = {
        tab_row,
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
        tab = Tabs.RECENT,
        -- New means pushed by another device since the list was last left;
        -- this opening keeps comparing against the old time.
        last_seen = getSettings():readSetting(LAST_SEEN),
        cleanup = true,
        opening = true,
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
        -- A row is the name, then the device and when, wrapped. The default
        -- font for 8 rows (22) fits two lines and cuts the device off a long
        -- name; 16 fits three.
        multilines_forced = true,
        items_per_page = 8,
        items_font_size = 16,
    }
    -- Closing the list, or opening a book from it, marks everything seen.
    menu.onCloseWidget = function(m)
        getSettings():saveSetting(LAST_SEEN, os.time())
        getSettings():flush()
        local parent = Menu.onCloseWidget
        if parent then return parent(m) end
    end
    menu.onLeftButtonTap = function() self:showListMenu(menu, state) end
    -- MenuItem calls self.menu:onMenuHold(item, pos); the default does nothing.
    menu.onMenuHold = function(_menu, item)
        self:showDetails(menu, state, item)
        return true
    end
    self:loadGoals(state)
    self:redrawList(menu, state)
    UIManager:show(menu)
    self:fetchIntoList(menu, state)
    self:startBackfill()
end

-- After the list renders, give local books without a Drive record one, by an
-- exact file name search, one request at a time, at most once per run, and
-- only while online. Each match also pushes the book's source.
function SyncedHistory:startBackfill()
    local api = driveApi(self.ui)
    if backfill_started or not api or not api.isPaired() or not NetworkMgr:isOnline() then return end
    backfill_started = true
    local ui = self.ui
    UIManager:scheduleIn(2, function()
        Drive.backfill{
            paths = getIndex():paths(),
            readRecord = api.readRecord,
            writeRecord = api.writeRecord,
            find = api.findByFileName,
            basename = LocalIndex.basename,
            mtime = function(p) return lfs.attributes(p, "modification") end,
            push = function(p) pushDocument(ui, p) end,
            log = logger,
            next = function(f) UIManager:scheduleIn(0.5, f) end,
            done = function(stats)
                logger.info("syncedhistory: backfill done, matched", stats.matched,
                    "skipped", stats.skipped, "failed", stats.failed)
            end,
        }
    end)
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

-- "Reading goals": the daily goal, the week's first day, which kinds count,
-- the strip on the list, and a sync on demand (only when already online).
function SyncedHistory:goalsMenu()
    local function save(k, v)
        getSettings():saveSetting(k, v)
        getSettings():flush()
    end
    local kinds = {}
    for i, kind in ipairs(Goals.KINDS) do
        kinds[i] = {
            text = _(Goals.KIND_TITLES[kind]),
            checked_func = function()
                local c = getSettings():readSetting(COUNTED)
                return not (c and c[kind] == false)
            end,
            callback = function()
                local c = getSettings():readSetting(COUNTED) or {}
                if c[kind] == false then c[kind] = nil else c[kind] = false end
                save(COUNTED, c)
            end,
        }
    end
    return {
        text = _("Reading goals"),
        sub_item_table = {
            {
                text_func = function() return string.format(_("Daily goal: %d min"), goalMin()) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("Daily reading goal"),
                        value = goalMin(),
                        value_min = Goals.MIN_GOAL,
                        value_max = Goals.MAX_GOAL,
                        value_step = Goals.GOAL_STEP,
                        value_hold_step = 30,
                        default_value = Goals.DEFAULT_GOAL,
                        unit = _("min"),
                        callback = function(spin)
                            save(GOAL, Goals.clampGoal(spin.value))
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return _("Week starts on") .. ": " .. (weekStart() == Goals.SUNDAY and _("Sunday") or _("Monday"))
                end,
                sub_item_table = {
                    { text = _("Monday"), radio = true,
                        checked_func = function() return weekStart() == Goals.MONDAY end,
                        callback = function() save(WEEK_START, Goals.MONDAY) end },
                    { text = _("Sunday"), radio = true,
                        checked_func = function() return weekStart() == Goals.SUNDAY end,
                        callback = function() save(WEEK_START, Goals.SUNDAY) end },
                },
            },
            { text = _("Count kinds toward goal"), sub_item_table = kinds },
            {
                text = _("Show goal strip on list"),
                checked_func = stripShown,
                callback = function() save(SHOW_STRIP, not stripShown()) end,
            },
            {
                text = _("Sync reading stats now"),
                keep_menu_open = true,
                callback = function()
                    if not NetworkMgr:isOnline() then
                        return showText("Not online. Turn Wi-Fi on, then try again.")
                    end
                    syncStats(function(ok, info)
                        UIManager:show(InfoMessage:new{ timeout = 3, text = ok
                            and string.format(_("Reading stats synced: %d sent, %d received."),
                                info.uploaded or 0, info.pulled or 0)
                            or (_("Reading stats not synced: ") .. tostring(info and (info.reason or info.status))) })
                    end)
                end,
            },
        },
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
    menu_items.synced_reading_goals = self:goalsMenu()
    menu_items.synced_reading_goals.sorting_hint = "tools"
    menu_items.synced_reading_calendar = {
        text = _("Open calendar"),
        sorting_hint = "tools",
        callback = function() openCalendar(self.ui) end,
    }
end

return SyncedHistory
