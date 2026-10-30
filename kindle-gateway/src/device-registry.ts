import type { DeviceLink, Hello } from './device-link';

/**
 * Devices that hold an open live-mode connection right now. There is no registration, no
 * address list and no offline flag: an entry exists exactly while its connection is open,
 * and disappears the moment the connection closes.
 */
export interface DeviceInfo {
  name: string;
  /** Short hash of the device serial (or of its configured name); never the serial itself. */
  idHash: string;
  koreaderVersion?: string;
  pluginVersions?: Record<string, string>;
  remoteAddress: string;
  connectedAt: Date;
  link: DeviceLink;
}

/** What list_devices shows: everything but the live connection object. */
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

export type AttachResult = { ok: true; device: DeviceInfo } | { ok: false; reason: string };

export class DeviceRegistry {
  private devices = new Map<string, DeviceInfo>();
  private waiters: Array<{ name: string; after: number; resolve: (d: DeviceInfo) => void }> = [];

  /**
   * Accept a device after its hello. A name held by a connected device with a different
   * hash is refused; the same hash replaces the old connection (the device reconnected
   * before the gateway noticed the old one died).
   */
  attach(hello: Hello, link: DeviceLink): AttachResult {
    const existing = this.devices.get(hello.name);
    if (existing && existing.link.isOpen) {
      if (existing.idHash !== hello.id_hash) {
        return { ok: false, reason: `name '${hello.name}' is held by another device` };
      }
      existing.link.close('replaced by a new connection from the same device');
    }
    const device: DeviceInfo = {
      name: hello.name,
      idHash: hello.id_hash,
      koreaderVersion: hello.koreader_version,
      pluginVersions: hello.plugin_versions,
      remoteAddress: link.remoteAddress,
      connectedAt: new Date(),
      link,
    };
    this.devices.set(hello.name, device);
    link.onClose(() => {
      if (this.devices.get(hello.name) === device) this.devices.delete(hello.name);
    });
    const ready = this.waiters.filter((w) => w.name === hello.name && device.connectedAt.getTime() >= w.after);
    this.waiters = this.waiters.filter((w) => !ready.includes(w));
    for (const w of ready) w.resolve(device);
    return { ok: true, device };
  }

  get(name: string): DeviceInfo | undefined {
    const d = this.devices.get(name);
    return d && d.link.isOpen ? d : undefined;
  }

  list(): DeviceSummary[] {
    return Array.from(this.devices.values())
      .filter((d) => d.link.isOpen)
      .map((d) => ({
        name: d.name,
        status: 'online' as const,
        idHash: d.idHash,
        koreaderVersion: d.koreaderVersion,
        pluginVersions: d.pluginVersions,
        remoteAddress: d.remoteAddress,
        connectedAt: d.connectedAt.toISOString(),
        lastMessageAt: d.link.lastMessageAt.toISOString(),
      }));
  }

  /** Resolve with the first connection for `name` made at or after `after`, or undefined on timeout. */
  waitForConnection(name: string, after: Date, timeoutMs: number): Promise<DeviceInfo | undefined> {
    const current = this.get(name);
    if (current && current.connectedAt.getTime() >= after.getTime()) return Promise.resolve(current);
    return new Promise((resolve) => {
      const waiter = {
        name,
        after: after.getTime(),
        resolve: (d: DeviceInfo) => { clearTimeout(timer); resolve(d); },
      };
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== waiter);
        resolve(undefined);
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }
}
