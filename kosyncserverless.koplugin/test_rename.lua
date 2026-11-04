--[[--
Tests for the clone of KOReader's built-in progress sync plugin. main.lua never
loads this file, and scripts/publish.sh leaves test_*.lua out of the package.

1. Every source file is free of names that would clash with the built-in
   plugin when both are loaded (module names, Spore middleware names, action
   ids, event names and handlers, menu key, settings and queue files), and the
   new names are all there.
2. The one-time login carry-over (kosyncserverless_carryover.lua) on stub
   settings objects.

Two ways to run it:

  1. Standalone, any LuaJIT or Lua 5.1:
       luajit test_rename.lua

  2. With KOReader's own luajit, which adds a round trip through the real
     LuaSettings on a temporary folder and a load smoke test of the modules
     with KOReader's package path. Run from the KOReader install folder (the
     one holding setupkoenv.lua):
       cd /mnt/us/koreader
       ./luajit <plugin dir>/test_rename.lua --koreader
]]

local mode = arg and arg[1] == "--koreader" and "koreader" or "standalone"

local this_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = this_dir .. "/?.lua;" .. package.path

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("ok   " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or ""))
    end
end

local function read(name)
    local f = io.open(this_dir .. "/" .. name, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- Plugin sources, test files excluded. Listed by hand so a new file has to be
-- added here, and so this runs without lfs.
local SOURCES = {
    "main.lua",
    "_meta.lua",
    "KOSyncServerlessClient.lua",
    "KOSyncServerlessQueue.lua",
    "kosyncserverless_carryover.lua",
    "kosyncserverless_http.lua",
    "kosyncserverless_retry.lua",
    "kosyncserverless_sleep.lua",
}

local src = {}
for _, name in ipairs(SOURCES) do
    src[name] = read(name)
    check("source exists: " .. name, src[name] ~= nil)
end

-- Returns "file:line: text" of every line matching the Lua pattern.
local function grep(pattern, plain)
    local hits = {}
    for _, name in ipairs(SOURCES) do
        local n = 0
        for line in ((src[name] or "") .. "\n"):gmatch("([^\n]*)\n") do
            n = n + 1
            if line:find(pattern, 1, plain) then
                table.insert(hits, name .. ":" .. n .. ": " .. line)
            end
        end
    end
    return hits
end

local function none(name, pattern, plain)
    local hits = grep(pattern, plain)
    check("no " .. name, #hits == 0, table.concat(hits, " | "))
end

-- 1a. Upstream names that would clash if both plugins are loaded.
none("upstream client module KOSyncClient", "KOSyncClient", true)
none("upstream queue module KOSyncQueue", "KOSyncQueue", true)
none("upstream queue file kosync_queue.lua", "kosync_queue.lua", true)
none("upstream plugin name \"kosync\"", "name%s*=%s*\"kosync\"")
none("upstream action ids \"kosync_...\"", "\"kosync_", true)
none("upstream event KOSyncPushProgress", "KOSyncPushProgress", true)
none("upstream event KOSyncPullProgress", "KOSyncPullProgress", true)
none("upstream event KOSyncToggleAutoSync", "KOSyncToggleAutoSync", true)
none("upstream menu key progress_sync", "progress_sync%s*=")
none("upstream menu text \"Progress sync\"", "_(\"Progress sync\")", true)
none("shared Spore middleware GinClient", "Middleware.GinClient", true)
none("shared Spore middleware KOSyncAuth", "Middleware.KOSyncAuth", true)
none("shared Spore middleware AsyncHTTP", "Middleware.AsyncHTTP", true)
none("enable(\"GinClient\")", "enable(\"GinClient\"", true)
none("enable(\"KOSyncAuth\")", "enable(\"KOSyncAuth\"", true)
none("enable(\"AsyncHTTP\")", "enable(\"AsyncHTTP\"", true)
none("any settings write to G_reader_settings", "G_reader_settings:save", true)

-- The built-in settings file is named exactly once: the carry-over source.
local builtin = grep("\"/kosync.lua\"", true)
check("settings/kosync.lua named once, as the carry-over source",
    #builtin == 1 and builtin[1]:find("builtin_settings_file", 1, true) ~= nil,
    table.concat(builtin, " | "))

-- Every onKOSync... handler belongs to the new names.
for _, hit in ipairs(grep(":onKOSync%u")) do
    check("handler renamed: " .. hit, hit:find(":onKOSyncServerless", 1, true) ~= nil)
end

-- Every registered action and every event it sends uses the new prefix.
local main = src["main.lua"] or ""
local actions, events = {}, {}
for id in main:gmatch("registerAction%(\"([^\"]+)\"") do actions[id] = true end
for ev in main:gmatch("event=\"([^\"]+)\"") do events[ev] = true end
for id in pairs(actions) do
    check("action id prefixed: " .. id, id:find("^kosyncserverless_") ~= nil)
end
for ev in pairs(events) do
    check("event prefixed: " .. ev, ev:find("^KOSyncServerless") ~= nil)
end

-- Plugin-local modules that require() can reach are all prefixed, so they
-- never collide in package.loaded with the built-in plugin's.
for _, name in ipairs(SOURCES) do
    for mod in (src[name] or ""):gmatch("require%(\"([^\"]+)\"%)") do
        if read(mod .. ".lua") then
            check("local module prefixed: " .. mod, mod:lower():find("^kosyncserverless") ~= nil)
        end
    end
end

-- G_reader_settings keys read: only KOReader-wide ones, shared on purpose.
local SHARED_KEYS = { device_id = true, wifi_enable_action = true, auto_restore_wifi = true }
for _, name in ipairs(SOURCES) do
    for key in (src[name] or ""):gmatch("G_reader_settings:%a+%(\"([^\"]+)\"") do
        check("G_reader_settings key is a shared one: " .. key, SHARED_KEYS[key] == true)
    end
end

-- 1b. New names present.
local function has(name, text, file)
    check("has " .. name, (src[file or "main.lua"] or ""):find(text, 1, true) ~= nil)
end
has("plugin name kosyncserverless", 'name = "kosyncserverless",')
has("settings file settings/kosyncserverless.lua", '.. "/kosyncserverless.lua"')
has("queue file settings/kosyncserverless_queue.lua", '.. "/kosyncserverless_queue.lua"', "KOSyncServerlessQueue.lua")
has("menu key progress_sync_serverless", "menu_items.progress_sync_serverless = {")
has("menu text Progress sync serverless", 'text = _("Progress sync serverless"),')
has("device_id read from G_reader_settings", 'G_reader_settings:readSetting("device_id")')
for _, id in ipairs{ "kosyncserverless_push_progress", "kosyncserverless_pull_progress",
                     "kosyncserverless_set_autosync", "kosyncserverless_toggle_autosync" } do
    check("action registered: " .. id, actions[id] == true)
end
for _, ev in ipairs{ "KOSyncServerlessPushProgress", "KOSyncServerlessPullProgress",
                     "KOSyncServerlessToggleAutoSync" } do
    check("event sent: " .. ev, events[ev] == true)
    has("handler on" .. ev, "function KOSyncServerless:on" .. ev .. "(")
end
has("_meta name", 'name = "kosyncserverless",', "_meta.lua")
has("_meta version 0.2.1", 'version = "0.2.1",', "_meta.lua")
has("coexistence check on ui.kosync", "not self.ui.kosync")

-- 2. Login carry-over.
local CarryOver = require("kosyncserverless_carryover")

-- Minimal LuaSettings stand-in.
local function stub(data)
    local o = { data = data or {}, flushes = 0 }
    function o:readSetting(k) return self.data[k] end
    function o:saveSetting(k, v) self.data[k] = v; return self end
    function o:isTrue(k) return self.data[k] == true end
    function o:flush() self.flushes = self.flushes + 1; return self end
    return o
end

local function legacy_settings()
    return { settings = {
        custom_server = "https://kosync.example",
        username = "reader",
        userkey = "0123456789abcdef0123456789abcdef",
        auto_sync = true,
        pages_before_update = 5,
        sync_forward = 2,
        sync_backward = 3,
        checksum_method = 1,
        send_metadata = true,
        kosync_hostname = "pw3-a",
        nested = { a = { b = 1 } },
    } }
end

do -- fresh install: own file empty
    local own, legacy = stub(), stub(legacy_settings())
    check("carry-over: copies when own has no settings", CarryOver.apply(own, legacy) == true)
    local s = own.data.settings or {}
    local want = legacy_settings().settings
    for k, v in pairs(want) do
        if type(v) ~= "table" then
            check("carry-over: field " .. k, s[k] == v, tostring(s[k]))
        end
    end
    check("carry-over: nested field", s.nested and s.nested.a and s.nested.a.b == 1)
    check("carry-over: deep copy, not shared", s.nested ~= legacy.data.settings.nested)
    check("carry-over: marker set", own.data[CarryOver.MARKER_KEY] == true)
    check("carry-over: flushed once", own.flushes == 1, own.flushes)
    check("carry-over: legacy untouched", legacy.flushes == 0 and legacy.data.settings.username == "reader")
    check("carry-over: second start copies nothing", CarryOver.apply(own, stub(legacy_settings())) == false)
    check("carry-over: second start does not flush", own.flushes == 1, own.flushes)
end

do -- own file holds upstream defaults (no username), legacy wins
    local own = stub({ settings = { auto_sync = false, sync_forward = 1, checksum_method = 0, own_only = "x" } })
    check("carry-over: copies over defaults", CarryOver.apply(own, stub(legacy_settings())) == true)
    check("carry-over: legacy field wins", own.data.settings.checksum_method == 1)
    check("carry-over: own-only field kept", own.data.settings.own_only == "x")
end

do -- own already logged in
    local own = stub({ settings = { username = "other", userkey = "k" } })
    check("carry-over: skipped when own has username", CarryOver.apply(own, stub(legacy_settings())) == false)
    check("carry-over: own username kept", own.data.settings.username == "other")
    check("carry-over: no flush when skipped", own.flushes == 0)
end

do -- already carried over once, user cleared username since
    local own = stub({ settings = {}, [CarryOver.MARKER_KEY] = true })
    check("carry-over: once only (marker)", CarryOver.apply(own, stub(legacy_settings())) == false)
end

do -- built-in plugin never logged in, or its file is missing
    local own = stub()
    check("carry-over: skipped when legacy has no username",
        CarryOver.apply(own, stub({ settings = { custom_server = "https://x" } })) == false)
    check("carry-over: skipped when legacy file empty", CarryOver.apply(own, stub({})) == false)
    check("carry-over: skipped when legacy object nil", CarryOver.apply(own, nil) == false)
    check("carry-over: nothing written", own.data.settings == nil and own.flushes == 0)
end

-- 3. KOReader only: real LuaSettings round trip and a load smoke test.
if mode == "koreader" then
    require("setupkoenv")
    local LuaSettings = require("luasettings")
    local dir = (os.getenv("TMPDIR") or "/tmp") .. "/kosyncserverless-test-" .. tostring(os.time())
    assert(os.execute("mkdir -p " .. dir) == 0 or true)
    local legacy_path, own_path = dir .. "/kosync.lua", dir .. "/kosyncserverless.lua"
    local l = LuaSettings:open(legacy_path)
    l:saveSetting("settings", legacy_settings().settings)
    l:flush()

    local own = LuaSettings:open(own_path)
    check("koreader: real LuaSettings copy", CarryOver.apply(own, LuaSettings:open(legacy_path)) == true)
    local reread = LuaSettings:open(own_path)
    local s = reread:readSetting("settings") or {}
    check("koreader: copy on disk has username", s.username == "reader")
    check("koreader: copy on disk has userkey", s.userkey == "0123456789abcdef0123456789abcdef")
    check("koreader: copy on disk has custom_server", s.custom_server == "https://kosync.example")
    check("koreader: copy on disk has checksum_method", s.checksum_method == 1)
    check("koreader: copy on disk has kosync_hostname", s.kosync_hostname == "pw3-a")
    check("koreader: marker on disk", reread:isTrue(CarryOver.MARKER_KEY))
    check("koreader: reopened file copies nothing", CarryOver.apply(reread, LuaSettings:open(legacy_path)) == false)

    -- Load smoke test: the modules resolve and the client builds its URLs.
    -- KOReader's device module reads the global reader settings on load; give
    -- it a throwaway one so the real settings are never touched.
    G_reader_settings = G_reader_settings or LuaSettings:open(dir .. "/settings.reader.lua") -- luacheck: ignore
    local ok_c, Client = pcall(require, "KOSyncServerlessClient")
    check("koreader: require KOSyncServerlessClient", ok_c and type(Client) == "table", Client)
    if ok_c then
        local ok_n, client = pcall(function()
            return Client:new{ custom_url = "http://127.0.0.1:1/", scheduleIn = function() end }
        end)
        check("koreader: client built", ok_n and client and client.base_url == "http://127.0.0.1:1", client)
        check("koreader: no Spore middleware registered",
            package.loaded["Spore.Middleware.GinClient"] == nil)
    end
    local ok_q, Queue = pcall(require, "KOSyncServerlessQueue")
    check("koreader: require KOSyncServerlessQueue", ok_q and type(Queue.push) == "function", Queue)
    -- main.lua pulls in the whole widget stack, which needs a running
    -- KOReader; compiling it proves the syntax, and running it is left to the
    -- emulator. Run it anyway when the widget stack happens to load.
    local chunk, cerr = loadfile(this_dir .. "/main.lua")
    check("koreader: main.lua compiles with LuaJIT", chunk ~= nil, cerr)
    local ok_m, Main = false, nil
    if chunk then ok_m, Main = pcall(chunk) end
    if not ok_m then print("note main.lua not run outside KOReader: " .. tostring(Main)) end
    if ok_m and type(Main) == "table" then
        check("koreader: main name", Main.name == "kosyncserverless")
        check("koreader: main settings_file", (Main.settings_file or ""):find("/kosyncserverless%.lua$") ~= nil, Main.settings_file)
        check("koreader: main builtin_settings_file", (Main.builtin_settings_file or ""):find("/kosync%.lua$") ~= nil)
        for _, h in ipairs{ "onKOSyncServerlessPushProgress", "onKOSyncServerlessPullProgress",
                            "onKOSyncServerlessToggleAutoSync", "warnIfBuiltinLoaded" } do
            check("koreader: main has " .. h, type(Main[h]) == "function")
        end
        check("koreader: main has no upstream handler", Main.onKOSyncPushProgress == nil)
    end
    os.execute("rm -rf " .. dir)
end

print(string.format("\n%d passed, %d failed (%s)", passed, failed, mode))
os.exit(failed == 0 and 0 or 1)
