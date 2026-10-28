#!/bin/bash
# PID 1 of the emulator container (under docker's init): starts Xvfb, seeds
# KOReader's settings on first run, then relaunches KOReader whenever it exits.
set -u

KO_DIR=/mnt/us/koreader
MCP_DIR="$KO_DIR/plugins/koreader_mcp.koplugin"
SEED=/opt/emulator-seed
W=${EMULATE_READER_W:-1072}
H=${EMULATE_READER_H:-1448}

log() { echo "[supervisor] $(date '+%F %T') $*"; }

reader_pid=""
xvfb_pid=""
shutdown() {
    log "stopping"
    [ -n "$reader_pid" ] && kill "$reader_pid" 2>/dev/null
    [ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null
    wait
    exit 0
}
trap shutdown TERM INT

start_xvfb() {
    # Host networking shares the abstract X socket namespace with the host,
    # hence the unusual display number (DISPLAY, default :73).
    rm -f "/tmp/.X${DISPLAY#:}-lock"
    Xvfb "$DISPLAY" -screen 0 "${W}x${H}x24" -nolisten tcp &
    xvfb_pid=$!
    for _ in $(seq 50); do
        xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    log "Xvfb did not come up on $DISPLAY"
    return 1
}

seed_settings() {
    mkdir -p "$KO_HOME/settings"
    if [ ! -e "$KO_HOME/settings.reader.lua" ]; then
        cp "$SEED/settings.reader.lua" "$KO_HOME/settings.reader.lua"
        log "seeded settings.reader.lua"
    fi
    if [ ! -e "$KO_HOME/settings/kosync.lua" ]; then
        cp "$SEED/kosync.lua" "$KO_HOME/settings/kosync.lua"
        log "seeded settings/kosync.lua"
    fi
}

# Rewritten before every launch: a gateway deploy of koreader_mcp must not
# leave the emulator on the Kindle's default port (8888 is taken on the host).
write_mcp_config() {
    {
        echo "return {"
        echo "    port = ${MCP_PORT:-8889},"
        echo "    device_name = \"${MCP_DEVICE_NAME:-emu}\","
        [ -n "${MCP_GATEWAY_URL:-}" ] && echo "    gateway_url = \"${MCP_GATEWAY_URL}\","
        echo "}"
    } > "$MCP_DIR/config.lua"
}

seed_settings
start_xvfb || exit 1

n=0
while true; do
    if ! kill -0 "$xvfb_pid" 2>/dev/null; then
        log "Xvfb gone, restarting it"
        start_xvfb || { sleep 2; continue; }
    fi
    [ -d "$MCP_DIR" ] && write_mcp_config
    n=$((n + 1))
    log "starting KOReader (launch $n)"
    cd "$KO_DIR" || exit 1
    # Explicit ./luajit, as the Kindle launcher does: run through the shebang the
    # process is named reader.lua and the gateway's `killall luajit` misses it.
    ./luajit ./reader.lua &
    reader_pid=$!
    wait "$reader_pid"
    rc=$?
    reader_pid=""
    log "KOReader exited with code $rc; relaunching in 2 s"
    sleep 2
done
