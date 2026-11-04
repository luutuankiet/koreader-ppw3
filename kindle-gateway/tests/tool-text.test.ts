import {
  disconnectText,
  formatLogTail,
  formatPowerButton,
  formatWaitResult,
  isDisconnectError,
  uiActTimeoutMs,
  waitForTimeoutMs,
} from '../src/tool-text';

const snap = { snapshot: 4, window: 'ConfirmBox', total: 1, nodes: [{ ref: '4_1', kind: 'button', text: 'OK', state: '' }] };

describe('wait_for text', () => {
  test('matched, then the snapshot as the snapshot tool prints it', () => {
    expect(formatWaitResult({ matched: true, waited: 1.25, snapshot: snap }, false)).toBe(
      'matched after 1.3s\n\nsnapshot 4 · window ConfirmBox · 1 widgets\n[4_1] button "OK"');
  });
  test('timed out says why', () => {
    expect(formatWaitResult({ matched: false, waited: 10, snapshot: snap }, false).split('\n')[0]).toBe('timed out after 10s (not found)');
    expect(formatWaitResult({ matched: false, waited: 2, snapshot: snap }, true).split('\n')[0]).toBe('timed out after 2s (text still present)');
  });
  test('call timeout is the device timeout plus a margin, clamped like the device', () => {
    expect(waitForTimeoutMs()).toBe(20_000);
    expect(waitForTimeoutMs(3)).toBe(13_000);
    expect(waitForTimeoutMs(600)).toBe(70_000);
    expect(waitForTimeoutMs(0)).toBe(10_500);
  });
});

describe('ui_act wait', () => {
  test('keeps 20 s unless wait needs longer, capped like the device', () => {
    expect(uiActTimeoutMs()).toBe(20_000);
    expect(uiActTimeoutMs(5)).toBe(20_000);
    expect(uiActTimeoutMs(25)).toBe(35_000);
    expect(uiActTimeoutMs(300)).toBe(40_000);
  });
});

describe('power_button and read_log text', () => {
  test('power button actions', () => {
    expect(formatPowerButton({ action: 'suspend', screen_saver_mode: false })).toBe('power button: suspend (device was awake)');
    expect(formatPowerButton({ action: 'resume', screen_saver_mode: true })).toBe('power button: resume (device was asleep)');
    expect(formatPowerButton({ action: 'locked', screen_saver_mode: true })).toMatch(/^power button: locked.*try again in ~20 s$/);
  });
  test('log tail marker, truncation and an empty Lua table', () => {
    expect(formatLogTail({ marker: 120, lines: ['a', 'b'], truncated: true })).toBe('marker: 120 (older lines dropped)\na\nb');
    expect(formatLogTail({ marker: 7, lines: {} })).toBe('marker: 7');
  });
});

describe('disconnects', () => {
  test('recognises the disconnect rejection of either gateway', () => {
    expect(isDisconnectError(new Error('device disconnected (connection closed)'))).toBe(true);
    expect(isDisconnectError(new Error('device disconnected (connection closed (1006))'))).toBe(true);
    expect(isDisconnectError(new Error('Tool call to x timed out after 20s'))).toBe(false);
  });
  test('says whether the device came back', () => {
    expect(disconnectText(true)).toBe('device restarting or disconnected; device reconnected, take a new snapshot');
    expect(disconnectText(false)).toMatch(/^device restarting or disconnected; device has not reconnected yet/);
  });
});
