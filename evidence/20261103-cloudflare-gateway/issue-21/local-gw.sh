#!/usr/bin/env bash
# Call one tool on the thinkpad Node gateway (stateless MCP at 127.0.0.1:9999/mcp).
#   local-gw.sh <tool> '<json args>'
U=http://127.0.0.1:9999/mcp
H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
curl -s "${H[@]}" -X POST $U -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":${2:-{\}}}}" | sed -e 's/^data: //' | grep '^{' | head -1 | python3 -c "import sys,json;d=json.loads(sys.stdin.read());r=d.get('result') or d;print('\n'.join(c.get('text','['+c.get('type','')+']') for c in r.get('content',[])) if 'content' in r else json.dumps(d))"
