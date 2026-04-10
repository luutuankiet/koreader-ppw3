local socket = require("socket")
local handlers = require("handlers")

local server = {}
server.__index = server

-- Simple JSON encoder (no external deps)
local json = {}

local function escape_str(s)
    local replacements = {
        ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
        ['\r'] = '\\r', ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f',
    }
    return s:gsub('["\\%c]', function(c)
        return replacements[c] or string.format('\\u%04x', string.byte(c))
    end)
end

function json.encode(val)
    local t = type(val)
    if val == nil then return "null" end
    if t == "boolean" then return val and "true" or "false" end
    if t == "number" then return tostring(val) end
    if t == "string" then return '"' .. escape_str(val) .. '"' end
    if t == "table" then
        -- Check if array
        local is_array = (#val > 0) or next(val) == nil
        if is_array and #val > 0 then
            -- Verify it's actually a sequence
            for i = 1, #val do
                if val[i] == nil then is_array = false; break end
            end
        end
        if is_array then
            local parts = {}
            for i = 1, #val do
                parts[i] = json.encode(val[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                table.insert(parts, '"' .. escape_str(tostring(k)) .. '":' .. json.encode(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

function json.decode(str)
    -- Minimal JSON decoder using load/loadstring
    if not str or str == "" then return nil end
    str = str:gsub("%s+$", ""):gsub("^%s+", "")
    -- Replace JSON literals with Lua equivalents
    local lua_str = str
        :gsub('"([^"\\]-)"(%s*:)', function(k, colon) return '["' .. k .. '"]' .. colon:gsub(':', ' =') end)
    -- This simple approach won't work for complex JSON. Use pattern-based parser instead.
    return json._parse(str, 1)
end

-- Recursive descent JSON parser
function json._parse(str, pos)
    pos = pos or 1
    -- Skip whitespace
    pos = str:find('[^ \t\n\r]', pos) or pos
    local c = str:sub(pos, pos)
    if c == '"' then
        return json._parse_string(str, pos)
    elseif c == '{' then
        return json._parse_object(str, pos)
    elseif c == '[' then
        return json._parse_array(str, pos)
    elseif c == 't' then
        return true, pos + 4
    elseif c == 'f' then
        return false, pos + 5
    elseif c == 'n' then
        return nil, pos + 4  -- null
    else
        -- number
        local num_str = str:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
        if num_str then
            return tonumber(num_str), pos + #num_str
        end
        return nil, pos
    end
end

function json._parse_string(str, pos)
    local result = {}
    pos = pos + 1  -- skip opening quote
    while pos <= #str do
        local c = str:sub(pos, pos)
        if c == '"' then
            return table.concat(result), pos + 1
        elseif c == '\\' then
            pos = pos + 1
            local esc = str:sub(pos, pos)
            if esc == 'n' then table.insert(result, '\n')
            elseif esc == 'r' then table.insert(result, '\r')
            elseif esc == 't' then table.insert(result, '\t')
            elseif esc == '"' then table.insert(result, '"')
            elseif esc == '\\' then table.insert(result, '\\')
            elseif esc == '/' then table.insert(result, '/')
            elseif esc == 'u' then
                local hex = str:sub(pos + 1, pos + 4)
                local cp = tonumber(hex, 16)
                if cp and cp < 128 then
                    table.insert(result, string.char(cp))
                else
                    table.insert(result, '?')
                end
                pos = pos + 4
            end
        else
            table.insert(result, c)
        end
        pos = pos + 1
    end
    return table.concat(result), pos
end

function json._parse_object(str, pos)
    local obj = {}
    pos = pos + 1  -- skip {
    while pos <= #str do
        pos = str:find('[^ \t\n\r]', pos) or pos
        if str:sub(pos, pos) == '}' then return obj, pos + 1 end
        if str:sub(pos, pos) == ',' then pos = pos + 1 end
        pos = str:find('[^ \t\n\r]', pos) or pos
        if str:sub(pos, pos) == '}' then return obj, pos + 1 end
        local key, val
        key, pos = json._parse_string(str, pos)
        pos = str:find('[^ \t\n\r]', pos) or pos
        pos = pos + 1  -- skip :
        val, pos = json._parse(str, pos)
        obj[key] = val
    end
    return obj, pos
end

function json._parse_array(str, pos)
    local arr = {}
    pos = pos + 1  -- skip [
    while pos <= #str do
        pos = str:find('[^ \t\n\r]', pos) or pos
        if str:sub(pos, pos) == ']' then return arr, pos + 1 end
        if str:sub(pos, pos) == ',' then pos = pos + 1 end
        pos = str:find('[^ \t\n\r]', pos) or pos
        if str:sub(pos, pos) == ']' then return arr, pos + 1 end
        local val
        val, pos = json._parse(str, pos)
        table.insert(arr, val)
    end
    return arr, pos
end

-- Logging helper
local log
local logger_ok, logger = pcall(require, "logger")
if logger_ok then
    log = function(msg) logger.info("[MCP] " .. msg) end
else
    log = function(msg) print("[MCP] " .. msg) end
end

function server.new(port)
    local self = setmetatable({}, server)
    self.port = port or 8888
    self.tcp = nil
    self.running = false
    self.json = json
    return self
end

function server:start()
    self.tcp = assert(socket.bind("0.0.0.0", self.port))
    self.tcp:settimeout(0)  -- non-blocking

    -- Set FD_CLOEXEC on listening socket to prevent child processes
    -- (from run_command/io.popen) from inheriting port 8888.
    -- Without this, killing luajit leaves zombie processes holding the port.
    local ok_ffi, ffi = pcall(require, "ffi")
    if ok_ffi then
        ffi.cdef[[int fcntl(int fd, int cmd, ...);]]
        local fd = self.tcp:getfd()
        if fd >= 0 then
            ffi.C.fcntl(fd, 2, ffi.cast("int", 1))  -- F_SETFD=2, FD_CLOEXEC=1
            log("FD_CLOEXEC set on listening socket (fd=" .. fd .. ")")
        end
    end

    self.running = true
    log("Server started on port " .. self.port)
end

function server:stop()
    self.running = false
    if self.tcp then
        self.tcp:close()
        self.tcp = nil
    end
    log("Server stopped")
end

function server:poll()
    if not self.running then return end
    local client = self.tcp:accept()
    if client then
        client:settimeout(5)
        local ok, err = pcall(self.handle_client, self, client)
        if not ok then
            log("Error handling client: " .. tostring(err))
        end
        client:close()
    end
end

function server:handle_client(client)
    -- Read request line
    local request_line, err = client:receive()
    if not request_line then return end

    local method, path = request_line:match("^(%u+)%s+(/[^%s]*)%s+HTTP")
    if not method then
        self:send_response(client, 400, {error = "Bad request"})
        return
    end

    -- Read headers
    local headers = {}
    local content_length = 0
    while true do
        local line = client:receive()
        if not line or line == "" then break end
        local key, value = line:match("^([^:]+):%s*(.+)$")
        if key then
            headers[key:lower()] = value
            if key:lower() == "content-length" then
                content_length = tonumber(value) or 0
            end
        end
    end

    -- Read body
    local body = ""
    if content_length > 0 then
        body = client:receive(content_length)
    end

    -- Route
    if method == "GET" and path == "/health" then
        self:send_response(client, 200, {
            status = "ok",
            device = "koreader_mcp",
            port = self.port,
        })
    elseif method == "POST" and path == "/jsonrpc" then
        self:handle_jsonrpc(client, body)
    else
        self:send_response(client, 404, {error = "Not found"})
    end
end

function server:handle_jsonrpc(client, body)
    local request = json._parse(body, 1)
    if not request then
        self:send_response(client, 400, {
            jsonrpc = "2.0",
            error = {code = -32700, message = "Parse error"},
            id = nil,
        })
        return
    end

    local rpc_method = request.method
    local params = request.params or {}
    local id = request.id

    local result, rpc_error = handlers.dispatch(rpc_method, params)
    if rpc_error then
        self:send_response(client, 200, {
            jsonrpc = "2.0",
            error = rpc_error,
            id = id,
        })
    else
        self:send_response(client, 200, {
            jsonrpc = "2.0",
            result = result,
            id = id,
        })
    end
end

function server:send_response(client, status_code, body_table)
    local body = json.encode(body_table)
    local status_text = ({[200]="OK", [400]="Bad Request", [404]="Not Found"})[status_code] or "OK"
    local response = table.concat({
        "HTTP/1.1 " .. status_code .. " " .. status_text,
        "Content-Type: application/json",
        "Content-Length: " .. #body,
        "Connection: close",
        "",
        body,
    }, "\r\n")
    client:send(response)
end

-- Standalone blocking loop (for testing without KOReader)
function server:run_blocking()
    self:start()
    log("Running in standalone blocking mode. Press Ctrl+C to stop.")
    while self.running do
        self:poll()
        socket.sleep(0.1)
    end
end

return server
