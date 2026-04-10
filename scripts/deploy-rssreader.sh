#!/usr/bin/env bash
# Deploy rssreader.koplugin to Kindle over SSH
#
# Usage: ./deploy-rssreader.sh [kindle|ukindle]
#
# Deploys from the local dev workspace to the Kindle plugin directory.
# Excludes .git, .gitignore, and sample files.

set -e

DEVICE=${1:-kindle}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${SCRIPT_DIR}/../rssreader.koplugin"
KINDLE_PLUGIN_PATH="/mnt/us/koreader/plugins/rssreader.koplugin"

echo "=== RSS Reader Plugin Deployment ==="
echo "Target device: ${DEVICE}"
echo "Plugin source: ${PLUGIN_DIR}"
echo "Kindle path:   ${KINDLE_PLUGIN_PATH}"
echo

# Verify source exists
if [ ! -f "${PLUGIN_DIR}/main.lua" ]; then
    echo "ERROR: Plugin source not found at ${PLUGIN_DIR}"
    exit 1
fi

# Test connectivity
echo "[1/4] Testing SSH connectivity..."
if ! ssh -o ConnectTimeout=5 "${DEVICE}" echo "connected" > /dev/null 2>&1; then
    echo "ERROR: Cannot connect to ${DEVICE}. Is WiFi on? Is the device awake?"
    exit 1
fi
echo "  Connected!"

# Create staging tarball (exclude .git, samples, LICENSE, README)
echo "[2/4] Creating deployment package..."
TMP_TAR=$(mktemp /tmp/rssreader-deploy-XXXXXX.tar.gz)
trap "rm -f ${TMP_TAR}" EXIT

cd "${PLUGIN_DIR}"
tar czf "${TMP_TAR}" \
    --exclude='.git' \
    --exclude='.gitignore' \
    --exclude='*.sample.lua' \
    --exclude='rssreader_configuration.lua' \
    --exclude='rssreader_local_defaults.lua' \
    --exclude='LICENSE' \
    --exclude='README.md' \
    .

echo "  NOTE: Config files (rssreader_configuration.lua, rssreader_local_defaults.lua) are"
echo "         excluded from deploy. Edit them on the Kindle directly via SSH."

echo "  Package size: $(du -h ${TMP_TAR} | cut -f1)"

# Deploy
echo "[3/4] Deploying to Kindle..."
ssh "${DEVICE}" "mkdir -p ${KINDLE_PLUGIN_PATH}"
scp "${TMP_TAR}" "${DEVICE}:/tmp/rssreader-deploy.tar.gz"
ssh "${DEVICE}" "cd ${KINDLE_PLUGIN_PATH} && tar xzf /tmp/rssreader-deploy.tar.gz && rm /tmp/rssreader-deploy.tar.gz"

# Verify
echo "[4/4] Verifying deployment..."
DEPLOYED_FILES=$(ssh "${DEVICE}" "ls ${KINDLE_PLUGIN_PATH}/*.lua | wc -l")
echo "  Deployed ${DEPLOYED_FILES} Lua files"
ssh "${DEVICE}" "ls -la ${KINDLE_PLUGIN_PATH}/main.lua ${KINDLE_PLUGIN_PATH}/rssreader_cache.lua ${KINDLE_PLUGIN_PATH}/rssreader_freshrss.lua 2>&1"

echo
echo "=== Deployment complete ==="
echo "To activate: restart KOReader on the Kindle"
echo "  Option 1: Long-press power button -> Restart"
echo "  Option 2: ssh ${DEVICE} 'killall -HUP koreader.sh 2>/dev/null || true'"
