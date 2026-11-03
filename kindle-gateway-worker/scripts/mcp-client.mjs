// Drive the Worker's /mcp with the MCP SDK client against `npx wrangler dev` and a connected
// device (scripts/fake-device.mjs or a real one): list tools and devices, snapshot, tap, take a
// screenshot (saved as a file, with timing) and restart KOReader.
//
//   AGENT_KEY=... node scripts/mcp-client.mjs [http://127.0.0.1:8787] [device] [out-dir] [legacy|modern]
import { Client, StreamableHTTPClientTransport } from '@modelcontextprotocol/client';
import { writeFileSync } from 'node:fs';

const base = process.argv[2] ?? 'http://127.0.0.1:8787';
const device = process.argv[3] ?? 'fake-kindle';
const outDir = process.argv[4] ?? '.';
const mode = process.argv[5] ?? 'modern';
const { AGENT_KEY } = process.env;
if (!AGENT_KEY) {
  console.error('set AGENT_KEY');
  process.exit(2);
}
const log = (...a) => console.log(new Date().toISOString(), ...a);

const client = new Client(
  { name: 'mcp-client-script', version: '1.0.0' },
  mode === 'modern' ? { versionNegotiation: { mode: { pin: '2026-07-28' } } } : {},
);
await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp`), {
  requestInit: { headers: { Authorization: `Bearer ${AGENT_KEY}` } },
}));
log('protocol', client.getNegotiatedProtocolVersion());

const { tools } = await client.listTools();
log(`tools (${tools.length}):`, tools.map((t) => t.name).sort().join(' '));
writeFileSync(`${outDir}/tools-list.json`, JSON.stringify(tools, null, 2));

async function call(name, args) {
  const t0 = performance.now();
  const res = await client.callTool({ name, arguments: args });
  const ms = Math.round(performance.now() - t0);
  const summary = res.content.map((b) => (b.type === 'text' ? b.text : `[${b.type} ${b.mimeType} ${b.data.length} base64 chars]`)).join('\n');
  log(`${name} ${JSON.stringify(args)} -> ${ms} ms${res.isError ? ' (isError)' : ''}\n${summary}`);
  return { res, ms };
}

await call('list_devices', {});
await call('device_status', { device });
const snap = await call('snapshot', { device });
const ref = /\[(\d+_\d+)\]/.exec(snap.res.content[0].text)?.[1];
await call('tap', { device, ref });
const base0 = await call('device_status', { device });
for (let i = 1; i <= 3; i++) {
  const ss = await call('screenshot', { device });
  const img = ss.res.content.find((b) => b.type === 'image');
  const ext = img.mimeType === 'image/jpeg' ? 'jpg' : 'png';
  writeFileSync(`${outDir}/screenshot-${mode}-${i}.${ext}`, Buffer.from(img.data, 'base64'));
  log(`screenshot ${i}: ${img.mimeType}, ${Buffer.from(img.data, 'base64').length} bytes, ${ss.ms} ms wall (device_status round trip ${base0.ms} ms)`);
}
await call('restart_koreader', { device });
await call('list_devices', {});
await call('snapshot', { device });
await client.close();
log('done');
