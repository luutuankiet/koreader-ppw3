-- Parse the committed registry/index.json with the installer's own code.
-- Run from the KOReader folder: ./luajit /tmp/pp20/73-registry_parse.lua
package.path = "/tmp/pp20/?.lua;common/?.lua;frontend/?.lua;" .. package.path
require("setupkoenv")
local json = require("json")
local Core = require("pluginpackages_core")
local f = assert(io.open("/tmp/pp20/index.json"))
local index = json.decode(f:read("*a")); f:close()
local list, err = Core.parseIndex(index)
assert(list, err)
print("raw entries", #index.plugins, "accepted", #list)
local url, base = Core.indexLocation("")
print("default list", url)
for _, e in ipairs(list) do print(e.name, e.version, Core.packageUrl(e, base)) end
assert(#list == #index.plugins and #list == 2, "an entry was dropped")
print("PASS")
