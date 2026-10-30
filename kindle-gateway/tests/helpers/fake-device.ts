import * as net from 'net';

export type Handler = (method: string, params: any, id: number) => unknown;

/** Speaks the live-mode protocol as a device would, over a real TCP connection. */
export class FakeDevice {
  socket!: net.Socket;
  received: any[] = [];
  closed = false;
  private buffer = '';
  private waiters: Array<{ match: (m: any) => boolean; resolve: (m: any) => void }> = [];

  constructor(private port: number, public handler?: Handler) {}

  async connect(): Promise<this> {
    this.socket = net.connect(this.port, '127.0.0.1');
    this.socket.setEncoding('utf8');
    this.socket.on('data', (c: string) => this.onData(c));
    this.socket.on('close', () => { this.closed = true; });
    this.socket.on('error', () => { this.closed = true; });
    await new Promise<void>((resolve) => this.socket.once('connect', () => resolve()));
    return this;
  }

  /** Connect and say hello; resolves with the welcome or refused reply. */
  async hello(name: string, idHash = 'aaaaaaaaaaaa'): Promise<any> {
    if (!this.socket) await this.connect();
    this.sendJson({ type: 'hello', name, id_hash: idHash, koreader_version: 'v-test', plugin_versions: { koreader_mcp: '1' } });
    return this.waitFor((m) => m.type === 'welcome' || m.type === 'refused');
  }

  sendJson(msg: object): void { this.socket.write(JSON.stringify(msg) + '\n'); }
  sendRaw(text: string): void { this.socket.write(text); }

  waitFor(match: (m: any) => boolean): Promise<any> {
    const seen = this.received.find(match);
    if (seen) return Promise.resolve(seen);
    return new Promise((resolve) => this.waiters.push({ match, resolve }));
  }

  waitClosed(): Promise<void> {
    if (this.closed) return Promise.resolve();
    return new Promise((resolve) => this.socket.once('close', () => resolve()));
  }

  destroy(): void { this.socket?.destroy(); }

  private onData(chunk: string): void {
    this.buffer += chunk;
    let nl: number;
    while ((nl = this.buffer.indexOf('\n')) >= 0) {
      const msg = JSON.parse(this.buffer.slice(0, nl));
      this.buffer = this.buffer.slice(nl + 1);
      this.received.push(msg);
      if (typeof msg.id === 'number' && msg.method && this.handler) {
        const result = this.handler(msg.method, msg.params, msg.id);
        if (result !== undefined) this.sendJson({ id: msg.id, result });
      }
      for (const w of this.waiters.filter((x) => x.match(msg))) {
        this.waiters.splice(this.waiters.indexOf(w), 1);
        w.resolve(msg);
      }
    }
  }
}

export function listening(server: net.Server): Promise<number> {
  return new Promise((resolve) => {
    const done = () => resolve((server.address() as net.AddressInfo).port);
    if (server.listening) done(); else server.once('listening', done);
  });
}

export function closeServer(server: net.Server): Promise<void> {
  return new Promise((resolve) => server.close(() => resolve()));
}
