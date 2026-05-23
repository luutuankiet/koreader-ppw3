#!/bin/bash
set -e
cd /home/ubuntu/dev/koreader-ppw3/dev/koreader_mcp.koplugin

# Kill any existing server
pkill -f 'luajit standalone_test' 2>&1 || true
sleep 1

# Start server in background
luajit standalone_test.lua &
SERVER_PID=$!
sleep 2

echo "=== TEST 1: health ==="
curl -s http://localhost:8888/health
echo ""

echo "=== TEST 2: read_files ==="
curl -s -X POST http://localhost:8888/jsonrpc -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"read_files","params":{"files":[{"path":"/etc/hostname"}]},"id":1}'
echo ""

echo "=== TEST 3: run_command ==="
curl -s -X POST http://localhost:8888/jsonrpc -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"run_command","params":{"command":"uname -a"},"id":2}'
echo ""

echo "=== TEST 4: device_status ==="
curl -s -X POST http://localhost:8888/jsonrpc -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"device_status","params":{},"id":3}'
echo ""

echo "=== TEST 5: list_tools ==="
curl -s -X POST http://localhost:8888/jsonrpc -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"list_tools","params":{},"id":4}'
echo ""

echo "=== TEST 6: error handling (bogus method) ==="
curl -s -X POST http://localhost:8888/jsonrpc -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"bogus","params":{},"id":5}'
echo ""

# Cleanup
kill $SERVER_PID 2>&1 || true
wait $SERVER_PID 2>&1 || true
echo "=== ALL TESTS COMPLETE ==="
