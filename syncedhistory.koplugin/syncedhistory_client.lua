--[[--
Server client for the synced reading list.

Talks to the progress sync server that KOReader's built-in progress sync
(kosync.koplugin) is logged into, with that plugin's server, user name and
user key. Three routes, all added to kosyncd for this plugin:

    GET    /syncs/list                  every book of the user that has progress;
                                        a book saved under several file names is
                                        one item whose aliases list every key
    PUT    /syncs/documents             {document, filename}: remember a book's file name
    DELETE /syncs/documents/{document}  forget one key: its progress and file name

Every dependency is injected, so the module runs outside KOReader:

    local Client = require("syncedhistory_client")
    local client = Client.new{
        kosync = function() return kosync_settings_table end,
        request = function(req, callback) ... end, -- see syncedhistory_http.lua
        md5 = require("ffi/sha2").md5,
        json_decode = require("json").decode,
        json_encode = require("json").encode,
        settings = LuaSettings:open(path),     -- optional, holds the cache
    }
    client:fetchList(function(list, info) ... end)
    client:pushDocument("/mnt/us/documents/Dune.epub")
    client:removeDocuments({ key1, key2 }, function(ok, info) ... end)

Never log or show the user key. Lua 5.1 only.
]]

local LocalIndex = require("syncedhistory_localindex")

local Client = {}
Client.__index = Client

Client.TIMEOUT = 15 -- seconds; a cold start of the server takes about 11.5 s
Client.CACHE_KEY = "server_list"
-- kosync.koplugin/main.lua, CHECKSUM_METHOD.FILENAME
Client.CHECKSUM_FILENAME = 1
-- kosync.koplugin/KOSyncClient.lua, the GinClient middleware
Client.ACCEPT = "application/vnd.koreader.v1+json"

Client.MSG_LOGIN = "Synced reading list uses the built-in progress sync. Set its custom sync server and log in there first."
Client.MSG_METHOD = "Progress sync must match documents by file name (Progress sync > Document matching method)."
Client.MSG_CACHED = "Could not reach the sync server. Showing the cached list."
Client.MSG_NO_CACHE = "Could not reach the sync server, and there is no cached list yet."
Client.MSG_REMOVE_FAILED = "Could not remove the book from the sync server. It is still in the list."

local function noop() end

--[[--
Create a client.

@tparam table opts
  kosync       (required) function() -> the built-in sync settings table
               (custom_server, username, userkey, checksum_method), or nil
  request      (required) function(req, callback); req has method, url,
               headers, body, timeout; callback(res) with res.status (number
               or nil), res.body (string or nil), res.err (string or nil)
  md5          (required) function(string) -> lowercase hex digest
  json_decode  (required) function(string) -> value; may raise
  json_encode  (required) function(value) -> string
  settings     (optional) readSetting(k), saveSetting(k, v), flush()
  log          (optional) table with info, warn, dbg (KOReader's logger)
  clock        (optional) function() -> seconds since the epoch
]]
function Client.new(opts)
    assert(opts and opts.kosync, "Client.new: kosync is required")
    assert(opts.request, "Client.new: request is required")
    assert(opts.md5, "Client.new: md5 is required")
    assert(opts.json_decode and opts.json_encode, "Client.new: json_decode and json_encode are required")
    local log = opts.log or {}
    return setmetatable({
        kosync = opts.kosync,
        request = opts.request,
        md5 = opts.md5,
        json_decode = opts.json_decode,
        json_encode = opts.json_encode,
        settings = opts.settings,
        log = { info = log.info or noop, warn = log.warn or noop, dbg = log.dbg or noop },
        clock = opts.clock or os.time,
    }, Client)
end

--- The sync key of a book: md5 of its file name without the folder, the same
-- as LocalIndex:keyFor and the built-in sync's file-name method.
function Client:keyFor(path_or_name)
    return self.md5(LocalIndex.basename(path_or_name))
end

--[[--
Server and credentials from the built-in sync settings.

@treturn table|nil { server = base URL without trailing slash, username, userkey }
@treturn string|nil the message to show when the client cannot be used
@treturn string|nil "login" or "method"
]]
function Client:credentials()
    local ok, s = pcall(self.kosync)
    if not ok or type(s) ~= "table" then s = {} end
    local server, user, key = s.custom_server, s.username, s.userkey
    if type(server) ~= "string" or server:match("^%s*$") or server:match("^https?://$")
        or type(user) ~= "string" or user == ""
        or type(key) ~= "string" or key == "" then
        return nil, Client.MSG_LOGIN, "login"
    end
    if s.checksum_method ~= Client.CHECKSUM_FILENAME then
        return nil, Client.MSG_METHOD, "method"
    end
    server = server:gsub("^%s+", ""):gsub("[%s/]+$", "")
    return { server = server, username = user, userkey = key }
end

-- Same headers as KOSyncClient: GinClient (accept) plus KOSyncAuth, plus
-- the content type Spore's Format.JSON middleware sets on a body.
local function headersFor(creds, with_body)
    local h = {
        ["accept"] = Client.ACCEPT,
        ["x-auth-user"] = creds.username,
        ["x-auth-key"] = creds.userkey,
    }
    if with_body then h["content-type"] = "application/json" end
    return h
end

-- Keep only plain fields, so the cache never holds a JSON null sentinel
-- that LuaSettings cannot write. aliases stays nil when the server sent
-- none (a server older than the merge), so callers fall back to document.
local function str(v) return type(v) == "string" and v or nil end
local function num(v) return type(v) == "number" and v or nil end

local function cleanAliases(list)
    if type(list) ~= "table" then return nil end
    local out = {}
    for _, a in ipairs(list) do
        if type(a) == "table" and type(a.document) == "string" and a.document ~= "" then
            out[#out + 1] = { document = a.document, filename = str(a.filename) }
        end
    end
    return #out > 0 and out or nil
end

local function cleanRow(row)
    if type(row) ~= "table" or type(row.document) ~= "string" or row.document == "" then
        return nil
    end
    return {
        document = row.document,
        percentage = num(row.percentage),
        device = str(row.device),
        device_id = str(row.device_id),
        timestamp = num(row.timestamp),
        filename = str(row.filename),
        aliases = cleanAliases(row.aliases),
    }
end
Client._cleanRow = cleanRow

--- The cached list and when it was fetched (seconds since the epoch), or nil.
function Client:cachedList()
    if not self.settings then return nil end
    local saved = self.settings:readSetting(Client.CACHE_KEY)
    if type(saved) ~= "table" or type(saved.items) ~= "table" then return nil end
    return saved.items, saved.fetched_at
end

function Client:saveList(items)
    if not self.settings then return end
    self.settings:saveSetting(Client.CACHE_KEY, { items = items, fetched_at = self.clock() })
    self.settings:flush()
end

--[[--
Fetch the user's list from the server, without blocking.

Returns at once. `callback(list, info)` runs when the request ends:
  - fresh:  list from the server, info = { fresh = true }
  - failed: the cached list (or nil), info = { cached = true|false,
            status = number|nil, err = string|nil, message = text to show }
  - unusable settings: list = cached list or nil, info = { reason = "login" or
            "method", message = text to show }; no request is made.
]]
function Client:fetchList(callback)
    callback = callback or noop
    local creds, message, reason = self:credentials()
    if not creds then
        self.log.warn("syncedhistory: list fetch skipped:", reason)
        callback(self:cachedList(), { reason = reason, message = message })
        return
    end
    local url = creds.server .. "/syncs/list"
    self.log.dbg("syncedhistory: GET", url)
    self.request({
        method = "GET",
        url = url,
        headers = headersFor(creds, false),
        timeout = Client.TIMEOUT,
    }, function(res)
        res = res or {}
        local list
        if res.status == 200 and type(res.body) == "string" then
            local ok, decoded = pcall(self.json_decode, res.body)
            if ok and type(decoded) == "table" then
                list = {}
                for _, row in ipairs(decoded) do
                    local clean = cleanRow(row)
                    if clean then list[#list + 1] = clean end
                end
            end
        end
        if list then
            self:saveList(list)
            self.log.info("syncedhistory: fetched", #list, "books")
            callback(list, { fresh = true })
            return
        end
        self.log.warn("syncedhistory: list fetch failed:", res.status, res.err)
        local cached = self:cachedList()
        callback(cached, {
            cached = cached ~= nil,
            status = res.status,
            err = res.err,
            message = cached and Client.MSG_CACHED or Client.MSG_NO_CACHE,
        })
    end)
end

--[[--
Tell the server the file name of a book, fire and forget.

Failures are only logged. Does nothing when the built-in sync settings are
unusable. `done(ok)` is optional, for tests and checks.
]]
function Client:pushDocument(path, done)
    done = done or noop
    local filename = LocalIndex.basename(path)
    if filename == "" then done(false); return end
    local creds, _, reason = self:credentials()
    if not creds then
        self.log.dbg("syncedhistory: document push skipped:", reason)
        done(false)
        return
    end
    local document = self:keyFor(filename)
    self.request({
        method = "PUT",
        url = creds.server .. "/syncs/documents",
        headers = headersFor(creds, true),
        body = self.json_encode({ document = document, filename = filename }),
        timeout = Client.TIMEOUT,
    }, function(res)
        res = res or {}
        if res.status == 200 then
            self.log.dbg("syncedhistory: pushed file name for", document)
            done(true)
        else
            self.log.warn("syncedhistory: document push failed:", res.status, res.err)
            done(false)
        end
    end)
end

-- Drop the given keys from the cached list, so a removed book does not come
-- back from the cache when the next fetch fails.
function Client:forgetCached(keys)
    local items, fetched_at = self:cachedList()
    if not items then return end
    local gone = {}
    for _, k in ipairs(keys) do gone[k] = true end
    local kept = {}
    for _, row in ipairs(items) do
        local hit = gone[row.document]
        for _, a in ipairs(type(row.aliases) == "table" and row.aliases or {}) do
            if gone[a.document] then hit = true end
        end
        if not hit then kept[#kept + 1] = row end
    end
    self.settings:saveSetting(Client.CACHE_KEY, { items = kept, fetched_at = fetched_at })
    self.settings:flush()
end

--[[--
Remove a book from the server list: one DELETE per key, one after the other.

`done(ok, info)` runs once every request has ended. ok is true only when
every key was deleted (a 200, even for a key the server no longer had).
info = { removed = keys deleted, failed = keys not deleted, status, err,
message = text to show when ok is false }. The cached list loses the book
only when ok is true.
]]
function Client:removeDocuments(keys, done)
    done = done or noop
    local creds, message, reason = self:credentials()
    if not creds then
        self.log.warn("syncedhistory: remove skipped:", reason)
        done(false, { removed = {}, failed = keys or {}, reason = reason, message = message })
        return
    end
    local todo, removed, failed = {}, {}, {}
    for _, k in ipairs(keys or {}) do
        if type(k) == "string" and k ~= "" then todo[#todo + 1] = k end
    end
    local last
    local function finish()
        local ok = #failed == 0 and #removed > 0
        -- A partly removed book stays in the cache: the row must not vanish
        -- while the server still holds one of its keys.
        if ok then self:forgetCached(removed) end
        self.log.info("syncedhistory: removed", #removed, "of", #todo, "keys")
        done(ok, {
            removed = removed,
            failed = failed,
            status = last and last.status,
            err = last and last.err,
            message = not ok and Client.MSG_REMOVE_FAILED or nil,
        })
    end
    local i = 0
    local function step()
        i = i + 1
        local key = todo[i]
        if not key then finish(); return end
        self.request({
            method = "DELETE",
            -- A key is 32 hex characters; nothing in it needs escaping.
            url = creds.server .. "/syncs/documents/" .. key,
            headers = headersFor(creds, false),
            timeout = Client.TIMEOUT,
        }, function(res)
            res = res or {}
            if res.status == 200 then
                removed[#removed + 1] = key
            else
                last = res
                failed[#failed + 1] = key
                self.log.warn("syncedhistory: delete failed:", key, res.status, res.err)
            end
            step()
        end)
    end
    step()
end

return Client
