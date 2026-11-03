#!/bin/bash
set -u  # as supervisor.sh
# Runs write_mcp_config from emulator/supervisor.sh without starting anything, with and without the WS vars.
eval "$(sed -n '/^write_mcp_config()/,/^}/p' emulator/supervisor.sh)"
MCP_DIR=$(mktemp -d)
echo "== defaults (no MCP_GATEWAY_URL / MCP_GATEWAY_KEY) =="
write_mcp_config; cat "$MCP_DIR/config.lua"
echo "== MCP_GATEWAY_URL and MCP_GATEWAY_KEY set =="
MCP_GATEWAY_URL="ws://127.0.0.1:8787/device" MCP_GATEWAY_KEY="example-key" write_mcp_config; cat "$MCP_DIR/config.lua"
echo "== empty values keep raw TCP =="
MCP_GATEWAY_URL="" MCP_GATEWAY_KEY="" write_mcp_config; cat "$MCP_DIR/config.lua"
rm -rf "$MCP_DIR"
