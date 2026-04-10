export interface DeviceInfo {
  name: string;
  ip: string;
  port: number;
  tools: string[];
  status: 'online' | 'offline';
  lastSeen: Date;
  registeredAt: Date;
}

export class DeviceRegistry {
  private devices: Map<string, DeviceInfo> = new Map();

  register(name: string, ip: string, port: number, tools: string[]): DeviceInfo {
    const existing = this.devices.get(name);
    const now = new Date();
    const device: DeviceInfo = {
      name,
      ip,
      port,
      tools,
      status: 'online',
      lastSeen: now,
      registeredAt: existing?.registeredAt ?? now,
    };
    this.devices.set(name, device);
    return device;
  }

  get(name: string): DeviceInfo | undefined {
    return this.devices.get(name);
  }

  list(): DeviceInfo[] {
    return Array.from(this.devices.values());
  }

  markOffline(name: string): void {
    const device = this.devices.get(name);
    if (device) {
      device.status = 'offline';
    }
  }

  markOnline(name: string): void {
    const device = this.devices.get(name);
    if (device) {
      device.status = 'online';
    }
  }

  updateLastSeen(name: string): void {
    const device = this.devices.get(name);
    if (device) {
      device.lastSeen = new Date();
      device.status = 'online';
    }
  }

  remove(name: string): boolean {
    return this.devices.delete(name);
  }
}
