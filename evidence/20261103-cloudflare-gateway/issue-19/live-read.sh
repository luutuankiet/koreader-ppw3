#!/usr/bin/env bash
# Live read-back over the real /mcp endpoint of `wrangler dev --port 8788` with plain curl
# JSON-RPC (protocol 2025-11-25, stateless: no initialize or session needed per request):
# tools/list, then list_diagnostics and read_diagnostics on the bundle live-upload.sh stored.
# The image block is summarised (mime type, size, PNG magic, width x height), never printed.
# AGENT_KEY comes from keys.env and is never echoed.
# Usage: live-read.sh [device]
set -euo pipefail
KEYS=<topic-folder>/keys.env
AGENT_KEY=$(grep '^AGENT_KEY=' "$KEYS" | cut -d= -f2-)
URL=http://127.0.0.1:8788/mcp
DEVICE=${1:-live-test}

rpc() { # rpc <label> <json body> [auth header value]
  local label=$1 body=$2 auth=${3:-Bearer $AGENT_KEY}
  echo "== $label"
  echo "request: $body"
  curl -sS -w '\nhttp %{http_code}\n' -X POST "$URL" \
    -H "Authorization: $auth" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' -H 'MCP-Protocol-Version: 2025-11-25' \
    --data "$body" | python3 -c '
import sys, json, base64, struct
raw = sys.stdin.read()
body, _, status = raw.rpartition("\nhttp ")
print("http", status.strip())
data = [l[6:] for l in body.splitlines() if l.startswith("data: ")]
if data:
    print("framing: text/event-stream, one message event")
    body = data[0]
try:
    msg = json.loads(body)
except Exception:
    print(body); sys.exit(0)
res = msg.get("result")
if res is None:
    print(json.dumps(msg, indent=2)); sys.exit(0)
if "tools" in res:
    print("tools:", " ".join(sorted(t["name"] for t in res["tools"])))
    for t in res["tools"]:
        if t["name"].endswith("_diagnostics"):
            print(" ", t["name"], "required:", t["inputSchema"].get("required", []), "properties:", sorted(t["inputSchema"].get("properties", {})))
    sys.exit(0)
print("isError:", res.get("isError", False))
for b in res.get("content", []):
    if b["type"] == "text":
        print("--- text block"); print(b["text"])
    else:
        data = base64.b64decode(b["data"])
        png = data[:8] == bytes([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        w, h = struct.unpack(">II", data[16:24]) if png else (None, None)
        print("--- %s block: %s, %d bytes, png magic %s, %sx%s" % (b["type"], b["mimeType"], len(data), png, w, h))
'
  echo
}

rpc "tools/list" '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
rpc "list_diagnostics (all devices)" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_diagnostics","arguments":{}}}'
rpc "list_diagnostics device=$DEVICE" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_diagnostics","arguments":{"device":"'"$DEVICE"'"}}}'
rpc "read_diagnostics device=$DEVICE (newest)" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"read_diagnostics","arguments":{"device":"'"$DEVICE"'"}}}'
rpc "read_diagnostics unknown bundle" '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"read_diagnostics","arguments":{"device":"'"$DEVICE"'","file":"19990101-000000.tar.gz"}}}'
rpc "list_diagnostics with the device key (must be refused)" '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_diagnostics","arguments":{}}}' "Bearer $(grep '^DEVICE_KEY=' "$KEYS" | cut -d= -f2-)"
