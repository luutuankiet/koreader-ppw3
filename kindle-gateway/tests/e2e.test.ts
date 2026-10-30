import http from 'http';
import { DeviceRegistry } from '../src/device-registry';
import { createApp } from '../src/gateway-server';

// --- Fake Kindle (inline, no import needed) ---
function createFakeKindle(port: number) {
  return http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, device: 'fake-kindle' }));
      return;
    }
    if (req.method === 'POST' && req.url === '/jsonrpc') {
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        const rpc = JSON.parse(body);
        let result: unknown;
        switch (rpc.method) {
          case 'read_files':
            result = { files: [{ path: '/mnt/us/test.txt', size: 42 }] };
            break;
          case 'run_command':
            result = { exit_code: 0, stdout: `ran: ${rpc.params?.command || 'none'}` };
            break;
          case 'device_status':
            result = { battery: 85, wifi: true, koreader: { version: '2024.04' } };
            break;
          default:
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ jsonrpc: '2.0', id: rpc.id, error: { code: -32601, message: 'Unknown method' } }));
            return;
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ jsonrpc: '2.0', id: rpc.id, result }));
      });
      return;
    }
    res.writeHead(404);
    res.end();
  });
}

// --- Test helpers ---
function post(port: number, path: string, body: object, extraHeaders?: Record<string, string>): Promise<{ status: number; data: any; headers: http.IncomingHttpHeaders }> {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const req = http.request({ hostname: '127.0.0.1', port, path, method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': data.length, ...extraHeaders } }, (res) => {
      let buf = '';
      res.on('data', (c) => { buf += c; });
      res.on('end', () => {
        try { resolve({ status: res.statusCode!, data: JSON.parse(buf), headers: res.headers }); }
        catch { resolve({ status: res.statusCode!, data: buf, headers: res.headers }); }
      });
    });
    req.on('error', reject);
    req.end(data);
  });
}

function get(port: number, path: string): Promise<{ status: number; data: any }> {
  return new Promise((resolve, reject) => {
    http.get({ hostname: '127.0.0.1', port, path }, (res) => {
      let buf = '';
      res.on('data', (c) => { buf += c; });
      res.on('end', () => {
        try { resolve({ status: res.statusCode!, data: JSON.parse(buf) }); }
        catch { resolve({ status: res.statusCode!, data: buf }); }
      });
    }).on('error', reject);
  });
}

// --- E2E Tests ---
describe('E2E: kindle-gateway + fake kindle', () => {
  const KINDLE_PORT = 18888;
  const GATEWAY_PORT = 19999;

  let fakeKindle: http.Server;
  let gatewayServer: http.Server;

  beforeAll(async () => {
    // Start fake kindle
    fakeKindle = createFakeKindle(KINDLE_PORT);
    await new Promise<void>((resolve) => fakeKindle.listen(KINDLE_PORT, '127.0.0.1', resolve));

    // Start gateway
    const registry = new DeviceRegistry();
    const app = createApp(registry);
    gatewayServer = app.listen(GATEWAY_PORT, '127.0.0.1');
    await new Promise<void>((resolve) => gatewayServer.on('listening', resolve));
  });

  afterAll(async () => {
    await new Promise<void>((resolve) => gatewayServer.close(() => resolve()));
    await new Promise<void>((resolve) => fakeKindle.close(() => resolve()));
  });

  test('gateway health check', async () => {
    const res = await get(GATEWAY_PORT, '/health');
    expect(res.status).toBe(200);
    expect(res.data.ok).toBe(true);
  });

  test('register fake kindle with gateway', async () => {
    const res = await post(GATEWAY_PORT, '/register', {
      name: 'test-kindle',
      ip: '127.0.0.1',
      port: KINDLE_PORT,
      tools: ['read_files', 'run_command', 'device_status'],
    });
    expect(res.status).toBe(200);
    expect(res.data.ok).toBe(true);
    expect(res.data.device.name).toBe('test-kindle');
    expect(res.data.device.status).toBe('online');
  });

  test('MCP initialize (stateless: no session id issued)', async () => {
    const res = await post(GATEWAY_PORT, '/mcp', {
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {
        protocolVersion: '2025-03-26',
        capabilities: {},
        clientInfo: { name: 'e2e-test', version: '1.0.0' },
      },
    }, { 'Accept': 'application/json, text/event-stream' });
    expect(res.status).toBe(200);
    expect(res.data).toBeDefined();
    // Stateless transport: no session ID for a client to hold onto
    expect(res.headers['mcp-session-id']).toBeUndefined();
  });

  test('MCP tool call: list_devices via full protocol', async () => {
    // Initialize (optional on a stateless server, kept to mirror a real client)
    const initRes = await post(GATEWAY_PORT, '/mcp', {
      jsonrpc: '2.0',
      id: 10,
      method: 'initialize',
      params: {
        protocolVersion: '2025-03-26',
        capabilities: {},
        clientInfo: { name: 'e2e-tool-test', version: '1.0.0' },
      },
    }, { 'Accept': 'application/json, text/event-stream' });
    expect(initRes.status).toBe(200);

    // Send initialized notification
    await post(GATEWAY_PORT, '/mcp', {
      jsonrpc: '2.0',
      method: 'notifications/initialized',
    }, { 'Accept': 'application/json, text/event-stream' });

    // Call list_devices tool
    const toolRes = await post(GATEWAY_PORT, '/mcp', {
      jsonrpc: '2.0',
      id: 11,
      method: 'tools/call',
      params: {
        name: 'list_devices',
        arguments: {},
      },
    }, { 'Accept': 'application/json, text/event-stream' });
    expect(toolRes.status).toBe(200);
    // StreamableHTTP may return SSE or JSON — parse accordingly
    let content: any;
    if (typeof toolRes.data === 'string' && toolRes.data.includes('data:')) {
      // SSE format: extract JSON from 'data: {...}' lines
      const lines = toolRes.data.split('\n').filter((l: string) => l.startsWith('data:'));
      for (const line of lines) {
        const json = JSON.parse(line.slice(5).trim());
        if (json.result?.content) {
          content = json.result.content;
          break;
        }
      }
    } else {
      content = toolRes.data?.result?.content;
    }
    expect(content).toBeDefined();
    if (content && content[0]) {
      const devices = JSON.parse(content[0].text);
      expect(devices.length).toBeGreaterThanOrEqual(1);
      expect(devices[0].name).toBe('test-kindle');
    }
  });

  describe('stateless transport', () => {
    const MCP_ACCEPT = { 'Accept': 'application/json, text/event-stream' };
    // Responses may arrive as SSE; pull the JSON-RPC payload out of the data: line.
    const rpcPayload = (data: any) => {
      if (typeof data !== 'string') return data;
      const line = data.split('\n').find((l: string) => l.startsWith('data:'));
      return line ? JSON.parse(line.slice(5)) : data;
    };
    const toolNames = (data: any) => rpcPayload(data).result.tools.map((t: { name: string }) => t.name);

    test('tools/list works without a prior initialize', async () => {
      const res = await post(GATEWAY_PORT, '/mcp', { jsonrpc: '2.0', id: 40, method: 'tools/list', params: {} }, MCP_ACCEPT);
      expect(res.status).toBe(200);
      expect(res.headers['mcp-session-id']).toBeUndefined();
      expect(toolNames(res.data)).toContain('list_devices');
    });

    test('a stale or bogus mcp-session-id header is ignored', async () => {
      const res = await post(GATEWAY_PORT, '/mcp', { jsonrpc: '2.0', id: 41, method: 'tools/list', params: {} },
        { ...MCP_ACCEPT, 'mcp-session-id': 'bogus' });
      expect(res.status).toBe(200);
      expect(toolNames(res.data)).toContain('list_devices');
    });

    test('GET and DELETE /mcp return 405', async () => {
      for (const method of ['GET', 'DELETE']) {
        const res = await new Promise<{ status: number; body: string }>((resolve, reject) => {
          http.request({ hostname: '127.0.0.1', port: GATEWAY_PORT, path: '/mcp', method, headers: MCP_ACCEPT }, (r) => {
            let buf = '';
            r.on('data', (c) => { buf += c; });
            r.on('end', () => resolve({ status: r.statusCode!, body: buf }));
          }).on('error', reject).end();
        });
        expect(res.status).toBe(405);
        expect(JSON.parse(res.body).error.message).toMatch(/Method not allowed/);
      }
    });
  });

  test('fake kindle health is reachable from gateway host', async () => {
    const res = await get(KINDLE_PORT, '/health');
    expect(res.status).toBe(200);
    expect(res.data.ok).toBe(true);
    expect(res.data.device).toBe('fake-kindle');
  });

  test('fake kindle responds to JSON-RPC directly', async () => {
    const res = await post(KINDLE_PORT, '/jsonrpc', {
      jsonrpc: '2.0',
      id: 99,
      method: 'device_status',
      params: {},
    });
    expect(res.status).toBe(200);
    expect(res.data.result.battery).toBe(85);
    expect(res.data.result.koreader.version).toBe('2024.04');
  });

  test('registration with missing fields returns 400', async () => {
    const res = await post(GATEWAY_PORT, '/register', { name: 'bad-device' });
    expect(res.status).toBe(400);
    expect(res.data.error).toBeDefined();
  });
});
