// A fake Kindle for `npx wrangler dev`: connects to /device with the device key, says hello and
// keeps running, answering the methods the MCP tools call (ui_snapshot, ui_act,
// capture_screenshot, run_command, device_status, get_current_view, echo). A run_command that
// starts koreader.sh closes the socket and reconnects 2 s later, as a restarted KOReader does.
//
//   DEVICE_KEY=... node scripts/fake-device.mjs [http://127.0.0.1:8787] [screenshot.png]
//
// Without a PNG argument, capture_screenshot returns a 1x1 PNG.
import { readFileSync } from 'node:fs';
import WebSocket from 'ws';

const base = process.argv[2] ?? 'http://127.0.0.1:8787';
const png = process.argv[3]
  ? readFileSync(process.argv[3]).toString('base64')
  : 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGP4DwABAQEAG7buVgAAAABJRU5ErkJggg==';
const { DEVICE_KEY } = process.env;
if (!DEVICE_KEY) {
  console.error('set DEVICE_KEY');
  process.exit(2);
}
const name = 'fake-kindle';
const log = (...a) => console.log(new Date().toISOString(), ...a);
let snapshotId = 0;

function snapshot() {
  const id = ++snapshotId;
  return {
    snapshot: id,
    window: 'FileManager',
    total: 2,
    nodes: [
      { ref: `${id}_1`, kind: 'item', text: 'Synced reading list', state: '' },
      { ref: `${id}_2`, kind: 'button', text: 'Close', state: '' },
    ],
  };
}

function connect() {
  const ws = new WebSocket(`${base.replace(/^http/, 'ws')}/device`, { headers: { Authorization: `Bearer ${DEVICE_KEY}` } });
  let heartbeat;
  ws.on('open', () => {
    log('connected; sending hello');
    ws.send(JSON.stringify({ type: 'hello', name, id_hash: 'feedfacecafebeef', koreader_version: 'fake', plugin_versions: { koreader_mcp: 'fake' } }));
    heartbeat = setInterval(() => ws.send('{"type":"ping"}'), 60_000);
  });
  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString());
    if (msg.type) {
      log('<-', JSON.stringify(msg));
      if (msg.type === 'refused') process.exit(1);
      return;
    }
    log('<- call', msg.method, JSON.stringify(msg.params).slice(0, 120));
    const reply = (result) => ws.send(JSON.stringify({ id: msg.id, result }));
    switch (msg.method) {
      case 'ui_snapshot': return reply(snapshot());
      case 'ui_act': return reply({ result: `${msg.params.what} ok`, snapshot: snapshot(), logs: ['fake: acted'] });
      case 'capture_screenshot': return reply({ image_base64: png, size_bytes: Buffer.from(png, 'base64').length });
      case 'device_status': return reply({ name, battery: 80, fake: true });
      case 'get_current_view': return reply({ widgets: ['FileManager'] });
      case 'echo': return reply({ echoed: msg.params });
      case 'run_command': {
        reply({ output: 'ok' });
        if (String(msg.params.command).includes('koreader.sh')) {
          log('restart requested: closing, reconnecting in 2 s');
          snapshotId = 0;
          setTimeout(() => ws.close(1001, 'restarting'), 100);
          setTimeout(connect, 2_000);
        }
        return;
      }
      default:
        ws.send(JSON.stringify({ id: msg.id, error: { code: -32601, message: `unknown method ${msg.method}` } }));
    }
  });
  ws.on('close', (code, reason) => { clearInterval(heartbeat); log('closed', code, reason.toString()); });
  ws.on('error', (err) => log('error', err.message));
}

connect();
