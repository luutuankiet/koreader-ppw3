#!/usr/bin/env bash
# Live check of the R2 inbox under `wrangler dev --port 8788`: builds a bundle the way
# koreader_mcp's diagnostics.lua does (manifest.json, crash.log, snapshot.json, screenshot.png,
# tar -czf), uploads it with curl like the device (PUT, Content-Type application/gzip,
# Content-Length, Bearer device key), then tries the refusals. Keys come from keys.env and
# are never echoed.
# Usage: live-upload.sh <worktree root>
set -euo pipefail
ROOT=$1
EV=$(cd "$(dirname "$0")" && pwd)
KEYS=<topic-folder>/keys.env
DEVICE_KEY=$(grep '^DEVICE_KEY=' "$KEYS" | cut -d= -f2-)
AGENT_KEY=$(grep '^AGENT_KEY=' "$KEYS" | cut -d= -f2-)
URL=http://127.0.0.1:8788
DEVICE=live-test
STAMP=20261103-230000

STAGE=$(mktemp -d)
cat > "$STAGE/manifest.json" <<'JSON'
{"koreader_version":"v2026.07.1","plugin":"koreader_mcp","device_model":"emulator","sent_at":"2026-11-03 23:00:00"}
JSON
printf '11/03/26-22:58:01 WARN  not a real crash, live check of the R2 inbox\n11/03/26-22:58:02 INFO  second line\n' > "$STAGE/crash.log"
cat > "$STAGE/snapshot.json" <<'JSON'
{"snapshot":7,"window":"FileManager","total":2,"nodes":[{"ref":"7_1","kind":"button","text":"Home","state":""},{"ref":"7_2","kind":"text","text":"diagnostics live check","state":""}]}
JSON
# A real PNG at the Kindle's resolution, so the bundle has a realistic size.
(cd "$ROOT/kindle-gateway" && node -e '
  require("sharp")({ create: { width: 1072, height: 1448, channels: 3, background: "#ccc" } }).greyscale()
    .png().toFile(process.argv[1]).then(() => {});' "$STAGE/screenshot.png")
BUNDLE="$EV/$STAMP.tar.gz"
(cd "$STAGE" && tar --owner=0 --group=0 --numeric-owner -czf "$BUNDLE" manifest.json crash.log snapshot.json screenshot.png)
rm -rf "$STAGE"
SIZE=$(stat -c %s "$BUNDLE")
echo "bundle: $(basename "$BUNDLE"), $SIZE bytes"

put() { # put <label> <path> <file> [curl args...]
  local label=$1 path=$2 file=$3; shift 3
  printf '%-44s -> ' "$label"
  curl -sS -o /tmp/r2-live-body -w '%{http_code} ' -X PUT --data-binary @"$file" "$@" "$URL$path"
  cat /tmp/r2-live-body; echo
}

put "upload with the device key"       "/inbox/$DEVICE/$STAMP.tar.gz" "$BUNDLE" \
  -H "Authorization: Bearer $DEVICE_KEY" -H 'Content-Type: application/gzip'
put "same name again"                   "/inbox/$DEVICE/$STAMP.tar.gz" "$BUNDLE" \
  -H "Authorization: Bearer $DEVICE_KEY" -H 'Content-Type: application/gzip'
put "no key"                            "/inbox/$DEVICE/other.tar.gz" "$BUNDLE"
put "agent key"                         "/inbox/$DEVICE/other.tar.gz" "$BUNDLE" -H "Authorization: Bearer $AGENT_KEY"
put "bad name"                          "/inbox/$DEVICE/x%2F..%2Fy.tar.gz" "$BUNDLE" -H "Authorization: Bearer $DEVICE_KEY"
head -c $((10 * 1024 * 1024 + 1)) /dev/zero > /tmp/r2-live-big
put "10 MiB + 1 with Content-Length"   "/inbox/$DEVICE/big.tar.gz" /tmp/r2-live-big -H "Authorization: Bearer $DEVICE_KEY"
printf '\x1f\x8b' | cat - /tmp/r2-live-big > /tmp/r2-live-big-gz
put "10 MiB + 3 chunked (no length)"   "/inbox/$DEVICE/big2.tar.gz" /tmp/r2-live-big-gz \
  -H "Authorization: Bearer $DEVICE_KEY" -H 'Transfer-Encoding: chunked'
rm -f /tmp/r2-live-big /tmp/r2-live-big-gz /tmp/r2-live-body
