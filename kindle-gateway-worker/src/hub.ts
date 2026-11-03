import { DurableObject } from 'cloudflare:workers';
import { isRpcResponse, validateHello } from '../../kindle-gateway/src/device-protocol';
import { SnapshotTracker } from '../../kindle-gateway/src/ui-snapshot';
import { createMcpFetch } from './mcp';
import { resizeScreenshot } from './screenshot';

/**
 * The device's 60 s heartbeat and its answer, matched byte for byte by the runtime
 * (setWebSocketAutoResponse) so a ping never wakes the hub. A ping that differs in any byte
 * (a trailing newline, other spacing) still gets a pong, but wakes the object to do it.
 */
export const DEVICE_PING = '{"type":"ping"}';
export const DEVICE_PONG = '{"type":"pong"}';

/** Close a socket that has not sent a valid hello within this long. */
export const HELLO_TIMEOUT_MS = 10_000;
/** Close a socket with no message and no ping for this long (the device pings every 60 s). */
export const SILENCE_MS = 150_000;
/** How often the alarm looks for silent sockets while any are open. Each run wakes the hub. */
export const SWEEP_INTERVAL_MS = 5 * 60_000;
/** Default wait for a tool call reply, as on the Node gateway. */
export const DEFAULT_CALL_TIMEOUT_MS = 10_000;
/** Default wait for a device to come back after a restart. */
export const DEFAULT_RECONNECT_TIMEOUT_MS = 60_000;

/**
 * Per-socket state kept by the runtime across hibernation (serializeAttachment, at most
 * 2,048 bytes). `name` is set once the hello is accepted; a socket without it is not yet a
 * device.
 */
interface Attachment {
  connectedAt: number;
  lastMessageAt: number;
  remoteAddress: string;
  name?: string;
  idHash?: string;
  koreaderVersion?: string;
  pluginVersions?: Record<string, string>;
}

/** What listDevices returns; the same shape as the Node gateway's list_devices. */
export interface DeviceSummary {
  name: string;
  status: 'online';
  idHash: string;
  koreaderVersion?: string;
  pluginVersions?: Record<string, string>;
  remoteAddress: string;
  connectedAt: string;
  lastMessageAt: string;
}

/**
 * A device's reply to a call: `{id,result}` or `{id,error}`. `result` and `data` are whatever
 * JSON the device sent. Not `unknown` (the RPC stub types it as never) and not a recursive
 * JSON type (too deep for the stub's type mapping, TS2589).
 */
export interface DeviceReply {
  id: number;
  result?: object | string | number | boolean | null;
  error?: { code: number; message: string; data?: object | string | number | boolean | null };
}

interface PendingCall {
  ws: WebSocket;
  resolve: (r: DeviceReply) => void;
  reject: (e: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

interface Waiter {
  name: string;
  after: number;
  resolve: (d: DeviceSummary | null) => void;
  timer: ReturnType<typeof setTimeout>;
}

/**
 * One instance (idFromName("hub")) holds every device's WebSocket. Sockets are accepted with
 * the Hibernation API, so the object is evicted from memory while nothing happens and the
 * runtime keeps the sockets open. The registry is never held in memory: it is read from
 * ctx.getWebSockets() and each socket's attachment, so it survives hibernation unchanged.
 * Pending calls and reconnect waiters live in memory; an outstanding call keeps the object
 * awake, and nothing is pending once it is allowed to sleep.
 */
export class Hub extends DurableObject<Env> {
  private pending = new Map<number, PendingCall>();
  private waiters: Waiter[] = [];
  /** Small ids survive Lua's number formatting; a random start avoids matching a late reply
   *  to a call made before the object last slept. */
  private nextId = Math.floor(Math.random() * 1_000_000);
  /** Messages delivered to webSocketMessage since this instance started (tests use it to
   *  show that an auto-answered ping never woke the object). */
  handledMessages = 0;
  /** Latest snapshot id per device for the stale-reference check, in memory as on the Node
   *  gateway. Lost when the object hibernates, which is safe: the tracker passes through any
   *  reference it cannot judge and the device refuses stale ones itself. */
  private tracker = new SnapshotTracker();
  private mcp?: (request: Request) => Promise<Response>;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(DEVICE_PING, DEVICE_PONG));
  }

  /** The Worker forwards authenticated `/mcp` requests and `GET /device` upgrades here. */
  async fetch(request: Request): Promise<Response> {
    if (new URL(request.url).pathname === '/mcp') return this.serveMcp(request);
    if (request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
      return new Response('expected a WebSocket upgrade', { status: 426 });
    }
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server);
    const now = Date.now();
    const att: Attachment = {
      connectedAt: now,
      lastMessageAt: now,
      remoteAddress: request.headers.get('CF-Connecting-IP') ?? 'unknown',
    };
    server.serializeAttachment(att);
    await this.ensureSweep();
    return new Response(null, { status: 101, webSocket: client });
  }

  /** MCP runs here, not in the Worker: the free Worker gets 10 ms of CPU per request. */
  private serveMcp(request: Request): Promise<Response> {
    this.mcp ??= createMcpFetch({
      listDevices: () => this.listDevices(),
      call: (d, m, p, t) => this.call(d, m, p, t),
      waitForReconnect: (d, t, a) => this.waitForReconnect(d, t, a),
      tracker: this.tracker,
      resizeScreenshot,
      einkDelayMs: Number(this.env.EINK_DELAY_MS),
      reconnectTimeoutMs: DEFAULT_RECONNECT_TIMEOUT_MS,
    });
    return this.mcp(request);
  }

  // ---- device API used by the MCP tools --------------------------------------------------

  /** Devices whose hello was accepted and whose socket is still open. */
  async listDevices(): Promise<DeviceSummary[]> {
    return this.devices().map(({ ws, att }) => this.summary(ws, att));
  }

  /**
   * Send `{id,method,params}` to `deviceName` and resolve with its `{id,result|error}` reply.
   * A device-side error comes back as a resolved reply with `error`. Rejects (the Error
   * message crosses the RPC boundary) when the device is not connected, disconnects before
   * replying, or says nothing within `timeoutMs`; the timeout message starts with "no reply"
   * as on the Node gateway.
   */
  async call(
    deviceName: string,
    method: string,
    params?: Record<string, unknown>,
    timeoutMs: number = DEFAULT_CALL_TIMEOUT_MS,
  ): Promise<DeviceReply> {
    const device = this.devices().find((d) => d.att.name === deviceName);
    if (!device) throw new Error(`device '${deviceName}' is not connected`);
    const id = ++this.nextId;
    return new Promise<DeviceReply>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`no reply to ${method} within ${timeoutMs / 1000}s`));
      }, timeoutMs);
      this.pending.set(id, { ws: device.ws, resolve, reject, timer });
      try {
        device.ws.send(JSON.stringify({ id, method, params: params ?? {} }));
      } catch (err) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new Error(`send to '${deviceName}' failed: ${(err as Error).message}`));
      }
    });
  }

  /**
   * Resolve with `deviceName` once it holds a connection opened at or after `afterMs`
   * (default: now), or with null after `timeoutMs`. Used after restart_koreader.
   */
  async waitForReconnect(
    deviceName: string,
    timeoutMs: number = DEFAULT_RECONNECT_TIMEOUT_MS,
    afterMs: number = Date.now(),
  ): Promise<DeviceSummary | null> {
    const current = this.devices().find((d) => d.att.name === deviceName);
    if (current && current.att.connectedAt >= afterMs) return this.summary(current.ws, current.att);
    return new Promise((resolve) => {
      const waiter: Waiter = {
        name: deviceName,
        after: afterMs,
        resolve: (d) => { clearTimeout(waiter.timer); resolve(d); },
        timer: setTimeout(() => {
          this.waiters = this.waiters.filter((w) => w !== waiter);
          resolve(null);
        }, timeoutMs),
      };
      this.waiters.push(waiter);
    });
  }

  // ---- Hibernation API handlers ----------------------------------------------------------

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    this.handledMessages++;
    const text = typeof message === 'string' ? message : new TextDecoder().decode(message);
    const att = ws.deserializeAttachment() as Attachment;
    att.lastMessageAt = Date.now();
    this.saveAttachment(ws, att);
    // One message per frame is the protocol; tolerate a trailing newline or several lines.
    for (const line of text.split('\n')) {
      const trimmed = line.trim();
      if (trimmed === '') continue;
      let msg: Record<string, unknown>;
      try {
        msg = JSON.parse(trimmed);
      } catch {
        console.warn(`[hub] ${att.name ?? att.remoteAddress}: dropping a frame that is not JSON`);
        continue;
      }
      if (!msg || typeof msg !== 'object') continue;
      if (isRpcResponse(msg)) {
        this.settle(ws, msg as unknown as DeviceReply);
      } else if (msg.type === 'ping') {
        ws.send(DEVICE_PONG);
      } else if (!att.name) {
        if (!this.acceptHello(ws, att, msg)) return;
      }
    }
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    this.dropSocket(ws, `connection closed (${code}${reason ? ` ${reason}` : ''})`);
    try { ws.close(1000, 'closing'); } catch { /* already closed */ }
  }

  async webSocketError(ws: WebSocket, error: unknown): Promise<void> {
    this.dropSocket(ws, `socket error: ${String(error)}`);
  }

  /** Close sockets that never said hello or went silent; repeat while any socket is open. */
  async alarm(): Promise<void> {
    const now = Date.now();
    for (const ws of this.ctx.getWebSockets()) {
      const att = ws.deserializeAttachment() as Attachment | null;
      if (!att) continue;
      if (!att.name && now - att.connectedAt > HELLO_TIMEOUT_MS) {
        this.closeSocket(ws, 1008, 'no hello');
      } else if (att.name && now - this.lastSign(ws, att) > SILENCE_MS) {
        this.closeSocket(ws, 1001, `silent for ${SILENCE_MS / 1000}s`);
      }
    }
    if (this.ctx.getWebSockets().length > 0) {
      await this.ctx.storage.setAlarm(Date.now() + SWEEP_INTERVAL_MS);
    }
  }

  // ---- internals -------------------------------------------------------------------------

  private acceptHello(ws: WebSocket, att: Attachment, msg: Record<string, unknown>): boolean {
    const hello = validateHello(msg);
    if (typeof hello === 'string') {
      ws.send(JSON.stringify({ type: 'refused', reason: hello }));
      this.closeSocket(ws, 1008, 'bad hello');
      return false;
    }
    for (const other of this.devices()) {
      if (other.ws === ws || other.att.name !== hello.name) continue;
      if (other.att.idHash !== hello.id_hash) {
        const reason = `name '${hello.name}' is held by another device`;
        console.warn(`[hub] refused '${hello.name}' from ${att.remoteAddress}: ${reason}`);
        ws.send(JSON.stringify({ type: 'refused', reason }));
        this.closeSocket(ws, 1008, 'name taken');
        return false;
      }
      // Same device reconnected before its old socket was noticed dead.
      this.closeSocket(other.ws, 1000, 'replaced by a new connection');
    }
    att.name = hello.name;
    att.idHash = hello.id_hash;
    att.koreaderVersion = hello.koreader_version;
    att.pluginVersions = hello.plugin_versions;
    att.connectedAt = Date.now();
    this.saveAttachment(ws, att);
    ws.send(JSON.stringify({ type: 'welcome', name: hello.name }));
    console.log(`[hub] '${hello.name}' online from ${att.remoteAddress} (KOReader ${hello.koreader_version ?? '?'})`);
    const summary = this.summary(ws, att);
    const ready = this.waiters.filter((w) => w.name === hello.name && att.connectedAt >= w.after);
    this.waiters = this.waiters.filter((w) => !ready.includes(w));
    for (const w of ready) w.resolve(summary);
    return true;
  }

  private settle(ws: WebSocket, reply: DeviceReply): void {
    const p = this.pending.get(reply.id);
    if (!p || p.ws !== ws) return; // late reply to a call that timed out or predates a sleep
    this.pending.delete(reply.id);
    clearTimeout(p.timer);
    p.resolve(reply);
  }

  /** Every socket whose hello was accepted, with its attachment. */
  private devices(): Array<{ ws: WebSocket; att: Attachment }> {
    const out: Array<{ ws: WebSocket; att: Attachment }> = [];
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.readyState !== WebSocket.OPEN) continue;
      const att = ws.deserializeAttachment() as Attachment | null;
      if (att?.name) out.push({ ws, att });
    }
    return out;
  }

  private summary(ws: WebSocket, att: Attachment): DeviceSummary {
    return {
      name: att.name!,
      status: 'online',
      idHash: att.idHash!,
      koreaderVersion: att.koreaderVersion,
      pluginVersions: att.pluginVersions,
      remoteAddress: att.remoteAddress,
      connectedAt: new Date(att.connectedAt).toISOString(),
      lastMessageAt: new Date(this.lastSign(ws, att)).toISOString(),
    };
  }

  /** Latest of the last real message and the last auto-answered ping. */
  private lastSign(ws: WebSocket, att: Attachment): number {
    const pinged = this.ctx.getWebSocketAutoResponseTimestamp(ws)?.getTime() ?? 0;
    return Math.max(att.lastMessageAt, pinged);
  }

  /** Attachments are capped at 2,048 bytes; plugin versions are the first thing to drop. */
  private saveAttachment(ws: WebSocket, att: Attachment): void {
    try {
      ws.serializeAttachment(att);
    } catch {
      const { pluginVersions: _dropped, ...rest } = att;
      ws.serializeAttachment(rest);
    }
  }

  private closeSocket(ws: WebSocket, code: number, reason: string): void {
    this.dropSocket(ws, reason);
    try { ws.close(code, reason); } catch { /* already closed */ }
  }

  private dropSocket(ws: WebSocket, reason: string): void {
    const att = ws.deserializeAttachment() as Attachment | null;
    if (att?.name) console.log(`[hub] '${att.name}' offline: ${reason}`);
    for (const [id, p] of this.pending) {
      if (p.ws !== ws) continue;
      this.pending.delete(id);
      clearTimeout(p.timer);
      p.reject(new Error(`device disconnected (${reason})`));
    }
  }

  private async ensureSweep(): Promise<void> {
    if ((await this.ctx.storage.getAlarm()) === null) {
      await this.ctx.storage.setAlarm(Date.now() + SWEEP_INTERVAL_MS);
    }
  }
}
