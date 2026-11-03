// Captures what kindle-gateway's list_diagnostics and read_diagnostics answer today for three
// bundles built like the device builds them, and writes the bundles plus those answers to
// kindle-gateway-worker/test/fixtures/diagnostics-golden.json, so the Worker tests can check
// they give the same output on the same inputs.
// Run from kindle-gateway/: npx tsx <topic-folder>/72/capture-golden.ts
import { execFileSync } from 'child_process';
import fs from 'fs';
import http from 'http';
import os from 'os';
import path from 'path';
import sharp from 'sharp';
import { DeviceRegistry } from '../../../../kindle-gateway/src/device-registry';
import { createApp } from '../../../../kindle-gateway/src/gateway-server';

const SNAPSHOT = {
  snapshot: 3, window: 'Menu', total: 2,
  nodes: [{ ref: '3_1', kind: 'button', text: 'OK', state: '' }, { ref: '3_2', kind: 'text', text: 'Hello', state: '' }],
};

const OUT = path.resolve(__dirname, '../../../../kindle-gateway-worker/test/fixtures/diagnostics-golden.json');

async function main() {
  const inbox = fs.mkdtempSync(path.join(os.tmpdir(), 'golden-inbox-'));
  const bundles: Array<{ device: string; file: string; base64: string; mtime: string }> = [];

  async function make(device: string, file: string, log: string, mtime: string, withShot: boolean, withSnapshot = true) {
    const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'golden-stage-'));
    fs.writeFileSync(path.join(stage, 'manifest.json'), JSON.stringify({ koreader_version: 'v2026.07.1', device }));
    fs.writeFileSync(path.join(stage, 'crash.log'), log);
    const names = ['manifest.json', 'crash.log'];
    if (withSnapshot) {
      fs.writeFileSync(path.join(stage, 'snapshot.json'), JSON.stringify(SNAPSHOT));
      names.push('snapshot.json');
    }
    if (withShot) {
      await sharp({ create: { width: 8, height: 8, channels: 3, background: '#888' } }).png().toFile(path.join(stage, 'screenshot.png'));
      names.push('screenshot.png');
    }
    fs.mkdirSync(path.join(inbox, device), { recursive: true });
    const out = path.join(inbox, device, file);
    // Same -czf as the device; neutral owner fields keep local user names out of the fixture.
    execFileSync('tar', ['--owner=0', '--group=0', '--numeric-owner', '-czf', out, ...names], { cwd: stage });
    fs.utimesSync(out, new Date(mtime), new Date(mtime));
    fs.rmSync(stage, { recursive: true });
    bundles.push({ device, file, base64: fs.readFileSync(out).toString('base64'), mtime });
  }

  // Upload order (oldest first) is the order the Worker test replays them in.
  await make('kindle-1', '20261031-090000.tar.gz', '', '2026-10-31T09:00:00.000Z', true);
  await make('emu', '20261031-100000.tar.gz', 'first\nline two\n', '2026-10-31T10:00:00.000Z', true);
  await make('emu', '20261031-110000.tar.gz', 'second\n', '2026-10-31T11:00:00.000Z', false, false);

  const server = createApp(new DeviceRegistry(), inbox).listen(0, '127.0.0.1');
  await new Promise<void>((r) => server.on('listening', () => r()));
  const port = (server.address() as { port: number }).port;

  function call(name: string, args: object): Promise<any> {
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

  // Images are summarised: the gateway re-encodes them with sharp, which the Worker cannot.
  const strip = (r: any) => ({
    isError: r.isError ?? false,
    content: r.content.map((c: any) => (c.type === 'image' ? { type: 'image' } : c)),
  });

  const cases: Array<{ tool: string; args: Record<string, unknown> }> = [
    { tool: 'list_diagnostics', args: {} },
    { tool: 'list_diagnostics', args: { device: 'emu' } },
    { tool: 'list_diagnostics', args: { device: 'nobody' } },
    { tool: 'list_diagnostics', args: { device: '../..' } },
    { tool: 'read_diagnostics', args: { device: 'emu' } },
    { tool: 'read_diagnostics', args: { device: 'emu', file: '20261031-100000.tar.gz' } },
    { tool: 'read_diagnostics', args: { device: 'kindle-1' } },
    { tool: 'read_diagnostics', args: { device: '..' } },
    { tool: 'read_diagnostics', args: { device: 'emu', file: '../../x.tar.gz' } },
    { tool: 'read_diagnostics', args: { device: 'emu', file: 'none.tar.gz' } },
    { tool: 'read_diagnostics', args: { device: 'nobody' } },
  ];
  const results = [];
  for (const c of cases) results.push({ ...c, result: strip(await call(c.tool, c.args)) });
  server.close();
  fs.rmSync(inbox, { recursive: true });

  fs.writeFileSync(OUT, JSON.stringify({ bundles, cases: results }, null, 2) + '\n');
  console.log(`wrote ${OUT}: ${bundles.length} bundles, ${results.length} cases`);
}

main().catch((err) => { console.error(err); process.exit(1); });
