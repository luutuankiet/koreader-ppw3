import express, { Request, Response } from 'express';
import * as fs from 'fs';
import * as path from 'path';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { DeviceRegistry } from './device-registry';
import { KindleClient } from './kindle-client';
import { z } from 'zod';
import sharp from 'sharp';
import * as crypto from 'crypto';
import { buildRestartCommand, resolvePluginSource } from './device-commands';
import { SnapshotTracker, UiActResult, UiSnapshot, formatActResult, formatSnapshot, DEFAULT_MAX_LINES } from './ui-snapshot';

// --- Type helpers ---
type ContentBlock =
  | { type: 'text'; text: string }
  | { type: 'image'; data: string; mimeType: string };

type ToolResult = { content: ContentBlock[]; isError?: boolean };
type ToolArgs = Record<string, string | undefined>;
// Typed arguments for tools whose schema has booleans or numbers.
type UiArgs = { device: string; ref?: string; text?: string; name?: string; value?: string; clear?: boolean; screenshot?: boolean; max_lines?: number };

function defineTool(
  server: McpServer,
  name: string,
  description: string,
  schema: Record<string, z.ZodTypeAny>,
  handler: (args: ToolArgs) => Promise<ToolResult>
): void {
  (server.tool as Function)(name, description, schema, handler);
}

// --- Config ---
const EINK_REFRESH_DELAY = parseInt(process.env.EINK_DELAY || '1500', 10);
const PLUGINS_SRC = process.env.PLUGINS_SRC || '/workspace';

/** Resize screenshot to 50% + JPEG for token efficiency (~110KB PNG → ~20KB JPEG) */
async function resizeScreenshot(base64Data: string): Promise<{ data: string; mimeType: string }> {
  try {
    const buffer = Buffer.from(base64Data, 'base64');
    const resized = await sharp(buffer)
      .resize(536, 724)
      .grayscale()
      .jpeg({ quality: 50 })
      .toBuffer();
    return { data: resized.toString('base64'), mimeType: 'image/jpeg' };
  } catch (err) {
    console.warn('[resize] Failed, returning original:', err);
    return { data: base64Data, mimeType: 'image/png' };
  }
}

export function createApp(registry: DeviceRegistry) {
  const app = express();
  app.use(express.json());
  // Latest snapshot id per device, shared by every MCP request (the transport is stateless).
  const uiTracker = new SnapshotTracker();

  app.get('/health', (_req: Request, res: Response) => {
    res.json({ ok: true, devices: registry.list().length });
  });

  // --- MCP server factory ---
  function createMcpServer(): McpServer {
    const server = new McpServer({ name: 'kindle-gateway', version: '2.0.0' });

    // === Base tools ===

    defineTool(server, 'list_devices',
      'List the devices connected right now. A device is listed exactly while its live-mode connection is open.', {},
      async () => ({
        content: [{ type: 'text' as const, text: JSON.stringify(registry.list(), null, 2) }],
      })
    );

    defineTool(server, 'read_files',
      'Read files from a registered Kindle device',
      { device: z.string().describe('Device name'), params: z.string().describe('JSON params to forward') },
      async (args) => await forwardToolCall(registry, args.device!, 'read_files', JSON.parse(args.params!))
    );

    defineTool(server, 'run_command',
      'Run a command on a registered Kindle device',
      { device: z.string().describe('Device name'), params: z.string().describe('JSON params to forward') },
      async (args) => await forwardToolCall(registry, args.device!, 'run_command', JSON.parse(args.params!))
    );

    defineTool(server, 'device_status',
      'Get status from a registered Kindle device',
      { device: z.string().describe('Device name'), params: z.string().optional().describe('Optional JSON params') },
      async (args) => {
        const params = args.params ? JSON.parse(args.params) : {};
        return await forwardToolCall(registry, args.device!, 'device_status', params);
      }
    );

    // === L3 Lua API tools (all return screenshot in response) ===

    defineTool(server, 'get_current_view',
      'Get the current KOReader widget stack. Returns widget info + screenshot of current screen.',
      { device: z.string().describe('Device name') },
      async (args) => await forwardWithScreenshot(registry, args.device!, 'get_current_view', {})
    );

    defineTool(server, 'get_menu_items',
      'List items in the currently visible KOReader menu. Returns items + screenshot.',
      { device: z.string().describe('Device name'), params: z.string().optional().describe('Optional JSON: {"max_items": 50}') },
      async (args) => {
        const params = args.params ? JSON.parse(args.params) : {};
        return await forwardWithScreenshot(registry, args.device!, 'get_menu_items', params);
      }
    );

    defineTool(server, 'select_menu_item',
      'Select a KOReader menu item by text or index. Returns result + screenshot of resulting UI.',
      { device: z.string().describe('Device name'), params: z.string().describe('JSON: {"text": "FreshRSS"} or {"index": 3}') },
      async (args) => await forwardWithScreenshot(registry, args.device!, 'select_menu_item', JSON.parse(args.params!))
    );

    defineTool(server, 'go_back',
      'Navigate back in KOReader menu stack. Returns result + screenshot.',
      { device: z.string().describe('Device name') },
      async (args) => await forwardWithScreenshot(registry, args.device!, 'go_back', {})
    );

    defineTool(server, 'close_top_widget',
      'Close/dismiss the topmost KOReader widget. Returns result + screenshot.',
      { device: z.string().describe('Device name') },
      async (args) => await forwardWithScreenshot(registry, args.device!, 'close_top_widget', {})
    );

    defineTool(server, 'send_event',
      'Trigger a KOReader internal event (e.g. ShowMenu, ShowReaderMenu, Close). Returns result + screenshot. Use instead of touch simulation.',
      { device: z.string().describe('Device name'), params: z.string().describe('JSON: {"event": "ShowMenu", "args": {}}') },
      async (args) => await forwardWithScreenshot(registry, args.device!, 'send_event', JSON.parse(args.params!))
    );

    // === Widget snapshot and actions ===
    // Each action waits on the device until KOReader is idle, then returns one result
    // line, the new snapshot and the log lines the action caused. Screenshot only on request.

    const uiCommon = {
      device: z.string().describe('Device name'),
      screenshot: z.boolean().optional().describe('Also return a screenshot (default false)'),
      max_lines: z.number().int().positive().optional().describe(`Snapshot lines before the [+N more] cut (default ${DEFAULT_MAX_LINES})`),
    };
    const ui = (handler: (a: UiArgs) => Promise<ToolResult>) =>
      (args: ToolArgs) => handler(args as unknown as UiArgs);

    defineTool(server, 'snapshot',
      'List the widgets of the top KOReader window, one line each: [ref] kind "text" (state). Refs look like 3_7 and stay valid for the last 2 snapshots. Kinds: item (main menu row), row (list row), check, button, icon, input, tap, text.',
      uiCommon,
      ui(async (a) => await uiCall(registry, uiTracker, a, 'ui_snapshot', {}))
    );

    defineTool(server, 'tap',
      'Tap a widget by its snapshot ref (a gesture at the centre of the widget, no touch injection). Waits for KOReader to settle, returns the result, a new snapshot and the logs it caused.',
      { ...uiCommon, ref: z.string().describe('Widget ref from the last 2 snapshots, e.g. "3_7"') },
      ui(async (a) => await uiCall(registry, uiTracker, a, 'ui_act', { what: 'tap', ref: a.ref }))
    );

    defineTool(server, 'hold',
      'Long-press a widget by its snapshot ref. Waits for KOReader to settle, returns the result, a new snapshot and the logs it caused.',
      { ...uiCommon, ref: z.string().describe('Widget ref from the last 2 snapshots, e.g. "3_7"') },
      ui(async (a) => await uiCall(registry, uiTracker, a, 'ui_act', { what: 'hold', ref: a.ref }))
    );

    defineTool(server, 'tap_text',
      'Tap the first visible widget whose text matches (exact, case-insensitive; else the first that contains it). Needs no snapshot first.',
      { ...uiCommon, text: z.string().describe('Visible text, e.g. "Synced reading list"') },
      ui(async (a) => await uiCall(registry, uiTracker, a, 'ui_act', { what: 'tap_text', text: a.text }))
    );

    defineTool(server, 'type',
      'Type text into the focused input field of the top window (or its only input).',
      { ...uiCommon, text: z.string().describe('Text to type'), clear: z.boolean().optional().describe('Clear the field first') },
      ui(async (a) => await uiCall(registry, uiTracker, a, 'ui_act', { what: 'type', text: a.text, clear: a.clear === true }))
    );

    defineTool(server, 'action',
      'Run a KOReader Dispatcher action by name, e.g. "show_menu" (main menu), "home", "toggle_wifi". Optional value for actions that take one.',
      { ...uiCommon, name: z.string().describe('Dispatcher action name'), value: z.string().optional().describe('Optional value; numbers and true/false are converted') },
      ui(async (a) => await uiCall(registry, uiTracker, a, 'ui_act', { what: 'action', name: a.name, value: parseActionValue(a.value) }))
    );

    // === Screenshot (standalone, no preceding event) ===

    defineTool(server, 'screenshot',
      'Take a screenshot of the Kindle e-ink display. Returns the image directly as an MCP image content block.',
      { device: z.string().describe('Device name') },
      async (args) => await captureScreenshotTool(registry, args.device!)
    );

    // === Device management ===

    defineTool(server, 'restart_koreader',
      'Restart KOReader on a Kindle device. Kills luajit, restarts koreader.sh, waits for the device to reconnect.',
      { device: z.string().describe('Device name') },
      async (args) => await restartKoreader(registry, args.device!)
    );

    defineTool(server, 'deploy_plugin',
      'Deploy a KOReader plugin to a Kindle. Reads the top-level .lua files from the workspace (or an optional workspace-relative source folder), transfers them, restarts KOReader.',
      {
        device: z.string().describe('Device name'),
        plugin: z.string().describe('Plugin dir name without .koplugin (e.g. "koreader_mcp"); also names the device folder /mnt/us/koreader/plugins/<plugin>.koplugin'),
        source: z.string().optional().describe('Optional source folder relative to the workspace root (e.g. ".claude/worktrees/foo/koreader_mcp.koplugin"). Default: "<plugin>.koplugin" at the workspace root.'),
      },
      async (args) => await deployPlugin(registry, args.device!, args.plugin!, args.source)
    );

    return server;
  }

  // --- MCP StreamableHTTP transport (stateless) ---
  // Stateless: every POST gets a fresh server + transport and no session ID is
  // issued, so a client can never hold a session ID the gateway has forgotten
  // (gateway restart, closed stream). Tools read only the shared device registry.
  app.post('/mcp', async (req: Request, res: Response) => {
    const server = createMcpServer();
    try {
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
      res.on('close', () => {
        transport.close();
        server.close();
      });
      await server.connect(transport);
      await transport.handleRequest(req, res, req.body);
    } catch (err) {
      console.error('[mcp] Error handling request:', err);
      if (!res.headersSent) {
        res.status(500).json({ jsonrpc: '2.0', error: { code: -32603, message: 'Internal server error' }, id: null });
      }
    }
  });

  const methodNotAllowed = (_req: Request, res: Response) => {
    res.status(405).json({ jsonrpc: '2.0', error: { code: -32000, message: 'Method not allowed (stateless server)' }, id: null });
  };
  app.get('/mcp', methodNotAllowed);
  app.delete('/mcp', methodNotAllowed);

  return app;
}

// ============================================================
// Tool implementation functions
// ============================================================

/** Forward a tool call to a Kindle device (text-only response) */
async function forwardToolCall(
  registry: DeviceRegistry,
  deviceName: string,
  method: string,
  params: Record<string, unknown>
): Promise<ToolResult> {
  const device = registry.get(deviceName);
  if (!device) return errResult(`Device '${deviceName}' is not connected`);

  const client = new KindleClient(device);
  try {
    const response = await client.callTool(method, params);
    if (response.error) return errResult(`Device error: ${response.error.message}`);
    return {
      content: [{
        type: 'text' as const,
        text: typeof response.result === 'string' ? response.result : JSON.stringify(response.result, null, 2),
      }],
    };
  } catch (err) {
    console.error(`[forward] Failed to reach ${deviceName}:`, err);
    return errResult(`Failed to reach '${deviceName}': ${err instanceof Error ? err.message : String(err)}`);
  }
}

/** Forward a tool call then capture a screenshot after e-ink refresh.
 *  Returns both the text result AND the screenshot as an MCP image block. */
async function forwardWithScreenshot(
  registry: DeviceRegistry,
  deviceName: string,
  method: string,
  params: Record<string, unknown>
): Promise<ToolResult> {
  const device = registry.get(deviceName);
  if (!device) return errResult(`Device '${deviceName}' is not connected`);

  const client = new KindleClient(device);
  try {
    // 1. Forward the L3 call
    const response = await client.callTool(method, params, 15000);

    if (response.error) return errResult(`Device error: ${response.error.message}`);

    const resultText = typeof response.result === 'string'
      ? response.result
      : JSON.stringify(response.result, null, 2);

    const content: ContentBlock[] = [{ type: 'text' as const, text: resultText }];

    // 2. Wait for e-ink refresh
    await new Promise(resolve => setTimeout(resolve, EINK_REFRESH_DELAY));

    // 3. Capture screenshot via Kindle's capture_screenshot handler
    try {
      const ssResp = await client.callTool('capture_screenshot', {}, 30000);
      if (!ssResp.error && ssResp.result) {
        const ss = ssResp.result as { image_base64?: string; mime_type?: string };
        if (ss.image_base64) {
          const img = await resizeScreenshot(ss.image_base64);
          content.push({
            type: 'image' as const,
            data: img.data,
            mimeType: img.mimeType,
          });
        }
      }
    } catch (ssErr) {
      console.warn(`[screenshot] Capture failed for ${deviceName}:`, ssErr);
      // Non-fatal — return text result even if screenshot fails
    }

    return { content };
  } catch (err) {
    console.error(`[forwardWithSS] Failed for ${deviceName}:`, err);
    return errResult(`Failed to reach '${deviceName}': ${err instanceof Error ? err.message : String(err)}`);
  }
}

/** Dispatcher values arrive as strings over MCP; numbers and booleans are converted. */
export function parseActionValue(v: string | undefined): unknown {
  if (v === undefined || v === '') return undefined;
  if (v === 'true') return true;
  if (v === 'false') return false;
  if (/^-?\d+(\.\d+)?$/.test(v)) return Number(v);
  return v;
}

/** Shared wrapper for snapshot / tap / hold / tap_text / type / action. Exported for tests. */
export async function uiCall(
  registry: DeviceRegistry,
  tracker: SnapshotTracker,
  args: UiArgs,
  method: 'ui_snapshot' | 'ui_act',
  params: Record<string, unknown>
): Promise<ToolResult> {
  const deviceName = args.device;
  const device = registry.get(deviceName);
  if (!device) return errResult(`Device '${deviceName}' is not connected`);

  if (typeof params.ref === 'string') {
    const stale = tracker.checkRef(deviceName, params.ref);
    if (stale) return errResult(stale);
  }

  const client = new KindleClient(device);
  let response;
  try {
    // ui_act replies only once KOReader is idle (capped at 5s on the device).
    response = await client.callTool(method, params, 20000);
  } catch (err) {
    console.error(`[ui] Failed to reach ${deviceName}:`, err);
    return errResult(`Failed to reach '${deviceName}': ${err instanceof Error ? err.message : String(err)}`);
  }
  if (response.error) return errResult(response.error.message);

  const maxLines = args.max_lines ?? DEFAULT_MAX_LINES;
  let text: string;
  if (method === 'ui_snapshot') {
    const snap = response.result as UiSnapshot;
    tracker.see(deviceName, snap.snapshot);
    text = formatSnapshot(snap, maxLines).join('\n');
  } else {
    const act = response.result as UiActResult;
    tracker.see(deviceName, act.snapshot?.snapshot);
    text = formatActResult(act, maxLines);
  }
  const content: ContentBlock[] = [{ type: 'text' as const, text }];
  if (args.screenshot === true) {
    try {
      const ss = await client.callTool('capture_screenshot', {}, 30000);
      const img = (ss.result || {}) as { image_base64?: string };
      if (!ss.error && img.image_base64) {
        const small = await resizeScreenshot(img.image_base64);
        content.push({ type: 'image' as const, data: small.data, mimeType: small.mimeType });
      }
    } catch (ssErr) {
      console.warn(`[ui] Screenshot failed for ${deviceName}:`, ssErr);
    }
  }
  return { content };
}

/** Standalone screenshot — calls Kindle's capture_screenshot, returns MCP image block */
async function captureScreenshotTool(
  registry: DeviceRegistry,
  deviceName: string
): Promise<ToolResult> {
  const device = registry.get(deviceName);
  if (!device) return errResult(`Device '${deviceName}' is not connected`);

  const client = new KindleClient(device);
  try {
    const resp = await client.callTool('capture_screenshot', {}, 30000);
    if (resp.error) return errResult(`Screenshot failed: ${resp.error.message}`);

    const ss = resp.result as { image_base64?: string; mime_type?: string; size_bytes?: number };
    if (!ss.image_base64) return errResult('Screenshot returned no image data');

    const img = await resizeScreenshot(ss.image_base64);
    return {
      content: [
        { type: 'text' as const, text: JSON.stringify({ device: deviceName, size_bytes: ss.size_bytes }, null, 2) },
        { type: 'image' as const, data: img.data, mimeType: img.mimeType },
      ],
    };
  } catch (err) {
    return errResult(`Screenshot failed: ${err instanceof Error ? err.message : String(err)}`);
  }
}

/** Restart KOReader on a Kindle device (or the emulator). Exported for tests. */
export async function restartKoreader(
  registry: DeviceRegistry,
  deviceName: string,
  reconnectTimeoutMs: number = 60000
): Promise<ToolResult> {
  const device = registry.get(deviceName);
  if (!device) return errResult(`Device '${deviceName}' is not connected`);

  const client = new KindleClient(device);
  console.log(`[restart] Scheduling KOReader restart on ${deviceName}`);

  // Pre-restart: cleanup /tmp
  try {
    await client.callTool('run_command', {
      command: 'rm -f /tmp/koreader-fb.dump /tmp/fm-out-* /tmp/mcp_ss.png /tmp/*.dump /tmp/ko_restart.log; echo cleaned'
    }, 5000);
  } catch { /* best effort */ }

  // Schedule restart with delay (so the reply can get out before KOReader dies)
  const requestedAt = new Date();
  try {
    await client.callTool('run_command', { command: buildRestartCommand() }, 5000);
  } catch {
    // May time out if the restart is fast
  }

  // The restart closes the connection; coming back means a new connection for this name.
  console.log(`[restart] Waiting for ${deviceName} to reconnect...`);
  const back = await registry.waitForConnection(deviceName, requestedAt, reconnectTimeoutMs);
  return {
    content: [{
      type: 'text' as const,
      text: JSON.stringify({ device: deviceName, restarted: !!back, status: back ? 'online' : 'restart_timeout' }, null, 2),
    }],
  };
}

/** Deploy a KOReader plugin to a Kindle device */
async function deployPlugin(
  registry: DeviceRegistry,
  deviceName: string,
  pluginName: string,
  source?: string
): Promise<ToolResult> {
  const device = registry.get(deviceName);
  if (!device) return errResult(`Device '${deviceName}' is not connected`);

  const pluginDir = `${pluginName}.koplugin`;
  // Plugins live at workspace root (flat layout), or at an explicit workspace-relative `source`.
  const resolved = resolvePluginSource(PLUGINS_SRC, pluginName, source);
  if (!resolved.ok) return errResult(resolved.error);
  const srcPath = resolved.srcPath;
  const destPath = `/mnt/us/koreader/plugins/${pluginDir}`;

  // Step 1: Check source exists
  if (!fs.existsSync(srcPath)) {
    const available = fs.existsSync(PLUGINS_SRC)
      ? fs.readdirSync(PLUGINS_SRC).filter(d => d.endsWith('.koplugin')).join(', ')
      : `PLUGINS_SRC not found: ${PLUGINS_SRC}`;
    return errResult(`Plugin source not found at ${srcPath}. Available: ${available}`);
  }

  const luaFiles = fs.readdirSync(srcPath).filter(f => f.endsWith('.lua'));
  if (luaFiles.length === 0) return errResult(`No .lua files in ${srcPath}`);

  const client = new KindleClient(device);
  const deployed: string[] = [];
  const errors: string[] = [];

  // Step 2: Pre-deploy cleanup: free /tmp
  console.log(`[deploy] Pre-deploy cleanup on ${deviceName}`);
  try {
    const cleanResp = await client.callTool('run_command', {
      command: 'rm -f /tmp/koreader-fb.dump /tmp/fm-out-* /tmp/mcp_ss.png /tmp/*.dump; df /tmp | tail -1'
    }, 5000);
    if (cleanResp.result) {
      console.log(`[deploy] /tmp status: ${JSON.stringify(cleanResp.result)}`);
    }
  } catch { /* best effort */ }

  // Step 3: Ensure target dir exists
  await client.callTool('run_command', { command: `mkdir -p ${destPath}` }, 5000);

  // Step 4: Transfer each .lua file via native write_file (no ARG_MAX limit) with shell fallback for older koreader_mcp on device
  for (const file of luaFiles) {
    const content = fs.readFileSync(path.join(srcPath, file));
    const b64 = content.toString('base64');
    const expectedMd5 = crypto.createHash('md5').update(content).digest('hex');
    const destFile = `${destPath}/${file}`;
    console.log(`[deploy] Transferring ${file} (${content.length}B) to ${deviceName}`);

    // Path 1: native write_file (preferred — bypasses BusyBox shell ARG_MAX ~64KB)
    let nativeAttempted = false;
    try {
      const resp = await client.callTool('write_file', {
        path: destFile,
        content_base64: b64,
      }, 30000);
      const result = resp.result as { path: string; bytes_written: number; md5: string | null } | undefined;
      if (!resp.error && result) {
        nativeAttempted = true;
        if (result.md5 && result.md5 !== expectedMd5) {
          errors.push(`${file}: md5 mismatch (expected ${expectedMd5}, got ${result.md5})`);
        } else {
          console.log(`[deploy] ${file}: ${result.bytes_written}B via write_file, md5=${result.md5 || 'n/a'}`);
          deployed.push(file);
        }
      } else if (resp.error) {
        console.warn(`[deploy] write_file unsupported on ${deviceName} (${resp.error.message}) — falling back to shell`);
      }
    } catch (err) {
      console.warn(`[deploy] write_file threw for ${file}: ${err instanceof Error ? err.message : String(err)} — falling back to shell`);
    }

    if (nativeAttempted) continue;

    // Path 2: legacy shell printf (works for files < ~48KB raw; for backward compat with old koreader_mcp)
    try {
      const resp = await client.callTool('run_command', {
        command: `printf '%s' '${b64}' | base64 -d > ${destFile} && echo ok`
      }, 15000);
      const result = resp.result as { stdout: string; exit_code: number } | undefined;
      if (resp.error || (result && result.exit_code !== 0)) {
        errors.push(`${file}: ${resp.error?.message || result?.stdout || 'unknown'}`);
      } else {
        deployed.push(file);
      }
    } catch (err) {
      errors.push(`${file}: ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  if (errors.length > 0 && deployed.length === 0) {
    return errResult(`Deploy failed:\n${errors.join('\n')}`);
  }

  // Step 4: Restart KOReader
  const restartResult = await restartKoreader(registry, deviceName);
  const restartData = JSON.parse((restartResult.content[0] as { text: string }).text);

  return {
    content: [{
      type: 'text' as const,
      text: JSON.stringify({
        device: deviceName,
        plugin: pluginDir,
        source: path.relative(path.resolve(PLUGINS_SRC), srcPath),
        deployed_files: deployed,
        errors: errors.length > 0 ? errors : undefined,
        koreader_restarted: restartData.restarted,
      }, null, 2),
    }],
  };
}

/** Error result helper */
function errResult(msg: string): ToolResult {
  return { content: [{ type: 'text' as const, text: `Error: ${msg}` }], isError: true };
}
