import { SELF, env } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { listBundles, listDiagnostics, readDiagnostics, type ToolResult } from '../src/diagnostics-tools';
import { INBOX_MAX_BYTES } from '../src/inbox';
// Bundles built like the device builds them, and what kindle-gateway's list_diagnostics and
// read_diagnostics answered for them (captured from that implementation, images summarised).
import golden from './fixtures/diagnostics-golden.json';

const DEVICE_KEY = 'test-device-key';
const AGENT_KEY = 'test-agent-key';
const GZIP = new Uint8Array([0x1f, 0x8b, 0x08, 0x00, 1, 2, 3, 4]);

function put(path: string, body: BodyInit | null, headers: Record<string, string> = {}): Promise<Response> {
  return SELF.fetch(`https://gw.example${path}`, {
    method: 'PUT',
    headers: { Authorization: `Bearer ${DEVICE_KEY}`, ...headers },
    body,
  });
}

/** A body with no Content-Length: `total` bytes in 64 KiB chunks, gzip magic first. */
function streamOf(total: number): ReadableStream<Uint8Array> {
  let sent = 0;
  return new ReadableStream({
    pull(controller) {
      if (sent >= total) return controller.close();
      const n = Math.min(65536, total - sent);
      const chunk = new Uint8Array(n);
      if (sent === 0) chunk.set(GZIP.subarray(0, Math.min(n, GZIP.length)));
      sent += n;
      controller.enqueue(chunk);
    },
  });
}

async function stored(): Promise<string[]> {
  return (await env.INBOX.list()).objects.map((o) => o.key);
}

function fromBase64(s: string): Uint8Array {
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}

describe('PUT /inbox/<device>/<file>', () => {
  it('stores a bundle at inbox/<device>/<file> and answers like kindle-gateway', async () => {
    const res = await put('/inbox/up-ok/20261103-120000.tar.gz', GZIP, { 'Content-Type': 'application/gzip' });
    expect(res.status).toBe(201);
    expect(await res.json()).toEqual({ ok: true, path: 'up-ok/20261103-120000.tar.gz', size: GZIP.length });
    const obj = await env.INBOX.get('inbox/up-ok/20261103-120000.tar.gz');
    expect(new Uint8Array(await obj!.arrayBuffer())).toEqual(GZIP);
  });

  it('accepts a streamed body without Content-Length', async () => {
    const res = await put('/inbox/up-chunked/a.tar.gz', streamOf(200_000));
    expect(res.status).toBe(201);
    expect(((await res.json()) as { size: number }).size).toBe(200_000);
    expect((await env.INBOX.head('inbox/up-chunked/a.tar.gz'))!.size).toBe(200_000);
  });

  it('never overwrites a bundle', async () => {
    expect((await put('/inbox/up-dup/a.tar.gz', GZIP)).status).toBe(201);
    const again = await put('/inbox/up-dup/a.tar.gz', new Uint8Array([0x1f, 0x8b, 9, 9]));
    expect(again.status).toBe(409);
    const obj = await env.INBOX.get('inbox/up-dup/a.tar.gz');
    expect(new Uint8Array(await obj!.arrayBuffer())).toEqual(GZIP);
  });

  describe('device key', () => {
    const cases: Array<[string, Record<string, string>]> = [
      ['no Authorization', {}],
      ['a wrong key', { Authorization: 'Bearer not-the-key' }],
      ['the agent key', { Authorization: `Bearer ${AGENT_KEY}` }],
      ['the device key as Basic', { Authorization: `Basic ${DEVICE_KEY}` }],
    ];
    for (const [what, headers] of cases) {
      it(`refuses ${what} with 401 and stores nothing`, async () => {
        const res = await SELF.fetch('https://gw.example/inbox/up-auth/a.tar.gz', { method: 'PUT', headers, body: GZIP });
        expect(res.status).toBe(401);
        expect(await env.INBOX.head('inbox/up-auth/a.tar.gz')).toBeNull();
      });
    }
    it('checks the key before anything else', async () => {
      const res = await SELF.fetch('https://gw.example/inbox/../../x', { method: 'GET' });
      expect(res.status).toBe(404); // the URL parser climbed out of /inbox/ already
      expect((await SELF.fetch('https://gw.example/inbox/a/b', { method: 'GET' })).status).toBe(401);
    });
  });

  describe('size cap', () => {
    it('refuses a Content-Length over the cap with 413 before reading', async () => {
      const res = await put('/inbox/up-big/a.tar.gz', new Uint8Array(INBOX_MAX_BYTES + 1));
      expect(res.status).toBe(413);
      expect(await res.json()).toEqual({ error: `bundle larger than ${INBOX_MAX_BYTES} bytes` });
      expect(await env.INBOX.head('inbox/up-big/a.tar.gz')).toBeNull();
    });

    it('takes a body of exactly the cap', async () => {
      const body = new Uint8Array(INBOX_MAX_BYTES);
      body.set(GZIP);
      expect((await put('/inbox/up-big/exact.tar.gz', body)).status).toBe(201);
    });

    it('refuses a streamed body that grows past the cap, storing nothing', async () => {
      const res = await put('/inbox/up-big/streamed.tar.gz', streamOf(INBOX_MAX_BYTES + 1));
      expect(res.status).toBe(413);
      expect(await env.INBOX.head('inbox/up-big/streamed.tar.gz')).toBeNull();
    });
  });

  describe('bad bodies', () => {
    it('refuses an empty bundle', async () => {
      expect((await put('/inbox/up-body/empty.tar.gz', new Uint8Array(0))).status).toBe(400);
      expect((await put('/inbox/up-body/empty2.tar.gz', streamOf(0))).status).toBe(400);
    });
    it('refuses a body that is not gzip, streamed or not', async () => {
      const res = await put('/inbox/up-body/text.tar.gz', 'hello there');
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ error: 'bundle is not gzip data' });
      expect((await put('/inbox/up-body/one.tar.gz', new Uint8Array([0x1f]))).status).toBe(400);
      expect(await stored()).not.toContain('inbox/up-body/text.tar.gz');
      expect(await stored()).not.toContain('inbox/up-body/one.tar.gz');
    });
    it('answers 405 to anything but PUT', async () => {
      const res = await SELF.fetch('https://gw.example/inbox/up-body/a.tar.gz', {
        method: 'POST', headers: { Authorization: `Bearer ${DEVICE_KEY}` }, body: GZIP,
      });
      expect(res.status).toBe(405);
    });
  });

  describe('names (same rules as kindle-gateway/src/package-host.ts)', () => {
    const bad = [
      '/inbox/up-names/..%2F..%2Fx.tar.gz', // encoded traversal stays one segment and fails the rules
      '/inbox/up-names/sub/x.tar.gz', // a slash in the file name
      '/inbox/up-names/', // empty file name
      '/inbox//x.tar.gz', // empty device
      '/inbox/up-names', // no file at all
      '/inbox/up-names/x.zip', // not .tar.gz
      '/inbox/up-names/.x.tar.gz', // leading dot
      '/inbox/.hidden/x.tar.gz',
      '/inbox/up%20names/x.tar.gz', // odd characters
      '/inbox/up-names/x%00.tar.gz',
      '/inbox/up-names/x;y.tar.gz',
      `/inbox/${'d'.repeat(65)}/x.tar.gz`, // longer than 64
      `/inbox/up-names/${'f'.repeat(65)}.tar.gz`,
    ];
    for (const path of bad) {
      it(`refuses ${path.slice(0, 60)}`, async () => {
        const res = await put(path, GZIP);
        expect(res.status).toBe(400);
        expect(((await res.json()) as { error: string }).error).toMatch(/^path must be/);
      });
    }

    it('dot segments resolve before routing, so they never reach the inbox', async () => {
      for (const path of ['/inbox/../evil/x.tar.gz', '/inbox/%2e%2e/evil/x.tar.gz', '/inbox/up-names/../../x.tar.gz']) {
        const res = await put(path, GZIP);
        expect(res.status).not.toBe(201);
      }
      expect((await stored()).every((k) => k.startsWith('inbox/'))).toBe(true);
    });

    it('takes the longest names the rules allow', async () => {
      const res = await put(`/inbox/${'d'.repeat(64)}/${'f'.repeat(64)}.tar.gz`, GZIP);
      expect(res.status).toBe(201);
    });
  });
});

describe('list_diagnostics and read_diagnostics on R2', () => {
  type Case = { tool: string; args: Record<string, unknown>; result: { isError: boolean; content: Array<Record<string, unknown>> } };
  const cases = golden.cases as Case[];
  // The functions behind the tools; mcp.test.ts checks they are registered on /mcp.
  const handlers: Record<string, (bucket: R2Bucket, args: never) => Promise<ToolResult>> = {
    list_diagnostics: listDiagnostics,
    read_diagnostics: readDiagnostics,
  };
  const received = new Map<string, string>();

  beforeAll(async () => {
    // An empty inbox, then the three bundles uploaded oldest first through the real route.
    const keys = await stored();
    if (keys.length) await env.INBOX.delete(keys);
    for (const b of golden.bundles) {
      const res = await put(`/inbox/${b.device}/${b.file}`, fromBase64(b.base64));
      expect(res.status).toBe(201);
      await new Promise((r) => setTimeout(r, 5)); // distinct upload times
    }
    for (const info of await listBundles(env.INBOX)) received.set(`${info.device}/${info.file}`, info.received);
    // Keys that are not bundles are skipped, as kindle-gateway skips stray files.
    await env.INBOX.put('inbox/emu/.20261031.tar.gz.abcd.part', 'unfinished');
    await env.INBOX.put('inbox/emu/sub/x.tar.gz', 'nested');
  });

  /** kindle-gateway's answer with its mtimes swapped for the times R2 stored the bundles at. */
  function expected(c: Case): Case['result'] {
    let text = JSON.stringify(c.result);
    for (const b of golden.bundles) text = text.replaceAll(b.mtime, received.get(`${b.device}/${b.file}`)!);
    return JSON.parse(text);
  }

  for (const c of cases) {
    it(`${c.tool} ${JSON.stringify(c.args)} answers what kindle-gateway answers`, async () => {
      const r: ToolResult = await handlers[c.tool](env.INBOX, c.args as never);
      const summary = { isError: r.isError ?? false, content: r.content.map((b) => (b.type === 'image' ? { type: 'image' } : b)) };
      expect(summary).toEqual(expected(c));
    });
  }

  it('sends the screenshot as the PNG from the bundle', async () => {
    const r = await readDiagnostics(env.INBOX, { device: 'kindle-1' });
    const img = r.content[1] as { type: 'image'; data: string; mimeType: string };
    expect(img.mimeType).toBe('image/png');
    expect(Array.from(fromBase64(img.data).subarray(0, 4))).toEqual([0x89, 0x50, 0x4e, 0x47]);
  });

  it('reports a damaged bundle as a tool error', async () => {
    await env.INBOX.put('inbox/broken/20261101-000000.tar.gz', 'not gzip at all');
    const r = await readDiagnostics(env.INBOX, { device: 'broken' });
    expect(r.isError).toBe(true);
    expect((r.content[0] as { text: string }).text).toMatch(/^Error: Diagnostics: /);
  });
});
