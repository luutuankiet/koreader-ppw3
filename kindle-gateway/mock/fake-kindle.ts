import http from 'http';

const PORT = parseInt(process.env.KINDLE_PORT || '8888', 10);

const server = http.createServer((req, res) => {
  // Health endpoint
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, device: 'fake-kindle', battery: 85, wifi: true }));
    return;
  }

  // JSON-RPC endpoint
  if (req.method === 'POST' && req.url === '/jsonrpc') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      try {
        const request = JSON.parse(body);
        console.log(`[fake-kindle] RPC call: ${request.method}`);

        const result = handleRpc(request.method, request.params);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          jsonrpc: '2.0',
          id: request.id,
          result,
        }));
      } catch (err) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          jsonrpc: '2.0',
          id: null,
          error: { code: -32700, message: 'Parse error' },
        }));
      }
    });
    return;
  }

  res.writeHead(404);
  res.end('Not Found');
});

function handleRpc(method: string, params?: Record<string, unknown>): unknown {
  switch (method) {
    case 'read_files':
      return {
        files: [
          { path: '/mnt/us/documents/book.epub', size: 1024000, modified: '2025-01-15T10:30:00Z' },
          { path: '/mnt/us/documents/notes.txt', size: 256, modified: '2025-01-20T14:00:00Z' },
        ],
      };

    case 'run_command':
      const cmd = (params?.command as string) || 'echo hello';
      return {
        exit_code: 0,
        stdout: `[fake-kindle] executed: ${cmd}\nOK`,
        stderr: '',
      };

    case 'device_status':
      return {
        device: 'Kindle Paperwhite 3',
        firmware: '5.16.2.1.1',
        battery: 85,
        wifi: true,
        ip: '192.168.1.100',
        storage: { total: '4GB', free: '2.1GB' },
        koreader: { version: '2024.04', running: true },
      };

    default:
      return { error: `Unknown method: ${method}` };
  }
}

server.listen(PORT, () => {
  console.log(`[fake-kindle] Mock Kindle server running on port ${PORT}`);
});

export { server };
