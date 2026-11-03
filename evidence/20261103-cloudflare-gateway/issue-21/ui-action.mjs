// A visible UI action through the deployed Worker: snapshot, tap the "tech/" folder row,
// screenshot it, then tap "../" back to Home. Never prints the key.
//   AGENT_KEY=... node ui-action.mjs <worker dir> <base url> <device> <out dir>
import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const [W, base, device, outDir] = process.argv.slice(2);
const { Client, StreamableHTTPClientTransport } = await import(pathToFileURL(`${W}/node_modules/@modelcontextprotocol/client/dist/index.mjs`).href);
const log = (...a) => console.log(new Date().toISOString(), ...a);
const client = new Client({ name: 'e2e-21-ui', version: '1.0.0' }, { versionNegotiation: { mode: { pin: '2026-07-28' } } });
await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp`), {
  requestInit: { headers: { Authorization: `Bearer ${process.env.AGENT_KEY}` } },
}));
const call = async (name, args) => {
  const res = await client.callTool({ name, arguments: args });
  const text = res.content.filter((b) => b.type === 'text').map((b) => b.text).join('\n');
  log(`${res.isError ? 'FAIL' : 'PASS'} ${name} ${JSON.stringify(args)}\n${text}`);
  return { res, text };
};
const refOf = (text, needle) => text.split('\n').find((l) => l.includes(needle))?.match(/\[(\d+_\d+)\]/)?.[1];
const s1 = await call('snapshot', { device });
await call('tap', { device, ref: refOf(s1.text, 'row "tech/') });
const s2 = await call('snapshot', { device });
const ss = await call('screenshot', { device });
const img = ss.res.content.find((b) => b.type === 'image');
writeFileSync(`${outDir}/screenshot-after-tap.jpg`, Buffer.from(img.data, 'base64'));
log(`in folder: ${/tech/.test(s2.text) && !/Laws of chess/.test(s2.text) ? 'yes' : 'NO'}`);
await call('tap', { device, ref: refOf(s2.text, '../') });
const s3 = await call('snapshot', { device });
log(`back home: ${/Laws of chess/.test(s3.text) ? 'yes' : 'NO'}`);
await client.close();
