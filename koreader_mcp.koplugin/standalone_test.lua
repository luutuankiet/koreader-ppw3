#!/usr/bin/env luajit
-- Standalone test script for koreader_mcp.koplugin
-- Run with: luajit standalone_test.lua
-- Tests the MCP server without KOReader dependencies

-- Add current directory to package path
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "?.lua;" .. package.path

print("[TEST] Starting KOReader MCP server in standalone mode...")
print("[TEST] Server will listen on port 8888")
print("[TEST] Press Ctrl+C to stop")
print("")

local server = require("server")
local srv = server.new(8888)
srv:run_blocking()
