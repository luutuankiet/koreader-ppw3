--[[
KOReader MCP plugin: the agent bridge.

The device dials out to the gateway and carries tool calls over that one connection
(live.lua). There is no listening server: outside a session this plugin has no socket
and no timer. config.lua (optional) holds device_name, gateway_host, gateway_port and
live_mode; live_mode = "always" starts a session at boot and keeps it, unless the owner
turned Live mode off in the menu, which is remembered across restarts.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local DEFAULT_HOST = "192.168.1.19"
local DEFAULT_PORT = 9990
-- The gateway's HTTP port, where /inbox/ takes diagnostics bundles. Not the live
-- connection: a bundle must reach the gateway with live mode off.
local DEFAULT_HTTP_PORT = 9999

local function log(msg) logger.info("[MCP] " .. msg) end

-- KOReader rebuilds the plugin instance on every file manager / reader switch, so the
-- session belongs to the loaded file, and onCloseWidget must not stop it.
local session
local config = {}
local settings
local plugin_dir
local timers_scheduled = 0

local function readSerial()
    local f = io.open("/proc/usid", "r")
    if not f then return nil end
    local serial = f:read("*l")
    f:close()
    return serial and serial:gsub("%s+", "") or nil
end

local function pluginVersions()
    local versions = {}
    local parent = plugin_dir:match("^(.*)/[^/]+/?$")
    if not parent then return versions end
    local ok = pcall(function()
        for entry in lfs.dir(parent) do
            local name = entry:match("^(.+)%.koplugin$")
            if name then
                local loaded, meta = pcall(dofile, parent .. "/" .. entry .. "/_meta.lua")
                if loaded and type(meta) == "table" and meta.version then
                    versions[name] = tostring(meta.version)
                end
            end
        end
    end)
    if not ok then log("could not list plugin versions") end
    return versions
end

local function identity()
    local Live = require("live")
    local sha2 = require("ffi/sha2")
    local id = Live.identity{
        serial = readSerial(),
        config_name = config.device_name,
        sha256 = sha2.sha256,
    }
    local names = settings:readSetting("names") or {}
    id.name = names[id.id_hash] or id.name
    local ok, version = pcall(function() return require("version"):getCurrentRevision() end)
    id.koreader_version = ok and version or "unknown"
    id.plugin_versions = pluginVersions()
    return id
end

local function connect(host, port)
    local sock = require("socket").tcp()
    sock:settimeout(5)
    local ok, err = sock:connect(host, port)
    if not ok then
        sock:close()
        return nil, err
    end
    -- A child of run_command must not inherit the connection: the detached restart shell
    -- would hold it open and the gateway would never see this device go offline.
    local ok_ffi, ffi = pcall(require, "ffi")
    if ok_ffi then
        ffi.cdef[[int fcntl(int fd, int cmd, ...);]]
        ffi.C.fcntl(sock:getfd(), 2, ffi.cast("int", 1)) -- F_SETFD=2, FD_CLOEXEC=1
    end
    sock:setoption("tcp-nodelay", true)
    sock:settimeout(0)
    return sock
end

-- 60s pings sit below KOReader's WiFi activity threshold, so its auto-off would cut the
-- session. Pause the check rather than flip the setting, which a crash would persist.
local function pauseWifiCheck()
    local ok, listener = pcall(require, "ui/network/networklistener")
    if ok and listener._unscheduleActivityCheck then pcall(listener._unscheduleActivityCheck, listener) end
end

local function resumeWifiCheck()
    local ok, listener = pcall(require, "ui/network/networklistener")
    if ok and listener._scheduleActivityCheck
        and G_reader_settings:isTrue("auto_disable_wifi") and NetworkMgr:isWifiOn() then
        pcall(listener._scheduleActivityCheck, listener)
    end
end

local function setScreenSaverHeld(held)
    if not Device:isKindle() then return end
    if not held and require("pluginshare").keepalive then return end
    os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver " .. (held and "1" or "0"))
end

local function gatewayAddress()
    local stored = settings:readSetting("gateway") or {}
    return stored.host or config.gateway_host or DEFAULT_HOST,
        tonumber(stored.port or config.gateway_port) or DEFAULT_PORT
end

local function newSession()
    local Live = require("live")
    local handlers = require("handlers")
    local server_json = require("server").json
    local ui_agent = require("ui_agent")
    local host, port = gatewayAddress()
    return Live.new({
        connect = connect,
        schedule = function(seconds, fn)
            timers_scheduled = timers_scheduled + 1
            -- Our own timers are never "pending UI work" for ui_act's idle wait.
            ui_agent.own_tasks[fn] = true
            UIManager:scheduleIn(seconds, fn)
            return fn
        end,
        unschedule = function(fn) UIManager:unschedule(fn) end,
        now = function() return require("socket").gettime() end,
        json = {
            encode = server_json.encode,
            decode = function(line) return (server_json._parse(line, 1)) end,
        },
        dispatch = handlers.dispatch,
        deferred = handlers.deferred,
        identity = identity,
        battery = function()
            local ok, capacity = pcall(function() return Device:getPowerDevice():getCapacity() end)
            return ok and capacity or nil
        end,
        on_begin = function()
            setScreenSaverHeld(true)
            pauseWifiCheck()
            -- A config-driven session starts by itself and leaves no state behind.
            if config.live_mode ~= "always" then
                settings:saveSetting("session_open", true)
                settings:flush()
            end
        end,
        on_end = function(reason)
            setScreenSaverHeld(false)
            resumeWifiCheck()
            settings:saveSetting("session_open", false)
            settings:flush()
            log("session over (" .. tostring(reason) .. "), timers scheduled by this plugin: " .. timers_scheduled)
        end,
        log = log,
    }, { host = host, port = port, always = config.live_mode == "always" })
end

local function startSession()
    if session and session:isActive() then return end
    session = newSession()
    session:start()
end

local function stopSession(reason)
    if session then session:stop(reason) end
end

local function restartIfActive()
    if session and session:isActive() then
        stopSession("settings changed")
        startSession()
    end
end

local KOReaderMCP = WidgetContainer:extend{
    name = "koreader_mcp",
    is_doc_only = false,
}

function KOReaderMCP:init()
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    if settings then return end -- only instance rebuilds get past here from now on

    plugin_dir = self.path or "plugins/koreader_mcp.koplugin"
    local pattern = plugin_dir .. "/?.lua"
    if not package.path:find(pattern, 1, true) then
        package.path = pattern .. ";" .. package.path
    end
    local ok, loaded = pcall(dofile, plugin_dir .. "/config.lua")
    if ok and type(loaded) == "table" then config = loaded end
    settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/koreader_mcp.lua")

    -- session_open still set means KOReader was killed mid-session, as restart_koreader
    -- does: pick the session back up so the agent gets the device back.
    -- live_off is set when the owner turns Live mode off in the menu, so that choice
    -- outlasts a restart even when config.lua says always.
    local always = config.live_mode == "always" and not settings:isTrue("live_off")
    if always or settings:isTrue("session_open") then
        UIManager:nextTick(startSession)
    else
        log("live mode off, timers scheduled by this plugin: " .. timers_scheduled)
    end
end

function KOReaderMCP:onNetworkConnected()
    if session and session:isActive() then
        pauseWifiCheck()
        session:networkUp()
    end
end

-- Follows the gateway host set in the menu. inbox_url (settings, then config.lua)
-- replaces the whole address, for a gateway whose HTTP port is not 9999.
local function inboxUrl()
    local url = settings:readSetting("inbox_url") or config.inbox_url
    if type(url) == "string" and url ~= "" then return (url:gsub("/+$", "")) end
    local host = gatewayAddress()
    return "http://" .. host .. ":" .. DEFAULT_HTTP_PORT
end

local function diagnosticsInfo(device_name)
    local diagnostics = require("diagnostics")
    local ok, version = pcall(function() return require("version"):getCurrentRevision() end)
    return {
        device = device_name,
        model = Device.model,
        time_utc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        koreader_version = ok and version or "unknown",
        live_mode = session ~= nil and session:isActive(),
        plugins = diagnostics.pluginVersions({ "plugins", DataStorage:getDataDir() .. "/plugins" }),
    }
end

local function sendDiagnostics()
    local diagnostics = require("diagnostics")
    local function tell(text, timeout)
        UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
    end

    -- A file of its own, not settings.reader.lua: this runs on every send and
    -- must never rewrite the reader's settings.
    local offset_path = DataStorage:getSettingsDir() .. "/koreader_mcp_diagnostics_offset.txt"
    local device = diagnostics.safeName(identity().name)
    -- Capture before anything of ours goes on screen.
    local built, err = diagnostics.build({
        json_encode = require("server").json.encode,
        log_path = "crash.log", -- KOReader's launcher writes it in the install folder, its working directory
        offset_path = offset_path,
        info = diagnosticsInfo(device),
        snapshot = function() return require("ui_agent").snapshot() end,
        screenshot = function(path) return require("handlers").capture_png(path) end,
    })
    if not built then
        log("diagnostics not built: " .. tostring(err))
        tell(_("Diagnostics not sent: ") .. tostring(err))
        return
    end

    local stamp = os.date("!%Y%m%d-%H%M%S")
    local url = inboxUrl()
    -- Asks to turn WiFi on if it is off, as any KOReader network action does.
    NetworkMgr:runWhenOnline(function()
        local sending = InfoMessage:new{ text = _("Sending diagnostics...") }
        UIManager:show(sending)
        UIManager:forceRePaint()
        local sent, upload_err = diagnostics.upload(url, device, built, stamp)
        UIManager:close(sending)
        if sent then
            diagnostics.commit(built, offset_path)
            log("diagnostics sent: " .. device .. "/" .. stamp .. " (" .. built.size .. " bytes)")
            tell(_("Diagnostics sent."), 3)
        else
            log("diagnostics upload to " .. url .. " failed: " .. tostring(upload_err))
            tell(_("Diagnostics not sent: ") .. tostring(upload_err))
        end
        os.remove(built.path)
    end)
end

function KOReaderMCP:onExit()
    stopSession("KOReader exiting")
end

function KOReaderMCP:addToMainMenu(menu_items)
    menu_items.koreader_mcp = {
        text = _("Agent bridge"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text = _("Live mode"),
                checked_func = function() return session ~= nil and session:isActive() end,
                callback = function()
                    if session and session:isActive() then
                        settings:saveSetting("live_off", true)
                        settings:flush()
                        stopSession("turned off in the menu")
                    else
                        settings:delSetting("live_off")
                        settings:flush()
                        NetworkMgr:runWhenOnline(startSession)
                    end
                end,
            },
            {
                text = _("Rename device"),
                keep_menu_open = true,
                callback = function() self:showRename() end,
            },
            {
                text = _("Gateway address"),
                keep_menu_open = true,
                callback = function() self:showGatewayAddress() end,
            },
        },
    }
    menu_items.koreader_mcp_diagnostics = {
        text = _("Send diagnostics"),
        sorting_hint = "tools",
        callback = function()
            -- One shot, after the menu has closed: the bundle should show the
            -- screen being reported, not this menu.
            UIManager:scheduleIn(0.5, sendDiagnostics)
        end,
    }
end

local function promptDialog(title, value, on_save)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = value,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local text = dialog:getInputText()
                    UIManager:close(dialog)
                    on_save(text)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KOReaderMCP:showRename()
    local id = identity()
    promptDialog(_("Device name"), id.name, function(name)
        if not require("live").validName(name) then
            UIManager:show(InfoMessage:new{ text = _("Use up to 32 letters, digits, dots, dashes or underscores.") })
            return
        end
        -- Keyed by the hash, so a settings backup restored on another device does not rename it.
        local names = settings:readSetting("names") or {}
        names[id.id_hash] = name
        settings:saveSetting("names", names)
        settings:flush()
        restartIfActive()
    end)
end

function KOReaderMCP:showGatewayAddress()
    local host, port = gatewayAddress()
    promptDialog(_("Gateway address (host:port)"), host .. ":" .. port, function(text)
        local new_host, new_port = text:match("^([%w%.%-]+):(%d+)$")
        if not new_host then
            UIManager:show(InfoMessage:new{ text = _("Use host:port, for example 192.168.1.19:9990.") })
            return
        end
        settings:saveSetting("gateway", { host = new_host, port = tonumber(new_port) })
        settings:flush()
        restartIfActive()
    end)
end

return KOReaderMCP
