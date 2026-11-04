import type { McpServer } from '@modelcontextprotocol/server';
import { z } from 'zod';
import { buildRestartCommand } from '../../../kindle-gateway/src/restart-command';
import {
  DEFAULT_MAX_LINES,
  UiActResult,
  UiSnapshot,
  formatActResult,
  formatSnapshot,
} from '../../../kindle-gateway/src/ui-snapshot';
import {
  ACT_WAIT_NOTE, DESCRIPTIONS, DISCONNECT_RECONNECT_WAIT_MS, LogTail, PowerButtonResult, UiWaitResult,
  disconnectText, formatLogTail, formatPowerButton, formatWaitResult, isDisconnectError, uiActTimeoutMs, waitForTimeoutMs,
} from '../../../kindle-gateway/src/tool-text';
import type { ToolContext } from '../mcp';

/**
 * The device tools, ported from kindle-gateway/src/gateway-server.ts with the same names,
 * descriptions, argument schemas and timeouts. deploy_plugin is not here (devices install
 * plugins from the registry); the diagnostics tools live in their own group.
 */

type ContentBlock = { type: 'text'; text: string } | { type: 'image'; data: string; mimeType: string };
export type ToolResult = { content: ContentBlock[]; isError?: boolean };
type UiArgs = {
  device: string; ref?: string; text?: string; name?: string; value?: string; clear?: boolean; screenshot?: boolean; max_lines?: number;
  wait?: number; gone?: boolean; timeout?: number; exact?: boolean;
};

/** Timeouts, as on the Node gateway. */
export const TIMEOUTS = {
  default: 10_000,
  menuTool: 15_000,
  ui: 20_000,
  screenshot: 30_000,
  restartStep: 5_000,
} as const;

export function registerDeviceTools(server: McpServer, ctx: ToolContext): void {
  const tool = <S extends z.ZodRawShape>(
    name: string,
    description: string,
    shape: S,
    handler: (args: z.infer<z.ZodObject<S>>) => Promise<ToolResult>,
  ) => {
    server.registerTool(name, { description, inputSchema: z.object(shape) }, async (args: z.infer<z.ZodObject<S>>) => handler(args));
  };
  const device = z.string().describe('Device name');

  tool('list_devices',
    'List the devices connected right now. A device is listed exactly while its live-mode connection is open.', {},
    async () => ({ content: [{ type: 'text', text: JSON.stringify(await ctx.listDevices(), null, 2) }] }));

  tool('read_files', 'Read files from a registered Kindle device',
    { device, params: z.string().describe('JSON params to forward') },
    async (a) => forward(ctx, a.device, 'read_files', parseParams(a.params)));

  tool('run_command', 'Run a command on a registered Kindle device',
    { device, params: z.string().describe('JSON params to forward') },
    async (a) => forward(ctx, a.device, 'run_command', parseParams(a.params)));

  tool('device_status', 'Get status from a registered Kindle device',
    { device, params: z.string().optional().describe('Optional JSON params') },
    async (a) => forward(ctx, a.device, 'device_status', parseParams(a.params)));

  // Menu tools: the call, then a screenshot once the e-ink has refreshed.
  tool('get_current_view',
    'Get the current KOReader widget stack. Returns widget info + screenshot of current screen.',
    { device },
    async (a) => forwardWithScreenshot(ctx, a.device, 'get_current_view', {}));

  tool('get_menu_items',
    'List items in the currently visible KOReader menu. Returns items + screenshot.',
    { device, params: z.string().optional().describe('Optional JSON: {"max_items": 50}') },
    async (a) => forwardWithScreenshot(ctx, a.device, 'get_menu_items', parseParams(a.params)));

  tool('select_menu_item',
    'Select a KOReader menu item by text or index. Returns result + screenshot of resulting UI.',
    { device, params: z.string().describe('JSON: {"text": "FreshRSS"} or {"index": 3}') },
    async (a) => forwardWithScreenshot(ctx, a.device, 'select_menu_item', parseParams(a.params)));

  tool('go_back', 'Navigate back in KOReader menu stack. Returns result + screenshot.',
    { device },
    async (a) => forwardWithScreenshot(ctx, a.device, 'go_back', {}));

  tool('close_top_widget', 'Close/dismiss the topmost KOReader widget. Returns result + screenshot.',
    { device },
    async (a) => forwardWithScreenshot(ctx, a.device, 'close_top_widget', {}));

  tool('send_event',
    'Trigger a KOReader internal event (e.g. ShowMenu, ShowReaderMenu, Close). Returns result + screenshot. Use instead of touch simulation.',
    { device, params: z.string().describe('JSON: {"event": "ShowMenu", "args": {}}') },
    async (a) => forwardWithScreenshot(ctx, a.device, 'send_event', parseParams(a.params)));

  // Widget snapshot and actions: each action waits on the device until KOReader is idle, then
  // returns one result line, the new snapshot and the log lines it caused.
  const uiCommon = {
    device,
    screenshot: z.boolean().optional().describe('Also return a screenshot (default false)'),
    max_lines: z.number().int().positive().optional().describe(`Snapshot lines before the [+N more] cut (default ${DEFAULT_MAX_LINES})`),
  };
  const ref = z.string().describe('Widget ref from the last 2 snapshots, e.g. "3_7"');
  const wait = z.number().positive().optional().describe(DESCRIPTIONS.wait);

  tool('snapshot',
    'List the widgets of the top KOReader window, one line each: [ref] kind "text" (state). Refs look like 3_7 and stay valid for the last 2 snapshots. Kinds: item (main menu row), row (list row), check, button, icon, input, tap, text.',
    uiCommon,
    async (a) => uiCall(ctx, a, 'ui_snapshot', {}));

  tool('tap',
    'Tap a widget by its snapshot ref (a gesture at the centre of the widget, no touch injection). Waits for KOReader to settle, returns the result, a new snapshot and the logs it caused.' + ACT_WAIT_NOTE,
    { ...uiCommon, wait, ref },
    async (a) => uiCall(ctx, a, 'ui_act', { what: 'tap', ref: a.ref, wait_cap: a.wait }));

  tool('hold',
    'Long-press a widget by its snapshot ref. Waits for KOReader to settle, returns the result, a new snapshot and the logs it caused.' + ACT_WAIT_NOTE,
    { ...uiCommon, wait, ref },
    async (a) => uiCall(ctx, a, 'ui_act', { what: 'hold', ref: a.ref, wait_cap: a.wait }));

  tool('tap_text',
    'Tap the first visible widget whose text matches (exact, case-insensitive; else the first that contains it). Needs no snapshot first.' + ACT_WAIT_NOTE,
    { ...uiCommon, wait, text: z.string().describe('Visible text, e.g. "Synced reading list"') },
    async (a) => uiCall(ctx, a, 'ui_act', { what: 'tap_text', text: a.text, wait_cap: a.wait }));

  tool('type', 'Type text into the focused input field of the top window (or its only input).',
    { ...uiCommon, text: z.string().describe('Text to type'), clear: z.boolean().optional().describe('Clear the field first') },
    async (a) => uiCall(ctx, a, 'ui_act', { what: 'type', text: a.text, clear: a.clear === true }));

  tool('action',
    'Run a KOReader Dispatcher action by name, e.g. "show_menu" (main menu), "home", "toggle_wifi". Optional value for actions that take one.' + ACT_WAIT_NOTE,
    { ...uiCommon, wait, name: z.string().describe('Dispatcher action name'), value: z.string().optional().describe('Optional value; numbers and true/false are converted') },
    async (a) => uiCall(ctx, a, 'ui_act', { what: 'action', name: a.name, value: parseActionValue(a.value), wait_cap: a.wait }));

  tool('wait_for', DESCRIPTIONS.wait_for,
    {
      ...uiCommon,
      text: z.string().describe('Text to wait for (case-insensitive; contained unless exact)'),
      gone: z.boolean().optional().describe('Wait for the text to disappear instead'),
      timeout: z.number().positive().optional().describe('Seconds to wait (default 10, the device clamps it to 0.5..60)'),
      exact: z.boolean().optional().describe('Match the whole text only'),
    },
    async (a) => uiCall(ctx, a, 'ui_wait', { text: a.text, gone: a.gone, timeout: a.timeout, exact: a.exact }));

  tool('power_button', DESCRIPTIONS.power_button,
    { device },
    async (a) => textCall(ctx, a.device, 'power_button', {}, (r) => formatPowerButton(r as PowerButtonResult)));

  tool('read_log', DESCRIPTIONS.read_log,
    {
      device,
      since: z.number().int().nonnegative().optional().describe('Marker from an earlier read_log; only newer lines are returned'),
      max_lines: z.number().int().positive().optional().describe('Most lines to return (newest kept)'),
      grep: z.string().optional().describe('Only lines containing this text'),
    },
    async (a) => {
      const params: Record<string, unknown> = {};
      if (a.since !== undefined) params.since = a.since;
      if (a.max_lines !== undefined) params.max_lines = a.max_lines;
      if (a.grep !== undefined) params.grep = a.grep;
      return textCall(ctx, a.device, 'read_log', params, (r) => formatLogTail(r as LogTail));
    });

  tool('screenshot',
    'Take a screenshot of the Kindle e-ink display. Returns the image directly as an MCP image content block.',
    { device },
    async (a) => screenshotTool(ctx, a.device));

  tool('restart_koreader',
    'Restart KOReader on a Kindle device. Kills luajit, restarts koreader.sh, waits for the device to reconnect.',
    { device },
    async (a) => restartKoreader(ctx, a.device));
}

// ---- implementations ---------------------------------------------------------------------

export function errResult(msg: string): ToolResult {
  return { content: [{ type: 'text', text: `Error: ${msg}` }], isError: true };
}

function parseParams(json: string | undefined): Record<string, unknown> {
  return json ? JSON.parse(json) : {};
}

/** Dispatcher values arrive as strings over MCP; numbers and booleans are converted. */
export function parseActionValue(v: string | undefined): unknown {
  if (v === undefined || v === '') return undefined;
  if (v === 'true') return true;
  if (v === 'false') return false;
  if (/^-?\d+(\.\d+)?$/.test(v)) return Number(v);
  return v;
}

function resultText(result: unknown): string {
  return typeof result === 'string' ? result : JSON.stringify(result, null, 2);
}

async function isConnected(ctx: ToolContext, name: string): Promise<boolean> {
  return (await ctx.listDevices()).some((d) => d.name === name);
}

/** A device call whose timeout reads as on the Node gateway's KindleClient. */
async function callDevice(ctx: ToolContext, name: string, method: string, params: Record<string, unknown>, timeoutMs: number) {
  try {
    return await ctx.call(name, method, params, timeoutMs);
  } catch (err) {
    const msg = (err as Error).message;
    if (msg.startsWith('no reply')) throw new Error(`Tool call to ${name} timed out after ${timeoutMs / 1000}s`);
    throw err;
  }
}

const reachErr = (name: string, err: unknown) =>
  errResult(`Failed to reach '${name}': ${err instanceof Error ? err.message : String(err)}`);

/**
 * A failed device call. When the connection closed under it (a restart, usually), wait for the
 * device to reconnect, forget its snapshot refs (a restart resets the device's counter), and
 * say which; the wait is wall time in the hub, not CPU.
 */
async function callFailed(ctx: ToolContext, name: string, err: unknown): Promise<ToolResult> {
  if (!isDisconnectError(err)) return reachErr(name, err);
  const back = await ctx.waitForReconnect(name, DISCONNECT_RECONNECT_WAIT_MS, Date.now());
  ctx.tracker.forget(name);
  const text = disconnectText(!!back);
  return back ? { content: [{ type: 'text', text }] } : errResult(text);
}

/** A text-only device call for power_button and read_log. */
async function textCall(
  ctx: ToolContext, name: string, method: string, params: Record<string, unknown>, format: (result: unknown) => string,
): Promise<ToolResult> {
  if (!(await isConnected(ctx, name))) return errResult(`Device '${name}' is not connected`);
  try {
    const reply = await callDevice(ctx, name, method, params, TIMEOUTS.default);
    if (reply.error) return errResult(`Device error: ${reply.error.message}`);
    return { content: [{ type: 'text', text: format(reply.result) }] };
  } catch (err) {
    return callFailed(ctx, name, err);
  }
}

/** The screenshot as an image block, or nothing (a failed screenshot is never fatal here). */
async function screenshotBlock(ctx: ToolContext, name: string): Promise<ContentBlock | null> {
  try {
    const ss = await callDevice(ctx, name, 'capture_screenshot', {}, TIMEOUTS.screenshot);
    const img = (ss.result ?? {}) as { image_base64?: string };
    if (ss.error || !img.image_base64) return null;
    const small = ctx.resizeScreenshot(img.image_base64);
    return { type: 'image', data: small.data, mimeType: small.mimeType };
  } catch (err) {
    console.warn(`[screenshot] capture failed for ${name}: ${String(err)}`);
    return null;
  }
}

async function forward(ctx: ToolContext, name: string, method: string, params: Record<string, unknown>): Promise<ToolResult> {
  if (!(await isConnected(ctx, name))) return errResult(`Device '${name}' is not connected`);
  try {
    const reply = await callDevice(ctx, name, method, params, TIMEOUTS.default);
    if (reply.error) return errResult(`Device error: ${reply.error.message}`);
    return { content: [{ type: 'text', text: resultText(reply.result) }] };
  } catch (err) {
    return callFailed(ctx, name, err);
  }
}

async function forwardWithScreenshot(ctx: ToolContext, name: string, method: string, params: Record<string, unknown>): Promise<ToolResult> {
  if (!(await isConnected(ctx, name))) return errResult(`Device '${name}' is not connected`);
  try {
    const reply = await callDevice(ctx, name, method, params, TIMEOUTS.menuTool);
    if (reply.error) return errResult(`Device error: ${reply.error.message}`);
    const content: ContentBlock[] = [{ type: 'text', text: resultText(reply.result) }];
    await new Promise((r) => setTimeout(r, ctx.einkDelayMs));
    const img = await screenshotBlock(ctx, name);
    if (img) content.push(img);
    return { content };
  } catch (err) {
    return callFailed(ctx, name, err);
  }
}

/** snapshot / tap / hold / tap_text / type / action / wait_for. */
async function uiCall(ctx: ToolContext, args: UiArgs, method: 'ui_snapshot' | 'ui_act' | 'ui_wait', params: Record<string, unknown>): Promise<ToolResult> {
  const name = args.device;
  if (!(await isConnected(ctx, name))) return errResult(`Device '${name}' is not connected`);
  if (typeof params.ref === 'string') {
    const stale = ctx.tracker.checkRef(name, params.ref);
    if (stale) return errResult(stale);
  }
  let reply;
  try {
    // ui_act replies only once KOReader is idle (5 s, or wait_cap up to 30 s, on the device);
    // ui_wait replies when the text matched or its own timeout passed.
    const timeoutMs = method === 'ui_wait' ? waitForTimeoutMs(args.timeout) : uiActTimeoutMs(args.wait);
    reply = await callDevice(ctx, name, method, params, timeoutMs);
  } catch (err) {
    return callFailed(ctx, name, err);
  }
  if (reply.error) return errResult(reply.error.message);

  const maxLines = args.max_lines ?? DEFAULT_MAX_LINES;
  let text: string;
  if (method === 'ui_snapshot') {
    const snap = reply.result as unknown as UiSnapshot;
    ctx.tracker.see(name, snap.snapshot);
    text = formatSnapshot(snap, maxLines).join('\n');
  } else if (method === 'ui_wait') {
    const w = reply.result as unknown as UiWaitResult;
    ctx.tracker.see(name, w.snapshot?.snapshot);
    text = formatWaitResult(w, args.gone === true, maxLines);
  } else {
    const act = reply.result as unknown as UiActResult;
    ctx.tracker.see(name, act.snapshot?.snapshot);
    text = formatActResult(act, maxLines);
  }
  const content: ContentBlock[] = [{ type: 'text', text }];
  if (args.screenshot === true) {
    const img = await screenshotBlock(ctx, name);
    if (img) content.push(img);
  }
  return { content };
}

async function screenshotTool(ctx: ToolContext, name: string): Promise<ToolResult> {
  if (!(await isConnected(ctx, name))) return errResult(`Device '${name}' is not connected`);
  try {
    const reply = await callDevice(ctx, name, 'capture_screenshot', {}, TIMEOUTS.screenshot);
    if (reply.error) return errResult(`Screenshot failed: ${reply.error.message}`);
    const ss = (reply.result ?? {}) as { image_base64?: string; size_bytes?: number };
    if (!ss.image_base64) return errResult('Screenshot returned no image data');
    const img = ctx.resizeScreenshot(ss.image_base64);
    return {
      content: [
        { type: 'text', text: JSON.stringify({ device: name, size_bytes: ss.size_bytes }, null, 2) },
        { type: 'image', data: img.data, mimeType: img.mimeType },
      ],
    };
  } catch (err) {
    return errResult(`Screenshot failed: ${err instanceof Error ? err.message : String(err)}`);
  }
}

async function restartKoreader(ctx: ToolContext, name: string): Promise<ToolResult> {
  if (!(await isConnected(ctx, name))) return errResult(`Device '${name}' is not connected`);
  console.log(`[restart] scheduling a KOReader restart on ${name}`);
  try {
    await ctx.call(name, 'run_command', {
      command: 'rm -f /tmp/koreader-fb.dump /tmp/fm-out-* /tmp/mcp_ss.png /tmp/*.dump /tmp/ko_restart.log; echo cleaned',
    }, TIMEOUTS.restartStep);
  } catch { /* best effort */ }
  const requestedAt = Date.now();
  try {
    await ctx.call(name, 'run_command', { command: buildRestartCommand() }, TIMEOUTS.restartStep);
  } catch { /* may time out or disconnect if the restart is fast */ }
  // The restart closes the connection; coming back means a new connection for this name.
  const back = await ctx.waitForReconnect(name, ctx.reconnectTimeoutMs, requestedAt);
  ctx.tracker.forget(name);
  return {
    content: [{
      type: 'text',
      text: JSON.stringify({ device: name, restarted: !!back, status: back ? 'online' : 'restart_timeout' }, null, 2),
    }],
  };
}
