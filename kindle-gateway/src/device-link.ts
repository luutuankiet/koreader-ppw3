import * as net from 'net';
import type { DeviceRegistry } from './device-registry';
import { isRpcResponse, validateHello, type Hello, type RpcResponse } from './device-protocol';

export { validateHello, type Hello, type RpcResponse };

/**
 * Live-mode device connections. A device dials the gateway on DEVICE_PORT and keeps one
 * TCP connection open; the gateway never calls a device. Messages are one JSON object per
 * line, both ways; their shapes are listed in device-protocol.ts.
 *
 * A device is online exactly while its connection is open. Any message counts as a sign of
 * life; after `silenceMs` without one the gateway closes the connection.
 */

export interface LinkOptions {
  /** Close a connection that sent nothing for this long. Spec: 150 s. */
  silenceMs: number;
  /** Close a connection that has not sent a valid hello within this long. */
  helloTimeoutMs: number;
  /** Largest accepted line; a screenshot reply is a few hundred KB of base64. */
  maxLineBytes: number;
}

export const DEFAULT_LINK_OPTIONS: LinkOptions = {
  silenceMs: 150_000,
  helloTimeoutMs: 10_000,
  maxLineBytes: 32 * 1024 * 1024,
};

/** One open device connection. Owns reply routing for the calls sent down it. */
export class DeviceLink {
  readonly remoteAddress: string;
  lastMessageAt = new Date();
  /** Set once the hello is accepted; before that the hello timeout applies. */
  helloDone = false;
  private buffer = '';
  private nextId = 0;
  private pending = new Map<number, { resolve: (r: RpcResponse) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }>();
  private silenceTimer?: NodeJS.Timeout;
  private closed = false;
  private closeHandlers: Array<(reason: string) => void> = [];

  constructor(private socket: net.Socket, private opts: LinkOptions, private onMessage: (msg: Record<string, unknown>) => void) {
    this.remoteAddress = socket.remoteAddress ?? 'unknown';
    socket.setEncoding('utf8');
    socket.setNoDelay(true);
    socket.on('data', (chunk: string) => this.onData(chunk));
    socket.on('close', () => this.shutdown('connection closed'));
    socket.on('error', (err) => this.shutdown(`socket error: ${err.message}`));
    this.armSilenceTimer(opts.helloTimeoutMs);
  }

  get isOpen(): boolean { return !this.closed; }

  onClose(handler: (reason: string) => void): void {
    if (this.closed) handler('already closed');
    else this.closeHandlers.push(handler);
  }

  send(msg: object): void {
    if (!this.closed) this.socket.write(JSON.stringify(msg) + '\n');
  }

  /** Send a tool call and wait for the reply with the same id. */
  call(method: string, params: Record<string, unknown> | undefined, timeoutMs: number): Promise<RpcResponse> {
    if (this.closed) return Promise.reject(new Error('device connection is closed'));
    const id = ++this.nextId;
    return new Promise<RpcResponse>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`no reply to ${method} within ${timeoutMs / 1000}s`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.send({ id, method, params: params ?? {} });
    });
  }

  close(reason: string): void {
    this.socket.destroy();
    this.shutdown(reason);
  }

  /** Called once the hello is accepted: from now on silence means the device is gone. */
  startLiveness(): void {
    this.armSilenceTimer(this.opts.silenceMs);
  }

  private armSilenceTimer(ms: number): void {
    if (this.silenceTimer) clearTimeout(this.silenceTimer);
    this.silenceTimer = setTimeout(() => this.close(`silent for ${ms / 1000}s`), ms);
  }

  private onData(chunk: string): void {
    this.buffer += chunk;
    if (this.buffer.length > this.opts.maxLineBytes) {
      this.close('line too long');
      return;
    }
    let nl: number;
    while ((nl = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, nl).trim();
      this.buffer = this.buffer.slice(nl + 1);
      if (line === '') continue;
      let msg: Record<string, unknown>;
      try {
        msg = JSON.parse(line);
      } catch {
        console.warn(`[link] ${this.remoteAddress}: dropping a line that is not JSON`);
        continue;
      }
      this.lastMessageAt = new Date();
      if (this.helloDone) this.armSilenceTimer(this.opts.silenceMs);
      if (isRpcResponse(msg)) {
        const p = this.pending.get(msg.id);
        if (p) {
          this.pending.delete(msg.id);
          clearTimeout(p.timer);
          p.resolve(msg as unknown as RpcResponse);
        }
        continue;
      }
      if (msg.type === 'ping') {
        this.send({ type: 'pong' });
        continue;
      }
      this.onMessage(msg);
      if (this.closed) return;
    }
  }

  private shutdown(reason: string): void {
    if (this.closed) return;
    this.closed = true;
    if (this.silenceTimer) clearTimeout(this.silenceTimer);
    for (const [, p] of this.pending) {
      clearTimeout(p.timer);
      p.reject(new Error(`device disconnected (${reason})`));
    }
    this.pending.clear();
    for (const h of this.closeHandlers) h(reason);
    this.closeHandlers = [];
  }
}

/** Accept device connections on `port` and attach each one to the registry after its hello. */
export function startDeviceListener(
  registry: DeviceRegistry,
  port: number,
  host = '0.0.0.0',
  options: Partial<LinkOptions> = {},
): net.Server {
  const opts = { ...DEFAULT_LINK_OPTIONS, ...options };
  const server = net.createServer((socket) => {
    const link: DeviceLink = new DeviceLink(socket, opts, (msg) => {
      if (link.helloDone) return; // nothing else is expected from a device yet
      const hello = validateHello(msg);
      if (typeof hello === 'string') {
        link.send({ type: 'refused', reason: hello });
        link.close(`bad hello: ${hello}`);
        return;
      }
      const attached = registry.attach(hello, link);
      if (!attached.ok) {
        console.warn(`[link] refused '${hello.name}' from ${link.remoteAddress}: ${attached.reason}`);
        link.send({ type: 'refused', reason: attached.reason });
        link.close(attached.reason);
        return;
      }
      link.helloDone = true;
      link.startLiveness();
      link.send({ type: 'welcome', name: hello.name });
      console.log(`[link] '${hello.name}' online from ${link.remoteAddress} (KOReader ${hello.koreader_version ?? '?'})`);
      link.onClose((reason) => console.log(`[link] '${hello.name}' offline: ${reason}`));
    });
  });
  server.listen(port, host);
  return server;
}
