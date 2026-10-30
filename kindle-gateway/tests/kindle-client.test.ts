import * as net from 'net';
import { startDeviceListener } from '../src/device-link';
import { DeviceRegistry } from '../src/device-registry';
import { KindleClient } from '../src/kindle-client';
import { closeServer, FakeDevice, listening } from './helpers/fake-device';

describe('KindleClient', () => {
  let server: net.Server;
  let registry: DeviceRegistry;
  let fake: FakeDevice;

  beforeEach(async () => {
    registry = new DeviceRegistry();
    server = startDeviceListener(registry, 0, '127.0.0.1');
    fake = new FakeDevice(await listening(server), (method, params) =>
      method === 'silent' ? undefined : { method, params });
    await fake.hello('test-kindle');
  });

  afterEach(async () => {
    fake.destroy();
    await closeServer(server);
  });

  test('callTool returns the reply to its call', async () => {
    const client = new KindleClient(registry.get('test-kindle')!);
    const response = await client.callTool('read_files', { path: '/test' });
    expect(response.result).toEqual({ method: 'read_files', params: { path: '/test' } });
  });

  test('a device error reply is returned, not thrown', async () => {
    fake.handler = (_m, _p, id) => { fake.sendJson({ id, error: { code: -32601, message: 'Unknown method' } }); return undefined; };
    const response = await new KindleClient(registry.get('test-kindle')!).callTool('nope');
    expect(response.error?.message).toBe('Unknown method');
  });

  test('no reply throws the timeout message callers show to the agent', async () => {
    const client = new KindleClient(registry.get('test-kindle')!);
    await expect(client.callTool('silent', {}, 20)).rejects.toThrow('Tool call to test-kindle timed out after 0.02s');
  });

  test('a dropped connection throws', async () => {
    const client = new KindleClient(registry.get('test-kindle')!);
    fake.handler = () => { fake.destroy(); return undefined; };
    await expect(client.callTool('x')).rejects.toThrow(/disconnected/);
  });
});
