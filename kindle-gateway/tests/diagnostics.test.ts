import { execFileSync } from 'child_process';
import fs from 'fs';
import http from 'http';
import os from 'os';
import path from 'path';
import sharp from 'sharp';
import { listBundles, parseTar, readBundle } from '../src/diagnostics';
import { DeviceRegistry } from '../src/device-registry';
import { createApp } from '../src/gateway-server';

const SNAPSHOT = { snapshot: 3, window: 'Menu', total: 1, nodes: [{ ref: '3_1', kind: 'button', text: 'OK', state: '' }] };

describe('diagnostics bundles', () => {
  let inbox: string;

  async function makeBundle(device: string, file: string, log: string, mtime: Date, withShot = true) {
    const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'diag-stage-'));
    fs.writeFileSync(path.join(stage, 'manifest.json'), JSON.stringify({ koreader_version: 'v2026.07.1' }));
    fs.writeFileSync(path.join(stage, 'crash.log'), log);
    fs.writeFileSync(path.join(stage, 'snapshot.json'), JSON.stringify(SNAPSHOT));
    const names = ['manifest.json', 'crash.log', 'snapshot.json'];
    if (withShot) {
      await sharp({ create: { width: 4, height: 4, channels: 3, background: '#888' } }).png().toFile(path.join(stage, 'screenshot.png'));
      names.push('screenshot.png');
    }
    const dir = path.join(inbox, device);
    fs.mkdirSync(dir, { recursive: true });
    const out = path.join(dir, file);
    // Same flags as the device.
    execFileSync('tar', ['-czf', out, ...names], { cwd: stage });
    fs.utimesSync(out, mtime, mtime);
    fs.rmSync(stage, { recursive: true });
  }

  beforeAll(async () => {
    inbox = fs.mkdtempSync(path.join(os.tmpdir(), 'diag-inbox-'));
    await makeBundle('emu', '20261031-100000.tar.gz', 'first\n', new Date('2026-10-31T10:00:00Z'));
    await makeBundle('emu', '20261031-110000.tar.gz', 'second\n', new Date('2026-10-31T11:00:00Z'), false);
    await makeBundle('kindle-1', '20261031-090000.tar.gz', '', new Date('2026-10-31T09:00:00Z'));
    fs.writeFileSync(path.join(inbox, 'emu', '.20261031.tar.gz.abcd.part'), 'unfinished');
  });

  afterAll(() => fs.rmSync(inbox, { recursive: true }));

  test('lists newest first, without partial uploads', () => {
    expect(listBundles(inbox).map((b) => `${b.device}/${b.file}`)).toEqual([
      'emu/20261031-110000.tar.gz', 'emu/20261031-100000.tar.gz', 'kindle-1/20261031-090000.tar.gz',
    ]);
    expect(listBundles(inbox, 'kindle-1')).toHaveLength(1);
    expect(listBundles(inbox, 'nobody')).toEqual([]);
    expect(listBundles(path.join(inbox, 'missing'))).toEqual([]);
  });

  test('reads the newest by default, or a named one', () => {
    expect(readBundle(inbox, 'emu').files['crash.log'].toString()).toBe('second\n');
    const older = readBundle(inbox, 'emu', '20261031-100000.tar.gz');
    expect(older.files['crash.log'].toString()).toBe('first\n');
    expect(Object.keys(older.files).sort()).toEqual(['crash.log', 'manifest.json', 'screenshot.png', 'snapshot.json']);
  });

  test('refuses names that climb out of the inbox', () => {
    expect(() => readBundle(inbox, '..')).toThrow(/invalid device/);
    expect(() => listBundles(inbox, '../..')).toThrow(/invalid device/);
    expect(() => readBundle(inbox, 'emu', '../../x.tar.gz')).toThrow(/invalid bundle/);
    expect(() => readBundle(inbox, 'emu', 'none.tar.gz')).toThrow(/no bundle/);
  });

  test('parseTar stops at the end marker on an empty archive', () => {
    expect(parseTar(Buffer.alloc(1024))).toEqual({});
  });

  describe('MCP tools', () => {
    let server: http.Server;
    let port: number;

    beforeAll(async () => {
      server = createApp(new DeviceRegistry(), inbox).listen(0, '127.0.0.1');
      await new Promise<void>((resolve) => server.on('listening', resolve));
      port = (server.address() as { port: number }).port;
    });
    afterAll(async () => { await new Promise<void>((resolve) => server.close(() => resolve())); });

    function call(name: string, args: object): Promise<{ isError?: boolean; content: Array<{ type: string; text?: string; mimeType?: string }> }> {
      const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } });
      return new Promise((resolve, reject) => {
        const req = http.request({
          hostname: '127.0.0.1', port, path: '/mcp', method: 'POST',
          headers: { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' },
        }, (res) => {
          let data = '';
          res.on('data', (c) => { data += c; });
          res.on('end', () => {
            const line = data.split('\n').find((l) => l.startsWith('data:'));
            resolve(JSON.parse(line ? line.slice(5) : data).result);
          });
        });
        req.on('error', reject);
        req.end(body);
      });
    }

    test('list_diagnostics', async () => {
      const r = await call('list_diagnostics', { device: 'emu' });
      expect(JSON.parse(r.content[0].text!).map((b: { file: string }) => b.file)).toEqual([
        '20261031-110000.tar.gz', '20261031-100000.tar.gz',
      ]);
    });

    test('read_diagnostics returns text and image', async () => {
      const r = await call('read_diagnostics', { device: 'emu', file: '20261031-100000.tar.gz' });
      expect(r.isError).toBeFalsy();
      const text = r.content[0].text!;
      expect(text).toContain('v2026.07.1');
      expect(text).toContain('first');
      expect(text).toContain('3_1');
      expect(r.content[1].type).toBe('image');
    });

    test('read_diagnostics without a screenshot, then a bad name', async () => {
      const r = await call('read_diagnostics', { device: 'emu' });
      expect(r.content).toHaveLength(1);
      const bad = await call('read_diagnostics', { device: '..' });
      expect(bad.isError).toBe(true);
    });
  });
});
