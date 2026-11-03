// Compare the Worker's tools/list (saved by mcp-client.mjs) with the thinkpad Node gateway's
// live tools/list: names, descriptions and input schemas.
//   node tools-parity.mjs <worker tools-list.json> [http://127.0.0.1:9999/mcp] > tools-parity.log
import { readFileSync, writeFileSync } from 'node:fs';
const [workerPath, nodeUrl = 'http://127.0.0.1:9999/mcp'] = process.argv.slice(2);
const res = await fetch(nodeUrl, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' },
  body: JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} }),
});
const raw = await res.text();
const data = raw.split('\n').find((l) => l.startsWith('data: '));
const nodeTools = JSON.parse(data ? data.slice(6) : raw).result.tools;
writeFileSync(workerPath.replace(/tools-list\.json$/, 'tools-list-node-gateway.json'), JSON.stringify(nodeTools, null, 2));
const workerTools = JSON.parse(readFileSync(workerPath, 'utf8'));
const byName = (ts) => new Map(ts.map((t) => [t.name, t]));
const n = byName(nodeTools), w = byName(workerTools);
// Compare what an agent sees; drop JSON Schema dialect noise ($schema, additionalProperties).
// Keys are sorted: zod 4 emits "description" before "type" on optional fields, zod 3 after.
const sortKeys = (v) => (Array.isArray(v) ? v.map(sortKeys) : v && typeof v === 'object'
  ? Object.fromEntries(Object.keys(v).filter((k) => k !== '$schema' && k !== 'additionalProperties').sort().map((k) => [k, sortKeys(v[k])]))
  : v);
const norm = (s) => JSON.stringify(sortKeys(s));
console.log(`node gateway: ${n.size} tools, worker: ${w.size} tools`);
console.log('only on node gateway:', [...n.keys()].filter((k) => !w.has(k)).sort().join(' ') || '(none)');
console.log('only on worker:', [...w.keys()].filter((k) => !n.has(k)).sort().join(' ') || '(none)');
let same = 0;
for (const [name, wt] of [...w].sort()) {
  const nt = n.get(name);
  if (!nt) continue;
  const diffs = [];
  if (nt.description !== wt.description) diffs.push(`description\n    node:   ${nt.description}\n    worker: ${wt.description}`);
  if (norm(nt.inputSchema) !== norm(wt.inputSchema)) diffs.push(`inputSchema\n    node:   ${norm(nt.inputSchema)}\n    worker: ${norm(wt.inputSchema)}`);
  if (diffs.length) console.log(`DIFF ${name}: ${diffs.join('\n  ')}`);
  else same++;
}
console.log(`${same} shared tools identical in name, description and input schema`);
