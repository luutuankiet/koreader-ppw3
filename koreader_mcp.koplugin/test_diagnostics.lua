-- Run with: luajit test_diagnostics.lua (from this folder). Needs no KOReader, only tar.
package.path = "./?.lua;" .. package.path
local d = require("diagnostics")

local fails = 0
local function check(name, cond)
    if not cond then
        fails = fails + 1
        print("FAIL " .. name)
    else
        print("ok   " .. name)
    end
end
local function hides(name, input, secret, secrets)
    local out = d.redact(input, secrets)
    check(name, not out:find(secret, 1, true))
end

-- redaction
local SERIAL = "G090AB12CD34EF56"
hides("serial", "usid is " .. SERIAL .. " ok", SERIAL, { SERIAL })
hides("serial lower case", "usid " .. SERIAL:lower(), SERIAL:lower(), { SERIAL })
hides("key=value", "GET /x?password=hunter2&a=1", "hunter2")
hides("Lua table dump", '["password"] = "hun ter2",', "hun ter2")
hides("json", '{"api_key":"abc123"}', "abc123")
hides("colon", "Token: abc123", "abc123")
hides("longer name", "access_token=abc123", "abc123")
hides("camel case", "userPassword = hunter2", "hunter2")
hides("GoogleLogin", "Authorization: GoogleLogin auth=abc123", "abc123")
hides("bare bearer", "sent Bearer abc.123 to", "abc.123")
hides("cookie to end of line", "Cookie: a=one; b=two", "two")
hides("url userinfo", "https://me:hunter2@rss.lan/api", "hunter2")
hides("kosync userkey", 'userkey = "abc123"', "abc123")
hides("username", 'username = "ken"', "ken")
check("author survives", d.redact('author = "Tolkien"') == 'author = "Tolkien"')
check("plain url survives", d.redact("http://rss.lan/api") == "http://rss.lan/api")
check("normal log survives", d.redact("07/01 INFO opened book.epub\n") == "07/01 INFO opened book.epub\n")
check("rest of line survives", d.redact("password=x next") == "password=<redacted> next")
check("empty serial is ignored", d.redact("abc", { "" }) == "abc")

local snap = d.redactSnapshot({ window = "w", nodes = {
    { kind = "input", text = "hunter2" },
    { kind = "input", text = "hint: Password" },
    { kind = "button", text = "OK" },
    { kind = "text", text = SERIAL },
} }, { SERIAL })
check("input text hidden", snap.nodes[1].text == "<redacted>")
check("input hint kept", snap.nodes[2].text == "hint: Password")
check("button kept", snap.nodes[3].text == "OK")
check("serial in snapshot hidden", snap.nodes[4].text == "<serial>")

-- versions and names
check("quoted version", d.parseMetaVersion('version = "0.3.0",') == "0.3.0")
check("number version", d.parseMetaVersion("version = 1.5,") == "1.5")
check("no version", d.parseMetaVersion('fullname = _("Hello"),') == nil)
check("other key ending in version", d.parseMetaVersion('min_version = "9",') == nil)
check("safe name", d.safeName("my kindle/../x") == "my_kindle_.._x")
check("leading dot", d.safeName(".hidden") == "_hidden")

-- log offset
local tmp = os.tmpname()
local function setLog(text)
    local f = io.open(tmp, "wb"); f:write(text); f:close()
end
setLog("one\ntwo\nunfinis")
local r = d.readNewLog(tmp, 0)
check("complete lines only", r.text == "one\ntwo\n" and r.next_offset == 8)
setLog("one\ntwo\nunfinished\nthree\n")
r = d.readNewLog(tmp, 8)
check("only what is new", r.text == "unfinished\nthree\n" and r.from == 8)
r = d.readNewLog(tmp, r.next_offset)
check("nothing new", r.text == "" and r.next_offset == 25)
r = d.readNewLog(tmp, 9999)
check("rotated log restarts", r.restarted and r.from == 0 and r.text:sub(1, 4) == "one\n")
r = d.readNewLog(tmp, 0, 10)
check("cap keeps the newest whole lines", r.text == "three\n" and r.skipped_bytes == 19 and r.next_offset == 25)
r = d.readNewLog("/nonexistent/crash.log", 7)
check("missing log keeps the offset", r.missing and r.next_offset == 7)
os.remove(tmp)

-- build: a failed send must not move the offset, and the secrets stay out
local dir = os.tmpname()
os.remove(dir)
os.execute("mkdir -p " .. dir)
local log_path, offset_path, usid = dir .. "/crash.log", dir .. "/offset", dir .. "/usid"
local function write(path, text)
    local f = io.open(path, "wb"); f:write(text); f:close()
end
write(usid, SERIAL .. "\n")
write(log_path, "first " .. SERIAL .. " password=hunter2\n")
-- The real encoder lives in server.lua, which needs the socket library.
local function encode(t)
    if type(t) ~= "table" then return tostring(t) end
    local parts = {}
    for k, v in pairs(t) do parts[#parts + 1] = tostring(k) .. "=" .. encode(v) end
    return "{" .. table.concat(parts, ",") .. "}"
end
local function build(screenshot)
    return d.build({
        json_encode = encode,
        log_path = log_path, offset_path = offset_path, usid_path = usid,
        stage_dir = dir .. "/stage", bundle_path = dir .. "/b.tar.gz",
        info = { device = "t" },
        snapshot = function() return { window = "w", total = 0, nodes = {} } end,
        screenshot = screenshot or function(path) write(path, "PNG"); return true end,
    })
end
local function unpacked(name)
    os.execute("rm -rf " .. dir .. "/x; mkdir " .. dir .. "/x; tar -xzf " .. dir .. "/b.tar.gz -C " .. dir .. "/x")
    local f = io.open(dir .. "/x/" .. name, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end
local built = assert(build())
local first = unpacked("crash.log")
check("bundle has the log", first:find("first", 1, true) ~= nil)
check("no serial in the bundle log", not first:find(SERIAL, 1, true))
check("no password in the bundle log", not first:find("hunter2", 1, true))
check("bundle has all parts", unpacked("screenshot.png") == "PNG" and unpacked("snapshot.json") and unpacked("manifest.json"))
check("nothing remembered before commit", d.readOffset(offset_path) == 0)
built = assert(build())
check("uncommitted send repeats its lines", unpacked("crash.log") == first)
check("commit", d.commit(built, offset_path))
write(log_path, "first " .. SERIAL .. " password=hunter2\nsecond\n")
assert(build(function() return nil, "no screen" end))
check("second send has only the new line", unpacked("crash.log") == "second\n")
check("failed part is reported", unpacked("manifest.json"):find("no screen", 1, true) ~= nil)
check("failed part leaves the rest", unpacked("screenshot.png") == nil and unpacked("snapshot.json") ~= nil)
os.execute("rm -rf " .. dir)

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
