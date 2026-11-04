/**
 * Text shared by the Node gateway (gateway-server.ts) and the Worker (kindle-gateway-worker
 * tools/device-tools.ts) for wait_for, power_button, read_log, the `wait` option of the tap
 * tools, and the report after a device drops mid-call. Both gateways import this file, so the
 * descriptions and the output an agent reads stay identical. Pure functions only: the Worker
 * runs them on 10 ms of CPU per request, and all waiting happens on the device.
 */
import { DEFAULT_MAX_LINES, UiSnapshot, formatSnapshot } from './ui-snapshot';

/** Call timeout for snapshot and ui_act without `wait`. */
export const UI_CALL_TIMEOUT_MS = 20_000;
/** How long a tool waits for a device that dropped mid-call (a restart, usually) to come back. */
export const DISCONNECT_RECONNECT_WAIT_MS = 30_000;
/** Margin on top of the device-side wait before the gateway gives up on a reply. */
const REPLY_MARGIN_S = 10;

export const DESCRIPTIONS = {
  wait_for:
    'Wait on the device until a widget whose text matches appears (or, with gone, disappears), then return one line, "matched after Xs" or "timed out after Xs", and the snapshot as the snapshot tool prints it (its refs work with tap). Use instead of sleeping between steps.',
  power_button:
    'Press the power button. On a real Kindle pressing it while awake suspends the device and the live session drops, so it reliably wakes only the emulator. Says what it did: suspend, resume, or locked (the sleep screen still ignores input for a while).',
  read_log:
    'Read the KOReader log (crash.log) on the device. The first line is "marker: N"; pass the marker back as since to get only lines newer than that read.',
  wait:
    'Seconds to wait for the UI to settle (default 5, the device caps it at 30). The snapshot is returned once the UI settles or wait passes.',
} as const;

/** Appended to the descriptions of tap, hold, tap_text and action. */
export const ACT_WAIT_NOTE = ' With wait, the snapshot is returned once the UI settles or wait seconds pass.';

export interface UiWaitResult {
  matched: boolean;
  waited: number;
  snapshot?: UiSnapshot;
}

export interface PowerButtonResult {
  action: 'suspend' | 'resume' | 'locked' | string;
  screen_saver_mode?: boolean;
}

export interface LogTail {
  marker: number;
  // An empty Lua table encodes as {}, not [].
  lines: string[] | Record<string, never>;
  truncated?: boolean;
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, v));
}

/** ui_wait call timeout: the device-side timeout (default 10 s, clamped 0.5..60) plus margin. */
export function waitForTimeoutMs(timeout?: number): number {
  const t = typeof timeout === 'number' && Number.isFinite(timeout) ? clamp(timeout, 0.5, 60) : 10;
  return Math.ceil((t + REPLY_MARGIN_S) * 1000);
}

/** ui_act call timeout: the usual 20 s, or longer when `wait` (device caps at 30 s) needs it. */
export function uiActTimeoutMs(wait?: number): number {
  if (typeof wait !== 'number' || !Number.isFinite(wait)) return UI_CALL_TIMEOUT_MS;
  return Math.max(UI_CALL_TIMEOUT_MS, Math.ceil((clamp(wait, 0, 30) + REPLY_MARGIN_S) * 1000));
}

/** 1.25 -> "1.3s", 2 -> "2s". */
export function seconds(n: number): string {
  return `${Number((Number.isFinite(n) ? n : 0).toFixed(1))}s`;
}

/** First line says whether the wait matched, then the snapshot as the snapshot tool prints it. */
export function formatWaitResult(r: UiWaitResult, gone: boolean, maxLines: number = DEFAULT_MAX_LINES): string {
  const head = r.matched
    ? `matched after ${seconds(r.waited)}`
    : `timed out after ${seconds(r.waited)} (${gone ? 'text still present' : 'not found'})`;
  const out = [head];
  if (r.snapshot) out.push('', ...formatSnapshot(r.snapshot, maxLines));
  return out.join('\n');
}

export function formatPowerButton(r: PowerButtonResult): string {
  switch (r.action) {
    case 'suspend': return 'power button: suspend (device was awake)';
    case 'resume': return 'power button: resume (device was asleep)';
    case 'locked': return 'power button: locked, the sleep screen still ignores input, try again in ~20 s';
    default: return `power button: ${String(r.action)}`;
  }
}

export function formatLogTail(r: LogTail): string {
  const lines = Array.isArray(r.lines) ? r.lines : [];
  return [`marker: ${r.marker}${r.truncated ? ' (older lines dropped)' : ''}`, ...lines].join('\n');
}

/** The rejection both gateways raise when a device's connection closes with a call pending. */
export function isDisconnectError(err: unknown): boolean {
  return err instanceof Error && err.message.startsWith('device disconnected');
}

/** What a tool reports after its device dropped mid-call and the gateway waited for it. */
export function disconnectText(reconnected: boolean): string {
  return reconnected
    ? 'device restarting or disconnected; device reconnected, take a new snapshot'
    : `device restarting or disconnected; device has not reconnected yet (waited ${DISCONNECT_RECONNECT_WAIT_MS / 1000}s)`;
}
