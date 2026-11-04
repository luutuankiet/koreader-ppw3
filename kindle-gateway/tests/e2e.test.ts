import http from 'http';
import * as net from 'net';
import { startDeviceListener } from '../src/device-link';
import { closeServer, FakeDevice, listening } from './helpers/fake-device';
import { DeviceRegistry } from '../src/device-registry';
import { createApp } from '../src/gateway-server';

let snapshotId = 0;
let uiActCalls = 0;
let fake: FakeDevice;
const fakeSnapshot = (id: number) => ({
  snapshot: id,
  window: 'Menu',
  total: 45,
  nodes: Array.from({ length: 45 }, (_, i) => ({ ref: `${id}_${i + 1}`, kind: 'row', text: `Book ${i + 1}`, state: '' })),
});

function fakeTools(method: string, params: any, id: number): unknown {
  switch (method) {
    case 'read_files': return { files: [{ path: '/mnt/us/test.txt', size: 42 }] };
    case 'run_command': return { exit_code: 0, stdout: `ran: ${params?.command || 'none'}` };
    case 'ui_snapshot':
      snapshotId += 1;
      return fakeSnapshot(snapshotId);
    case 'ui_act':
      uiActCalls += 1;
      if (params?.ref === '999_1') {
        fake.sendJson({ id, error: { code: -32602, message: 'stale reference 999_1, take a new snapshot' } });
        return undefined;
      }
      snapshotId += 1;
      return { result: `${params?.what} done`, snapshot: fakeSnapshot(snapshotId), logs: ['a log line'] };
    case 'device_status': return { battery: 85, wifi: true, koreader: { version: '2024.04' } };
    default: return { unexpected: method };
  }
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
  const GATEWAY_PORT = 19999;

  let listener: net.Server;
  let gatewayServer: http.Server;

  beforeAll(async () => {
    const registry = new DeviceRegistry();
    listener = startDeviceListener(registry, 0, '127.0.0.1');
    fake = new FakeDevice(await listening(listener), fakeTools);
    await fake.hello('test-kindle');

    const app = createApp(registry);
    gatewayServer = app.listen(GATEWAY_PORT, '127.0.0.1');
    await new Promise<void>((resolve) => gatewayServer.on('listening', resolve));
  });

  afterAll(async () => {
    fake.destroy();
    await new Promise<void>((resolve) => gatewayServer.close(() => resolve()));
    await closeServer(listener);
  });

  test('gateway health check', async () => {
    const res = await get(GATEWAY_PORT, '/health');
    expect(res.status).toBe(200);
    expect(res.data.ok).toBe(true);
  });

  test('/register is gone', async () => {
    const res = await post(GATEWAY_PORT, '/register', { name: 'x', ip: '127.0.0.1', port: 1 });
    expect(res.status).toBe(404);
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
      expect(toolNames(res.data)).toEqual(expect.arrayContaining(['wait_for', 'power_button', 'read_log']));
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

  describe('snapshot and tap tools', () => {
    const call = async (name: string, args: object) => {
      const res = await post(GATEWAY_PORT, '/mcp', { jsonrpc: '2.0', id: 50, method: 'tools/call', params: { name, arguments: args } },
        { 'Accept': 'application/json, text/event-stream' });
      const line = String(res.data).split('\n').find((l: string) => l.startsWith('data:'));
      return (line ? JSON.parse(line.slice(5)) : res.data).result;
    };

    test('snapshot returns the cut list', async () => {
      const r = await call('snapshot', { device: 'test-kindle' });
      expect(r.isError).toBeFalsy();
      expect(r.content[0].text).toContain('[+5 more]');
      expect(r.content).toHaveLength(1); // no screenshot unless asked
    });

    test('tap on a fresh reference returns result, snapshot and logs', async () => {
      const s = await call('snapshot', { device: 'test-kindle' });
      const ref = /\[(\d+_1)\]/.exec(s.content[0].text)![1];
      const r = await call('tap', { device: 'test-kindle', ref });
      expect(r.content[0].text).toContain('tap done');
      expect(r.content[0].text).toContain('[+5 more]');
      expect(r.content[0].text).toContain('a log line');
    });

    test('a reference older than two snapshots is stale, without calling the device', async () => {
      const first = await call('snapshot', { device: 'test-kindle' });
      const ref = /\[(\d+_1)\]/.exec(first.content[0].text)![1];
      await call('snapshot', { device: 'test-kindle' });
      await call('snapshot', { device: 'test-kindle' });
      const before = uiActCalls;
      const r = await call('tap', { device: 'test-kindle', ref });
      expect(r.isError).toBe(true);
      expect(r.content[0].text).toMatch(/stale reference .*take a new snapshot/);
      expect(uiActCalls).toBe(before);
    });

    test('a device error reaches the agent and leaves the device online', async () => {
      const r = await call('tap', { device: 'test-kindle', ref: '999_1' });
      expect(r.isError).toBe(true);
      expect(r.content[0].text).toContain('stale reference 999_1');
      const list = await call('list_devices', {});
      expect(JSON.parse(list.content[0].text)[0].name).toBe('test-kindle');
    });
  });

  describe('tools reach the device over its connection', () => {
    const MCP_ACCEPT = { 'Accept': 'application/json, text/event-stream' };
    async function callTool(id: number, name: string, args: object): Promise<any> {
      const res = await post(GATEWAY_PORT, '/mcp', { jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args } }, MCP_ACCEPT);
      const payload = typeof res.data === 'string'
        ? JSON.parse(res.data.split('\n').find((l: string) => l.startsWith('data:'))!.slice(5))
        : res.data;
      return payload.result;
    }

    test('run_command goes down the link and its reply comes back', async () => {
      const result = await callTool(50, 'run_command', { device: 'test-kindle', params: JSON.stringify({ command: 'uptime' }) });
      expect(result.content[0].text).toContain('ran: uptime');
    });

    test('a device with no connection is reported as not connected', async () => {
      const result = await callTool(51, 'run_command', { device: 'absent', params: JSON.stringify({ command: 'uptime' }) });
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toMatch(/not connected/);
    });
  });
});
