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
        if config.port then
            self.port = config.port
        end
        if config.device_name then
            self.device_name = config.device_name
            log("Device name from config: " .. self.device_name)
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

    UIManager:scheduleIn(0.5, function()
        if self.server and self.server.running then
            self.server:poll()
            self:schedule_poll()
        end
    end)
end

function KOReaderMCP:registerWithGateway()
    if not self.gateway_url then return end

    local http = require("socket.http")
    local ltn12 = require("ltn12")

    -- Get device name and IP
    local device_name = self.device_name or ("kindle-" .. (os.getenv("HOSTNAME") or "unknown"))
    local ip = self:getLocalIP()
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

function KOReaderMCP:onCloseWidget()
    if self.server then
        self.server:stop()
    end
end

return KOReaderMCP
