import { PhotonImage } from '@cf-wasm/photon/workerd';
import {
  CLIENT_CAPABILITIES_META_KEY,
  CLIENT_INFO_META_KEY,
  Client,
  PROTOCOL_VERSION_META_KEY,
  StreamableHTTPClientTransport,
} from '@modelcontextprotocol/client';
import { SELF, env } from 'cloudflare:test';
import { afterEach, describe, expect, it } from 'vitest';
import { bytesToBase64 } from '../src/screenshot';

const DEVICE_KEY = 'test-device-key';
const AGENT_KEY = 'test-agent-key';
const MCP_URL = 'https://gw.test/mcp';

/** The tools the Node gateway serves (kindle-gateway/src/gateway-server.ts), minus deploy_plugin
 *  (devices install from the registry). */
const EXPECTED_TOOLS = [
  'action', 'close_top_widget', 'device_status', 'get_current_view', 'get_menu_items', 'go_back',
  'hold', 'list_devices', 'list_diagnostics', 'power_button', 'read_diagnostics', 'read_files', 'read_log', 'restart_koreader',
  'run_command', 'screenshot', 'select_menu_item', 'send_event', 'snapshot', 'tap', 'tap_text', 'type', 'wait_for',
].sort();

/** A real PNG at the Paperwhite 3's full resolution, made with photon so no fixture file is needed. */
function devicePng(): string {
  const w = 1072;
  const h = 1448;
  const px = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4;
      const v = (x >> 4) % 2 === (y >> 4) % 2 ? 255 : 0;
      px[i] = px[i + 1] = px[i + 2] = v;
      px[i + 3] = 255;
    }
  }
  const img = new PhotonImage(px, w, h);
  try {
    return bytesToBase64(img.get_bytes());
  } finally {
    img.free();
  }
}
const PNG = devicePng();

function snapshotResult(id: number) {
  return {
    snapshot: id,
    window: 'FileManager',
    total: 2,
    nodes: [
      { ref: `${id}_1`, kind: 'item', text: 'Synced reading list', state: '' },
      { ref: `${id}_2`, kind: 'button', text: 'Close', state: '' },
    ],
  };
}

/** A fake Kindle over the hub's WebSocket, answering the methods the device tools call. */
class FakeKindle {
  ws!: WebSocket;
  snapshotId = 0;
  calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  screenshotData = PNG;
  restarts = 0;
  closed = false;

  constructor(readonly name: string, readonly idHash = 'feedfacecafebeef') {}

  async connect(): Promise<void> {
    const res = await SELF.fetch('https://gw.test/device', {
      headers: { Upgrade: 'websocket', Authorization: `Bearer ${DEVICE_KEY}` },
    });
    expect(res.status).toBe(101);
    const ws = res.webSocket!;
    ws.accept();
    this.ws = ws;
    this.closed = false;
    const welcomed = new Promise<void>((resolve) => {
      ws.addEventListener('message', (e) => {
        const msg = JSON.parse(e.data as string);
        if (msg.type === 'welcome') resolve();
        else if (typeof msg.id === 'number') this.answer(ws, msg);
      });
    });
    ws.addEventListener('close', () => { this.closed = true; });
    ws.send(JSON.stringify({ type: 'hello', name: this.name, id_hash: this.idHash, koreader_version: 'fake' }));
    await welcomed;
  }

  private answer(ws: WebSocket, msg: { id: number; method: string; params: Record<string, unknown> }): void {
    this.calls.push({ method: msg.method, params: msg.params });
    const reply = (result: unknown) => ws.send(JSON.stringify({ id: msg.id, result }));
    switch (msg.method) {
      case 'ui_snapshot':
        reply(snapshotResult(++this.snapshotId));
        break;
      case 'ui_wait': {
        const matched = msg.params.text === 'Close';
        reply({ matched, waited: matched ? 0.5 : Number(msg.params.timeout ?? 10), snapshot: snapshotResult(++this.snapshotId) });
        break;
      }
      case 'power_button':
        reply({ action: 'suspend', screen_saver_mode: false });
        break;
      case 'read_log':
        reply({ marker: 42, lines: ['line a', 'line b'], truncated: msg.params.since === undefined });
        break;
      case 'ui_act':
        if (msg.params.text === 'Restart') {
          // A dialog's Restart button: KOReader dies before it replies, then a fresh one connects.
          this.restarts++;
          setTimeout(() => {
            try { ws.close(1001, 'restarting'); } catch { /* already closed */ }
            setTimeout(() => { void this.connect(); }, 100);
          }, 50);
          break;
        }
        reply({ result: `${msg.params.what} ok`, snapshot: snapshotResult(++this.snapshotId), logs: ['did it'] });
        break;
      case 'capture_screenshot':
        reply({ image_base64: this.screenshotData, size_bytes: 123 });
        break;
      case 'device_status':
        reply({ battery: 80 });
        break;
      case 'get_current_view':
        reply({ widgets: ['FileManager'] });
        break;
      case 'run_command': {
        const command = String(msg.params.command);
        reply({ output: 'ok' });
        if (command.includes('koreader.sh')) {
          // As KOReader does: the process dies, then a fresh one connects again.
          this.restarts++;
          setTimeout(() => {
            try { ws.close(1001, 'restarting'); } catch { /* already closed */ }
            setTimeout(() => { void this.connect(); }, 100);
          }, 50);
        }
        break;
      }
      default:
        ws.send(JSON.stringify({ id: msg.id, error: { code: -32601, message: `unknown method ${msg.method}` } }));
    }
  }

  close(): void {
    try { this.ws.close(1000, 'test done'); } catch { /* already closed */ }
  }
}

const open: FakeKindle[] = [];
async function kindle(name: string): Promise<FakeKindle> {
  const k = new FakeKindle(name);
  await k.connect();
  open.push(k);
  return k;
}

const clients: Client[] = [];
async function mcpClient(modern: boolean): Promise<Client> {
  const transport = new StreamableHTTPClientTransport(new URL(MCP_URL), {
    fetch: (url, init) => SELF.fetch(url, init),
    requestInit: { headers: { Authorization: `Bearer ${AGENT_KEY}` } },
  });
  const client = new Client(
    { name: 'mcp-test', version: '1.0.0' },
    modern ? { versionNegotiation: { mode: { pin: '2026-07-28' } } } : {},
  );
  await client.connect(transport);
  clients.push(client);
  return client;
}

type Block = { type: string; text?: string; data?: string; mimeType?: string };
async function call(client: Client, name: string, args: Record<string, unknown>) {
  const res = (await client.callTool({ name, arguments: args })) as { content: Block[]; isError?: boolean };
  return res;
}

afterEach(async () => {
  for (const k of open.splice(0)) k.close();
  for (const c of clients.splice(0)) await c.close().catch(() => {});
});

function rpc(body: unknown, headers: Record<string, string> = {}): Promise<Response> {
  return SELF.fetch(MCP_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json, text/event-stream',
      Authorization: `Bearer ${AGENT_KEY}`,
      ...headers,
    },
    body: JSON.stringify(body),
  });
}

/** A JSON body, or the one `data:` line of an SSE stream (the 2025 path streams its answer). */
function parseBody(raw: string): unknown {
  const data = raw.split('\n').find((l) => l.startsWith('data: '));
  return JSON.parse(data ? data.slice(6) : raw);
}

describe('agent auth on /mcp', () => {
  const initialize = { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 't', version: '1' } } };

  it('refuses a request with no key, before any MCP work', async () => {
    const res = await rpc(initialize, { Authorization: '' });
    expect(res.status).toBe(401);
    expect(res.headers.get('WWW-Authenticate')).toBe('Bearer');
  });

  it('refuses a wrong key', async () => {
    expect((await rpc(initialize, { Authorization: 'Bearer nope' })).status).toBe(401);
  });

  it('refuses the device key', async () => {
    expect((await rpc(initialize, { Authorization: `Bearer ${DEVICE_KEY}` })).status).toBe(401);
  });

  it('refuses GET and DELETE without a key too', async () => {
    expect((await SELF.fetch(MCP_URL)).status).toBe(401);
    expect((await SELF.fetch(MCP_URL, { method: 'DELETE' })).status).toBe(401);
  });
});

describe('stateless MCP, both protocol versions', () => {
  it('answers a 2025-11-25 initialize and never issues a session id', async () => {
    const res = await rpc({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 't', version: '1' } } });
    expect(res.status).toBe(200);
    expect(res.headers.get('mcp-session-id')).toBeNull();
    const body = parseBody(await res.text()) as { result: { protocolVersion: string; serverInfo: { name: string } } };
    expect(body.result.protocolVersion).toBe('2025-11-25');
    expect(body.result.serverInfo.name).toBe('kindle-gateway');
  });

  it('answers GET with 405 (no server-to-client stream)', async () => {
    const res = await SELF.fetch(MCP_URL, { headers: { Authorization: `Bearer ${AGENT_KEY}`, Accept: 'text/event-stream' } });
    expect(res.status).toBe(405);
  });

  it('lists the tools to a 2025 client', async () => {
    const client = await mcpClient(false);
    expect(client.getNegotiatedProtocolVersion()).toBe('2025-11-25');
    const { tools } = await client.listTools();
    expect(tools.map((t) => t.name).sort()).toEqual(EXPECTED_TOOLS);
  });

  it('lists the tools to a 2026-07-28 client (server/discover, no initialize)', async () => {
    const client = await mcpClient(true);
    expect(client.getNegotiatedProtocolVersion()).toBe('2026-07-28');
    const { tools } = await client.listTools();
    expect(tools.map((t) => t.name).sort()).toEqual(EXPECTED_TOOLS);
  });

  it('answers server/discover directly', async () => {
    const res = await rpc(
      {
        jsonrpc: '2.0',
        id: 7,
        method: 'server/discover',
        params: {
          _meta: {
            [PROTOCOL_VERSION_META_KEY]: '2026-07-28',
            [CLIENT_CAPABILITIES_META_KEY]: {},
            [CLIENT_INFO_META_KEY]: { name: 't', version: '1' },
          },
        },
      },
      { 'MCP-Protocol-Version': '2026-07-28', 'Mcp-Method': 'server/discover' },
    );
    const raw = await res.text();
    expect(res.status, raw).toBe(200);
    expect(res.headers.get('mcp-session-id')).toBeNull();
    const body = parseBody(raw) as { id: number; result: Record<string, unknown> };
    expect(body.id).toBe(7);
    expect(JSON.stringify(body.result)).toContain('2026-07-28');
  });

  it('keeps the schemas: tap needs device and ref', async () => {
    const client = await mcpClient(false);
    const { tools } = await client.listTools();
    const tap = tools.find((t) => t.name === 'tap')!;
    expect(tap.inputSchema.required).toEqual(expect.arrayContaining(['device', 'ref']));
    expect(Object.keys(tap.inputSchema.properties ?? {}).sort()).toEqual(['device', 'max_lines', 'ref', 'screenshot', 'wait']);
  });

  it('serves the diagnostics tools from the R2 inbox', async () => {
    await env.INBOX.put('inbox/mcp-test/20261101-000000.tar.gz', 'not gzip');
    const client = await mcpClient(true);
    const list = await call(client, 'list_diagnostics', { device: 'mcp-test' });
    expect(JSON.parse(list.content[0].text!)).toEqual([expect.objectContaining({ device: 'mcp-test', file: '20261101-000000.tar.gz' })]);
    const read = await call(client, 'read_diagnostics', { device: 'mcp-test' });
    expect(read.isError).toBe(true);
    expect(read.content[0].text).toMatch(/^Error: Diagnostics: /);
  });

  it('keeps the diagnostics schemas: read needs device, list needs nothing', async () => {
    const client = await mcpClient(false);
    const { tools } = await client.listTools();
    const read = tools.find((t) => t.name === 'read_diagnostics')!;
    const list = tools.find((t) => t.name === 'list_diagnostics')!;
    expect(read.inputSchema.required).toEqual(['device']);
    expect(Object.keys(read.inputSchema.properties ?? {}).sort()).toEqual(['device', 'file']);
    expect(list.inputSchema.required ?? []).toEqual([]);
    expect(Object.keys(list.inputSchema.properties ?? {})).toEqual(['device']);
  });
});

describe.each([
  ['2025-11-25', false],
  ['2026-07-28', true],
])('device tools over protocol %s', (_label, modern) => {
  it('lists a connected device', async () => {
    await kindle(`k-list-${modern}`);
    const client = await mcpClient(modern);
    const res = await call(client, 'list_devices', {});
    const devices = JSON.parse(res.content[0].text!);
    expect(devices.find((d: { name: string }) => d.name === `k-list-${modern}`)).toMatchObject({ status: 'online', idHash: 'feedfacecafebeef' });
  });

  it('snapshots, taps, and refuses a stale reference without asking the device', async () => {
    const dev = await kindle(`k-ui-${modern}`);
    const client = await mcpClient(modern);
    const snap = await call(client, 'snapshot', { device: dev.name });
    expect(snap.isError).toBeFalsy();
    expect(snap.content[0].text).toContain('[1_1] item "Synced reading list"');

    const tap = await call(client, 'tap', { device: dev.name, ref: '1_1' });
    expect(tap.content[0].text).toContain('tap ok');
    expect(dev.calls.at(-1)).toEqual({ method: 'ui_act', params: { what: 'tap', ref: '1_1' } });

    await call(client, 'snapshot', { device: dev.name }); // snapshot 3: 1_x is now stale
    const before = dev.calls.length;
    const stale = await call(client, 'tap', { device: dev.name, ref: '1_1' });
    expect(stale.isError).toBe(true);
    expect(stale.content[0].text).toContain('stale reference 1_1');
    expect(dev.calls.length).toBe(before);
  });

  it('returns a screenshot as a 536x724 grayscale JPEG', async () => {
    const dev = await kindle(`k-ss-${modern}`);
    const client = await mcpClient(modern);
    const res = await call(client, 'screenshot', { device: dev.name });
    expect(res.isError).toBeFalsy();
    const img = res.content.find((b) => b.type === 'image')!;
    expect(img.mimeType).toBe('image/jpeg');
    const bytes = Uint8Array.from(atob(img.data!), (c) => c.charCodeAt(0));
    expect([bytes[0], bytes[1]]).toEqual([0xff, 0xd8]);
    const decoded = PhotonImage.new_from_byteslice(bytes);
    try {
      expect([decoded.get_width(), decoded.get_height()]).toEqual([536, 724]);
    } finally {
      decoded.free();
    }
  });

  it('falls back to the original PNG when encoding fails', async () => {
    const dev = await kindle(`k-ssbad-${modern}`);
    dev.screenshotData = btoa('this is not a png');
    const client = await mcpClient(modern);
    const res = await call(client, 'screenshot', { device: dev.name });
    const img = res.content.find((b) => b.type === 'image')!;
    expect(img).toMatchObject({ mimeType: 'image/png', data: dev.screenshotData });
  });

  it('adds a screenshot after a menu tool', async () => {
    const dev = await kindle(`k-menu-${modern}`);
    const client = await mcpClient(modern);
    const res = await call(client, 'get_current_view', { device: dev.name });
    expect(JSON.parse(res.content[0].text!)).toEqual({ widgets: ['FileManager'] });
    expect(res.content[1]).toMatchObject({ type: 'image', mimeType: 'image/jpeg' });
  });

  it('forwards JSON params and passes a device error back', async () => {
    const dev = await kindle(`k-fwd-${modern}`);
    const client = await mcpClient(modern);
    const ok = await call(client, 'device_status', { device: dev.name });
    expect(JSON.parse(ok.content[0].text!)).toEqual({ battery: 80 });
    const bad = await call(client, 'read_files', { device: dev.name, params: '{"paths":["/x"]}' });
    expect(bad.isError).toBe(true);
    expect(bad.content[0].text).toBe('Error: Device error: unknown method read_files');
    expect(dev.calls.at(-1)).toEqual({ method: 'read_files', params: { paths: ['/x'] } });
  });

  it('says so when the device is not connected', async () => {
    const client = await mcpClient(modern);
    const res = await call(client, 'snapshot', { device: 'nobody' });
    expect(res).toMatchObject({ isError: true, content: [{ type: 'text', text: "Error: Device 'nobody' is not connected" }] });
  });

  it('restarts KOReader and waits for the device to come back', async () => {
    const dev = await kindle(`k-restart-${modern}`);
    const client = await mcpClient(modern);
    await call(client, 'snapshot', { device: dev.name });
    const res = await call(client, 'restart_koreader', { device: dev.name });
    expect(JSON.parse(res.content[0].text!)).toEqual({ device: dev.name, restarted: true, status: 'online' });
    expect(dev.restarts).toBe(1);
    // The restarted device counts snapshots from 1 again; the tracker forgot the old ids.
    dev.snapshotId = 0;
    await call(client, 'snapshot', { device: dev.name });
    const tap = await call(client, 'tap', { device: dev.name, ref: '1_1' });
    expect(tap.isError).toBeFalsy();
  });
});

describe('gateway quality-of-life tools (issue 23)', () => {
  it('wait_for asks the device to wait and prints the match line and the snapshot', async () => {
    const k = await kindle('qol-wait');
    const client = await mcpClient(true);
    const r = await call(client, 'wait_for', { device: 'qol-wait', text: 'Close', timeout: 3 });
    expect(r.isError).toBeFalsy();
    const lines = r.content[0].text!.split('\n');
    expect(lines[0]).toBe('matched after 0.5s');
    expect(lines).toContain(`[${k.snapshotId}_2] button "Close"`);
    expect(k.calls.at(-1)).toEqual({ method: 'ui_wait', params: { text: 'Close', timeout: 3 } });
    const miss = await call(client, 'wait_for', { device: 'qol-wait', text: 'Busy', gone: true, timeout: 2 });
    expect(miss.content[0].text!.split('\n')[0]).toBe('timed out after 2s (text still present)');
  });

  it('passes wait to ui_act as wait_cap', async () => {
    const k = await kindle('qol-tapwait');
    const client = await mcpClient(true);
    await call(client, 'tap_text', { device: 'qol-tapwait', text: 'OK', wait: 15 });
    expect(k.calls.at(-1)?.params).toMatchObject({ what: 'tap_text', text: 'OK', wait_cap: 15 });
  });

  it('reports a tap that restarts KOReader and waits for the reconnect', async () => {
    const k = await kindle('qol-restart');
    const client = await mcpClient(true);
    const r = await call(client, 'tap_text', { device: 'qol-restart', text: 'Restart' });
    expect(r.isError).toBeFalsy();
    expect(r.content[0].text).toBe('device restarting or disconnected; device reconnected, take a new snapshot');
    expect(k.restarts).toBe(1);
  });

  it('power_button and read_log print what the device returned', async () => {
    const k = await kindle('qol-misc');
    const client = await mcpClient(true);
    const p = await call(client, 'power_button', { device: 'qol-misc' });
    expect(p.content[0].text).toBe('power button: suspend (device was awake)');
    const log = await call(client, 'read_log', { device: 'qol-misc', max_lines: 50, grep: 'sync' });
    expect(k.calls.at(-1)).toEqual({ method: 'read_log', params: { max_lines: 50, grep: 'sync' } });
    expect(log.content[0].text).toBe('marker: 42 (older lines dropped)\nline a\nline b');
    const again = await call(client, 'read_log', { device: 'qol-misc', since: 42 });
    expect(again.content[0].text).toBe('marker: 42\nline a\nline b');
  });
});
