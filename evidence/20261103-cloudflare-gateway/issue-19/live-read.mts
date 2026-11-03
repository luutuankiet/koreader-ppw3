// Reads the live upload back through the Worker's own list_diagnostics and read_diagnostics
// handlers (kindle-gateway-worker/src/diagnostics-tools.ts), against the local R2 bucket that
// `wrangler dev` persists under kindle-gateway-worker/.wrangler/state. wrangler's
// getPlatformProxy hands Node the same INBOX binding the dev server uses; no route is added.
// Run from kindle-gateway-worker/: npx tsx <topic-folder>/72/live-read.mts
import { getPlatformProxy } from 'wrangler';
import { diagnosticsTools } from '../../../../kindle-gateway-worker/src/diagnostics-tools';

const proxy = await getPlatformProxy<{ INBOX: R2Bucket }>({ configPath: 'wrangler.jsonc', persist: true });
const bucket = proxy.env.INBOX;
const call = (name: string, args: Record<string, unknown>) =>
  diagnosticsTools.find((t) => t.name === name)!.handler(bucket, args);

const show = (label: string, r: Awaited<ReturnType<typeof call>>) => {
  console.log(`=== ${label}${r.isError ? ' (isError)' : ''}`);
  for (const c of r.content) {
    if (c.type === 'text') console.log(c.text);
    else console.log(`[image ${c.mimeType}, ${c.data.length} base64 chars, starts ${c.data.slice(0, 12)}]`);
  }
};

show('list_diagnostics {"device":"live-test"}', await call('list_diagnostics', { device: 'live-test' }));
show('read_diagnostics {"device":"live-test"} (newest)', await call('read_diagnostics', { device: 'live-test' }));
show('read_diagnostics {"device":"live-test","file":"big.tar.gz"}', await call('read_diagnostics', { device: 'live-test', file: 'big.tar.gz' }));
const keys = (await bucket.list({ prefix: 'inbox/live-test/' })).objects.map((o) => `${o.key} ${o.size}`);
console.log('=== R2 keys under inbox/live-test/\n' + keys.join('\n'));
await proxy.dispose();
