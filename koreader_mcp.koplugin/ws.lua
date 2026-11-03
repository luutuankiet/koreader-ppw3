--[[
A small WebSocket client (RFC 6455) for live.lua, on a socket that is already connected
(plain TCP for ws://, a LuaSec connection for wss://). Nothing here blocks once the
handshake is done: reads take what the socket has and return "timeout" otherwise.

The connection it returns speaks the part of the luasocket API live.lua uses, with one
text message where luasocket would give one line:
  conn:receive("*l")  -> text | nil, "timeout", "" | nil, err
  conn:send(data)     -> sends data, minus a trailing "\n", as one masked text frame
  conn:settimeout(t), conn:close(), conn:getfd()

Pure Lua 5.1 plus LuaJIT's bit and ffi; the SHA-1 and the random bytes are passed in, so
test_live.lua runs it on plain luajit.
]]

local bit = require("bit")
local band, bor, bxor, rshift, lshift = bit.band, bit.bor, bit.bxor, bit.rshift, bit.lshift

local ws = {}

ws.GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
ws.OP_CONT, ws.OP_TEXT, ws.OP_BINARY = 0, 1, 2
ws.OP_CLOSE, ws.OP_PING, ws.OP_PONG = 8, 9, 10
-- A message bigger than this is a broken gateway, not a call.
ws.MAX_MESSAGE = 16 * 1024 * 1024
ws.READ_CHUNK = 65536

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function ws.base64(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = lshift(a, 16) + lshift(b or 0, 8) + (c or 0)
        local q = {
            B64:sub(rshift(n, 18) + 1, rshift(n, 18) + 1),
            B64:sub(band(rshift(n, 12), 63) + 1, band(rshift(n, 12), 63) + 1),
            b and B64:sub(band(rshift(n, 6), 63) + 1, band(rshift(n, 6), 63) + 1) or "=",
            c and B64:sub(band(n, 63) + 1, band(n, 63) + 1) or "=",
        }
        out[#out + 1] = table.concat(q)
    end
    return table.concat(out)
end

local function hex2bin(hex)
    return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

-- Sec-WebSocket-Accept for a key, from a function returning the SHA-1 as hex.
function ws.accept(key, sha1_hex)
    return ws.base64(hex2bin(sha1_hex(key .. ws.GUID)))
end

-- XOR payload with the 4-byte mask. ffi keeps a 150 kB screenshot reply off a per-byte
-- string loop on the Kindle's CPU.
local ok_ffi, ffi = pcall(require, "ffi")
local function apply_mask(payload, mask)
    local n = #payload
    if n == 0 then return payload end
    local m1, m2, m3, m4 = mask:byte(1, 4)
    local m = { [0] = m1, m2, m3, m4 }
    if ok_ffi then
        local buf = ffi.new("uint8_t[?]", n)
        ffi.copy(buf, payload, n)
        for i = 0, n - 1 do buf[i] = bxor(buf[i], m[i % 4]) end
        return ffi.string(buf, n)
    end
    local out = {}
    for i = 1, n do out[i] = string.char(bxor(payload:byte(i), m[(i - 1) % 4])) end
    return table.concat(out)
end
ws.apply_mask = apply_mask

-- One frame, FIN set. mask (4 bytes) is required from a client and absent from a server.
function ws.encode_frame(opcode, payload, mask, fin)
    payload = payload or ""
    local n = #payload
    local head = { string.char(bor(fin == false and 0 or 0x80, opcode)) }
    local mask_bit = mask and 0x80 or 0
    if n < 126 then
        head[2] = string.char(bor(mask_bit, n))
    elseif n < 65536 then
        head[2] = string.char(bor(mask_bit, 126), rshift(n, 8), band(n, 255))
    else
        head[2] = string.char(bor(mask_bit, 127), 0, 0, 0, 0,
            band(rshift(n, 24), 255), band(rshift(n, 16), 255), band(rshift(n, 8), 255), band(n, 255))
    end
    if mask then
        head[3] = mask
        head[4] = apply_mask(payload, mask)
    else
        head[3] = payload
    end
    return table.concat(head)
end

-- Reads one frame from the start of buf, from position pos (default 1).
-- -> frame { fin, opcode, payload }, next position | nil (need more bytes) | nil, err
function ws.decode_frame(buf, pos)
    pos = pos or 1
    local avail = #buf - pos + 1
    if avail < 2 then return nil end
    local b1, b2 = buf:byte(pos, pos + 1)
    if band(b1, 0x70) ~= 0 then return nil, "reserved bits set" end
    local masked = band(b2, 0x80) ~= 0
    local len = band(b2, 0x7f)
    local at = pos + 2
    if len == 126 then
        if avail < 4 then return nil end
        local h, l = buf:byte(at, at + 1)
        len = h * 256 + l
        at = at + 2
    elseif len == 127 then
        if avail < 10 then return nil end
        local b = { buf:byte(at, at + 7) }
        if b[1] ~= 0 or b[2] ~= 0 or b[3] ~= 0 or b[4] ~= 0 then return nil, "frame too big" end
        len = ((b[5] * 256 + b[6]) * 256 + b[7]) * 256 + b[8]
        at = at + 8
    end
    if len > ws.MAX_MESSAGE then return nil, "frame too big" end
    local mask
    if masked then
        if #buf < at + 3 then return nil end
        mask = buf:sub(at, at + 3)
        at = at + 4
    end
    if #buf < at + len - 1 then return nil end
    local payload = buf:sub(at, at + len - 1)
    if mask then payload = apply_mask(payload, mask) end
    return { fin = band(b1, 0x80) ~= 0, opcode = band(b1, 0x0f), payload = payload }, at + len
end

local function parse_url(url)
    local scheme, rest = url:match("^(wss?)://(.+)$")
    if not scheme then return nil end
    local authority, path = rest:match("^([^/]+)(/.*)$")
    if not authority then authority, path = rest, "/" end
    local host, port = authority:match("^(.-):(%d+)$")
    if not host then host = authority end
    if host == "" then return nil end
    return {
        scheme = scheme,
        tls = scheme == "wss",
        host = host,
        port = tonumber(port) or (scheme == "wss" and 443 or 80),
        path = path,
        explicit_port = port ~= nil,
    }
end
ws.parse_url = parse_url

function ws.handshake_request(target, key, bearer)
    local host = target.host
    if target.explicit_port then host = host .. ":" .. target.port end
    local lines = {
        "GET " .. target.path .. " HTTP/1.1",
        "Host: " .. host,
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: " .. key,
        "Sec-WebSocket-Version: 13",
    }
    if bearer and bearer ~= "" then lines[#lines + 1] = "Authorization: Bearer " .. bearer end
    return table.concat(lines, "\r\n") .. "\r\n\r\n"
end

local Conn = {}
Conn.__index = Conn

local function no_data(err) return err == "timeout" or err == "wantread" or err == "wantwrite" end

function Conn:settimeout(t) return self.raw:settimeout(t) end
function Conn:getfd() return self.raw.getfd and self.raw:getfd() or -1 end

function Conn:_write(opcode, payload)
    local frame = ws.encode_frame(opcode, payload, self.random(4))
    local sent, err = self.raw:send(frame)
    if not sent then return nil, err end
    return #frame
end

function Conn:send(data)
    if self.closed then return nil, "closed" end
    if data:sub(-1) == "\n" then data = data:sub(1, -2) end
    local ok, err = self:_write(ws.OP_TEXT, data)
    if not ok then return nil, err end
    return #data + 1
end

function Conn:close()
    if not self.closed then
        self.closed = true
        -- Best effort: a gateway that hears a close frame drops us at once, not on silence.
        pcall(self.raw.settimeout, self.raw, 1)
        pcall(self._write, self, ws.OP_CLOSE, string.char(0x03, 0xe8)) -- 1000, normal
    end
    return pcall(self.raw.close, self.raw)
end

-- Reads whatever the socket holds now and turns complete frames into messages.
function Conn:_pump()
    while true do
        local data, err, partial = self.raw:receive(ws.READ_CHUNK)
        local got = data or partial
        if got and #got > 0 then self.buf = self.buf .. got end
        if not data then
            if no_data(err) then break end
            return nil, err
        end
    end
    local pos = 1
    while true do
        local frame, nxt = ws.decode_frame(self.buf, pos)
        if not frame then
            if nxt then return nil, nxt end -- nxt holds the error
            break
        end
        pos = nxt
        local op = frame.opcode
        if op == ws.OP_PING then
            local ok, err = self:_write(ws.OP_PONG, frame.payload)
            if not ok then return nil, err end
        elseif op == ws.OP_PONG then -- nothing to do: any frame counts as hearing the gateway
        elseif op == ws.OP_CLOSE then
            local code = #frame.payload >= 2 and (frame.payload:byte(1) * 256 + frame.payload:byte(2)) or 1005
            self.buf = ""
            return nil, "closed by gateway (" .. code .. ")"
        elseif op == ws.OP_TEXT or op == ws.OP_BINARY then
            if self.fragments then return nil, "new message inside a fragmented one" end
            if frame.fin then
                self.queue[#self.queue + 1] = frame.payload
            else
                self.fragments, self.fragment_size = { frame.payload }, #frame.payload
            end
        elseif op == ws.OP_CONT then
            if not self.fragments then return nil, "continuation without a message" end
            self.fragments[#self.fragments + 1] = frame.payload
            self.fragment_size = self.fragment_size + #frame.payload
            if self.fragment_size > ws.MAX_MESSAGE then return nil, "message too big" end
            if frame.fin then
                self.queue[#self.queue + 1] = table.concat(self.fragments)
                self.fragments = nil
            end
        else
            return nil, "unknown opcode " .. op
        end
    end
    if pos > 1 then self.buf = self.buf:sub(pos) end
    return true
end

function Conn:receive()
    if self.closed then return nil, "closed" end
    if #self.queue == 0 then
        if self.failed then return nil, self.failed end
        local ok, err = self:_pump()
        -- Messages that arrived before the error are still handed out first.
        if not ok then self.failed = err end
        if #self.queue == 0 and self.failed then return nil, self.failed end
    end
    local msg = table.remove(self.queue, 1)
    if msg then return msg end
    return nil, "timeout", ""
end

--[[
Upgrades raw, a connected socket with a timeout set, to a WebSocket.
opts: target (from parse_url), bearer, random(n) -> n bytes, sha1_hex(s) -> hex
-> conn | nil, err, kind   kind "rejected" means the gateway said no (wrong key);
                           retrying soon will not help.
]]
function ws.handshake(raw, opts)
    local key = ws.base64(opts.random(16))
    local sent, err = raw:send(ws.handshake_request(opts.target, key, opts.bearer))
    if not sent then return nil, "handshake send failed: " .. tostring(err) end
    local status_line, rerr = raw:receive("*l")
    if not status_line then return nil, "no handshake reply: " .. tostring(rerr) end
    local status = tonumber(status_line:match("^HTTP/%d%.%d (%d%d%d)"))
    local headers = {}
    while true do
        local line, herr = raw:receive("*l")
        if not line then return nil, "handshake reply cut short: " .. tostring(herr) end
        if line == "" or line == "\r" then break end
        local name, value = line:match("^([^:]+):%s*(.-)%s*$")
        if name then headers[name:lower()] = value end
    end
    if status == 401 or status == 403 then
        return nil, "gateway rejected the device key (HTTP " .. status .. ")", "rejected"
    end
    if status ~= 101 then return nil, "handshake failed: " .. tostring(status_line) end
    if (headers.upgrade or ""):lower() ~= "websocket" then return nil, "handshake: no Upgrade: websocket" end
    if opts.sha1_hex and headers["sec-websocket-accept"] ~= ws.accept(key, opts.sha1_hex) then
        return nil, "handshake: bad Sec-WebSocket-Accept"
    end
    return setmetatable({ raw = raw, random = opts.random, buf = "", queue = {} }, Conn)
end

return ws
