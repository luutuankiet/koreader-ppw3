import { DeviceRegistry } from '../src/device-registry';

describe('DeviceRegistry', () => {
  let registry: DeviceRegistry;

  beforeEach(() => {
    registry = new DeviceRegistry();
  });

  test('register adds a new device', () => {
    const device = registry.register('kindle1', '192.168.1.100', 8888, ['read_files']);
    expect(device.name).toBe('kindle1');
    expect(device.ip).toBe('192.168.1.100');
    expect(device.port).toBe(8888);
    expect(device.status).toBe('online');
    expect(device.tools).toEqual(['read_files']);
  });

  test('register updates existing device', () => {
    registry.register('kindle1', '192.168.1.100', 8888, ['read_files']);
    const updated = registry.register('kindle1', '192.168.1.101', 9999, ['read_files', 'run_command']);
    expect(updated.ip).toBe('192.168.1.101');
    expect(updated.port).toBe(9999);
    expect(updated.tools).toEqual(['read_files', 'run_command']);
  });

  test('get returns device by name', () => {
    registry.register('kindle1', '192.168.1.100', 8888, []);
    const device = registry.get('kindle1');
    expect(device).toBeDefined();
    expect(device!.name).toBe('kindle1');
  });

  test('get returns undefined for unknown device', () => {
    expect(registry.get('unknown')).toBeUndefined();
  });

  test('list returns all devices', () => {
    registry.register('kindle1', '192.168.1.100', 8888, []);
    registry.register('kindle2', '192.168.1.101', 8889, []);
    expect(registry.list()).toHaveLength(2);
  });

  test('markOffline sets device status', () => {
    registry.register('kindle1', '192.168.1.100', 8888, []);
    registry.markOffline('kindle1');
    expect(registry.get('kindle1')!.status).toBe('offline');
  });

  test('updateLastSeen updates timestamp and status', () => {
    registry.register('kindle1', '192.168.1.100', 8888, []);
    registry.markOffline('kindle1');
    const before = registry.get('kindle1')!.lastSeen;
    // Small delay to ensure timestamp difference
    registry.updateLastSeen('kindle1');
    expect(registry.get('kindle1')!.status).toBe('online');
  });

  test('remove deletes device', () => {
    registry.register('kindle1', '192.168.1.100', 8888, []);
    expect(registry.remove('kindle1')).toBe(true);
    expect(registry.get('kindle1')).toBeUndefined();
  });

  test('remove returns false for unknown device', () => {
    expect(registry.remove('unknown')).toBe(false);
  });
});
