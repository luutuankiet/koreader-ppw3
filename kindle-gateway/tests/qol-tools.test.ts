import * as net from 'net';
import { startDeviceListener } from '../src/device-link';
import { DeviceRegistry } from '../src/device-registry';
import { afterDisconnect, powerButton, readLog, uiCall } from '../src/gateway-server';
import { SnapshotTracker } from '../src/ui-snapshot';
import { closeServer, FakeDevice, listening } from './helpers/fake-device';

// wait_for, the wait option of the tap tools, power_button, read_log, and the report when a
// device drops mid-call, against a fake device answering the device-side contract.

const snap = (id: number) => ({ snapshot: id, window: 'ConfirmBox', total: 1, nodes: [{ ref: `${id}_1`, kind: 'button', text: 'Restart', state: '' }] });

describe('gateway quality-of-life tools', () => {
  let registry: DeviceRegistry;
  let listener: net.Server;
  let port: number;
  let tracker: SnapshotTracker;
  const devices: FakeDevice[] = [];
  let snapshotId = 0;
  const calls: Array<{ method: string; params: any }> = [];

  /** A fake device; tapping "Restart" drops it and a fresh one with the same name connects. */
  async function device(name: string, reconnect = true): Promise<FakeDevice> {
    const d: FakeDevice = new FakeDevice(port, (method, params) => {
      calls.push({ method, params });
      switch (method) {
        case 'ui_wait':
          snapshotId += 1;
          return { matched: params.text === 'Restart', waited: params.text === 'Restart' ? 0.4 : params.timeout ?? 10, snapshot: snap(snapshotId) };
        case 'ui_act':
          if (params.text === 'Restart') {
            d.destroy();
            if (reconnect) setTimeout(() => { void device(name); }, 50);
            return undefined;
          }
          snapshotId += 1;
          return { result: `${params.what} done`, snapshot: snap(snapshotId), logs: [] };
        case 'power_button': return { action: 'suspend', screen_saver_mode: false };
        case 'read_log': return { marker: 42, lines: ['line a', 'line b'], truncated: params.since === undefined };
        default: return { unexpected: method };
      }
    });
    devices.push(d);
    await d.hello(name);
    return d;
  }

  beforeEach(async () => {
    registry = new DeviceRegistry();
    listener = startDeviceListener(registry, 0, '127.0.0.1');
    port = await listening(listener);
    tracker = new SnapshotTracker();
    calls.length = 0;
  });

  afterEach(async () => {
    for (const d of devices.splice(0)) d.destroy();
    await new Promise((r) => setTimeout(r, 20)); // let the gateway log the closes
    await closeServer(listener);
  });

  test('wait_for sends ui_wait and prints the match line and the snapshot', async () => {
    await device('emu');
    snapshotId = 10;
    const r = await uiCall(registry, tracker, { device: 'emu', text: 'Restart', timeout: 3 }, 'ui_wait', { text: 'Restart', timeout: 3 });
    expect(r.isError).toBeFalsy();
    const text = (r.content[0] as { text: string }).text;
    expect(text.split('\n')[0]).toBe('matched after 0.4s');
    expect(text).toContain(`[${snapshotId}_1] button "Restart"`);
    expect(calls[0]).toEqual({ method: 'ui_wait', params: { text: 'Restart', timeout: 3 } });
    // refs from wait_for are tracked like a snapshot's
    expect(tracker.checkRef('emu', `${snapshotId - 2}_1`)).toMatch(/stale reference/);
  });

  test('wait_for says when it timed out waiting for text to go', async () => {
    await device('emu');
    const r = await uiCall(registry, tracker, { device: 'emu', text: 'Busy', gone: true, timeout: 2 }, 'ui_wait', { text: 'Busy', gone: true, timeout: 2 });
    expect((r.content[0] as { text: string }).text.split('\n')[0]).toBe('timed out after 2s (text still present)');
  });

  test('tap passes wait to the device as wait_cap', async () => {
    await device('emu');
    await uiCall(registry, tracker, { device: 'emu', wait: 15 }, 'ui_act', { what: 'tap_text', text: 'OK', wait_cap: 15 });
    expect(calls[0].params.wait_cap).toBe(15);
  });

  test('a tap that restarts KOReader reports the restart and the reconnect', async () => {
    await device('emu');
    tracker.see('emu', 50);
    const r = await uiCall(registry, tracker, { device: 'emu', text: 'Restart' }, 'ui_act', { what: 'tap_text', text: 'Restart' });
    expect(r.isError).toBeFalsy();
    expect((r.content[0] as { text: string }).text).toBe('device restarting or disconnected; device reconnected, take a new snapshot');
    expect(tracker.checkRef('emu', '1_1')).toBeNull(); // forgotten: the restarted device counts from 1 again
    expect(registry.get('emu')).toBeDefined();
  });

  test('a device that does not come back is reported as such', async () => {
    await device('emu', false);
    const r = await afterDisconnect(registry, 'emu', tracker, 50);
    expect(r.isError).toBe(true);
    expect((r.content[0] as { text: string }).text).toMatch(/has not reconnected yet/);
  });

  test('power_button prints what the device did', async () => {
    await device('emu');
    const r = await powerButton(registry, tracker, 'emu');
    expect((r.content[0] as { text: string }).text).toBe('power button: suspend (device was awake)');
  });

  test('read_log forwards only the given arguments and prints the marker first', async () => {
    await device('emu');
    const r = await readLog(registry, tracker, { device: 'emu', max_lines: 50, grep: 'sync' });
    expect(calls[0]).toEqual({ method: 'read_log', params: { max_lines: 50, grep: 'sync' } });
    expect((r.content[0] as { text: string }).text).toBe('marker: 42 (older lines dropped)\nline a\nline b');
    const again = await readLog(registry, tracker, { device: 'emu', since: 42 });
    expect((again.content[0] as { text: string }).text.split('\n')[0]).toBe('marker: 42');
  });
});
