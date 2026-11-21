--[[--
Requests and answers of the gdrive-epub server, without KOReader.

Builds the URL and headers of every call the plugin makes and turns an
answer (status and body) into a result the screens can act on. The HTTP
itself happens elsewhere (gdriveepub_http.lua), so this file runs in any
LuaJIT or Lua 5.1:

    local Api = require("gdriveepub_api")
    local req = Api.listRequest("https://server.example", key, { view = "search", q = "dbt" })
    -- req = { method = "GET", url = ".../api/files?q=dbt&view=search", headers = { ... } }
    local res = Api.parse(status, body, json.decode)
    -- res.ok, res.data, or res.error = "google_reauth" | "device_unauthorized" |
    --   "too_large" | "network" | "server" | ..., res.message, res.signin_url

Lua 5.1 only.
]]

local Api = {}

--- The server URL as typed: trimmed, no trailing slash; nil when empty or
--- not http(s).
function Api.normaliseBaseUrl(url)
    if type(url) ~= "string" then return nil end
    url = url:match("^%s*(.-)%s*$")
    url = url:gsub("/+$", "")
    if url == "" then return nil end
    if not url:match("^https?://[^/%s]+") then return nil end
    return url
end

--- Percent-encode one query value (RFC 3986 unreserved characters kept).
function Api.encode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

--- "a=1&b=2" from a table, keys sorted so the URL is predictable; nil and
--- empty values are left out.
function Api.query(params)
    local keys = {}
    for k, v in pairs(params or {}) do
        if v ~= nil and v ~= "" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = Api.encode(k) .. "=" .. Api.encode(params[k])
    end
    return table.concat(parts, "&")
end

local function withQuery(url, params)
    local q = Api.query(params)
    if q == "" then return url end
    return url .. "?" .. q
end

local function authHeaders(key)
    return { ["Authorization"] = "Bearer " .. tostring(key), ["Accept"] = "application/json" }
end

function Api.healthRequest(base)
    return { method = "GET", url = base .. "/health", headers = { ["Accept"] = "application/json" } }
end

function Api.pairStartRequest(base)
    return { method = "POST", url = base .. "/pair/start", body = "{}",
        headers = { ["Accept"] = "application/json", ["Content-Type"] = "application/json" } }
end

function Api.pairPollRequest(base, pair_id, secret)
    return { method = "GET",
        url = withQuery(base .. "/pair/" .. Api.encode(pair_id) .. "/poll", { secret = secret }),
        headers = { ["Accept"] = "application/json" } }
end

function Api.statusRequest(base, key)
    return { method = "GET", url = base .. "/api/status", headers = authHeaders(key) }
end

--- The list call. `params` is what gdriveepub_state.lua's State.params returns.
function Api.listRequest(base, key, params)
    return { method = "GET", url = withQuery(base .. "/api/files", params), headers = authHeaders(key) }
end

function Api.infoRequest(base, key, file_id)
    return { method = "GET", url = base .. "/api/files/" .. Api.encode(file_id), headers = authHeaders(key) }
end

function Api.downloadRequest(base, key, file_id)
    local h = authHeaders(key)
    h["Accept"] = "*/*"
    return { method = "GET", url = base .. "/api/files/" .. Api.encode(file_id) .. "/download", headers = h }
end

--- Turn an answer into { ok = true, data = <decoded body> } or
--- { ok = false, error = <code>, message = <text>, signin_url = <url or nil>, status = <n> }.
-- `res` is the HTTP result { status, body, err }; `decode` is a JSON decoder
-- that may throw.
function Api.parse(res, decode)
    if not res or res.err or not res.status then
        return { ok = false, error = "network", message = res and res.err or "no answer" }
    end
    local data
    if res.body and res.body ~= "" then
        local okd, d = pcall(decode, res.body)
        if okd and type(d) == "table" then data = d end
    end
    if res.status >= 200 and res.status < 300 then
        if not data then
            return { ok = false, error = "bad_answer", status = res.status, message = "The server sent an answer that is not JSON." }
        end
        return { ok = true, data = data, status = res.status }
    end
    local out = { ok = false, status = res.status }
    if data and type(data.error) == "string" then
        out.error = data.error
        out.message = type(data.message) == "string" and data.message or nil
        out.signin_url = type(data.signin_url) == "string" and data.signin_url or nil
    elseif res.status == 404 then
        out.error = "not_found"
    else
        out.error = "server"
    end
    out.message = out.message or ("HTTP " .. tostring(res.status))
    return out
end

local function str(v) return type(v) == "string" and v ~= "" and v or nil end

--- One file of `/api/files` or the answer of `/api/files/<id>`, or nil if it has no id.
--- `modifiedTime` and `modified_time` hold the same RFC 3339 string.
function Api.item(f)
    if type(f) ~= "table" or not str(f.id) then return nil end
    local modified = str(f.modifiedTime) or str(f.modified_time)
    return {
        id = f.id,
        name = str(f.name) or "Untitled",
        kind = (f.kind == "pdf" or f.kind == "epub") and f.kind or "doc",
        modifiedTime = modified,
        modified_time = modified,
        created_time = str(f.created_time),
        viewed_time = str(f.viewed_time),
        size = type(f.size) == "number" and f.size or tonumber(f.size),
        trashed = f.trashed == true or nil,
    }
end

--- Files from a list answer, only well-formed entries; plus the next page token.
function Api.files(data)
    local out = {}
    if type(data) ~= "table" or type(data.files) ~= "table" then return out, nil end
    for _, f in ipairs(data.files) do
        local item = Api.item(f)
        if item then out[#out + 1] = item end
    end
    local token = data.next_page_token
    if type(token) ~= "string" or token == "" then token = nil end
    return out, token
end

--- Pairing poll answer: "pending" | "approved" (with key) | "expired" | "error".
function Api.pairPollResult(parsed)
    if parsed.ok then
        local d = parsed.data
        if d.status == "approved" and type(d.device_key) == "string" and d.device_key ~= "" then
            return "approved", d.device_key
        end
        if d.status == "pending" then return "pending" end
        return "error"
    end
    if parsed.status == 404 or parsed.error == "expired" or parsed.error == "not_found" then
        return "expired"
    end
    return "error"
end

--- True when `parsed` from /pair/start carries what the pairing screen needs.
function Api.validPairing(parsed)
    if not parsed.ok then return false end
    local d = parsed.data
    return type(d.pair_id) == "string" and type(d.poll_secret) == "string" and type(d.url) == "string"
end

return Api
