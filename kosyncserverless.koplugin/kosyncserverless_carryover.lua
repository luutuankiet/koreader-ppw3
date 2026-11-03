--[[--
One-time copy of the login and settings of KOReader's built-in progress sync
plugin (settings/kosync.lua) into this plugin's own settings file, so a user
switching plugins does not have to log in again.

The copy happens when this plugin's own settings have no username, the
built-in plugin's settings do, and no copy was made before. After that this
plugin reads only its own file.

Pure apart from the two settings objects passed in: anything with LuaSettings'
readSetting, saveSetting, isTrue and flush works, which is how the tests drive
it.
]]

local CarryOver = {}

-- Top-level key in this plugin's settings file, beside "settings", so the
-- field names inside "settings" stay exactly upstream's.
CarryOver.MARKER_KEY = "carried_over_from_kosync"

local function deepcopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do
        copy[deepcopy(k)] = deepcopy(v)
    end
    return copy
end

--- Decides whether to copy and builds the merged settings table.
-- @param own table|nil this plugin's "settings" table
-- @param legacy table|nil the built-in plugin's "settings" table
-- @param already_done boolean the marker is set
-- @return table|nil the settings to save, or nil when nothing is to be copied
function CarryOver.merge(own, legacy, already_done)
    if already_done then return nil end
    if type(own) == "table" and own.username ~= nil then return nil end
    if type(legacy) ~= "table" or legacy.username == nil then return nil end
    local merged = {}
    if type(own) == "table" then
        for k, v in pairs(own) do merged[k] = deepcopy(v) end
    end
    -- Every field of the built-in plugin wins: own settings without a
    -- username are at most defaults or half-finished setup.
    for k, v in pairs(legacy) do merged[k] = deepcopy(v) end
    return merged
end

--- Copies the built-in plugin's settings into this plugin's settings once.
-- @param own_obj LuaSettings-like object for settings/kosyncserverless.lua
-- @param legacy_obj LuaSettings-like object for settings/kosync.lua, or nil
-- @return boolean true when a copy was made and flushed
function CarryOver.apply(own_obj, legacy_obj)
    if not own_obj or not legacy_obj then return false end
    local merged = CarryOver.merge(
        own_obj:readSetting("settings"),
        legacy_obj:readSetting("settings"),
        own_obj:isTrue(CarryOver.MARKER_KEY))
    if not merged then return false end
    own_obj:saveSetting("settings", merged)
    own_obj:saveSetting(CarryOver.MARKER_KEY, true)
    own_obj:flush()
    return true
end

return CarryOver
