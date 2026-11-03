// Fake WebSocket gateway for koreader_mcp (issue 69). Node built-ins only.
// Listens on 127.0.0.1:8791, path /device. Checks Authorization: Bearer <DEVICE_KEY>
// (read from keys.env, never logged), answers hello with welcome, sends one
// device_status call and logs the reply, answers {"type":"ping"} with {"type":"pong"},
// and sends one WebSocket ping control frame to check the client answers with a pong.
//
// node 69-fake-gateway.mjs [path/to/keys.env]
import http from "node:http";
import crypto from "node:crypto";
import fs from "node:fs";

const PORT = 8791;
const KEYS = process.argv[2] || "<topic-folder>/keys.env";
const DEVICE_KEY = fs.readFileSync(KEYS, "utf8").match(/^DEVICE_KEY=(.*)$/m)[1].trim();
const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

const log = (...a) => console.log(new Date().toISOString(), ...a);
let attempts = 0;

function frame(op, payload) {
  const body = Buffer.from(payload);
  let head;
  if (body.length < 126) head = Buffer.from([0x80 | op, body.length]);
  else if (body.length < 65536) { head = Buffer.alloc(4); head[0] = 0x80 | op; head[1] = 126; head.writeUInt16BE(body.length, 2); }
  else { head = Buffer.alloc(10); head[0] = 0x80 | op; head[1] = 127; head.writeBigUInt64BE(BigInt(body.length), 2); }
  return Buffer.concat([head, body]); // server frames are never masked
}

const server = http.createServer((req, res) => { res.writeHead(404); res.end(); });

server.on("upgrade", (req, socket) => {
  attempts += 1;
  const n = attempts;
  const auth = req.headers["authorization"] || "";
  const keyOk = auth === "Bearer " + DEVICE_KEY;
  log(`#${n} upgrade ${req.method} ${req.url} from ${socket.remoteAddress} auth=${auth ? (keyOk ? "bearer-ok" : "bearer-WRONG") : "missing"}`);
  if (req.url !== "/device" || !keyOk || (req.headers["upgrade"] || "").toLowerCase() !== "websocket") {
    log(`#${n} -> 401`);
    socket.end("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    return;
  }
  const accept = crypto.createHash("sha1").update(req.headers["sec-websocket-key"] + GUID).digest("base64");
  socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
    `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);
  log(`#${n} -> 101 switching protocols`);

  const sendText = (s) => { socket.write(frame(0x1, s)); log(`#${n} >> ${s}`); };
  let buf = Buffer.alloc(0);
  let fragments = [];

  function onMessage(text) {
    log(`#${n} << ${text.length > 400 ? text.slice(0, 400) + `... (${text.length} bytes)` : text}`);
    let msg;
    try { msg = JSON.parse(text); } catch { log(`#${n} not JSON`); return; }
    if (msg.type === "ping") { sendText('{"type":"pong"}'); return; }
    if (msg.type === "hello") {
      sendText(JSON.stringify({ type: "welcome", name: msg.name }));
      setTimeout(() => sendText(JSON.stringify({ id: 1, method: "device_status", params: {} })), 500);
      setTimeout(() => { socket.write(frame(0x9, "probe")); log(`#${n} >> [ping control frame "probe"]`); }, 1500);
      return;
    }
    if (msg.id === 1) log(`#${n} device_status reply received: ${msg.error ? "ERROR" : "result"}`);
  }

  socket.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      if (buf.length < 2) return;
      const fin = (buf[0] & 0x80) !== 0, op = buf[0] & 0x0f, masked = (buf[1] & 0x80) !== 0;
      let len = buf[1] & 0x7f, off = 2;
      if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
      const need = off + (masked ? 4 : 0) + len;
      if (buf.length < need) return;
      if (!masked) log(`#${n} protocol error: client frame not masked`);
      const mask = masked ? buf.subarray(off, off + 4) : null;
      const payload = Buffer.from(buf.subarray(off + (masked ? 4 : 0), need));
      if (mask) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
      buf = buf.subarray(need);
      if (op === 0x8) { log(`#${n} << close`); socket.end(frame(0x8, "")); return; }
      if (op === 0x9) { socket.write(frame(0xa, payload)); log(`#${n} << ping control, >> pong`); continue; }
      if (op === 0xa) { log(`#${n} << pong control frame "${payload.toString()}"`); continue; }
      fragments.push(payload);
      if (fin) { const text = Buffer.concat(fragments).toString("utf8"); fragments = []; onMessage(text); }
    }
  });
  socket.on("close", () => log(`#${n} socket closed`));
  socket.on("error", (e) => log(`#${n} socket error ${e.message}`));
});

server.listen(PORT, "127.0.0.1", () => log(`fake gateway listening on ws://127.0.0.1:${PORT}/device`));
