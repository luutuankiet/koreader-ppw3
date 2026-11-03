// A fake Kindle for `npx wrangler dev`: connects to /device with the device key, says hello,
// answers `echo` calls, sends the heartbeat ping, then drives one call through /debug/call
// (needs ENABLE_DEBUG_ROUTES=1 and the agent key) and exits 0 when the round trip matched.
//
//   DEVICE_KEY=... AGENT_KEY=... node scripts/fake-device.mjs [http://127.0.0.1:8787]
import WebSocket from 'ws';

const base = process.argv[2] ?? 'http://127.0.0.1:8787';
const { DEVICE_KEY, AGENT_KEY } = process.env;
if (!DEVICE_KEY || !AGENT_KEY) {
  console.error('set DEVICE_KEY and AGENT_KEY');
  process.exit(2);
}
const name = 'fake-kindle';
const log = (...a) => console.log(new Date().toISOString(), ...a);
const fail = (why) => { log('FAIL', why); process.exit(1); };
setTimeout(() => fail('timed out after 20s'), 20_000).unref();

// Wrong key first: the upgrade must be refused.
await new Promise((resolve) => {
  const bad = new WebSocket(`${base.replace(/^http/, 'ws')}/device`, { headers: { Authorization: 'Bearer wrong' } });
  bad.on('unexpected-response', (_req, res) => { log('wrong key -> HTTP', res.statusCode); resolve(); });
  bad.on('open', () => fail('wrong key was accepted'));
  bad.on('error', () => resolve());
});

const ws = new WebSocket(`${base.replace(/^http/, 'ws')}/device`, { headers: { Authorization: `Bearer ${DEVICE_KEY}` } });
ws.on('open', () => {
  log('connected; sending hello');
  ws.send(JSON.stringify({ type: 'hello', name, id_hash: 'feedfacecafebeef', koreader_version: 'fake', plugin_versions: { koreader_mcp: 'fake' } }));
});
ws.on('message', async (data) => {
  const text = data.toString();
  log('<-', text);
  const msg = JSON.parse(text);
  if (msg.type === 'welcome') {
    log('-> {"type":"ping"}');
    ws.send('{"type":"ping"}');
  } else if (msg.type === 'pong') {
    log('heartbeat answered; triggering a call through /debug/call');
    const res = await fetch(`${base}/debug/call`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${AGENT_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ device: name, method: 'echo', params: { hello: 'from wrangler dev' } }),
    });
    const body = await res.json();
    log('/debug/call ->', res.status, JSON.stringify(body));
    if (body?.result?.echoed?.hello !== 'from wrangler dev') fail('reply did not round-trip');
    const list = await fetch(`${base}/debug/devices`, { headers: { Authorization: `Bearer ${AGENT_KEY}` } });
    log('/debug/devices ->', list.status, await list.text());
    log('PASS');
    ws.close(1000, 'done');
    process.exit(0);
  } else if (typeof msg.id === 'number' && msg.method === 'echo') {
    const reply = JSON.stringify({ id: msg.id, result: { echoed: msg.params } });
    log('->', reply);
    ws.send(reply);
  } else if (msg.type === 'refused') {
    fail(`refused: ${msg.reason}`);
  }
});
ws.on('close', (code, reason) => log('closed', code, reason.toString()));
ws.on('error', (err) => fail(err.message));
