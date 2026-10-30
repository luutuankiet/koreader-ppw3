/**
 * Formatting and reference checks for the widget snapshot tools (snapshot, tap, hold,
 * tap_text, type, action). The device (koreader_mcp's ui_agent.lua) returns every
 * widget it found; this module turns that into the short text an agent reads.
 */

export interface UiNode {
  ref: string;
  kind: string;
  text: string;
  state: string;
}

/** What ui_snapshot returns, and what ui_act returns under `snapshot`. */
export interface UiSnapshot {
  snapshot: number;
  window: string;
  total: number;
  // An empty Lua table encodes as {}, not [].
  nodes: UiNode[] | Record<string, never>;
}

/** What ui_act returns. */
export interface UiActResult {
  result: string;
  snapshot?: UiSnapshot;
  snapshot_error?: string;
  logs?: string[] | Record<string, never>;
}

export const DEFAULT_MAX_LINES = 40;

function asArray<T>(v: T[] | Record<string, never> | undefined): T[] {
  return Array.isArray(v) ? v : [];
}

/** One line per widget: `[3_7] item "Synced reading list" (submenu)`. */
export function formatNode(n: UiNode): string {
  const text = n.text ? ` "${n.text}"` : '';
  const state = n.state ? ` (${n.state})` : '';
  return `[${n.ref}] ${n.kind}${text}${state}`;
}

/** Header plus at most `maxLines` widget lines, then `[+N more]` when cut. */
export function formatSnapshot(s: UiSnapshot, maxLines: number = DEFAULT_MAX_LINES): string[] {
  const nodes = asArray(s.nodes);
  const limit = Math.max(1, Math.floor(maxLines));
  const lines = [`snapshot ${s.snapshot} · window ${s.window} · ${nodes.length} widgets`];
  for (const n of nodes.slice(0, limit)) lines.push(formatNode(n));
  if (nodes.length > limit) lines.push(`[+${nodes.length - limit} more]`);
  return lines;
}

/** Result line, then the new snapshot, then the log lines the action caused. */
export function formatActResult(r: UiActResult, maxLines: number = DEFAULT_MAX_LINES): string {
  const out = [r.result];
  if (r.snapshot) out.push('', ...formatSnapshot(r.snapshot, maxLines));
  else if (r.snapshot_error) out.push('', `no snapshot: ${r.snapshot_error}`);
  const logs = asArray(r.logs);
  out.push('', logs.length ? `logs (${logs.length}):` : 'logs: none');
  for (const l of logs) out.push(`  ${l}`);
  return out.join('\n');
}

/**
 * Remembers the latest snapshot id seen per device, so a reference older than the last
 * two snapshots is refused without a device round-trip. The device stays authoritative:
 * anything this cannot judge is passed through. The id is overwritten, not maxed, so a
 * KOReader restart that resets the device counter is followed.
 */
export class SnapshotTracker {
  private latest = new Map<string, number>();

  see(device: string, snapshotId: number | undefined): void {
    if (typeof snapshotId === 'number' && Number.isFinite(snapshotId)) this.latest.set(device, snapshotId);
  }

  forget(device: string): void {
    this.latest.delete(device);
  }

  /** An error message for a reference the device would refuse anyway, else null. */
  checkRef(device: string, ref: string): string | null {
    const m = /^s?(\d+)_(\d+)$/.exec(ref.trim());
    if (!m) return `bad reference '${ref}', expected <snapshot>_<n> such as 3_7`;
    const latest = this.latest.get(device);
    const snap = parseInt(m[1], 10);
    if (latest !== undefined && snap < latest - 1) {
      return `stale reference ${ref}, take a new snapshot (latest is ${latest})`;
    }
    return null;
  }
}
