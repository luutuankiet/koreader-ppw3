#!/usr/bin/env bash
# Point emu at a gateway through the koreader_mcp plugin settings file (settings beat config.lua),
# then restart KOReader the documented way (`killall luajit`; the supervisor relaunches it).
#   emu-point.sh cloud    -> wss://kindle.kenluu.org/device with DEVICE_KEY from the environment
#   emu-point.sh restore  -> remove the settings file (it did not exist before), back to config.lua 127.0.0.1:9990
F=/mnt/us/koreader-home/settings/koreader_mcp.lua
case "$1" in
  cloud)
    [ -n "$DEVICE_KEY" ] || { echo "DEVICE_KEY unset"; exit 2; }
    printf 'return {\n    ["gateway_url"] = "wss://kindle.kenluu.org/device",\n    ["gateway_key"] = "%s",\n}\n' "$DEVICE_KEY" \
      | docker exec -i koreader-emu sh -c "cat > $F" ;;
  restore)
    docker exec koreader-emu sh -c "rm -f $F $F.old" ;;
  *) echo "usage: $0 cloud|restore"; exit 2 ;;
esac
docker exec koreader-emu sh -c "ls -l $F 2>&1; grep -c gateway_url $F 2>/dev/null; killall luajit"
echo "restarted at $(date -u +%FT%TZ)"
