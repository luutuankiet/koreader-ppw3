-- "Send diagnostics": build one .tar.gz and PUT it to the gateway inbox (issue #39).
--
-- Bundle: manifest.json (versions, log range), crash.log (only lines new since
-- the last successful send), snapshot.json (ui_agent.snapshot), screenshot.png.
-- A missing part is listed under manifest.errors; the rest still goes out.
--
-- Everything textual passes redact() before it reaches the disk, because
-- crash.log holds whatever any plugin chose to log. The screenshot cannot be
-- filtered; the bundle captures what is on screen when the button is pressed.
local M = {}

M.LOG_MAX_BYTES = 512 * 1024
M.USID_PATH = "/proc/usid"
M.STAGE_DIR = "/tmp/koreader_mcp_diag"
M.BUNDLE_PATH = "/tmp/koreader_mcp_diag.tar.gz"
local UPLOAD_TIMEOUT_S = 30
local REDACTED = "<redacted>"

-- ----------------------------------------------------------------- redaction
local function anyCase(word)
    return (word:gsub("%a", function(c)
        return "[" .. c:lower() .. c:upper() .. "]"
    end))
end

local function escapePattern(s)
    return (s:gsub("%p", "%%%0"))
end

-- Matched inside longer names too: access_token, userPassword, api_secret.
local KEYS_ANYWHERE = { "password", "passwd", "secret", "token", "apikey", "api_key", "userkey", "sessionid" }
-- Whole words only: "author" and "users" are not credentials.
local KEYS_WORD = { "auth", "sid", "pwd", "pass", "user", "username", "login" }
-- The whole rest of the line is the secret, and it may hold spaces.
local KEYS_TO_EOL = { "authorization", "cookie" }

local SECRET_PATTERNS = {}
do
    local function add(prefix)
        -- key, closing quote or bracket of a dumped table key, then = or :
        local head = "(" .. prefix .. "[\"'%]]*%s*[=:]%s*)"
        SECRET_PATTERNS[#SECRET_PATTERNS + 1] = head .. '"[^"\n]*"'
        SECRET_PATTERNS[#SECRET_PATTERNS + 1] = head .. "'[^'\n]*'"
        SECRET_PATTERNS[#SECRET_PATTERNS + 1] = head .. "[^%s,;&})\"']+"
    end
    for _, k in ipairs(KEYS_ANYWHERE) do add(anyCase(k)) end
    for _, k in ipairs(KEYS_WORD) do add("%f[%w]" .. anyCase(k)) end
end

--- Remove serials and credentials from a text. `secrets` is a list of exact
--- strings that must not survive (the device serial); never log them.
function M.redact(text, secrets)
    for _, secret in ipairs(secrets or {}) do
        if secret ~= "" then
            text = text:gsub(escapePattern(secret), "<serial>")
            text = text:gsub(escapePattern(secret:lower()), "<serial>")
        end
    end
    for _, k in ipairs(KEYS_TO_EOL) do
        text = text:gsub("(" .. anyCase(k) .. "[\"'%]]*%s*[=:]%s*)[^\n]*", "%1" .. REDACTED)
    end
    text = text:gsub(anyCase("bearer") .. "%s+[%w%._~%+/=-]+", "Bearer " .. REDACTED)
    -- https://user:pass@host
    text = text:gsub("(%a[%w%+%.-]*://)[^/%s@]+@", "%1" .. REDACTED .. "@")
    for _, pattern in ipairs(SECRET_PATTERNS) do
        text = text:gsub(pattern, "%1" .. REDACTED)
    end
    return text
end

--- The whole serial, for redaction only. Empty off a Kindle.
function M.readSerial(path)
    local f = io.open(path or M.USID_PATH, "r")
    if not f then return "" end
    local serial = f:read("*a") or ""
    f:close()
    return (serial:gsub("%s", ""))
end

--- A typed value can be a password, so an input field keeps only its hint.
function M.redactSnapshot(snap, secrets)
    if not snap then return snap end
    snap.window = M.redact(snap.window or "", secrets)
    for _, node in ipairs(snap.nodes or {}) do
        if node.kind == "input" and node.text ~= "" and node.text:sub(1, 6) ~= "hint: " then
            node.text = REDACTED
        else
            node.text = M.redact(node.text or "", secrets)
        end
    end
    return snap
end

-- ------------------------------------------------------------------ crash.log
function M.readOffset(path)
    local f = io.open(path, "r")
    if not f then return 0 end
    local n = tonumber(f:read("*l") or "")
    f:close()
    return (n and n >= 0) and n or 0
end

function M.writeOffset(path, offset)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(string.format("%d\n", offset))
    f:close()
    return true
end

--- Whole lines of the log after `offset`, at most max_bytes (the newest ones).
--- Returns { text, from, next_offset, skipped_bytes, restarted, missing }.
--- An unfinished last line stays for the next send. A log shorter than the
--- offset was rotated by the launcher, so it is read from its start.
function M.readNewLog(path, offset, max_bytes)
    max_bytes = max_bytes or M.LOG_MAX_BYTES
    local f = io.open(path, "rb")
    if not f then
        return { text = "", from = 0, next_offset = offset, skipped_bytes = 0, restarted = false, missing = true }
    end
    local size = f:seek("end")
    local restarted = size < offset
    if restarted then offset = 0 end
    local from = offset
    local skipped = 0
    if size - offset > max_bytes then
        from = size - max_bytes
        skipped = from - offset
    end
    f:seek("set", from)
    local data = f:read("*a") or ""
    f:close()
    if skipped > 0 then
        -- Landed inside a line: start at the next one.
        local first = data:find("\n", 1, true)
        if first then
            data = data:sub(first + 1)
            from = from + first
            skipped = skipped + first
        end
    end
    local last = #data
    while last > 0 and data:byte(last) ~= 10 do last = last - 1 end
    return {
        text = data:sub(1, last),
        from = from,
        next_offset = from + last,
        skipped_bytes = skipped,
        restarted = restarted,
        missing = false,
    }
end

-- ------------------------------------------------------------------- versions
--- Read as text, never run: a broken or hostile _meta.lua must not break the send.
function M.parseMetaVersion(text)
    return text:match("%f[%w_]version%s*=%s*[\"']?([%w%._%-]+)")
end

--- { name = version or "unknown" } for every *.koplugin under the given folders.
function M.pluginVersions(dirs)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then return {} end
    local plugins = {}
    for _, dir in ipairs(dirs) do
        if lfs.attributes(dir, "mode") == "directory" then
            for entry in lfs.dir(dir) do
                local name = entry:match("^(.+)%.koplugin$")
                if name then
                    local meta = io.open(dir .. "/" .. entry .. "/_meta.lua", "r")
                    local version
                    if meta then
                        version = M.parseMetaVersion(meta:read("*a") or "")
                        meta:close()
                    end
                    plugins[name] = version or "unknown"
                end
            end
        end
    end
    return plugins
end

-- --------------------------------------------------------------------- bundle
--- A path segment the inbox accepts (DEVICE_RE in kindle-gateway/src/package-host.ts).
function M.safeName(name)
    local safe = tostring(name or "unknown"):gsub("[^%w%._-]", "_"):sub(1, 64)
    return (safe:gsub("^%.", "_"))
end

local function writeFile(path, content)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    f:write(content)
    f:close()
    return true
end

local function succeeded(status) return status == 0 or status == true end

--- Build the bundle. opts:
---   json_encode, log_path, offset_path, usid_path, stage_dir, bundle_path,
---   info        table merged into the manifest (versions, device),
---   snapshot()  -> table or nil, err
---   screenshot(path) -> true or nil, err
--- Returns { path, size, next_offset, log } or nil, err. Nothing is remembered
--- yet: call M.commit after the upload, so a failed send repeats its lines.
function M.build(opts)
    local stage = opts.stage_dir or M.STAGE_DIR
    local bundle = opts.bundle_path or M.BUNDLE_PATH
    local secrets = { M.readSerial(opts.usid_path) }
    if not succeeded(os.execute("rm -rf " .. stage .. " " .. bundle .. " && mkdir -p " .. stage)) then
        return nil, "cannot create " .. stage
    end

    local errors = {}
    local files = { "manifest.json", "crash.log" }

    local log = M.readNewLog(opts.log_path, M.readOffset(opts.offset_path))
    if log.missing then errors[#errors + 1] = "no log file at " .. opts.log_path end
    local ok, err = writeFile(stage .. "/crash.log", M.redact(log.text, secrets))
    if not ok then return nil, "cannot write crash.log: " .. tostring(err) end

    local snap_ok, snap, snap_err = pcall(opts.snapshot)
    if snap_ok and snap then
        local encoded = opts.json_encode(M.redactSnapshot(snap, secrets))
        ok, err = writeFile(stage .. "/snapshot.json", encoded)
        if ok then files[#files + 1] = "snapshot.json" else errors[#errors + 1] = tostring(err) end
    else
        errors[#errors + 1] = "snapshot: " .. tostring(snap_ok and snap_err or snap)
    end

    local shot_path = stage .. "/screenshot.png"
    local shot_ok, shot, shot_err = pcall(opts.screenshot, shot_path)
    if shot_ok and shot then
        files[#files + 1] = "screenshot.png"
    else
        errors[#errors + 1] = "screenshot: " .. tostring(shot_ok and shot_err or shot)
    end

    local manifest = {}
    for k, v in pairs(opts.info or {}) do manifest[k] = v end
    manifest.log = {
        from = log.from,
        to = log.next_offset,
        skipped_bytes = log.skipped_bytes,
        restarted = log.restarted,
        missing = log.missing,
    }
    manifest.errors = errors
    ok, err = writeFile(stage .. "/manifest.json", M.redact(opts.json_encode(manifest), secrets))
    if not ok then return nil, "cannot write manifest.json: " .. tostring(err) end

    -- Only fixed names reach the shell. busybox tar on the Kindle takes the same flags.
    local cmd = "cd " .. stage .. " && tar -czf " .. bundle .. " " .. table.concat(files, " ")
    if not succeeded(os.execute(cmd)) then return nil, "tar failed" end
    local out = io.open(bundle, "rb")
    if not out then return nil, "tar wrote no bundle" end
    local size = out:seek("end")
    out:close()
    os.execute("rm -rf " .. stage)
    return { path = bundle, size = size, next_offset = log.next_offset, log = log }
end

function M.commit(built, offset_path)
    return M.writeOffset(offset_path, built.next_offset)
end

--- PUT the bundle; returns true or nil, err. The caller makes sure WiFi is up.
--- bearer, when set, is the device key the gateway asks for.
function M.upload(gateway_url, device, built, stamp, bearer)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local file, err = io.open(built.path, "rb")
    if not file then return nil, tostring(err) end
    local old_timeout = http.TIMEOUT
    http.TIMEOUT = UPLOAD_TIMEOUT_S
    local headers = {
        ["Content-Type"] = "application/gzip",
        ["Content-Length"] = tostring(built.size),
    }
    if bearer and bearer ~= "" then headers["Authorization"] = "Bearer " .. bearer end
    -- ltn12.source.file closes the file.
    local result, code = http.request({
        url = gateway_url .. "/inbox/" .. device .. "/" .. stamp .. ".tar.gz",
        method = "PUT",
        headers = headers,
        source = ltn12.source.file(file),
        sink = ltn12.sink.null(),
    })
    http.TIMEOUT = old_timeout
    if result and code == 201 then return true end
    return nil, "gateway replied " .. tostring(code)
end

return M
