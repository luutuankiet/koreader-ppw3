import http from 'http';
import { KindleClient } from '../src/kindle-client';
import { DeviceInfo } from '../src/device-registry';

describe('KindleClient', () => {
  let server: http.Server;
  let serverPort: number;

  beforeAll((done) => {
    server = http.createServer((req, res) => {
      if (req.method === 'GET' && req.url === '/health') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
        return;
      }

      if (req.method === 'POST' && req.url === '/jsonrpc') {
        let body = '';
        req.on('data', (chunk) => { body += chunk; });
        req.on('end', () => {
          const request = JSON.parse(body);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({
            jsonrpc: '2.0',
            id: request.id,
            result: { method: request.method, echo: true },
          }));
        });
        return;
      }

      res.writeHead(404);
      res.end();
    });

    server.listen(0, () => {
      serverPort = (server.address() as any).port;
      done();
    });
  });

  afterAll((done) => {
    server.close(done);
  });

  function makeDevice(): DeviceInfo {
    return {
      name: 'test-kindle',
      ip: '127.0.0.1',
      port: serverPort,
      tools: ['read_files'],
      status: 'online',
      lastSeen: new Date(),
      registeredAt: new Date(),
    };
  }

  test('healthCheck returns true for healthy server', async () => {
    const client = new KindleClient(makeDevice());
    const result = await client.healthCheck();
    expect(result).toBe(true);
  });

  test('healthCheck returns false for unreachable server', async () => {
    const device = makeDevice();
    device.port = 1; // Unreachable
    const client = new KindleClient(device);
    const result = await client.healthCheck();
    expect(result).toBe(false);
  });

  test('callTool sends JSON-RPC request and returns response', async () => {
    const client = new KindleClient(makeDevice());
    const response = await client.callTool('read_files', { path: '/test' });
    expect(response.jsonrpc).toBe('2.0');
    expect(response.result).toEqual({ method: 'read_files', echo: true });
  });

  test('callTool throws on unreachable server', async () => {
    const device = makeDevice();
    device.port = 1;
    const client = new KindleClient(device);
    await expect(client.callTool('read_files')).rejects.toThrow();
  });
});
