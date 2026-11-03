--[[--
Plugin packages: install, upgrade and roll back plugins from a package host.
The menu entry is the only thing that uses the network; there are no timers.

Downloading and unpacking run in a subprocess, so the screen stays alive and a
tap can abandon them. The folder swap runs here, once that subprocess reports
success. All disk work is in pluginpackages_core.lua.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local Version = require("version")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local json = require("json")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template

-- Loaded now, not on first use: a self-update renames this folder away while
-- this code keeps running, and package.path only holds it during plugin load.
local Core = require("pluginpackages_core")

-- Either a manifest URL ending in .json or, as saved by earlier versions, a
-- folder holding index.json; Core.indexLocation tells them apart.
local SETTING_HOST = "pluginpackages_host"

local PluginPackages = WidgetContainer:extend{
    name = "pluginpackages",
}

function PluginPackages:init()
    self.ui.menu:registerToMainMenu(self)
end

function PluginPackages:addToMainMenu(menu_items)
    menu_items.plugin_packages = {
        text = _("Plugin packages"),
        sorting_hint = "tools",
        callback = function() self:open() end,
    }
end

function PluginPackages:host()
    return G_reader_settings:readSetting(SETTING_HOST) or Core.DEFAULT_INDEX
end

function PluginPackages:root()
    return self.path:match("^(.*)/[^/]+$")
end

function PluginPackages:open()
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function() self:fetchAndShow() end)
    end)
end

function PluginPackages:fetchAndShow()
    local url, base = Core.indexLocation(self:host())
    self.base = base
    local completed, answer = Trapper:dismissableRunInSubprocess(function()
        local ok, body, err = pcall(Core.httpGet, url)
        if ok and body then return "OK\n" .. body end
        return "ER\n" .. tostring(ok and err or body)
    end, _("Fetching package list…"), true)
    local plugins, problem
    if not completed then
        problem = _("Cancelled")
    elseif not answer or answer:sub(1, 3) ~= "OK\n" then
        problem = answer and answer:sub(4) or _("no answer")
    else
        local ok, index = pcall(json.decode, answer:sub(4))
        if ok then plugins, problem = Core.parseIndex(index) else problem = _("not a package index") end
    end
    -- Show the list even when this failed: the host is edited from the list,
    -- and rollback needs no network.
    self:showList(plugins or {})
    if problem then
        logger.warn("pluginpackages: cannot read", url, problem)
        UIManager:show(InfoMessage:new{ text = T(_("Could not read the package list from\n%1\n\n%2"), url, problem) })
    end
end

function PluginPackages:versionLabel(installed, available)
    if available and installed then
        if installed == available then return installed end
        return installed .. " → " .. available
    end
    if available then return "→ " .. available end
    return installed or ""
end

function PluginPackages:buildItems(plugins)
    local root = self:root()
    local items = {}
    local seen = {}
    for _, entry in ipairs(plugins) do
        seen[entry.name] = true
        local installed = Core.readVersion(root .. "/" .. entry.name .. ".koplugin")
        items[#items + 1] = {
            text = entry.fullname or entry.name,
            mandatory = self:versionLabel(installed, entry.version),
            callback = function() self:showActions(entry, plugins) end,
        }
    end
    -- A plugin the host no longer lists can still be rolled back.
    for _, name in ipairs(Core.listBackups(root)) do
        if not seen[name] then
            local installed = Core.readVersion(root .. "/" .. name .. ".koplugin")
            items[#items + 1] = {
                text = name,
                mandatory = installed or "",
                callback = function() self:showActions({ name = name }, plugins) end,
            }
        end
    end
    items[#items + 1] = {
        text = T(_("Package host: %1"), self:host()),
        callback = function() self:editHost() end,
    }
    return items
end

function PluginPackages:showList(plugins)
    local screen = Device.screen
    self:closeList()
    self.list = Menu:new{
        title = _("Plugin packages"),
        item_table = self:buildItems(plugins),
        width = screen:getWidth(),
        height = screen:getHeight(),
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        onMenuSelect = function(_, item) item.callback() end,
        close_callback = function() self:closeList() end,
    }
    self.plugins = plugins
    UIManager:show(self.list)
end

function PluginPackages:closeList()
    if self.list then
        UIManager:close(self.list)
        self.list = nil
    end
end

function PluginPackages:editHost()
    local dialog
    dialog = InputDialog:new{
        title = _("Package host"),
        description = _("Leave empty to use the GitHub registry."),
        input = self:host(),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local value = util.trim(dialog:getInputText())
                    UIManager:close(dialog)
                    -- An empty host goes back to the GitHub registry (Core.DEFAULT_INDEX).
                    if value == "" or value == Core.DEFAULT_INDEX then
                        G_reader_settings:delSetting(SETTING_HOST)
                    else
                        G_reader_settings:saveSetting(SETTING_HOST, value)
                    end
                    -- Otherwise on disk only at a clean exit: a crash forgets the host.
                    G_reader_settings:flush()
                    self:open()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function tooOld(entry)
    if not entry.min_koreader then return false end
    local ok, needed = pcall(Version.getNormalizedVersion, Version, entry.min_koreader)
    if not ok or not needed then return false end
    return needed > Version:getNormalizedCurrentVersion()
end

function PluginPackages:showActions(entry, plugins)
    local root = self:root()
    local installed = Core.readVersion(root .. "/" .. entry.name .. ".koplugin")
    local bak_version = Core.readVersion(root .. "/" .. entry.name .. ".koplugin.bak")
    local buttons = {}
    local dialog
    if entry.sha256 then -- from the index, not a backup-only row
        local label
        if not installed then
            label = T(_("Install %1"), entry.version)
        elseif Core.compareVersions(installed, entry.version) < 0 then
            label = T(_("Upgrade to %1"), entry.version)
        else
            label = T(_("Reinstall %1"), entry.version)
        end
        buttons[#buttons + 1] = {{
            text = label,
            callback = function()
                UIManager:close(dialog)
                self:confirmInstall(entry)
            end,
        }}
    end
    if bak_version then
        buttons[#buttons + 1] = {{
            text = T(_("Roll back to %1"), bak_version),
            callback = function()
                UIManager:close(dialog)
                self:rollback(entry, plugins)
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(dialog) end,
    }}
    dialog = ButtonDialog:new{
        title = entry.description or entry.fullname or entry.name,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function PluginPackages:confirmInstall(entry)
    if tooOld(entry) then
        UIManager:show(InfoMessage:new{
            text = T(_("%1 needs KOReader %2 or newer."), entry.fullname or entry.name, entry.min_koreader),
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Download %1 %2 (%3)?"), entry.fullname or entry.name, entry.version,
            util.getFriendlySize(entry.size)),
        ok_text = _("Install"),
        ok_callback = function()
            NetworkMgr:runWhenOnline(function()
                Trapper:wrap(function() self:install(entry) end)
            end)
        end,
    })
end

function PluginPackages:install(entry)
    local root = self:root()
    local url = Core.packageUrl(entry, self.base)
    local completed, answer = Trapper:dismissableRunInSubprocess(function()
        local ok, new_dir, err = pcall(Core.prepare, entry, { root = root, url = url, fetch = Core.httpGet })
        if ok and new_dir then return "OK\n" .. new_dir end
        return "ER\n" .. tostring(ok and err or new_dir)
    end, T(_("Installing %1…"), entry.fullname or entry.name), true)
    if not completed then
        UIManager:show(InfoMessage:new{ text = _("Install cancelled. Nothing was changed.") })
        return
    end
    local problem
    if answer and answer:sub(1, 3) == "OK\n" then
        local ok, err = Core.swapIn(root, entry.name, answer:sub(4))
        if not ok then problem = err end
    else
        problem = answer and answer:sub(4) or _("no answer from the download")
    end
    if problem then
        logger.warn("pluginpackages: install failed", entry.name, problem)
        UIManager:show(InfoMessage:new{
            text = T(_("Install failed. The installed plugin was not changed.\n\n%1"), problem),
        })
        return
    end
    self:afterChange(T(_("%1 %2 installed."), entry.fullname or entry.name, entry.version))
end

function PluginPackages:rollback(entry)
    local ok, err = Core.rollback(self:root(), entry.name)
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("Roll back failed. Nothing was changed.\n\n%1"), err) })
        return
    end
    local version = Core.readVersion(self:root() .. "/" .. entry.name .. ".koplugin")
    self:afterChange(T(_("Rolled back %1 to %2."), entry.fullname or entry.name, version or "?"))
end

-- Plugins are only discovered at startup, so a change takes effect on restart.
function PluginPackages:afterChange(message)
    self:showList(self.plugins or {})
    UIManager:show(ConfirmBox:new{
        text = message .. "\n\n" .. _("Restart KOReader now to use it?"),
        ok_text = _("Restart"),
        cancel_text = _("Later"),
        ok_callback = function() UIManager:restartKOReader() end,
    })
end

return PluginPackages
