import { McpServer, createMcpHandler } from '@modelcontextprotocol/server';
import type { SnapshotTracker } from '../../kindle-gateway/src/ui-snapshot';
import type { DeviceReply, DeviceSummary } from './hub';
import type { EncodedImage } from './screenshot';
import { diagnosticsTools } from './diagnostics-tools';
import { registerDeviceTools } from './tools/device-tools';

/**
 * What a tool needs from the hub. The hub object passes itself in, so tools call devices
 * directly in the object (no RPC hop) and tests can pass a stand-in.
 */
export interface ToolContext {
  listDevices(): Promise<DeviceSummary[]>;
  /** Rejects when the device is not connected, disconnects, or does not reply in time. */
  call(device: string, method: string, params?: Record<string, unknown>, timeoutMs?: number): Promise<DeviceReply>;
  waitForReconnect(device: string, timeoutMs?: number, afterMs?: number): Promise<DeviceSummary | null>;
  /** Latest snapshot id per device, shared by every request (MCP itself is stateless). */
  tracker: SnapshotTracker;
  resizeScreenshot(base64Png: string): EncodedImage;
  /** Wait before the screenshot that follows a menu tool, for the e-ink refresh. */
  einkDelayMs: number;
  /** Wait for the device to come back after restart_koreader. */
  reconnectTimeoutMs: number;
  /** The R2 bucket diagnostics bundles are uploaded to (see inbox.ts). */
  inbox: R2Bucket;
}

/**
 * Every tool group served on /mcp. A group is a function that registers its tools on the
 * server; add a group by adding its file and one line here.
 */
export const toolSets: Array<(server: McpServer, ctx: ToolContext) => void> = [
  registerDeviceTools,
  diagnosticsTools,
];

export function createMcpServer(ctx: ToolContext): McpServer {
  const server = new McpServer({ name: 'kindle-gateway', version: '3.0.0' });
  for (const register of toolSets) register(server, ctx);
  return server;
}

/**
 * Stateless MCP over HTTP: protocol 2026-07-28 (server/discover, one request per exchange) and
 * the 2025-era initialize handshake through the SDK's stateless fallback, which never issues
 * an mcp-session-id and answers GET and DELETE with 405 (ADR 0004). Every request gets a
 * fresh server; tools keep state only in the hub (devices and the snapshot tracker).
 */
export function createMcpFetch(ctx: ToolContext): (request: Request) => Promise<Response> {
  const handler = createMcpHandler(() => createMcpServer(ctx), {
    legacy: 'stateless',
    responseMode: 'json',
    onerror: (err) => console.warn(`[mcp] ${err.message}`),
  });
  return (request) => handler.fetch(request);
}
