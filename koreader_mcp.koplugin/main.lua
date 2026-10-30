-- KOReader MCP Server Plugin
-- Provides an HTTP+JSON-RPC server for remote device management

-- Load socket for gateway registration (IP discovery)
local socket = require("socket")

-- Try to load KOReader modules; graceful fallback for standalone testing
local WidgetContainer
local UIManager
local logger_ok, logger = pcall(require, "logger")

local ok_wc
ok_wc, WidgetContainer = pcall(require, "ui/widget/container/widgetcontainer")
if not ok_wc then WidgetContainer = nil end

local ok_ui
ok_ui, UIManager = pcall(require, "ui/uimanager")
if not ok_ui then UIManager = nil end

local log
if logger_ok then
    log = function(msg) logger.info("[MCP] " .. msg) end
else
    log = function(msg) print("[MCP] " .. msg) end
end

-- Load server module from plugin directory
local plugin_dir
if WidgetContainer then
    -- Will be set in init
    plugin_dir = nil
else
    -- Standalone mode: use current directory
    plugin_dir = "."
end

local base_class = WidgetContainer or {}
local KOReaderMCP = WidgetContainer and WidgetContainer:extend{} or {}

KOReaderMCP.name = "koreader_mcp"
KOReaderMCP.is_doc_only = false

function KOReaderMCP:init()
    if self.path then
        plugin_dir = self.path
    end
    self.port = 8888
    self.gateway_url = nil  -- Set to gateway URL to enable registration

    -- Load config.lua if present (created by deploy script)
    local config_ok, config = pcall(function()
        return dofile((plugin_dir or ".") .. "/config.lua")
    end)
    if config_ok and config then
        if config.gateway_url then
            self.gateway_url = config.gateway_url
            log("Gateway URL from config: " .. self.gateway_url)
        end
        -- Optional listen port; the emulator sets 8889 because 8888 is taken on its host.
        local port = tonumber(config.port)
        if port then
            self.port = port
            log("Port from config: " .. self.port)
        elseif config.port ~= nil then
            log("Ignoring invalid port in config: " .. tostring(config.port))
        end
        if config.device_name then
            self.device_name = config.device_name
            log("Device name from config: " .. self.device_name)
        end
        -- Optional address sent to the gateway instead of the discovered local IP.
        -- The emulator sets its host's tailnet name: its discovered IP is a LAN address.
        if type(config.advertise_host) == "string" and config.advertise_host ~= "" then
            self.advertise_host = config.advertise_host
            log("Advertise host from config: " .. self.advertise_host)
        end
    end

    -- Add plugin dir to package path so we can require our modules
    if plugin_dir then
        local sep = package.config:sub(1,1)
        local pattern = plugin_dir .. sep .. "?.lua"
        if not package.path:find(pattern, 1, true) then
            package.path = pattern .. ";" .. package.path
        end
    end

    -- Ensure firewall allows connections to our port (persists across KOReader restarts)
    -- Use full path: /usr/sbin/iptables not in default PATH on some Kindle firmware
    os.execute("/usr/sbin/iptables -C INPUT -p tcp --dport " .. self.port .. " -j ACCEPT 2>/dev/null || /usr/sbin/iptables -I INPUT -p tcp --dport " .. self.port .. " -j ACCEPT")

    local srv_module = require("server")
    self.server = srv_module.new(self.port)
    self.server:start()

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    if UIManager then
        self:schedule_poll()
        log("Plugin initialized with UIManager polling")
    else
        log("Plugin initialized (no UIManager, use run_blocking for standalone)")
    end
end

function KOReaderMCP:schedule_poll()
    if not UIManager then return end
    if not self.server or not self.server.running then return end

    local function poll()
        if self.server and self.server.running then
            self.server:poll()
            self:schedule_poll()
        end
    end
    -- The server's own poll is never "pending UI work" for ui_act's idle wait.
    require("ui_agent").own_tasks[poll] = true
    UIManager:scheduleIn(0.5, poll)
end

function KOReaderMCP:getDeviceName()
    return self.device_name or ("kindle-" .. (os.getenv("HOSTNAME") or "unknown"))
end

function KOReaderMCP:registerWithGateway()
    if not self.gateway_url then return end

    local http = require("socket.http")
    local ltn12 = require("ltn12")

    -- Get device name and IP
    local device_name = self:getDeviceName()
    local ip = self.advertise_host or self:getLocalIP()
    if not ip then
        log("Cannot determine local IP, skipping registration")
        return
    end

    local body = '{"name":"' .. device_name .. '","ip":"' .. ip .. '","port":' .. self.port
        .. ',"tools":["read_files","run_command","device_status"]}'

    log("Registering with gateway: " .. self.gateway_url .. " as " .. device_name .. " (" .. ip .. ":" .. self.port .. ")")

    local resp_body = {}
    local result, code = http.request({
        url = self.gateway_url .. "/register",
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(resp_body),
    })

    if result and code == 200 then
        log("Registered with gateway successfully")
    else
        log("Gateway registration failed: " .. tostring(code))
    end
end

function KOReaderMCP:getLocalIP()
    -- Connect to a non-routable address to discover local IP
    local udp = socket.udp()
    udp:setpeername("8.8.8.8", 80)
    local ip = udp:getsockname()
    udp:close()
    return ip
end

function KOReaderMCP:onNetworkConnected()
    log("Network connected")
    self:registerWithGateway()
end

function KOReaderMCP:onNetworkDisconnected()
    log("Network disconnected")
end

function KOReaderMCP:addToMainMenu(menu_items)
    local _ = require("gettext")
    menu_items.koreader_mcp_diagnostics = {
        text = _("Send diagnostics"),
        sorting_hint = "tools",
        callback = function()
            -- One shot, after the menu has closed: the bundle should show the
            -- screen being reported, not this menu.
            UIManager:scheduleIn(0.5, function() self:sendDiagnostics() end)
        end,
    }
end

function KOReaderMCP:diagnosticsInfo()
    local Device = require("device")
    local DataStorage = require("datastorage")
    local diagnostics = require("diagnostics")
    local ok, version = pcall(function() return require("version"):getCurrentRevision() end)
    return {
        device = self:getDeviceName(),
        model = Device.model,
        time_utc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        koreader_version = ok and version or "unknown",
        plugins = diagnostics.pluginVersions({ "plugins", DataStorage:getDataDir() .. "/plugins" }),
    }
end

function KOReaderMCP:sendDiagnostics()
    local InfoMessage = require("ui/widget/infomessage")
    local NetworkMgr = require("ui/network/manager")
    local DataStorage = require("datastorage")
    local diagnostics = require("diagnostics")
    local _ = require("gettext")

    local function tell(text, timeout)
        UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
    end
    if not self.gateway_url then
        tell(_("Diagnostics not sent: no gateway_url in the plugin's config.lua."))
        return
    end

    -- A file of its own, not settings.reader.lua: this runs on every send and
    -- must never rewrite the reader's settings.
    local offset_path = DataStorage:getSettingsDir() .. "/koreader_mcp_diagnostics_offset.txt"
    -- Capture before anything of ours goes on screen.
    local built, err = diagnostics.build({
        json_encode = require("server").json.encode,
        log_path = "crash.log", -- KOReader's launcher writes it in the install folder, its working directory
        offset_path = offset_path,
        info = self:diagnosticsInfo(),
        snapshot = function() return require("ui_agent").snapshot() end,
        screenshot = function(path) return require("handlers").capture_png(path) end,
    })
    if not built then
        log("Diagnostics not built: " .. tostring(err))
        tell(_("Diagnostics not sent: ") .. tostring(err))
        return
    end

    local stamp = os.date("!%Y%m%d-%H%M%S")
    local device = diagnostics.safeName(self:getDeviceName())
    -- Asks to turn WiFi on if it is off, as any KOReader network action does.
    NetworkMgr:runWhenOnline(function()
        local sending = InfoMessage:new{ text = _("Sending diagnostics...") }
        UIManager:show(sending)
        UIManager:forceRePaint()
        local sent, upload_err = diagnostics.upload(self.gateway_url, device, built, stamp)
        UIManager:close(sending)
        if sent then
            diagnostics.commit(built, offset_path)
            log("Diagnostics sent: " .. device .. "/" .. stamp .. " (" .. built.size .. " bytes)")
            tell(_("Diagnostics sent."), 3)
        else
            log("Diagnostics upload failed: " .. tostring(upload_err))
            tell(_("Diagnostics not sent: ") .. tostring(upload_err))
        end
        os.remove(built.path)
    end)
end

function KOReaderMCP:onCloseWidget()
    if self.server then
        self.server:stop()
    end
end

return KOReaderMCP
