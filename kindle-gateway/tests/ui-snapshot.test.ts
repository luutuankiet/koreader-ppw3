import { SnapshotTracker, formatActResult, formatSnapshot, UiNode } from '../src/ui-snapshot';

const nodes = (n: number, snap = 1): UiNode[] =>
  Array.from({ length: n }, (_, i) => ({ ref: `${snap}_${i + 1}`, kind: 'row', text: `Book ${i + 1}`, state: '' }));

describe('formatSnapshot', () => {
  test('cuts at 40 widget lines by default and says how many were left out', () => {
    const lines = formatSnapshot({ snapshot: 1, window: 'Menu', total: 57, nodes: nodes(57) });
    expect(lines).toHaveLength(1 + 40 + 1);
    expect(lines[40]).toBe('[1_40] row "Book 40"');
    expect(lines[41]).toBe('[+17 more]');
  });

  test('exactly at the limit there is no cut line', () => {
    const lines = formatSnapshot({ snapshot: 1, window: 'Menu', total: 40, nodes: nodes(40) });
    expect(lines.join('\n')).not.toContain('more]');
  });

  test('max_lines overrides the limit', () => {
    const lines = formatSnapshot({ snapshot: 1, window: 'Menu', total: 5, nodes: nodes(5) }, 2);
    expect(lines.slice(-1)[0]).toBe('[+3 more]');
  });

  test('an empty Lua table arrives as {} and is not a crash', () => {
    const lines = formatSnapshot({ snapshot: 2, window: 'w', total: 0, nodes: {} });
    expect(lines).toEqual(['snapshot 2 · window w · 0 widgets']);
  });

  test('state is shown in brackets', () => {
    const lines = formatSnapshot({
      snapshot: 3, window: 'w', total: 1,
      nodes: [{ ref: '3_1', kind: 'check', text: 'Show all', state: 'checked disabled' }],
    });
    expect(lines[1]).toBe('[3_1] check "Show all" (checked disabled)');
  });
});

describe('formatActResult', () => {
  test('result line, then snapshot, then logs', () => {
    const text = formatActResult({
      result: 'tap at 10,10',
      snapshot: { snapshot: 4, window: 'w', total: 1, nodes: nodes(1, 4) },
      logs: ['DEBUG hello'],
    });
    expect(text.split('\n')).toEqual([
      'tap at 10,10', '', 'snapshot 4 · window w · 1 widgets', '[4_1] row "Book 1"', '', 'logs (1):', '  DEBUG hello',
    ]);
  });

  test('empty logs from Lua ({}) read as none', () => {
    expect(formatActResult({ result: 'ok', logs: {} })).toContain('logs: none');
  });
});

describe('SnapshotTracker', () => {
  test('the last two snapshots pass, older ones are stale', () => {
    const t = new SnapshotTracker();
    t.see('emu', 5);
    expect(t.checkRef('emu', '5_1')).toBeNull();
    expect(t.checkRef('emu', '4_1')).toBeNull();
    expect(t.checkRef('emu', '3_1')).toMatch(/^stale reference 3_1, take a new snapshot/);
  });

  test('an unknown device is left to the device to judge', () => {
    expect(new SnapshotTracker().checkRef('emu', '1_1')).toBeNull();
  });

  test('a KOReader restart that resets the counter is followed', () => {
    const t = new SnapshotTracker();
    t.see('emu', 50);
    t.see('emu', 1);
    expect(t.checkRef('emu', '1_1')).toBeNull();
  });

  test('devices do not share a counter', () => {
    const t = new SnapshotTracker();
    t.see('a', 9);
    expect(t.checkRef('b', '1_1')).toBeNull();
  });

  test('a malformed reference is refused', () => {
    expect(new SnapshotTracker().checkRef('emu', 'seven')).toMatch(/^bad reference/);
  });
});
