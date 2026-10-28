#!/bin/bash
# Entrypoint of the vnc container: waits for the emulator's display, then
# serves it as VNC (VNC_PORT) and noVNC (NOVNC_PORT). Exits when either
# process dies, so docker restarts both, e.g. after Xvfb comes back.
set -u

log() { echo "[vnc] $(date '+%F %T') $*"; }

until xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; do
    log "waiting for $DISPLAY"
    sleep 2
done

# -noshm: this container has its own IPC namespace, so X shared memory with
# the emulator's Xvfb is not available.
x11vnc -display "$DISPLAY" -rfbport "$VNC_PORT" -forever -shared -nopw -noshm -quiet &
websockify --web /usr/share/novnc "$NOVNC_PORT" "127.0.0.1:$VNC_PORT" &
log "VNC on :$VNC_PORT, noVNC on http://$(hostname):$NOVNC_PORT/"

wait -n
log "a process exited; stopping so docker restarts the container"
exit 1
