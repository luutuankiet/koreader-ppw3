// End-to-end checks against the deployed Worker's /mcp with the MCP SDK client (the one the
// worker's own tests use). Never prints the key.
//   AGENT_KEY=... node e2e-client.mjs <worker dir> <base url> <device> <out dir> <modern|legacy>
import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const [W, base, device, outDir, mode] = process.argv.slice(2);
const entry = pathToFileURL(`${W}/node_modules/@modelcontextprotocol/client/dist/index.mjs`).href;
const { Client, StreamableHTTPClientTransport } = await import(entry);
const log = (...a) => console.log(new Date().toISOString(), ...a);
const client = new Client({ name: 'e2e-21', version: '1.0.0' },
  mode === 'modern' ? { versionNegotiation: { mode: { pin: '2026-07-28' } } } : {});
await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp`), {
  requestInit: { headers: { Authorization: `Bearer ${process.env.AGENT_KEY}` } },
}));
log(`[${mode}] protocol`, client.getNegotiatedProtocolVersion());
const { tools } = await client.listTools();
log(`tools (${tools.length}):`, tools.map((t) => t.name).sort().join(' '));
const results = [];
async function call(name, args, check) {
  const t0 = performance.now();
  let res, err;
  try { res = await client.callTool({ name, arguments: args }); } catch (e) { err = e; }
  const ms = Math.round(performance.now() - t0);
  const text = err ? `THROW ${err.message}` : res.content.map((b) => (b.type === 'text' ? b.text : `[${b.type} ${b.mimeType} ${b.data.length} base64 chars]`)).join('\n');
  const ok = !err && !res.isError && (!check || check(res, text));
  results.push({ name, ok, ms });
  log(`${ok ? 'PASS' : 'FAIL'} ${name} ${JSON.stringify(args)} ${ms} ms${res?.isError ? ' (isError)' : ''}\n${text.length > 1500 ? text.slice(0, 1500) + `\n... (${text.length} chars)` : text}`);
  return { res, text };
}
await call('list_devices', {}, (_, t) => t.includes(`"${device}"`) && t.includes('online'));
await call('device_status', { device });
await call('get_current_view', { device });
const snap = await call('snapshot', { device });
const ref = /\[(\d+_\d+)\]/.exec(snap.text)?.[1];
if (mode === 'modern') {
  await call('tap', { device, ref }, () => !!ref);
  await call('go_back', { device });
}
const ss = await call('screenshot', { device }, (r) => r.content.some((b) => b.type === 'image' && b.mimeType === 'image/jpeg'));
const img = ss.res?.content.find((b) => b.type === 'image');
if (img) {
  const ext = img.mimeType === 'image/jpeg' ? 'jpg' : 'png';
  writeFileSync(`${outDir}/screenshot-${mode}.${ext}`, Buffer.from(img.data, 'base64'));
  log(`screenshot: ${img.mimeType}, ${Buffer.from(img.data, 'base64').length} bytes`);
}
await call('list_diagnostics', { device });
if (mode === 'modern') {
  await call('restart_koreader', { device }, (_, t) => !/timeout|false/.test(t));
  await call('list_devices', {}, (_, t) => t.includes(`"${device}"`) && t.includes('online'));
  await call('snapshot', { device });
}
await client.close();
log('summary', JSON.stringify(results));
