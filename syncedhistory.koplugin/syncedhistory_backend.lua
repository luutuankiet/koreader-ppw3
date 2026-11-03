--[[--
Which progress sync plugin the synced reading list works with: KOReader's
built-in one (kosync.koplugin) or "Progress sync serverless"
(kosyncserverless.koplugin). Both keep the same settings fields
(custom_server, username, userkey, checksum_method) under the key
"settings" of their own settings file, so only three things differ: the
ui.<name> module, the settings file read when no book is open, and the
event that pulls a book's position.

Pure Lua with no KOReader requires, so the choice can be tested anywhere.
]]

local Backend = {}

-- The setting in syncedhistory.lua, and its values in menu order.
Backend.SETTING = "progress_sync_backend"
Backend.DEFAULT = "auto"
Backend.CHOICES = { "auto", "kosync", "serverless" }

Backend.KOSYNC = {
    id = "kosync",
    module = "kosync",                       -- ui.kosync, the plugin's name
    class = "KOSync",                        -- the table its main.lua defines
    plugin_dir = "kosync.koplugin",
    settings_file = "kosync.lua",            -- in the settings folder
    legacy_key = "kosync",                   -- G_reader_settings key up to v2024.11
    pull_event = "KOSyncPullProgress",
    title = "Progress sync",
}

Backend.SERVERLESS = {
    id = "serverless",
    module = "kosyncserverless",
    class = "KOSyncServerless",
    plugin_dir = "kosyncserverless.koplugin",
    settings_file = "kosyncserverless.lua",
    pull_event = "KOSyncServerlessPullProgress",
    title = "Progress sync serverless",
}

--- The saved choice, or the default when unset or not one of CHOICES.
function Backend.choice(value)
    for _, c in ipairs(Backend.CHOICES) do
        if value == c then return c end
    end
    return Backend.DEFAULT
end

--[[--
The backend for a choice.

@tparam string|nil choice "auto", "kosync" or "serverless"; anything else is "auto"
@tparam function has_plugin function(module) -> true when that plugin is
  loaded (enabled) in this KOReader
@tparam[opt] function log function(...) for the fallback line
@treturn table Backend.KOSYNC or Backend.SERVERLESS

"auto" takes the serverless plugin when it is loaded, otherwise the
built-in one. "serverless" chosen while that plugin is not loaded falls
back to the built-in one and logs why: the list keeps working with the
login the built-in plugin holds instead of saying "log in first" about a
plugin that is not there. "kosync" is always the built-in one, even when it
is disabled, the same as before this setting existed.
]]
function Backend.resolve(choice, has_plugin, log)
    choice = Backend.choice(choice)
    if choice == "kosync" then return Backend.KOSYNC end
    local serverless = has_plugin(Backend.SERVERLESS.module) and true or false
    if serverless then return Backend.SERVERLESS end
    if choice == "serverless" and log then
        log("syncedhistory: progress sync serverless is not loaded, using the built-in progress sync")
    end
    return Backend.KOSYNC
end

--[[--
For the --koreader tests, which read the plugin's source text and run no
PluginLoader: resolve a choice by which plugin folders exist, and return
the chosen plugin's main.lua.

@tparam string|nil choice as for resolve
@tparam table roots folders that may hold <plugin>.koplugin, in order
@tparam function exists function(path) -> true when the file is there
@tparam[opt] function log as for resolve
@treturn table the backend
@treturn string|nil path of its main.lua, nil when not found
]]
function Backend.fromSources(choice, roots, exists, log)
    local function sourcePath(backend)
        for _, root in ipairs(roots) do
            local path = root .. "/" .. backend.plugin_dir .. "/main.lua"
            if exists(path) then return path end
        end
    end
    local backend = Backend.resolve(choice, function(module)
        return module == Backend.SERVERLESS.module and sourcePath(Backend.SERVERLESS) ~= nil
    end, log)
    return backend, sourcePath(backend)
end

return Backend
