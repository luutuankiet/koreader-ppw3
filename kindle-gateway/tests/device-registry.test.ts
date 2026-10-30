import * as net from 'net';
import { startDeviceListener } from '../src/device-link';
import { DeviceRegistry } from '../src/device-registry';
import { closeServer, FakeDevice, listening } from './helpers/fake-device';

/** Poll for a state change that follows a socket event on the other end. */
async function until(check: () => boolean, ms = 2000): Promise<void> {
  const end = Date.now() + ms;
  while (!check()) {
    if (Date.now() > end) throw new Error('condition not met in time');
    await new Promise((r) => setTimeout(r, 5));
  }
}

describe('device connections', () => {
  let registry: DeviceRegistry;
  let server: net.Server;
  let port: number;
  const devices: FakeDevice[] = [];

  const device = (handler?: ConstructorParameters<typeof FakeDevice>[1]) => {
    const d = new FakeDevice(port, handler);
    devices.push(d);
    return d;
  };

  async function start(options = {}) {
    registry = new DeviceRegistry();
    server = startDeviceListener(registry, 0, '127.0.0.1', options);
    port = await listening(server);
  }

  beforeEach(() => start());

  afterEach(async () => {
    for (const d of devices.splice(0)) d.destroy();
    await closeServer(server);
  });

  test('a device is listed only after its hello is accepted', async () => {
    const d = device();
    await d.connect();
    expect(registry.list()).toHaveLength(0);
    const reply = await d.hello('kindle1', 'abc123abc123');
    expect(reply).toEqual({ type: 'welcome', name: 'kindle1' });
    const [row] = registry.list();
    expect(row).toMatchObject({ name: 'kindle1', status: 'online', idHash: 'abc123abc123', koreaderVersion: 'v-test' });
    expect(row).not.toHaveProperty('link');
  });

  test.each([
    ['not a hello', { type: 'ping2' }],
    ['a name with a space', { type: 'hello', name: 'a b', id_hash: 'aaaaaaaaaaaa' }],
    ['a hash that is not hex', { type: 'hello', name: 'a', id_hash: 'SERIAL-NUMBER' }],
  ])('%s is refused and the connection closed', async (_label, msg) => {
    const d = await device().connect();
    d.sendJson(msg);
    const reply = await d.waitFor((m) => m.type === 'refused');
    expect(reply.reason).toBeTruthy();
    await d.waitClosed();
    expect(registry.list()).toHaveLength(0);
  });

  test('a device that never says hello is dropped', async () => {
    await closeServer(server);
    await start({ helloTimeoutMs: 30 });
    const d = await device().connect();
    await d.waitClosed();
    expect(d.closed).toBe(true);
  });

  test('a name held by a connected device with a different hash is refused', async () => {
    const first = device();
    await first.hello('kindle1', '111111111111');
    const second = device();
    const reply = await second.hello('kindle1', '222222222222');
    expect(reply.type).toBe('refused');
    await second.waitClosed();
    expect(first.closed).toBe(false);
    expect(registry.get('kindle1')!.idHash).toBe('111111111111');
  });

  test('the name is free again once its holder disconnects', async () => {
    const first = device();
    await first.hello('kindle1', '111111111111');
    first.destroy();
    await until(() => registry.list().length === 0);
    expect((await device().hello('kindle1', '222222222222')).type).toBe('welcome');
  });

  test('the same hash replaces the old connection, and the old close does not remove the new entry', async () => {
    const first = device();
    await first.hello('kindle1', '111111111111');
    const second = device();
    expect((await second.hello('kindle1', '111111111111')).type).toBe('welcome');
    await first.waitClosed();
    expect(registry.list()).toHaveLength(1);
    expect(second.closed).toBe(false);
  });

  test('closing the connection takes the device offline at once and fails calls in flight', async () => {
    const d = device();
    await d.hello('kindle1');
    const call = registry.get('kindle1')!.link.call('slow', {}, 5000);
    d.destroy();
    await expect(call).rejects.toThrow(/disconnected/);
    expect(registry.get('kindle1')).toBeUndefined();
  });

  test('a silent connection is closed; any message keeps it open', async () => {
    await closeServer(server);
    await start({ silenceMs: 120 });
    const d = device();
    await d.hello('kindle1');
    for (let i = 0; i < 4; i++) {
      await new Promise((r) => setTimeout(r, 50));
      d.sendJson({ type: 'ping' });
    }
    await d.waitFor((m) => m.type === 'pong');
    expect(registry.get('kindle1')).toBeDefined();
    await d.waitClosed();
    await until(() => registry.list().length === 0);
  });

  test('replies are routed by id, whatever order they come back in', async () => {
    const seen: number[] = [];
    const d = device((_m, _p, id) => { seen.push(id); return undefined; });
    await d.hello('kindle1');
    const { link } = registry.get('kindle1')!;
    const a = link.call('a', {}, 2000);
    const b = link.call('b', {}, 2000);
    await until(() => seen.length === 2);
    d.sendJson({ id: seen[1], result: 'for b' });
    d.sendJson({ id: seen[0], result: 'for a' });
    expect((await a).result).toBe('for a');
    expect((await b).result).toBe('for b');
  });

  test('a reply split across packets is still one message, and a non-JSON line is skipped', async () => {
    const seen: number[] = [];
    const d = device((_m, _p, id) => { seen.push(id); return undefined; });
    await d.hello('kindle1');
    const call = registry.get('kindle1')!.link.call('a', {}, 2000);
    await until(() => seen.length === 1);
    d.sendRaw('not json\n');
    d.sendRaw(`{"id":${seen[0]},"res`);
    await new Promise((r) => setTimeout(r, 20));
    d.sendRaw('ult":"whole"}\n');
    expect((await call).result).toBe('whole');
  });

  test('a call with no reply times out without closing the connection', async () => {
    const d = device();
    await d.hello('kindle1');
    const { link } = registry.get('kindle1')!;
    await expect(link.call('a', {}, 20)).rejects.toThrow(/no reply/);
    expect(link.isOpen).toBe(true);
  });

  test('waitForConnection ignores the old connection and resolves on a new one', async () => {
    const first = device();
    await first.hello('kindle1');
    const after = new Date(Date.now() + 1);
    const waiting = registry.waitForConnection('kindle1', after, 2000);
    first.destroy();
    await until(() => registry.list().length === 0);
    await new Promise((r) => setTimeout(r, 5));
    await device().hello('kindle1');
    expect((await waiting)!.name).toBe('kindle1');
  });

  test('waitForConnection gives up with undefined', async () => {
    expect(await registry.waitForConnection('nobody', new Date(), 10)).toBeUndefined();
  });
});
