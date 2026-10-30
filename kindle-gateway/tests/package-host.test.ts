import fs from 'fs';
import http from 'http';
import os from 'os';
import path from 'path';
import zlib from 'zlib';
import express from 'express';
import { DeviceRegistry } from '../src/device-registry';
import { createApp } from '../src/gateway-server';
import { packageHostRouter } from '../src/package-host';

const MAX = 1024;

interface Reply { status: number; body: Buffer; headers: http.IncomingHttpHeaders }

function request(port: number, method: string, urlPath: string, body?: Buffer,
  opts: { chunked?: boolean; contentType?: string } = {}): Promise<Reply> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string | number> = {};
    if (body) {
      headers['Content-Type'] = opts.contentType || 'application/gzip';
      if (!opts.chunked) headers['Content-Length'] = body.length;
    }
    const req = http.request({ hostname: '127.0.0.1', port, path: urlPath, method, headers }, (res) => {
      const chunks: Buffer[] = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode!, body: Buffer.concat(chunks), headers: res.headers }));
    });
    // The server may refuse and close mid-upload; the reply still arrives.
    req.on('error', (err: NodeJS.ErrnoException) => {
      if (err.code !== 'EPIPE' && err.code !== 'ECONNRESET') reject(err);
    });
    if (body && opts.chunked) {
      // Several writes without Content-Length: the cap must hold while streaming.
      for (let i = 0; i < body.length; i += 256) req.write(body.subarray(i, i + 256));
      req.end();
    } else {
      req.end(body);
    }
  });
}

const json = (r: Reply) => JSON.parse(r.body.toString('utf8'));

describe('package host', () => {
  let root: string;
  let pkgDir: string;
  let inboxDir: string;
  let server: http.Server;
  let port: number;

  beforeAll(async () => {
    root = fs.mkdtempSync(path.join(os.tmpdir(), 'pkghost-'));
    pkgDir = path.join(root, 'pkg');
    inboxDir = path.join(root, 'inbox');
    fs.mkdirSync(pkgDir);
    fs.mkdirSync(inboxDir);
    fs.writeFileSync(path.join(pkgDir, 'index.json'), JSON.stringify({ format: 1, plugins: [{ name: 'demo' }] }));
    fs.writeFileSync(path.join(pkgDir, 'demo-1.0.tar.gz'), zlib.gzipSync(Buffer.from('demo')));
    fs.writeFileSync(path.join(pkgDir, '.secret'), 'hidden');
    fs.writeFileSync(path.join(root, 'outside.txt'), 'outside');

    // Same composition as src/index.ts: package host first, then the gateway app.
    const app = express();
    app.use(packageHostRouter({ pkgDir, inboxDir, inboxMaxBytes: MAX }));
    app.use(createApp(new DeviceRegistry()));
    await new Promise<void>((resolve) => { server = app.listen(0, '127.0.0.1', resolve); });
    port = (server.address() as { port: number }).port;
  });

  afterAll(async () => {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(root, { recursive: true, force: true });
  });

  describe('GET /pkg/', () => {
    it('serves index.json, never cached', async () => {
      const r = await request(port, 'GET', '/pkg/index.json');
      expect(r.status).toBe(200);
      expect(json(r).plugins[0].name).toBe('demo');
      expect(r.headers['cache-control']).toBe('no-cache');
    });

    it('serves an archive byte for byte', async () => {
      const r = await request(port, 'GET', '/pkg/demo-1.0.tar.gz');
      expect(r.status).toBe(200);
      expect(r.body.equals(fs.readFileSync(path.join(pkgDir, 'demo-1.0.tar.gz')))).toBe(true);
    });

    it('404s a missing file, a dotfile and a path out of the folder', async () => {
      expect((await request(port, 'GET', '/pkg/nope.tar.gz')).status).toBe(404);
      expect((await request(port, 'GET', '/pkg/.secret')).status).toBe(404);
      expect((await request(port, 'GET', '/pkg/%2e%2e/outside.txt')).status).not.toBe(200);
      expect((await request(port, 'GET', '/pkg/')).status).toBe(404);
    });

    it('is read-only', async () => {
      const r = await request(port, 'PUT', '/pkg/index.json', Buffer.from('{}'), { contentType: 'application/octet-stream' });
      expect(r.status).toBe(405);
      expect(JSON.parse(fs.readFileSync(path.join(pkgDir, 'index.json'), 'utf8')).plugins[0].name).toBe('demo');
    });

    it('leaves the gateway routes working', async () => {
      const r = await request(port, 'GET', '/health');
      expect(r.status).toBe(200);
      expect(json(r).ok).toBe(true);
    });
  });

  describe('PUT /inbox/', () => {
    const bundle = zlib.gzipSync(Buffer.from('crash.log lines'));

    it('stores a bundle under the device folder', async () => {
      const r = await request(port, 'PUT', '/inbox/pw3-ab12/20261030T101500Z.tar.gz', bundle);
      expect(r.status).toBe(201);
      expect(json(r)).toEqual({ ok: true, path: 'pw3-ab12/20261030T101500Z.tar.gz', size: bundle.length });
      const saved = fs.readFileSync(path.join(inboxDir, 'pw3-ab12', '20261030T101500Z.tar.gz'));
      expect(saved.equals(bundle)).toBe(true);
    });

    it('never overwrites an existing bundle', async () => {
      await request(port, 'PUT', '/inbox/emu/1.tar.gz', bundle);
      const r = await request(port, 'PUT', '/inbox/emu/1.tar.gz', zlib.gzipSync(Buffer.from('other')));
      expect(r.status).toBe(409);
      expect(fs.readFileSync(path.join(inboxDir, 'emu', '1.tar.gz')).equals(bundle)).toBe(true);
    });

    it('refuses a declared size over the cap without storing anything', async () => {
      const big = Buffer.alloc(MAX + 1, 1);
      big[0] = 0x1f; big[1] = 0x8b;
      const r = await request(port, 'PUT', '/inbox/big/1.tar.gz', big);
      expect(r.status).toBe(413);
      expect(fs.existsSync(path.join(inboxDir, 'big', '1.tar.gz'))).toBe(false);
    });

    it('refuses a streamed upload once it passes the cap and removes the partial file', async () => {
      const big = Buffer.alloc(MAX * 3, 1);
      big[0] = 0x1f; big[1] = 0x8b;
      const r = await request(port, 'PUT', '/inbox/stream/1.tar.gz', big, { chunked: true });
      expect(r.status).toBe(413);
      await new Promise((resolve) => setTimeout(resolve, 50));
      expect(fs.readdirSync(path.join(inboxDir, 'stream'))).toEqual([]);
    });

    it('accepts exactly the cap', async () => {
      const edge = Buffer.alloc(MAX, 1);
      edge[0] = 0x1f; edge[1] = 0x8b;
      expect((await request(port, 'PUT', '/inbox/edge/1.tar.gz', edge)).status).toBe(201);
    });

    it('refuses data that is not gzip, and an empty body', async () => {
      expect((await request(port, 'PUT', '/inbox/emu/plain.tar.gz', Buffer.from('plain text'))).status).toBe(400);
      expect((await request(port, 'PUT', '/inbox/emu/empty.tar.gz', Buffer.alloc(0))).status).toBe(400);
      expect(fs.existsSync(path.join(inboxDir, 'emu', 'plain.tar.gz'))).toBe(false);
    });

    it('refuses names that are not one safe path segment', async () => {
      for (const p of ['/inbox/..%2Fpkg/x.tar.gz', '/inbox/.hidden/x.tar.gz', '/inbox/emu/x.zip', '/inbox/emu/..tar.gz', '/inbox/a%20b/x.tar.gz']) {
        expect([p, (await request(port, 'PUT', p, bundle)).status]).toEqual([p, 400]);
      }
      expect(fs.readdirSync(pkgDir).sort()).toEqual(['.secret', 'demo-1.0.tar.gz', 'index.json']);
    });

    it('accepts only PUT', async () => {
      expect((await request(port, 'GET', '/inbox/pw3-ab12/20261030T101500Z.tar.gz')).status).toBe(405);
    });
  });
});
