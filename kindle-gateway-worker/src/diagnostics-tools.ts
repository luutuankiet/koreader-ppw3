import {
  BUNDLE_RE, BundleInfo, DEVICE_RE, MAX_UNPACKED_BYTES, bundleText, newestFirst, noBundleMessage, parseTar,
} from '../../kindle-gateway/src/bundle-format';
import { inboxKey } from './inbox';

// list_diagnostics and read_diagnostics over the R2 inbox: same names, descriptions, inputs and
// answers as kindle-gateway's gateway-server.ts, which reads the same bundles from a folder.
// One difference: the screenshot comes back as the device's PNG, where kindle-gateway shrinks
// it to a half-size JPEG with sharp, which does not run in a Worker.
//
// These are plain functions over an R2 bucket; the MCP endpoint registers them with
// `diagnosticsTools` (name, description, JSON Schema input, handler).

export type ContentBlock = { type: 'text'; text: string } | { type: 'image'; data: string; mimeType: string };
export type ToolResult = { content: ContentBlock[]; isError?: boolean };

export interface DiagnosticsTool {
  name: string;
  description: string;
  inputSchema: { type: 'object'; properties: Record<string, { type: 'string'; description: string }>; required?: string[] };
  handler: (bucket: R2Bucket, args: Record<string, unknown>) => Promise<ToolResult>;
}

/** Newest first, optionally for one device. An unknown device is an empty list. */
export async function listBundles(bucket: R2Bucket, device?: string): Promise<BundleInfo[]> {
  if (device !== undefined && !DEVICE_RE.test(device)) throw new Error(`invalid device name: ${device}`);
  const prefix = device === undefined ? 'inbox/' : `inbox/${device}/`;
  const found: BundleInfo[] = [];
  let cursor: string | undefined;
  do {
    const page = await bucket.list({ prefix, cursor });
    for (const obj of page.objects) {
      const info = infoOf(obj);
      if (info) found.push(info);
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return found.sort(newestFirst);
}

/** `received` is when R2 stored it, as kindle-gateway uses the file's mtime. */
function infoOf(obj: R2Object): BundleInfo | undefined {
  const parts = obj.key.split('/');
  if (parts.length !== 3 || !DEVICE_RE.test(parts[1]) || !BUNDLE_RE.test(parts[2])) return undefined;
  return { device: parts[1], file: parts[2], size: obj.size, received: obj.uploaded.toISOString() };
}

/** One bundle unpacked in memory; the newest of the device when file is omitted. */
export async function readBundle(
  bucket: R2Bucket, device: string, file?: string,
): Promise<BundleInfo & { files: Record<string, Uint8Array> }> {
  if (!DEVICE_RE.test(device)) throw new Error(`invalid device name: ${device}`);
  if (file !== undefined && !BUNDLE_RE.test(file)) throw new Error(`invalid bundle name: ${file}`);
  const name = file ?? (await listBundles(bucket, device))[0]?.file;
  const obj = name === undefined ? null : await bucket.get(inboxKey(device, name));
  const info = obj && infoOf(obj);
  if (!obj || !info) throw new Error(noBundleMessage(device, file));
  const tar = await gunzip(obj.body, MAX_UNPACKED_BYTES);
  return { ...info, files: parseTar(tar) };
}

async function gunzip(gz: ReadableStream, maxBytes: number): Promise<Uint8Array> {
  const chunks: Uint8Array[] = [];
  let total = 0;
  for await (const chunk of gz.pipeThrough(new DecompressionStream('gzip'))) {
    total += chunk.byteLength;
    if (total > maxBytes) throw new Error(`bundle unpacks to more than ${maxBytes} bytes`);
    chunks.push(chunk);
  }
  const out = new Uint8Array(total);
  let pos = 0;
  for (const c of chunks) {
    out.set(c, pos);
    pos += c.byteLength;
  }
  return out;
}

function base64(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

async function diagnosticsResult(read: () => Promise<ToolResult>): Promise<ToolResult> {
  try {
    return await read();
  } catch (err) {
    return { content: [{ type: 'text', text: `Error: Diagnostics: ${(err as Error).message}` }], isError: true };
  }
}

const optionalString = (v: unknown): string | undefined => (typeof v === 'string' ? v : undefined);

export async function listDiagnostics(bucket: R2Bucket, args: { device?: string }): Promise<ToolResult> {
  return diagnosticsResult(async () => ({
    content: [{ type: 'text', text: JSON.stringify(await listBundles(bucket, args.device), null, 2) }],
  }));
}

export async function readDiagnostics(bucket: R2Bucket, args: { device: string; file?: string }): Promise<ToolResult> {
  return diagnosticsResult(async () => {
    const bundle = await readBundle(bucket, args.device, args.file);
    const content: ContentBlock[] = [{ type: 'text', text: bundleText(bundle, bundle.files) }];
    const png = bundle.files['screenshot.png'];
    if (png) content.push({ type: 'image', data: base64(png), mimeType: 'image/png' });
    return { content };
  });
}

export const diagnosticsTools: DiagnosticsTool[] = [
  {
    name: 'list_diagnostics',
    description: 'List diagnostics bundles devices have uploaded, newest first. Works while the device is asleep or offline.',
    inputSchema: {
      type: 'object',
      properties: { device: { type: 'string', description: 'Device name; omit for all devices' } },
    },
    handler: (bucket, args) => listDiagnostics(bucket, { device: optionalString(args.device) }),
  },
  {
    name: 'read_diagnostics',
    description: 'Read one diagnostics bundle: versions, the crash.log lines new since the previous send, the top window snapshot and the screenshot. Works while the device is asleep or offline.',
    inputSchema: {
      type: 'object',
      properties: {
        device: { type: 'string', description: 'Device name' },
        file: { type: 'string', description: 'Bundle file name from list_diagnostics; omit for the newest' },
      },
      required: ['device'],
    },
    handler: (bucket, args) => readDiagnostics(bucket, { device: String(args.device ?? ''), file: optionalString(args.file) }),
  },
];
