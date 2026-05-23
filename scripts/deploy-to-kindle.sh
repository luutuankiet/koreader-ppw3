#!/usr/bin/env bash
# Deploy koreader_mcp.koplugin to a Kindle device over SSH
#
# Usage: ./deploy-to-kindle.sh [kindle|ukindle] [gateway_ip:port]
#
# Prerequisites:
#   - SSH access to Kindle (via ~/.ssh/config aliases)
#   - KOReader installed on the Kindle
#   - Kindle WiFi enabled and connected

set -e

DEVICE=${1:-kindle}  # SSH alias or IP
GATEWAY=${2:-}  # Optional: e.g. "192.168.1.5:9999"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${SCRIPT_DIR}/../koreader_mcp.koplugin"
KINDLE_PLUGIN_PATH="/mnt/us/koreader/plugins/koreader_mcp.koplugin"

echo "=== KOReader MCP Plugin Deployment ==="
echo "Target device: ${DEVICE}"
echo "Plugin source: ${PLUGIN_DIR}"
echo "Kindle path:   ${KINDLE_PLUGIN_PATH}"
echo

# Test connectivity
echo "[1/4] Testing SSH connectivity..."
if ! ssh -o ConnectTimeout=5 "${DEVICE}" echo "connected" > /dev/null 2>&1; then
    echo "ERROR: Cannot connect to ${DEVICE}. Is WiFi on? Is the device awake?"
    echo "  Try: ssh ${DEVICE}"
    exit 1
fi
echo "  Connected!"

# Create plugin directory on Kindle
echo "[2/4] Creating plugin directory..."
ssh "${DEVICE}" "mkdir -p ${KINDLE_PLUGIN_PATH}"

# Copy plugin files
echo "[3/4] Copying plugin files..."
scp -r "${PLUGIN_DIR}/"* "${DEVICE}:${KINDLE_PLUGIN_PATH}/"
echo "  Files copied:"
ssh "${DEVICE}" "ls -la ${KINDLE_PLUGIN_PATH}/"

# Optionally set gateway URL
if [ -n "${GATEWAY}" ]; then
    echo "[4/4] Setting gateway URL: http://${GATEWAY}"
    # Create a config file the plugin reads on init
    ssh "${DEVICE}" "echo 'return { gateway_url = \"http://${GATEWAY}\" }' > ${KINDLE_PLUGIN_PATH}/config.lua"
else
    echo "[4/4] No gateway URL set (plugin will run standalone)"
fi

echo
echo "=== Deployment complete ==="
echo "To activate: restart KOReader on the Kindle"
echo "  ssh ${DEVICE} 'killall -HUP koreader.sh 2>/dev/null || true'"
echo "To verify:   curl http://<kindle-ip>:8888/health"
