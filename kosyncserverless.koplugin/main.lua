local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Math = require("optmath")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local time = require("ui/time")
local util = require("util")
local CarryOver = require("kosyncserverless_carryover")
local Retry = require("kosyncserverless_retry")
local T = require("ffi/util").template
local _ = require("gettext")

local KOSyncServerless = WidgetContainer:extend{
    name = "kosyncserverless",
    is_doc_only = true,
    title = _("Register/login to KOReader server"),
    settings_file = DataStorage:getSettingsDir() .. "/kosyncserverless.lua",
    updated = nil,

    push_timestamp = nil,
    pull_timestamp = nil,
    page_update_counter = nil,
    last_page = nil,
    last_page_turn_timestamp = nil,
    periodic_push_task = nil,
    periodic_push_scheduled = nil,

    settings = nil,
}

local SYNC_STRATEGY = {
    PROMPT  = 1,
    SILENT  = 2,
    DISABLE = 3,
}

local CHECKSUM_METHOD = {
    BINARY = 0,
    FILENAME = 1
}

-- Debounce automatic push/pull. Stamped only after a confirmed success, so a
-- failed attempt never blocks the next one (upstream stamped every attempt).
local API_CALL_DEBOUNCE_DELAY = time.s(Retry.DEBOUNCE_S)

-- NOTE: Upstream makes this public for ui/data/onetime_migration; nothing
--       outside this plugin reads this copy.
KOSyncServerless.default_settings = {
    custom_server = nil,
    username = nil,
    userkey = nil,
    -- Do *not* default to auto-sync, as wifi may not be on at all times, and the nagging enabling this may cause requires careful consideration.
    auto_sync = false,
    pages_before_update = nil,
    sync_forward = SYNC_STRATEGY.PROMPT,
    sync_backward = SYNC_STRATEGY.DISABLE,
    checksum_method = CHECKSUM_METHOD.BINARY,
    send_metadata = false,
}

-- The built-in plugin's settings, read once to carry its login over.
KOSyncServerless.builtin_settings_file = DataStorage:getSettingsDir() .. "/kosync.lua"

-- Shown at most once per KOReader process.
local coexistence_warned = false

function KOSyncServerless:loadSettings()
    if not KOSyncServerless.settings_obj then
        KOSyncServerless.settings_obj = LuaSettings:open(self.settings_file)
        local ok, copied = pcall(CarryOver.apply, KOSyncServerless.settings_obj,
            LuaSettings:open(self.builtin_settings_file))
        if not ok then
            logger.warn("KOSyncServerless: could not carry over the built-in plugin's settings:", copied)
        elseif copied then
            logger.info("KOSyncServerless: carried over settings from", self.builtin_settings_file)
        end
    end
    self.settings = KOSyncServerless.settings_obj:readSetting("settings", KOSyncServerless.default_settings)
end

function KOSyncServerless:onFlushSettings()
    if self.updated then
        KOSyncServerless.settings_obj:flush()
        self.updated = nil
    end
end

function KOSyncServerless:init()
    self.push_timestamp = 0
    self.pull_timestamp = 0
    self.page_update_counter = 0
    self.last_page = -1
    self.last_page_turn_timestamp = 0
    self.periodic_push_scheduled = false

    -- Like AutoSuspend, we need an instance-specific task for scheduling/resource management reasons.
    self.periodic_push_task = function()
        self.periodic_push_scheduled = false
        self.page_update_counter = 0
        -- We do *NOT* want to make sure networking is up here, as the nagging would be extremely annoying; we're leaving that to the network activity check...
        self:updateProgress(false, false)
    end
    self:loadSettings()
    self.device_id = G_reader_settings:readSetting("device_id")

    -- Disable auto-sync if beforeWifiAction was reset to "prompt" behind our back...
    if self.settings.auto_sync and Device:hasSeamlessWifiToggle() and G_reader_settings:readSetting("wifi_enable_action") ~= "turn_on" then
        self.settings.auto_sync = false
        logger.warn("KOSyncServerless: Automatic sync has been disabled because wifi_enable_action is *not* turn_on")
    end

    self.ui.menu:registerToMainMenu(self)
end

function KOSyncServerless:getSyncPeriod()
    if not self.settings.auto_sync then
        return _("Not available")
    end

    local period = self.settings.pages_before_update
    if period and period > 0 then
        return period
    else
        return _("Never")
    end
end

local function getNameStrategy(type)
    if type == 1 then
        return _("Prompt")
    elseif type == 2 then
        return _("Auto")
    else
        return _("Disable")
    end
end

local function showSyncedMessage()
    UIManager:show(InfoMessage:new{
        text = _("Progress has been synchronized."),
        timeout = 3,
    })
end

local function promptLogin()
    UIManager:show(InfoMessage:new{
        text = _("Please register or login before using the progress synchronization feature."),
        timeout = 3,
    })
end

local function showSyncError()
    UIManager:show(InfoMessage:new{
        text = _("Something went wrong when syncing progress, please check your network connection and try again later."),
        timeout = 3,
    })
end

local function validate(entry)
    if not entry then return false end
    if type(entry) == "string" then
        if entry == "" or not entry:match("%S") then return false end
    end
    return true
end

local function validateUser(user, pass)
    local error_message = nil
    local user_ok = validate(user)
    local pass_ok = validate(pass)
    if not user_ok and not pass_ok then
        error_message = _("invalid username and password")
    elseif not user_ok then
        error_message = _("invalid username")
    elseif not pass_ok then
        error_message = _("invalid password")
    end

    if not error_message then
        return user_ok and pass_ok
    else
        return user_ok and pass_ok, error_message
    end
end

function KOSyncServerless:onDispatcherRegisterActions()
    Dispatcher:registerAction("kosyncserverless_set_autosync",
        { category="string", event="KOSyncServerlessToggleAutoSync", title=_("Set auto progress sync (serverless)"), reader=true,
        args={true, false}, toggle={_("on"), _("off")},})
    Dispatcher:registerAction("kosyncserverless_toggle_autosync", { category="none", event="KOSyncServerlessToggleAutoSync", title=_("Toggle auto progress sync (serverless)"), reader=true,})
    Dispatcher:registerAction("kosyncserverless_push_progress", { category="none", event="KOSyncServerlessPushProgress", title=_("Push progress from this device (serverless)"), reader=true,})
    Dispatcher:registerAction("kosyncserverless_pull_progress", { category="none", event="KOSyncServerlessPullProgress", title=_("Pull progress from other devices (serverless)"), reader=true, separator=true,})
end

function KOSyncServerless:onReaderReady()
    if self.settings.auto_sync then
        UIManager:nextTick(function()
            self:getProgress(true, false)
        end)
    end
    -- NOTE: Keep in mind that, on Android, turning on WiFi requires a focus switch, which will trip a Suspend/Resume pair.
    --       NetworkMgr will attempt to hide the damage to avoid a useless pull -> push -> pull dance instead of the single pull requested.
    --       Plus, if wifi_enable_action is set to prompt, that also avoids stacking three prompts on top of each other...
    self:registerEvents()
    self:onDispatcherRegisterActions()
    self:warmUp("book open")

    self.last_page = self.ui:getCurrentPage()
    self:warnIfBuiltinLoaded()
end

-- Both plugins push and pull the same book when the built-in one is still
-- enabled. Keep working, but say so once per session.
function KOSyncServerless:warnIfBuiltinLoaded()
    if coexistence_warned or not self.ui.kosync then return end
    coexistence_warned = true
    logger.warn("KOSyncServerless: the built-in progress sync plugin is also enabled")
    UIManager:nextTick(function()
        UIManager:show(InfoMessage:new{
            text = _("The built-in Progress sync plugin is also enabled, so progress may be pushed and pulled twice.\n\nDisable it in Plugin management to use only Progress sync serverless."),
        })
    end)
end

function KOSyncServerless:addToMainMenu(menu_items)
    menu_items.progress_sync_serverless = {
        text = _("Progress sync serverless"),
        -- Not listed in KOReader's reader_menu_order.lua, so without a hint the
        -- menu sorter puts it on the first tab with a "NEW: " prefix.
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Custom sync server"),
                keep_menu_open = true,
                tap_input_func = function()
                    return {
                        -- @translators Server address defined by user for progress sync.
                        title = _("Custom progress sync server address"),
                        input = self.settings.custom_server or "https://",
                        callback = function(input)
                            self:setCustomServer(input)
                            self.updated = true
                        end,
                    }
                end,
            },
            {
                text = _("Device hostname"),
                keep_menu_open = true,
                callback = function()
                    local dialog
                    dialog = InputDialog:new{
                        -- @translators Name of this device defined by user for progress sync (if different than default device name)
                        title = _("Hostname for sync"),
                        input = self.settings.kosync_hostname,
                        input_hint = _("Leave empty to use default"),
                        buttons = {
                            {
                                {
                                    text = _("Cancel"),
                                    id = "close",
                                    callback = function()
                                        UIManager:close(dialog)
                                    end,
                                },
                                {
                                    text = _("OK"),
                                    is_enter_default = true,
                                    callback = function()
                                        local hostname = dialog:getInputText()
                                        logger.dbg("KOSyncServerless: Setting custom hostname to:", hostname)
                                        self.settings.kosync_hostname = hostname ~= "" and hostname or nil
                                        self.updated = true
                                        UIManager:close(dialog)
                                    end,
                                },
                            },
                        },
                    }
                    UIManager:show(dialog)
                    dialog:onShowKeyboard()
                end,
            },
            {
                text_func = function()
                    return self.settings.userkey and (_("Logout"))
                        or _("Register") .. " / " .. _("Login")
                end,
                keep_menu_open = true,
                callback_func = function()
                    if self.settings.userkey then
                        return function(menu)
                            self:logout(menu)
                            self.updated = true
                        end
                    else
                        return function(menu)
                            self:login(menu)
                        end
                    end
                end,
                separator = true,
            },
            {
                text = _("Automatically keep documents in sync"),
                checked_func = function() return self.settings.auto_sync end,
                help_text = _([[This may lead to nagging about toggling WiFi on document close and suspend/resume, depending on the device's connectivity.]]),
                callback = function()
                    self:onKOSyncServerlessToggleAutoSync(nil, true)
                    self.updated = true
                end,
            },
            {
                text_func = function()
                    return T(_("Periodically sync every # pages (%1)"), self:getSyncPeriod())
                end,
                enabled_func = function() return self.settings.auto_sync end,
                -- This is the condition that allows enabling auto_disable_wifi in NetworkManager ;).
                help_text = NetworkMgr:getNetworkInterfaceName() and _([[Unlike the automatic sync above, this will *not* attempt to setup a network connection, but instead relies on it being already up, and may trigger enough network activity to passively keep WiFi enabled!]]),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local items = SpinWidget:new{
                        text = _([[This value determines how many page turns it takes to update book progress.
If set to 0, updating progress based on page turns will be disabled.]]),
                        value = self.settings.pages_before_update or 0,
                        value_min = 0,
                        value_max = 999,
                        value_step = 1,
                        value_hold_step = 10,
                        ok_text = _("Set"),
                        title_text = _("Number of pages before update"),
                        default_value = 0,
                        callback = function(spin)
                            self:setPagesBeforeUpdate(spin.value)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                            self.updated = true
                        end
                    }
                    UIManager:show(items)
                end,
                separator = true,
            },
            {
                text = _("Sync behavior"),
                sub_item_table = {
                    {
                        text_func = function()
                            -- NOTE: With an up-to-date Sync server, "forward" means *newer*, not necessarily ahead in the document.
                            return T(_("Sync to a newer state (%1)"), getNameStrategy(self.settings.sync_forward))
                        end,
                        sub_item_table = {
                            {
                                text = _("Silently"),
                                checked_func = function()
                                    return self.settings.sync_forward == SYNC_STRATEGY.SILENT
                                end,
                                callback = function()
                                    self:setSyncForward(SYNC_STRATEGY.SILENT)
                                    self.updated = true
                                end,
                            },
                            {
                                text = _("Prompt"),
                                checked_func = function()
                                    return self.settings.sync_forward == SYNC_STRATEGY.PROMPT
                                end,
                                callback = function()
                                    self:setSyncForward(SYNC_STRATEGY.PROMPT)
                                    self.updated = true
                                end,
                            },
                            {
                                text = _("Never"),
                                checked_func = function()
                                    return self.settings.sync_forward == SYNC_STRATEGY.DISABLE
                                end,
                                callback = function()
                                    self:setSyncForward(SYNC_STRATEGY.DISABLE)
                                    self.updated = true
                                end,
                            },
                        }
                    },
                    {
                        text_func = function()
                            return T(_("Sync to an older state (%1)"), getNameStrategy(self.settings.sync_backward))
                        end,
                        sub_item_table = {
                            {
                                text = _("Silently"),
                                checked_func = function()
                                    return self.settings.sync_backward == SYNC_STRATEGY.SILENT
                                end,
                                callback = function()
                                    self:setSyncBackward(SYNC_STRATEGY.SILENT)
                                    self.updated = true
                                end,
                            },
                            {
                                text = _("Prompt"),
                                checked_func = function()
                                    return self.settings.sync_backward == SYNC_STRATEGY.PROMPT
                                end,
                                callback = function()
                                    self:setSyncBackward(SYNC_STRATEGY.PROMPT)
                                    self.updated = true
                                end,
                            },
                            {
                                text = _("Never"),
                                checked_func = function()
                                    return self.settings.sync_backward == SYNC_STRATEGY.DISABLE
                                end,
                                callback = function()
                                    self:setSyncBackward(SYNC_STRATEGY.DISABLE)
                                    self.updated = true
                                end,
                            },
                        }
                    },
                },
                separator = true,
            },
            {
                text = _("Push progress from this device now"),
                enabled_func = function()
                    return self.settings.userkey ~= nil
                end,
                callback = function()
                    self:updateProgress(true, true)
                end,
            },
            {
                text = _("Pull progress from other devices now"),
                enabled_func = function()
                    return self.settings.userkey ~= nil
                end,
                callback = function()
                    self:getProgress(true, true)
                end,
                separator = true,
            },
            {
                text = _("Document matching method"),
                sub_item_table = {
                    {
                        text = _("Binary. Only identical files will be kept in sync."),
                        checked_func = function()
                            return self.settings.checksum_method == CHECKSUM_METHOD.BINARY
                        end,
                        callback = function()
                            self:setChecksumMethod(CHECKSUM_METHOD.BINARY)
                            self.updated = true
                        end,
                    },
                    {
                        text = _("Filename. Files with matching names will be kept in sync."),
                        checked_func = function()
                            return self.settings.checksum_method == CHECKSUM_METHOD.FILENAME
                        end,
                        callback = function()
                            self:setChecksumMethod(CHECKSUM_METHOD.FILENAME)
                            self.updated = true
                        end,
                    },
                }
            },
            {
                text = _("Send document metadata"),
                checked_func = function() return self.settings.send_metadata end,
                help_text = _([[When enabled, document metadata (filename, title, and authors) will be sent along with progress sync requests. This data is ignored by the official sync server but may be used by custom sync servers.]]),
                callback = function()
                    self.settings.send_metadata = not self.settings.send_metadata
                    self.updated = true
                end,
            },
        }
    }
end

function KOSyncServerless:setPagesBeforeUpdate(pages_before_update)
    self.settings.pages_before_update = pages_before_update > 0 and pages_before_update or nil
end

function KOSyncServerless:setCustomServer(server)
    logger.dbg("KOSyncServerless: Setting custom server to:", server)
    self.settings.custom_server = server ~= "" and server or nil
end

function KOSyncServerless:setSyncForward(strategy)
    self.settings.sync_forward = strategy
end

function KOSyncServerless:setSyncBackward(strategy)
    self.settings.sync_backward = strategy
end

function KOSyncServerless:setChecksumMethod(method)
    self.settings.checksum_method = method
end

function KOSyncServerless:login(menu)
    if NetworkMgr:willRerunWhenOnline(function() self:login(menu) end) then
        return
    end

    local dialog
    dialog = MultiInputDialog:new{
        title = self.title,
        fields = {
            {
                text = self.settings.username,
                hint = "username",
            },
            {
                hint = "password",
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Login"),
                    callback = function()
                        local username, password = unpack(dialog:getFields())
                        username = util.trim(username)
                        local ok, err = validateUser(username, password)
                        if not ok then
                            UIManager:show(InfoMessage:new{
                                text = T(_("Cannot login: %1"), err),
                                timeout = 2,
                            })
                        else
                            UIManager:close(dialog)
                            UIManager:scheduleIn(0.5, function()
                                self:doLogin(username, password, menu)
                            end)
                            UIManager:show(InfoMessage:new{
                                text = _("Logging in. Please wait…"),
                                timeout = 1,
                            })
                        end
                    end,
                },
                {
                    text = _("Register"),
                    callback = function()
                        local username, password = unpack(dialog:getFields())
                        username = util.trim(username)
                        local ok, err = validateUser(username, password)
                        if not ok then
                            UIManager:show(InfoMessage:new{
                                text = T(_("Cannot register: %1"), err),
                                timeout = 2,
                            })
                        else
                            UIManager:close(dialog)
                            UIManager:scheduleIn(0.5, function()
                                self:doRegister(username, password, menu)
                            end)
                            UIManager:show(InfoMessage:new{
                                text = _("Registering. Please wait…"),
                                timeout = 1,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KOSyncServerless:newClient()
    local KOSyncServerlessClient = require("KOSyncServerlessClient")
    return KOSyncServerlessClient:new{
        custom_url = self.settings.custom_server,
        username = self.settings.username,
        userkey = self.settings.userkey,
    }
end

-- Shows "Waking sync server…" when a manual request has not answered within
-- a second, or as soon as a second attempt starts. Never modal: the reader
-- keeps working. Returns on_attempt (pass to the client) and close().
function KOSyncServerless:wakingMessage()
    local widget, closed = nil, false
    local function show()
        if closed or widget then return end
        widget = InfoMessage:new{ text = _("Waking sync server…") }
        UIManager:show(widget)
    end
    UIManager:scheduleIn(1, show)
    return function(n)
        if n and n > 1 then show() end
    end, function()
        closed = true
        UIManager:unschedule(show)
        if widget then
            UIManager:close(widget)
            widget = nil
        end
    end
end

function KOSyncServerless:doRegister(username, password, menu)
    local client = self:newClient()
    local userkey = md5(password)
    local on_attempt, close_waking = self:wakingMessage()
    client:register(username, userkey, function(ok, body, res)
        close_waking()
        if ok then
            self.settings.username = username
            self.settings.userkey = userkey
            if menu then
                menu:updateItems()
            end
            self.updated = true
            UIManager:show(InfoMessage:new{
                text = _("Registered to KOReader server."),
            })
        elseif not res.status then
            UIManager:show(InfoMessage:new{
                text = _("An error occurred while registering:") ..
                    "\n" .. tostring(res.err),
            })
        else
            UIManager:show(InfoMessage:new{
                text = body and body.message or _("Unknown server error"),
            })
        end
    end, { on_attempt = on_attempt })
end

function KOSyncServerless:doLogin(username, password, menu)
    local client = self:newClient()
    local userkey = md5(password)
    local on_attempt, close_waking = self:wakingMessage()
    client:authorize(username, userkey, function(ok, body, res)
        close_waking()
        if ok then
            self.settings.username = username
            self.settings.userkey = userkey
            self.updated = true
            if menu then
                menu:updateItems()
            end
            UIManager:show(InfoMessage:new{
                text = _("Logged in to KOReader server."),
            })
        elseif not res.status then
            UIManager:show(InfoMessage:new{
                text = _("An error occurred while logging in:") ..
                    "\n" .. tostring(res.err),
            })
        else
            UIManager:show(InfoMessage:new{
                text = body and body.message or _("Unknown server error"),
            })
        end
    end, { on_attempt = on_attempt })
end

function KOSyncServerless:logout(menu)
    self.settings.userkey = nil
    self.settings.auto_sync = true
    -- Clear any queued progress for the old account
    local KOSyncServerlessQueue = require("KOSyncServerlessQueue")
    KOSyncServerlessQueue:clear()
    if menu then
        menu:updateItems()
    end
end

function KOSyncServerless:getLastPercent()
    if self.ui.document.info.has_pages then
        return Math.roundPercent(self.ui.paging:getLastPercent())
    else
        return Math.roundPercent(self.ui.rolling:getLastPercent())
    end
end

function KOSyncServerless:getLastProgress()
    if self.ui.document.info.has_pages then
        return self.ui.paging:getLastProgress()
    else
        return self.ui.rolling:getLastProgress()
    end
end

function KOSyncServerless:getDocumentDigest()
    if self.settings.checksum_method == CHECKSUM_METHOD.FILENAME then
        return self:getFileNameDigest()
    else
        return self:getFileDigest()
    end
end

function KOSyncServerless:getFileDigest()
    return self.ui.doc_settings:readSetting("partial_md5_checksum")
end

function KOSyncServerless:getFileNameDigest()
    local file_name = self:getFileName()
    if not file_name then return end
    return md5(file_name)
end

function KOSyncServerless:getFileName()
    local file = self.ui.document.file
    if not file then return end

    local file_path, file_name = util.splitFilePathName(file) -- luacheck: no unused
    if not file_name then return end

    return file_name
end

function KOSyncServerless:getMetadata()
    if not self.settings.send_metadata then return end

    local props = self.ui.doc_props
    return {
        filename = self:getFileName(),
        title = props.display_title,
        authors = props.authors,
    }
end

function KOSyncServerless:syncToProgress(progress)
    logger.dbg("KOSyncServerless: [Sync] progress to", progress)
    if self.ui.document.info.has_pages then
        self.ui:handleEvent(Event:new("GotoPage", tonumber(progress)))
    else
        self.ui:handleEvent(Event:new("GotoXPointer", progress))
    end
end

function KOSyncServerless:currentProgressItem()
    return {
        document = self:getDocumentDigest(),
        metadata = self:getMetadata(),
        progress = self:getLastProgress(),
        percentage = self:getLastPercent(),
        device = self.settings.kosync_hostname or Device.model,
        device_id = self.device_id,
    }
end

local function doneHandle()
    return { cancel = function() return false end, attempts = function() return 0 end,
             finished = function() return true end }
end

--[[--
Push this book's progress now, with retries (see kosyncserverless_retry).

For callers that must wait for the push, such as pushing before sleep:
callback(ok, res) fires exactly once: after a confirmed success, after the
last failed attempt, right away when not logged in, or right away from
handle.cancel(). Nothing is shown on screen. On failure the progress is
queued for a later drain (not on 401); on success the debounce time is
stamped and any queued progress is drained.

@tparam function callback function(ok, res); res.status, res.err ("cancelled", "timeout", ...)
@tparam table opts optional { on_attempt = function(n) }
@treturn table handle { cancel = function() -> bool, attempts = function() -> n, finished = function() -> bool }
]]
function KOSyncServerless:pushNow(callback, opts)
    opts = opts or {}
    callback = callback or function() end
    if not self.settings.username or not self.settings.userkey then
        callback(false, { err = "not logged in" })
        return doneHandle()
    end
    local item = self:currentProgressItem()
    if not item.document then
        callback(false, { err = "no document" })
        return doneHandle()
    end
    logger.dbg("KOSyncServerless: [Push] progress to", item.percentage * 100, "% =>", item.progress)
    return self:newClient():push(item, function(ok, res)
        logger.dbg("KOSyncServerless: [Push] ok:", ok, "status:", res.status, "err:", res.err, "attempts:", res.attempts)
        if ok then
            self.push_timestamp = UIManager:getElapsedTimeSinceBoot()
            local KOSyncServerlessQueue = require("KOSyncServerlessQueue")
            if KOSyncServerlessQueue:count() > 0 then
                UIManager:nextTick(function() self:drainQueue() end)
            end
        elseif res.status ~= 401 then
            -- Queue for retry unless it's an auth failure
            local KOSyncServerlessQueue = require("KOSyncServerlessQueue")
            KOSyncServerlessQueue:push(item)
        end
        callback(ok, res)
    end, { on_attempt = opts.on_attempt })
end

function KOSyncServerless:updateProgress(ensure_networking, interactive, on_suspend)
    if not self.settings.username or not self.settings.userkey then
        if interactive then
            promptLogin()
        end
        return
    end

    local now = UIManager:getElapsedTimeSinceBoot()
    if not interactive and now - self.push_timestamp <= API_CALL_DEBOUNCE_DELAY then
        logger.dbg("KOSyncServerless: We've already pushed progress less than 25s ago!")
        return
    end

    if ensure_networking and NetworkMgr:willRerunWhenOnline(function() self:updateProgress(ensure_networking, interactive, on_suspend) end) then
        return
    end

    local on_attempt, close_waking
    if interactive then
        on_attempt, close_waking = self:wakingMessage()
    end
    local handle = self:pushNow(function(ok)
        if close_waking then close_waking() end
        if interactive then
            if ok then
                UIManager:show(InfoMessage:new{
                    text = _("Progress has been pushed."),
                    timeout = 3,
                })
            else
                showSyncError()
            end
        end
        if on_suspend then
            -- NOTE: We want to murder Wi-Fi once we're done in this specific case (i.e., Suspend),
            --       because some of our hasWifiManager targets will horribly implode when attempting to suspend with the Wi-Fi chip powered on,
            --       and they'll have attempted to kill Wi-Fi well before *we* run (e.g., in `Device:onPowerEvent`, *before* actually sending the Suspend Event)...
            if Device:hasWifiManager() then
                NetworkMgr:disableWifi()
            end
        end
    end, { on_attempt = on_attempt })

    -- This is solely for onSuspend's sake, to clear the ghosting left by the "Connected" InfoMessage
    if on_suspend then
        -- Our top-level widget should be the "Connected to network" InfoMessage from NetworkMgr's reconnectOrShowNetworkMenu
        local widget = UIManager:getTopmostVisibleWidget()
        if widget and widget.modal and widget.tag == "NetworkMgr" and not widget.dismiss_callback then
            -- We want a full-screen flash on dismiss
            widget.dismiss_callback = function()
                -- Enqueued, because we run before the InfoMessage's close
                UIManager:setDirty(nil, "full")
            end
        end
    end
    return handle
end

function KOSyncServerless:getProgress(ensure_networking, interactive)
    if not self.settings.username or not self.settings.userkey then
        if interactive then
            promptLogin()
        end
        return
    end

    local now = UIManager:getElapsedTimeSinceBoot()
    if not interactive and now - self.pull_timestamp <= API_CALL_DEBOUNCE_DELAY then
        logger.dbg("KOSyncServerless: We've already pulled progress less than 25s ago!")
        return
    end

    if ensure_networking and NetworkMgr:willRerunWhenOnline(function() self:getProgress(ensure_networking, interactive) end) then
        return
    end

    local doc_digest = self:getDocumentDigest()
    local on_attempt, close_waking
    if interactive then
        on_attempt, close_waking = self:wakingMessage()
    end
    return self:newClient():pull(doc_digest,
        function(ok, body, res)
            if close_waking then close_waking() end
            logger.dbg("KOSyncServerless: [Pull] ok:", ok, "status:", res.status, "err:", res.err, "attempts:", res.attempts, "body:", body)
            if ok then
                self.pull_timestamp = UIManager:getElapsedTimeSinceBoot()
            end
            -- The book may have been closed while the request ran.
            if not self.ui or not self.ui.document then return end
            if not ok or not body then
                if interactive then
                    showSyncError()
                end
                return
            end

            if not body.percentage then
                if interactive then
                    UIManager:show(InfoMessage:new{
                        text = _("No progress found for this document."),
                        timeout = 3,
                    })
                end
                return
            end

            if body.device == Device.model
            and body.device_id == self.device_id then
                if interactive then
                    UIManager:show(InfoMessage:new{
                        text = _("Latest progress is coming from this device."),
                        timeout = 3,
                    })
                end
                return
            end

            body.percentage = Math.roundPercent(body.percentage)
            local progress = self:getLastProgress()
            local percentage = self:getLastPercent()
            logger.dbg("KOSyncServerless: Current progress:", percentage * 100, "% =>", progress)

            if percentage == body.percentage
            or body.progress == progress then
                if interactive then
                    UIManager:show(InfoMessage:new{
                        text = _("The progress has already been synchronized."),
                        timeout = 3,
                    })
                end
                return
            end

            -- The progress needs to be updated.
            if interactive then
                -- If user actively pulls progress from other devices,
                -- we always update the progress without further confirmation.
                self:syncToProgress(body.progress)
                showSyncedMessage()
                return
            end

            local self_older
            if body.timestamp ~= nil then
                self_older = (body.timestamp > self.last_page_turn_timestamp)
            else
                -- If we are working with an old sync server, we can only use the percentage field.
                self_older = (body.percentage > percentage)
            end
            if self_older then
                if self.settings.sync_forward == SYNC_STRATEGY.SILENT then
                    self:syncToProgress(body.progress)
                    showSyncedMessage()
                elseif self.settings.sync_forward == SYNC_STRATEGY.PROMPT then
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Sync to latest location %1% from device '%2'?"),
                                 Math.round(body.percentage * 100),
                                 body.device),
                        ok_callback = function()
                            self:syncToProgress(body.progress)
                        end,
                    })
                end
            else -- if not self_older then
                if self.settings.sync_backward == SYNC_STRATEGY.SILENT then
                    self:syncToProgress(body.progress)
                    showSyncedMessage()
                elseif self.settings.sync_backward == SYNC_STRATEGY.PROMPT then
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Sync to previous location %1% from device '%2'?"),
                                 Math.round(body.percentage * 100),
                                 body.device),
                        ok_callback = function()
                            self:syncToProgress(body.progress)
                        end,
                    })
                end
            end
        end, { on_attempt = on_attempt })
end

function KOSyncServerless:_onCloseDocument()
    logger.dbg("KOSyncServerless: onCloseDocument")
    -- NOTE: Because everything is terrible, on Android, opening the system settings to enable WiFi means we lose focus,
    --       and we handle those system focus events via... Suspend & Resume events, so we need to neuter those handlers early.
    self.onResume = nil
    self.onSuspend = nil
    -- If we're already online, push normally.
    -- Otherwise, queue progress for later instead of blocking with goOnlineToRun.
    if NetworkMgr:isOnline() then
        self:updateProgress(false, false)
    else
        local doc_digest = self:getDocumentDigest()
        if doc_digest then
            local KOSyncServerlessQueue = require("KOSyncServerlessQueue")
            KOSyncServerlessQueue:push({
                document = doc_digest,
                metadata = self:getMetadata(),
                progress = self:getLastProgress(),
                percentage = self:getLastPercent(),
                device = self.settings.kosync_hostname or Device.model,
                device_id = self.device_id,
            })
        end
    end
end

function KOSyncServerless:schedulePeriodicPush()
    UIManager:unschedule(self.periodic_push_task)
    -- Use a sizable delay to make debouncing this on skim feasible...
    UIManager:scheduleIn(10, self.periodic_push_task)
    self.periodic_push_scheduled = true
end

function KOSyncServerless:_onPageUpdate(page)
    if page == nil then
        return
    end

    if self.last_page ~= page then
        self.last_page = page
        self.last_page_turn_timestamp = os.time()
        self.page_update_counter = self.page_update_counter + 1
        -- If we've already scheduled a push, regardless of the counter's state, delay it until we're *actually* idle
        if self.periodic_push_scheduled or self.settings.pages_before_update and self.page_update_counter >= self.settings.pages_before_update then
            self:schedulePeriodicPush()
        end
    end
end

-- Fire-and-forget GET /healthcheck so a sleeping server starts booting before
-- the first real request. Skipped when the server answered in the last
-- Retry.PING_SKIP_S seconds.
function KOSyncServerless:warmUp(why)
    if not self.settings.userkey or not NetworkMgr:isOnline() then return false end
    local sent = self:newClient():ping()
    logger.dbg("KOSyncServerless: warm-up ping on", why, sent and "sent" or "skipped")
    return sent
end

function KOSyncServerless:_onResume()
    logger.dbg("KOSyncServerless: onResume")
    self:warmUp("resume")
    if not self.settings.auto_sync then return end
    -- If we have auto_restore_wifi enabled, skip this to prevent both the "Connecting..." UI to pop-up,
    -- *and* a duplicate NetworkConnected event from firing...
    if Device:hasWifiRestore() and NetworkMgr.wifi_was_on and G_reader_settings:isTrue("auto_restore_wifi") then
        return
    end

    -- And if we don't, this *will* (attempt to) trigger a connection and as such a NetworkConnected event,
    -- but only a single pull will happen, since getProgress debounces itself.
    UIManager:scheduleIn(1, function()
        self:getProgress(true, false)
    end)
end

function KOSyncServerless:_onSuspend()
    logger.dbg("KOSyncServerless: onSuspend")
    -- We request an extra flashing refresh on success, to deal with potential ghosting left by the NetworkMgr UI
    self:updateProgress(true, false, true)
end

function KOSyncServerless:_onNetworkConnected()
    logger.dbg("KOSyncServerless: onNetworkConnected")
    self:warmUp("network connected")
    UIManager:scheduleIn(0.5, function()
        -- Drain any queued progress updates first
        self:drainQueue()
        -- Then pull as normal
        if self.settings.auto_sync then
            self:getProgress(false, false)
        end
    end)
end

-- Sends queued progress oldest first; each entry leaves the queue only after
-- the server confirmed it (upstream dropped entries whose send merely did not
-- throw). Stops at the first failure and keeps the rest for the next drain.
function KOSyncServerless:drainQueue(done)
    local KOSyncServerlessQueue = require("KOSyncServerlessQueue")
    if not self.settings.username or not self.settings.userkey
            or KOSyncServerlessQueue:count() == 0 then
        if done then done(0, KOSyncServerlessQueue:count()) end
        return
    end
    local client = self:newClient()
    KOSyncServerlessQueue:drainAsync(function(item, cb)
        client:push(item, function(ok, res)
            logger.dbg("KOSyncServerless: [Drain]", item.document, "ok:", ok, "status:", res.status, "err:", res.err)
            cb(ok)
        end)
    end, done)
end

function KOSyncServerless:_onNetworkDisconnecting()
    logger.dbg("KOSyncServerless: onNetworkDisconnecting")
    -- Network is supposed to be on already, don't wrap this in willRerunWhenOnline
    self:updateProgress(false, false)
end

function KOSyncServerless:onKOSyncServerlessPushProgress()
    self:updateProgress(true, true)
end

function KOSyncServerless:onKOSyncServerlessPullProgress()
    self:getProgress(true, true)
end

function KOSyncServerless:onKOSyncServerlessToggleAutoSync(toggle, from_menu)
    if toggle == self.settings.auto_sync then
        return true
    end
    -- Actively recommend switching the before wifi action to "turn_on" instead of prompt,
    -- as prompt will just not be practical (or even plain usable) here.
    if not self.settings.auto_sync
            and Device:hasSeamlessWifiToggle()
            and G_reader_settings:readSetting("wifi_enable_action") ~= "turn_on" then
        UIManager:show(InfoMessage:new{ text = _("You will have to switch the 'Action when Wi-Fi is off' Network setting to 'turn on' to be able to enable this feature!") })
        return true
    end
    self.settings.auto_sync = not self.settings.auto_sync
    self.updated = true
    self:registerEvents()

    if self.settings.auto_sync then
        -- Since we will update the progress when closing the document,
        -- pull the current progress now so as not to silently overwrite it.
        self:getProgress(true, true)
    elseif from_menu then
        -- Since we won't update the progress when closing the document,
        -- push the current progress now so as not to lose it.
        self:updateProgress(true, true)
    end

    if not from_menu then
        Notification:notify(self.settings.auto_sync and _("Auto progress sync: on") or _("Auto progress sync: off"))
    end
    return true
end

function KOSyncServerless:registerEvents()
    if self.settings.auto_sync then
        self.onCloseDocument = self._onCloseDocument
        self.onPageUpdate = self._onPageUpdate
        self.onSuspend = self._onSuspend
        self.onNetworkDisconnecting = self._onNetworkDisconnecting
    else
        self.onCloseDocument = nil
        self.onPageUpdate = nil
        self.onSuspend = nil
        self.onNetworkDisconnecting = nil
    end
    -- Always on: the warm-up ping and the queue drain do not depend on auto
    -- sync; both handlers check auto_sync before pulling.
    self.onResume = self._onResume
    self.onNetworkConnected = self._onNetworkConnected
end

function KOSyncServerless:onCloseWidget()
    UIManager:unschedule(self.periodic_push_task)
    self.periodic_push_task = nil
end

return KOSyncServerless
