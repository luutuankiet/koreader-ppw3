--[[--
Google Drive: list, search and download your Google Docs (as EPUB), PDFs
and EPUBs through your own gdrive-epub server. Tools > Google Drive.

The server URL is a setting. The Kindle pairs with the server once by
scanning a QR code with a phone; the server then keeps the Google sign-in.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local Api = require("gdriveepub_api")
local Files = require("gdriveepub_files")
local Format = require("gdriveepub_format")
local Http = require("gdriveepub_http")
local ListWidget = require("gdriveepub_listwidget")
local QrScreen = require("gdriveepub_qrscreen")
local Source = require("gdriveepub_source")
local State = require("gdriveepub_state")

local POLL_SECONDS = 3
local LIST_TIMEOUT = 30
-- Google can take over 30 s before the first byte of a large document, and the
-- server cleans the whole EPUB before it sends anything.
local DOWNLOAD_BLOCK_TIMEOUT = 120
local DOWNLOAD_TOTAL_TIMEOUT = 1800

local GDrive = WidgetContainer:extend{
    name = "gdriveepub",
    is_doc_only = false,
}

function GDrive:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/gdriveepub.lua")
    self.http = Http.new{ scheduleIn = function(s, f) UIManager:scheduleIn(s, f) end }
    self.state = State.new()
    self.api = self:makeApi()
    self.ui.menu:registerToMainMenu(self)
end

function GDrive:baseUrl() return Api.normaliseBaseUrl(self.settings:readSetting("server_url")) end
function GDrive:deviceKey() return self.settings:readSetting("device_key") end

function GDrive:setDeviceKey(key)
    if key then self.settings:saveSetting("device_key", key) else self.settings:delSetting("device_key") end
    self.settings:flush()
end

function GDrive:addToMainMenu(menu_items)
    menu_items.gdriveepub = {
        text = _("Google Drive"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = _("Open"), callback = function() self:open() end },
            { text = _("Downloaded files"), callback = function() self:showDownloaded() end },
            {
                text_func = function()
                    local u = self:baseUrl()
                    return u and (_("Server URL: ") .. u) or _("Server URL: not set")
                end,
                keep_menu_open = true,
                callback = function(menu) self:editServerUrl(function() if menu then menu:updateItems() end end) end,
            },
            { text = _("Pair again"), callback = function() self:setDeviceKey(nil); self:open() end },
            { text = _("Check connection"), callback = function() self:checkConnection() end },
        },
    }
end

function GDrive:info(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

function GDrive:editServerUrl(done)
    local dialog
    dialog = InputDialog:new{
        title = _("Google Drive server URL"),
        input = self.settings:readSetting("server_url") or "https://",
        input_hint = "https://your-server.example",
        description = _("The address of your gdrive-epub server."),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local url = Api.normaliseBaseUrl(dialog:getInputText())
                if not url then
                    self:info(_("That is not a URL. It must start with https:// or http://."))
                    return
                end
                UIManager:close(dialog)
                if url ~= self:baseUrl() then self:setDeviceKey(nil) end
                self.settings:saveSetting("server_url", url)
                self.settings:flush()
                if done then done(url) end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- One request with a "Working..." message. `cb(parsed, res)` only on success
--- unless `raw` is set; errors go to handleError with `retry`.
function GDrive:request(req, opts, cb)
    NetworkMgr:runWhenOnline(function()
        local msg = InfoMessage:new{ text = opts.message or _("Loading…"), dismissable = false }
        if not opts.quiet then UIManager:show(msg) UIManager:forceRePaint() end
        self.http(req, function(res)
            if not opts.quiet then UIManager:close(msg) end
            local parsed = Api.parse(res, json.decode)
            if opts.raw or parsed.ok then return cb(parsed, res) end
            self:handleError(parsed, opts.retry)
        end)
    end)
end

function GDrive:handleError(parsed, retry)
    logger.warn("gdriveepub: request failed", parsed.status, parsed.error, parsed.message)
    local e = parsed.error
    if e == "device_unauthorized" then
        self:setDeviceKey(nil)
        self:info(_("This Kindle is no longer paired with the server. Pair it again."), 3)
        self:startPairing(retry)
    elseif e == "google_reauth" then
        self:showReauth(parsed.signin_url, retry)
    elseif e == "too_large" then
        self:info(_("Google could not export this document."))
    elseif e == "network" then
        self:info(_("Cannot reach the server: ") .. tostring(parsed.message))
    else
        self:info(_("Server error: ") .. tostring(parsed.message or e))
    end
end

function GDrive:open()
    if not self:baseUrl() then
        return self:editServerUrl(function() self:open() end)
    end
    if not self:deviceKey() then
        return self:startPairing(function() self:open() end)
    end
    self:showList()
end

-- Pairing ---------------------------------------------------------------

function GDrive:stopPolling()
    if self.poll_fn then UIManager:unschedule(self.poll_fn) self.poll_fn = nil end
end

function GDrive:startPairing(after)
    local base = self:baseUrl()
    if not base then return self:editServerUrl(function() self:startPairing(after) end) end
    self:request(Api.pairStartRequest(base), { message = _("Starting pairing…") }, function(parsed)
        if not Api.validPairing(parsed) then
            return self:info(_("The server sent a pairing answer this plugin does not understand."))
        end
        self:showPairing(parsed.data, after)
    end)
end

function GDrive:showPairing(pairing, after)
    local base = self:baseUrl()
    local screen
    local function restart()
        self:stopPolling()
        UIManager:close(screen)
        self:startPairing(after)
    end
    screen = QrScreen:new{
        heading = _("Pair this Kindle"),
        text = _("Scan with your phone, then sign in with your Google work account."),
        url = pairing.url,
        status = _("Waiting for your phone…"),
        buttons = {
            { text = _("Cancel"), callback = function() self:stopPolling() UIManager:close(screen) end },
            { text = _("New code"), callback = restart },
        },
        on_close = function() self:stopPolling() end,
    }
    UIManager:show(screen)
    local deadline = os.time() + (tonumber(pairing.expires_in) or 600)
    local function poll()
        self.http(Api.pairPollRequest(base, pairing.pair_id, pairing.poll_secret), function(res)
            if screen._closed then return end
            local result, key = Api.pairPollResult(Api.parse(res, json.decode))
            if result == "approved" then
                self:setDeviceKey(key)
                UIManager:close(screen)
                self:info(_("Kindle paired."), 2)
                if after then UIManager:scheduleIn(0.5, after) end
            elseif result == "expired" or os.time() > deadline then
                screen:setStatus(_("This code expired. Tap New code."))
            else
                if result == "error" then screen:setStatus(_("Cannot reach the server, still trying…")) end
                UIManager:scheduleIn(POLL_SECONDS, self.poll_fn)
            end
        end)
    end
    self.poll_fn = poll
    local orig_close = screen.onCloseWidget
    screen.onCloseWidget = function(s) s._closed = true self:stopPolling() return orig_close(s) end
    UIManager:scheduleIn(POLL_SECONDS, self.poll_fn)
end

function GDrive:showReauth(signin_url, retry)
    local screen
    screen = QrScreen:new{
        heading = _("Sign in again on your phone"),
        text = _("Google ended the server's sign-in. Scan with your phone and sign in, then tap Done."),
        url = signin_url or ((self:baseUrl() or "") .. "/reauth"),
        status = "",
        buttons = {
            { text = _("Cancel"), callback = function() UIManager:close(screen) end },
            { text = _("Done, retry"), callback = function()
                UIManager:close(screen)
                if retry then retry() end
            end },
        },
    }
    UIManager:show(screen)
end

function GDrive:checkConnection()
    local base = self:baseUrl()
    if not base then return self:info(_("Set the server URL first.")) end
    self:request(Api.healthRequest(base), { message = _("Checking…"), retry = function() self:checkConnection() end }, function(h)
        local version = tostring(h.data.version or "?")
        if not self:deviceKey() then
            return self:info(_("Server is up (version ") .. version .. _("). This Kindle is not paired yet."))
        end
        self:request(Api.statusRequest(base, self:deviceKey()), { retry = function() self:checkConnection() end }, function(s)
            if s.data.google == "reauth_needed" then
                return self:showReauth(s.data.signin_url, function() self:checkConnection() end)
            end
            self:info(_("Server is up (version ") .. version .. _("), paired, Google sign-in OK."))
        end)
    end)
end

-- List ------------------------------------------------------------------

function GDrive:showList()
    local offset = Format.localOffset()
    self.list = ListWidget:new{
        subtitle = State.subtitle(self.state),
        files = self.state.files, more = State.hasMore(self.state),
        empty_text = _("Loading…"),
        meta = function(f) return Format.metaLine(f, offset) end,
        on_tap = function(f) self:download(f, false) end,
        on_hold = function(f) self:showDetails(f) end,
        on_action = function(name) self:onListAction(name) end,
    }
    UIManager:show(self.list)
    self:load(false)
end

function GDrive:load(append)
    local base, key = self:baseUrl(), self:deviceKey()
    local token = append and self.state.next_token or nil
    if not append then State.resetFiles(self.state) end
    local req = Api.listRequest(base, key, State.params(self.state, token))
    req.timeout = LIST_TIMEOUT
    self:request(req, { retry = function() self:load(append) end }, function(parsed)
        local files, next_token = Api.files(parsed.data)
        local before = #self.state.files
        State.addPage(self.state, files, next_token)
        if not self.list then return end
        self.list.empty_text = _("No files match.")
        local page = self.list.page
        self.list:setFiles(self.state.files, State.hasMore(self.state), State.subtitle(self.state), append)
        if append and #self.state.files > before then self.list:showPage(page + 1) end
    end)
end

function GDrive:onListAction(name)
    if name == "close" then
        UIManager:close(self.list)
        self.list = nil
    elseif name == "recent" then
        State.setRecent(self.state) self:load(false)
    elseif name == "search" then
        self:askSearch()
    elseif name == "filter" then
        self:showFilter()
    elseif name == "sort" then
        self:showSort()
    elseif name == "more" then
        self:load(true)
    end
end

function GDrive:askSearch()
    local dialog
    dialog = InputDialog:new{
        title = _("Search Google Drive"),
        input = self.state.q or "",
        input_hint = _("Keywords in the title or text"),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local q = dialog:getInputText()
                UIManager:close(dialog)
                State.setSearch(self.state, q)
                self:load(false)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function mark(label, on) return on and ("\226\156\147 " .. label) or label end

function GDrive:showFilter()
    local dialog
    local buttons = {}
    for _i, which in ipairs({ "modified_within", "created_within" }) do
        table.insert(buttons, { { text = which == "modified_within" and _("Updated within") or _("Created within"), enabled = false, callback = function() end } })
        local row = {}
        for _j, v in ipairs(State.WITHIN) do
            local label = v == "" and _("Any") or v
            table.insert(row, { text = mark(label, self.state[which] == v), callback = function()
                UIManager:close(dialog)
                State.setFilter(self.state, which, v)
                self:load(false)
            end })
        end
        table.insert(buttons, row)
    end
    table.insert(buttons, { { text = _("Clear filters"), callback = function()
        UIManager:close(dialog) State.clearFilters(self.state) self:load(false)
    end } })
    dialog = ButtonDialog:new{ title = _("Filter"), title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

function GDrive:showSort()
    local dialog
    local buttons = {}
    for _i, sort in ipairs(State.SORTS) do
        table.insert(buttons, { { text = mark(State.SORT_LABEL[sort], self.state.sort == sort), callback = function()
            UIManager:close(dialog) State.setSort(self.state, sort) self:load(false)
        end } })
    end
    dialog = ButtonDialog:new{ title = _("Sort by"), title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

function GDrive:showDetails(f)
    local dialog
    dialog = ButtonDialog:new{
        title = Format.details(f, Format.localOffset()),
        title_align = "left",
        buttons = {
            { { text = _("Download"), callback = function() UIManager:close(dialog) self:download(f, false) end },
              { text = _("Download & open"), callback = function() UIManager:close(dialog) self:download(f, true) end } },
            { { text = _("Close"), callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

-- Download --------------------------------------------------------------

function GDrive:downloadDir()
    local home = G_reader_settings:readSetting("home_dir") or filemanagerutil.getDefaultDir()
    return Format.joinPath(home, "GDrive")
end

local function openBook(ui, path)
    if filemanagerutil.openFile then
        filemanagerutil.openFile(ui, path)
    else
        ui:openFile(path)
    end
end

--- Download `f` ({id, name, kind}) to GDrive/<Format.fileName(f)> through a
--- hidden .part file, then record its Drive source in the sidecar. No dialogs.
--- cb(path, record) on success, cb(nil, nil, parsed) on failure (Api.parse shape).
function GDrive:fetchFile(f, cb)
    local dir = self:downloadDir()
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    local name = Format.fileName(f)
    local final = Format.joinPath(dir, name)
    local part = Format.joinPath(dir, "." .. name .. ".part")
    local req = Api.downloadRequest(self:baseUrl(), self:deviceKey(), f.id)
    req.sink_path, req.timeout, req.total_timeout = part, DOWNLOAD_BLOCK_TIMEOUT, DOWNLOAD_TOTAL_TIMEOUT
    self.http(req, function(res)
        if not (res and res.status and res.status >= 200 and res.status < 300) then
            os.remove(part)
            return cb(nil, nil, Api.parse(res, json.decode))
        end
        os.remove(final)
        local ok, err = os.rename(part, final)
        if not ok then
            os.remove(part)
            return cb(nil, nil, { ok = false, error = "save_failed", message = _("Could not save the file: ") .. tostring(err) })
        end
        local rec = Source.newRecord(f, res.headers)
        local okw, werr = pcall(self.writeRecord, self, final, rec)
        if not okw then logger.warn("gdriveepub: could not record the source of", final, werr) end
        cb(final, rec)
    end)
end

--- The sidecar of `path`: the open book's own settings when it is the one being
--- read (a second DocSettings would be overwritten when the reader closes).
function GDrive:sidecar(path)
    local doc = self.ui and self.ui.document
    if doc and doc.file == path and self.ui.doc_settings then return self.ui.doc_settings end
    return require("docsettings"):open(path)
end

function GDrive:readRecord(path) return Source.read(self:sidecar(path)) end
function GDrive:writeRecord(path, rec) Source.write(self:sidecar(path), rec) end

function GDrive:download(f, open_after)
    local retry = function() self:download(f, open_after) end
    NetworkMgr:runWhenOnline(function()
        local msg = InfoMessage:new{ dismissable = false,
            text = _("Downloading…") .. "\n" .. f.name .. "\n" .. _("Large documents can take a minute.") }
        UIManager:show(msg) UIManager:forceRePaint()
        self:fetchFile(f, function(final, _rec, parsed)
            UIManager:close(msg)
            if not final then
                if parsed.error == "save_failed" then return self:info(parsed.message) end
                return self:handleError(parsed, retry)
            end
            local function doOpen()
                if self.list then UIManager:close(self.list) self.list = nil end
                openBook(self.ui, final)
            end
            if open_after then return doOpen() end
            UIManager:show(ConfirmBox:new{
                text = _("Saved to ") .. "GDrive/" .. Format.fileName(f) .. "\n\n" .. _("Open now?"),
                ok_text = _("Open"), cancel_text = _("Later"),
                ok_callback = doOpen,
            })
        end)
    end)
end

-- Headless API ------------------------------------------------------------
-- For other plugins, as `ui.gdriveepub.api`. Never shows a dialog and never
-- turns WiFi on: the caller makes sure the device is online. Callbacks get
-- (true, result) or (false, err) where err is a server error code such as
-- "not_found", "device_unauthorized", "google_reauth", "network", "not_paired".

-- Set below, once deleteBook and realpath are defined.
local deleteBookFn, realpathFn

function GDrive:makeApi()
    local api = {}
    local function ready(cb)
        if self:baseUrl() and self:deviceKey() then return true end
        cb(false, "not_paired")
        return false
    end
    local function errOf(parsed) return parsed.error or "server", parsed end

    function api.isPaired() return self:baseUrl() ~= nil and self:deviceKey() ~= nil end
    function api.folder() return self:downloadDir() end

    --- cb(true, {id, name, kind, modifiedTime, trashed}) or cb(false, err)
    function api.info(file_id, cb)
        if not ready(cb) then return end
        self.http(Api.infoRequest(self:baseUrl(), self:deviceKey(), file_id), function(res)
            local parsed = Api.parse(res, json.decode)
            if not parsed.ok then return cb(false, errOf(parsed)) end
            local item = Api.item(parsed.data)
            if not item then return cb(false, "bad_answer") end
            cb(true, item)
        end)
    end

    --- cb(true, items) with every Drive file whose Format.fileName is exactly `basename`
    --- (first page of 100 search hits), or cb(false, err)
    function api.findByFileName(basename, cb)
        if not ready(cb) then return end
        local q = Source.searchQuery(basename)
        if q == "" then return cb(true, {}) end
        local req = Api.listRequest(self:baseUrl(), self:deviceKey(), { view = "search", q = q, page_size = 100 })
        req.timeout = LIST_TIMEOUT
        self.http(req, function(res)
            local parsed = Api.parse(res, json.decode)
            if not parsed.ok then return cb(false, errOf(parsed)) end
            cb(true, Source.matchByFileName(Api.files(parsed.data), basename, Format.fileName))
        end)
    end

    --- item = {id, name, kind}; saves where the UI download does and records the source.
    --- cb(true, path, record) or cb(false, err)
    function api.download(item, cb)
        if not ready(cb) then return end
        self:fetchFile(item, function(path, rec, parsed)
            if not path then return cb(false, errOf(parsed)) end
            cb(true, path, rec)
        end)
    end

    --- {id, modified, downloaded_at} or nil
    function api.readRecord(path)
        local ok, rec = pcall(self.readRecord, self, path)
        return ok and rec or nil
    end
    function api.writeRecord(path, rec) self:writeRecord(path, rec) end

    --- Delete one downloaded book with its reading data, as the Downloads
    --- screen does. Only a file directly inside the GDrive folder that is not
    --- open in the reader. Returns true, or false and the reason.
    function api.deleteBook(path)
        local dir, name = tostring(path):match("^(.*)/([^/]+)$")
        if not name then return false, "bad_name" end
        local folder = self:downloadDir()
        if not folder or realpathFn(dir) ~= realpathFn(folder) then return false, "outside" end
        local plan = Files.planDelete(folder, { name }, self:openDocumentPath(), realpathFn)
        if plan.skipped[1] then return false, plan.skipped[1].reason end
        if not plan.paths[1] then return false, "missing" end
        return deleteBookFn(plan.paths[1])
    end

    return api
end

-- Downloaded files ------------------------------------------------------

local function realpath(p)
    local ok, ffiutil = pcall(require, "ffi/util")
    if ok and ffiutil.realpath then return ffiutil.realpath(p) end
    return lfs.attributes(p, "mode") and p or nil
end

function GDrive:readDownloaded()
    local dir = self:downloadDir()
    local entries = {}
    if lfs.attributes(dir, "mode") == "directory" then
        for name in lfs.dir(dir) do
            local attr = lfs.attributes(Format.joinPath(dir, name))
            if attr then
                table.insert(entries, { name = name, mode = attr.mode, size = attr.size, modification = attr.modification })
            end
        end
    end
    return Files.build(entries)
end

--- Path of the book open in the reader, or nil in the file browser.
function GDrive:openDocumentPath()
    local doc = self.ui and self.ui.document
    return doc and doc.file or nil
end

function GDrive:showDownloaded()
    local offset = Format.localOffset()
    self.dl_sel = Files.newSelection()
    self.dl_files = self:readDownloaded()
    self.dl_list = ListWidget:new{
        title = _("Downloaded files"),
        subtitle = Files.subtitle(self.dl_files, self.dl_sel),
        files = self.dl_files, more = false,
        empty_text = _("No downloaded files in GDrive."),
        toolbar = {
            { text = _("Select all"), action = "all" },
            { text = _("Select none"), action = "none" },
            { text = _("Delete"), action = "delete" },
        },
        row_title = function(f) return Files.label(f, Files.isSelected(self.dl_sel, f.name)) end,
        meta = function(f) return Files.meta(f, offset) end,
        on_tap = function(f)
            Files.toggle(self.dl_sel, f.name)
            self.dl_list:redraw(Files.subtitle(self.dl_files, self.dl_sel))
        end,
        on_hold = function(f) self:showDownloadedFile(f) end,
        on_action = function(name) self:onDownloadedAction(name) end,
    }
    UIManager:show(self.dl_list)
end

function GDrive:reloadDownloaded()
    if not self.dl_list then return end
    self.dl_files = self:readDownloaded()
    Files.prune(self.dl_sel, self.dl_files)
    self.dl_list:setFiles(self.dl_files, false, Files.subtitle(self.dl_files, self.dl_sel), true)
end

function GDrive:onDownloadedAction(name)
    if name == "close" then
        UIManager:close(self.dl_list)
        self.dl_list = nil
    elseif name == "all" then
        Files.selectAll(self.dl_sel, self.dl_files)
        self.dl_list:redraw(Files.subtitle(self.dl_files, self.dl_sel))
    elseif name == "none" then
        Files.clear(self.dl_sel)
        self.dl_list:redraw(Files.subtitle(self.dl_files, self.dl_sel))
    elseif name == "delete" then
        self:confirmDeleteDownloaded()
    end
end

function GDrive:showDownloadedFile(f)
    local dialog
    dialog = ButtonDialog:new{
        title = f.name .. "\n" .. Files.meta(f, Format.localOffset()),
        title_align = "left",
        buttons = {
            { { text = _("Open"), callback = function()
                UIManager:close(dialog)
                if self.dl_list then UIManager:close(self.dl_list) self.dl_list = nil end
                openBook(self.ui, Format.joinPath(self:downloadDir(), f.name))
            end },
              { text = _("Close"), callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

function GDrive:confirmDeleteDownloaded()
    local names = Files.selectedNames(self.dl_sel, self.dl_files)
    if #names == 0 then return self:info(_("Tap files to select them first."), 2) end
    local text = #names == 1 and _("Delete 1 file and its reading data?")
        or string.format(_("Delete %d files and their reading data?"), #names)
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Delete"), cancel_text = _("Cancel"),
        ok_callback = function() self:deleteDownloaded(names) end,
    })
end

--- Delete one book the way KOReader's file browser does: the file, its
--- sidecar (metadata) in whichever location the settings use, its entry
--- in reading history and collections. Then the `.sdr` folder beside it if
--- it still exists and holds no other book's metadata (Book.epub and
--- Book.pdf share Book.sdr).
local function deleteBook(path)
    local ok, err = os.remove(path)
    if not ok then return false, err end
    local okb, BookList = pcall(require, "ui/widget/booklist")
    if okb and BookList.resetBookInfoCache then pcall(BookList.resetBookInfoCache, path) end
    local okd, DocSettings = pcall(require, "docsettings")
    if okd and DocSettings.updateLocation then
        local s, e = pcall(DocSettings.updateLocation, path)
        if not s then logger.warn("gdriveepub: sidecar cleanup failed", path, e) end
    end
    local sdr = Files.sidecarDir(path)
    if lfs.attributes(sdr, "mode") == "directory" then
        local left = {}
        for n in lfs.dir(sdr) do
            if n ~= "." and n ~= ".." then table.insert(left, n) end
        end
        local oku, ffiutil = pcall(require, "ffi/util")
        if Files.canPurgeSidecar(left) and oku and ffiutil.purgeDir then ffiutil.purgeDir(sdr) end
    end
    local okh, ReadHistory = pcall(require, "readhistory")
    if okh and ReadHistory.fileDeleted then pcall(ReadHistory.fileDeleted, ReadHistory, path) end
    local okc, ReadCollection = pcall(require, "readcollection")
    if okc and ReadCollection.removeItem then pcall(ReadCollection.removeItem, ReadCollection, path) end
    return true
end

deleteBookFn, realpathFn = deleteBook, realpath

local REASON = {
    open = "open in the reader",
    outside = "not inside the GDrive folder",
    bad_name = "unsafe file name",
    missing = "already gone",
    no_dir = "GDrive folder missing",
}

function GDrive:deleteDownloaded(names)
    local plan = Files.planDelete(self:downloadDir(), names, self:openDocumentPath(), realpath)
    local deleted, failed = 0, {}
    for i, path in ipairs(plan.paths) do
        local ok, err = deleteBook(path)
        if ok then deleted = deleted + 1 else table.insert(failed, plan.names[i] .. ": " .. tostring(err)) end
    end
    for _i, s in ipairs(plan.skipped) do
        table.insert(failed, s.name .. ": " .. _(REASON[s.reason] or s.reason))
    end
    logger.info("gdriveepub: deleted", deleted, "skipped", #failed)
    self:reloadDownloaded()
    local okf, FileManager = pcall(require, "apps/filemanager/filemanager")
    if okf and FileManager.instance and FileManager.instance.onRefresh then
        pcall(FileManager.instance.onRefresh, FileManager.instance)
    end
    local text = deleted == 1 and _("Deleted 1 file.") or string.format(_("Deleted %d files."), deleted)
    if #failed > 0 then text = text .. "\n\n" .. _("Not deleted:") .. "\n" .. table.concat(failed, "\n") end
    self:info(text, #failed > 0 and nil or 2)
end

return GDrive
