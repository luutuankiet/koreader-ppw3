import { SELF, env, evictDurableObject, runInDurableObject } from 'cloudflare:test';
import { afterEach, describe, expect, it } from 'vitest';
import { DEVICE_PING, DEVICE_PONG, type Hub } from '../src/hub';

const DEVICE_KEY = 'test-device-key';
const AGENT_KEY = 'test-agent-key';

function hubStub(): DurableObjectStub<Hub> {
  return env.HUB.get(env.HUB.idFromName('hub'));
}

/** A fake device on the client end of a WebSocket. Answers `echo` calls when `autoAnswer`. */
class FakeDevice {
  private queue: string[] = [];
  private wakers: Array<() => void> = [];
  closed: { code: number; reason: string } | null = null;
  autoAnswer = true;

  constructor(readonly ws: WebSocket) {
    ws.addEventListener('message', (e) => {
      const text = typeof e.data === 'string' ? e.data : new TextDecoder().decode(e.data as ArrayBuffer);
      const msg = JSON.parse(text);
      if (this.autoAnswer && typeof msg.id === 'number' && msg.method === 'echo') {
        ws.send(JSON.stringify({ id: msg.id, result: { echoed: msg.params } }));
      } else if (this.autoAnswer && typeof msg.id === 'number' && msg.method === 'fail') {
        ws.send(JSON.stringify({ id: msg.id, error: { code: -32000, message: 'device says no' } }));
      } else {
        this.queue.push(text);
      }
      this.wake();
    });
    ws.addEventListener('close', (e) => {
      this.closed = { code: e.code, reason: e.reason };
      this.wake();
    });
  }

  private wake(): void {
    const w = this.wakers;
    this.wakers = [];
    for (const f of w) f();
  }

  /** Next message not handled by autoAnswer, raw text. */
  async nextText(timeoutMs = 2000): Promise<string> {
    const deadline = Date.now() + timeoutMs;
    while (this.queue.length === 0) {
      if (this.closed) throw new Error(`socket closed: ${this.closed.code} ${this.closed.reason}`);
      if (Date.now() > deadline) throw new Error('no message in time');
      await new Promise<void>((resolve) => {
        this.wakers.push(resolve);
        setTimeout(resolve, 50);
      });
    }
    return this.queue.shift()!;
  }

  async next(timeoutMs = 2000): Promise<Record<string, unknown>> {
    return JSON.parse(await this.nextText(timeoutMs));
  }

  async waitClosed(timeoutMs = 2000): Promise<{ code: number; reason: string }> {
    const deadline = Date.now() + timeoutMs;
    while (!this.closed) {
      if (Date.now() > deadline) throw new Error('socket did not close');
      await new Promise<void>((resolve) => {
        this.wakers.push(resolve);
        setTimeout(resolve, 50);
      });
    }
    return this.closed;
  }

  hello(name: string, idHash = 'abcdef0123456789'): void {
    this.ws.send(JSON.stringify({ type: 'hello', name, id_hash: idHash, koreader_version: 'v2026.07.1', plugin_versions: { koreader_mcp: '1.0' } }));
  }

  close(): void {
    try { this.ws.close(1000, 'test done'); } catch { /* already closed */ }
  }
}

const open: FakeDevice[] = [];

/** Settle an RPC call expected to fail. `expect(rpc).rejects` leaves the remote rejection
 *  reported as unhandled, so catch it directly. */
async function rejectionOf(p: Promise<unknown>): Promise<Error> {
  try {
    await p;
  } catch (err) {
    return err as Error;
  }
  throw new Error('expected the call to fail');
}

async function connect(): Promise<FakeDevice> {
  const res = await SELF.fetch('https://gw.test/device', {
    headers: { Upgrade: 'websocket', Authorization: `Bearer ${DEVICE_KEY}` },
  });
  expect(res.status).toBe(101);
  const ws = res.webSocket!;
  ws.accept();
  const dev = new FakeDevice(ws);
  open.push(dev);
  return dev;
}

async function online(name: string, idHash?: string): Promise<FakeDevice> {
  const dev = await connect();
  dev.hello(name, idHash);
  expect(await dev.next()).toEqual({ type: 'welcome', name });
  return dev;
}

afterEach(() => {
  for (const d of open.splice(0)) d.close();
});

describe('Worker routing and auth', () => {
  it('serves /health without a key', async () => {
    const res = await SELF.fetch('https://gw.test/health');
    expect(res.status).toBe(200);
    expect(await res.text()).toBe('ok');
  });

  it('answers 404 for anything else', async () => {
    expect((await SELF.fetch('https://gw.test/')).status).toBe(404);
    expect((await SELF.fetch('https://gw.test/debug/devices')).status).toBe(404);
  });

  it('rejects /device without a key', async () => {
    const res = await SELF.fetch('https://gw.test/device', { headers: { Upgrade: 'websocket' } });
    expect(res.status).toBe(401);
    expect(res.webSocket).toBeNull();
  });

  it('rejects /device with a wrong key', async () => {
    const res = await SELF.fetch('https://gw.test/device', {
      headers: { Upgrade: 'websocket', Authorization: 'Bearer not-the-key' },
    });
    expect(res.status).toBe(401);
    expect(res.webSocket).toBeNull();
  });

  it('rejects the agent key on /device', async () => {
    const res = await SELF.fetch('https://gw.test/device', {
      headers: { Upgrade: 'websocket', Authorization: `Bearer ${AGENT_KEY}` },
    });
    expect(res.status).toBe(401);
  });

  it('wants a WebSocket upgrade on /device', async () => {
    const res = await SELF.fetch('https://gw.test/device', { headers: { Authorization: `Bearer ${DEVICE_KEY}` } });
    expect(res.status).toBe(426);
  });
});

describe('hello', () => {
  it('welcomes a valid hello and lists the device', async () => {
    await online('kindle-a');
    const devices = await hubStub().listDevices();
    const d = devices.find((x) => x.name === 'kindle-a');
    expect(d).toMatchObject({ name: 'kindle-a', status: 'online', idHash: 'abcdef0123456789', koreaderVersion: 'v2026.07.1' });
  });

  it('refuses a name held by another device and closes the socket', async () => {
    await online('kindle-b', 'aaaaaaaa11111111');
    const intruder = await connect();
    intruder.hello('kindle-b', 'bbbbbbbb22222222');
    expect(await intruder.next()).toEqual({ type: 'refused', reason: "name 'kindle-b' is held by another device" });
    expect((await intruder.waitClosed()).code).toBe(1008);
    const names = (await hubStub().listDevices()).filter((x) => x.name === 'kindle-b');
    expect(names).toHaveLength(1);
    expect(names[0].idHash).toBe('aaaaaaaa11111111');
  });

  it('lets the same device replace its old connection', async () => {
    const old = await online('kindle-c', 'cccccccc33333333');
    await online('kindle-c', 'cccccccc33333333');
    expect((await old.waitClosed()).reason).toBe('replaced by a new connection');
    expect((await hubStub().listDevices()).filter((x) => x.name === 'kindle-c')).toHaveLength(1);
  });

  it('refuses a malformed hello', async () => {
    const dev = await connect();
    dev.ws.send(JSON.stringify({ type: 'hello', name: 'bad name!', id_hash: 'abcdef0123456789' }));
    expect(await dev.next()).toEqual({ type: 'refused', reason: 'name must be 1-32 of [A-Za-z0-9._-]' });
    await dev.waitClosed();
  });
});

describe('calls', () => {
  it('round-trips a call and its result', async () => {
    await online('kindle-rt');
    const reply = await hubStub().call('kindle-rt', 'echo', { x: 1 }, 2000);
    expect(reply.result).toEqual({ echoed: { x: 1 } });
    expect(typeof reply.id).toBe('number');
  });

  it('passes a device-side error back as a reply', async () => {
    await online('kindle-err');
    const reply = await hubStub().call('kindle-err', 'fail', {}, 2000);
    expect(reply.error).toEqual({ code: -32000, message: 'device says no' });
  });

  it('times out when the device says nothing', async () => {
    const dev = await online('kindle-slow');
    dev.autoAnswer = false;
    expect((await rejectionOf(hubStub().call('kindle-slow', 'echo', {}, 300))).message).toBe('no reply to echo within 0.3s');
    // The call did reach the device.
    expect(await dev.next()).toMatchObject({ method: 'echo', params: {} });
  });

  it('rejects a call to a device that is not connected', async () => {
    expect((await rejectionOf(hubStub().call('nobody', 'echo', {}, 300))).message).toBe("device 'nobody' is not connected");
  });

  it('rejects a pending call when the device disconnects', async () => {
    const dev = await online('kindle-drop');
    dev.autoAnswer = false;
    const pending = rejectionOf(hubStub().call('kindle-drop', 'echo', {}, 5000));
    await dev.next(); // the call arrived
    dev.close();
    expect((await pending).message).toMatch(/^device disconnected/);
  });
});

describe('hibernation', () => {
  it('pins the heartbeat frames the Lua client sends and expects', () => {
    // koreader_mcp's WebSocket transport sends and matches these bytes exactly.
    expect(DEVICE_PING).toBe('{"type":"ping"}');
    expect(DEVICE_PONG).toBe('{"type":"pong"}');
  });

  it('answers the ping without waking the object', async () => {
    const dev = await online('kindle-ping');
    const stub = hubStub();
    await evictDurableObject(stub);
    dev.ws.send(DEVICE_PING);
    expect(await dev.nextText()).toBe(DEVICE_PONG);
    // A fresh instance starts at runInDurableObject: had the ping woken the object, the
    // instance that handled it would have counted it.
    const handled = await runInDurableObject(stub, (instance: Hub) => instance.handledMessages);
    expect(handled).toBe(0);
    const d = (await stub.listDevices()).find((x) => x.name === 'kindle-ping');
    expect(d).toBeDefined();
  });

  it('still answers a ping that is not byte-identical, by waking', async () => {
    const dev = await online('kindle-ping2');
    dev.ws.send(DEVICE_PING + '\n');
    expect(await dev.nextText()).toBe(DEVICE_PONG);
  });

  it('rebuilds the registry and completes a call after the object hibernated and woke', async () => {
    await online('kindle-wake', '0123456789abcdef');
    const stub = hubStub();
    await evictDurableObject(stub); // in-memory state gone; the socket is hibernated, not closed
    const devices = await stub.listDevices();
    expect(devices.find((x) => x.name === 'kindle-wake')).toMatchObject({ idHash: '0123456789abcdef', koreaderVersion: 'v2026.07.1' });
    const reply = await stub.call('kindle-wake', 'echo', { after: 'wake' }, 2000);
    expect(reply.result).toEqual({ echoed: { after: 'wake' } });
  });

  it('keeps refusing a duplicate name after waking', async () => {
    await online('kindle-dup', '1111111111111111');
    await evictDurableObject(hubStub());
    const intruder = await connect();
    intruder.hello('kindle-dup', '2222222222222222');
    expect(await intruder.next()).toMatchObject({ type: 'refused' });
  });
});

describe('waitForReconnect', () => {
  it('resolves when the device comes back', async () => {
    const old = await online('kindle-re', 'eeeeeeee55555555');
    const stub = hubStub();
    const waiting = stub.waitForReconnect('kindle-re', 5000);
    old.close();
    await new Promise((r) => setTimeout(r, 20));
    await online('kindle-re', 'eeeeeeee55555555');
    const back = await waiting;
    expect(back?.name).toBe('kindle-re');
  });

  it('resolves null when the device stays away', async () => {
    expect(await hubStub().waitForReconnect('never-back', 200)).toBeNull();
  });
});
