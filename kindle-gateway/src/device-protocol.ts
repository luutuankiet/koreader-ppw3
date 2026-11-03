/**
 * The device link's message shapes, shared by the Node gateway (raw TCP, one JSON object per
 * line) and the Cloudflare Worker (WebSocket, one JSON object per text frame). Keep this file
 * free of Node imports: kindle-gateway-worker imports it by relative path.
 *
 *   device  -> gateway  {"type":"hello","name","id_hash","koreader_version","plugin_versions"}
 *   gateway -> device   {"type":"welcome","name"} or {"type":"refused","reason"} then close
 *   gateway -> device   {"id":N,"method":"...","params":{...}}        (a tool call)
 *   device  -> gateway  {"id":N,"result":...} or {"id":N,"error":{"code","message"}}
 *   device  -> gateway  {"type":"ping"}   answered with {"type":"pong"}
 */

export interface Hello {
  name: string;
  id_hash: string;
  koreader_version?: string;
  plugin_versions?: Record<string, string>;
}

export interface RpcResponse {
  id: number;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

const NAME_RE = /^[A-Za-z0-9._-]{1,32}$/;
const HASH_RE = /^[0-9a-f]{8,64}$/;

export function validateHello(msg: unknown): Hello | string {
  if (!msg || typeof msg !== 'object') return 'hello must be a JSON object';
  const m = msg as Record<string, unknown>;
  if (m.type !== 'hello') return 'first message must be {"type":"hello",...}';
  if (typeof m.name !== 'string' || !NAME_RE.test(m.name)) return 'name must be 1-32 of [A-Za-z0-9._-]';
  if (typeof m.id_hash !== 'string' || !HASH_RE.test(m.id_hash)) return 'id_hash must be 8-64 lowercase hex characters';
  const pv = m.plugin_versions;
  return {
    name: m.name,
    id_hash: m.id_hash,
    koreader_version: typeof m.koreader_version === 'string' ? m.koreader_version : undefined,
    plugin_versions: pv && typeof pv === 'object' && !Array.isArray(pv) ? pv as Record<string, string> : undefined,
  };
}

/** A reply to a call the gateway sent, as opposed to a message the device starts. */
export function isRpcResponse(msg: Record<string, unknown>): msg is Record<string, unknown> & { id: number } {
  return typeof msg.id === 'number' && ('result' in msg || 'error' in msg);
}
