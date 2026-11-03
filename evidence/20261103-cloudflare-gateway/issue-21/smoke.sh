#!/usr/bin/env bash
# Smoke the deployed Worker: /health, /mcp without and with the agent key, both MCP protocol versions.
# Needs AGENT_KEY in the environment (source cfenv.sh). Never prints the key.
U=https://kindle.kenluu.org
H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
echo "== GET /health"; curl -s -w ' [%{http_code}]\n' $U/health
echo "== POST /mcp no key"; curl -s -w ' [%{http_code}]\n' "${H[@]}" -X POST $U/mcp -d '{}'
echo "== POST /mcp wrong key"; curl -s -w ' [%{http_code}]\n' "${H[@]}" -H 'Authorization: Bearer nope' -X POST $U/mcp -d '{}'
echo "== GET /device no key"; curl -s -w ' [%{http_code}]\n' $U/device
echo "== PUT /inbox no key"; curl -s -w ' [%{http_code}]\n' -X PUT --data-binary x $U/inbox/emu/x.tar.gz
A=(-H "Authorization: Bearer $AGENT_KEY")
echo "== 2025-11-25 initialize"
curl -s -D - "${H[@]}" "${A[@]}" -X POST $U/mcp -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' | grep -iE '^(HTTP|mcp-session-id)|jsonrpc' | cut -c1-400
echo "== 2025-11-25 tools/list"
curl -s "${H[@]}" "${A[@]}" -H 'MCP-Protocol-Version: 2025-11-25' -X POST $U/mcp -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | python3 -c "import sys,json;t=sys.stdin.read();t=t[t.index('{'):] ;d=json.loads(t.split('\n')[0]);print(len(d['result']['tools']),'tools:',' '.join(sorted(x['name'] for x in d['result']['tools'])))"
echo "== 2026-07-28 server/discover"
curl -s -D - "${H[@]}" "${A[@]}" -H 'MCP-Protocol-Version: 2026-07-28' -X POST $U/mcp -d '{"jsonrpc":"2.0","id":3,"method":"server/discover","params":{}}' | grep -iE '^(HTTP|mcp-session-id)|jsonrpc' | cut -c1-400
