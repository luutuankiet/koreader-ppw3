import { BUNDLE_RE, DEFAULT_INBOX_MAX_BYTES, DEVICE_RE } from '../../kindle-gateway/src/bundle-format';
import { bearerMatches } from './auth';

// The diagnostics inbox: koreader_mcp's "Send diagnostics" button PUTs one gzipped tar to
// /inbox/<device>/<timestamp>.tar.gz, which lands in R2 at inbox/<device>/<file>.
// Same name rules and replies as kindle-gateway's package-host.ts, plus the device key.

export const INBOX_MAX_BYTES = DEFAULT_INBOX_MAX_BYTES;

export function inboxKey(device: string, file: string): string {
  return `inbox/${device}/${file}`;
}

function refuse(status: number, error: string): Response {
  // The client may still be sending; do not keep reading a body we refused.
  return Response.json({ error }, { status, headers: { Connection: 'close' } });
}

/** Handles every request under /inbox/. */
export async function inboxRoute(request: Request, env: Env, maxBytes = INBOX_MAX_BYTES): Promise<Response> {
  if (!(await bearerMatches(request.headers.get('Authorization'), env.DEVICE_KEY))) {
    return new Response('unauthorized', { status: 401 });
  }
  if (request.method !== 'PUT') {
    return refuse(405, 'only PUT /inbox/<device>/<timestamp>.tar.gz is accepted');
  }
  // The URL parser has already resolved "." and ".." segments; an encoded "/" stays "%2F"
  // and fails the name rules, so a name is always one plain segment.
  const parts = new URL(request.url).pathname.slice('/inbox/'.length).split('/');
  if (parts.length !== 2 || !DEVICE_RE.test(parts[0]) || !BUNDLE_RE.test(parts[1])) {
    return refuse(400, 'path must be /inbox/<device>/<timestamp>.tar.gz using letters, digits, ".", "_" and "-"');
  }
  const [device, file] = parts;

  const header = request.headers.get('Content-Length');
  let declared: number | undefined;
  if (header !== null) {
    if (!/^\d+$/.test(header)) return refuse(400, 'bad Content-Length');
    declared = Number(header);
    if (declared > maxBytes) return refuse(413, `bundle larger than ${maxBytes} bytes`);
  }
  if (!request.body || declared === 0) return refuse(400, 'empty bundle');

  // Counts the bytes as they stream past and refuses gzip-less or oversized bodies, so a
  // missing or false Content-Length cannot get more than maxBytes into the bucket. Nothing
  // passes until the first two bytes are known to be the gzip magic: R2 ends the put as soon
  // as it has the declared length, which can be before flush() would get to object.
  let size = 0;
  const head: number[] = [];
  let held: Uint8Array[] = [];
  let refusal: Response | undefined;
  const meter = new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      size += chunk.byteLength;
      for (let i = 0; head.length < 2 && i < chunk.byteLength; i++) head.push(chunk[i]);
      if (size > maxBytes) {
        refusal = refuse(413, `bundle larger than ${maxBytes} bytes`);
      } else if (head.length === 2 && (head[0] !== 0x1f || head[1] !== 0x8b)) {
        refusal = refuse(400, 'bundle is not gzip data');
      }
      if (refusal) return controller.error(new Error('refused'));
      if (head.length < 2) return void held.push(chunk);
      for (const c of held) controller.enqueue(c);
      held = [];
      controller.enqueue(chunk);
    },
    flush(controller) {
      if (size === 0) refusal = refuse(400, 'empty bundle');
      else if (head.length < 2) refusal = refuse(400, 'bundle is not gzip data');
      if (refusal) controller.error(new Error('refused'));
    },
  });
  const metered = request.body.pipeThrough(meter);

  // R2 needs the length up front. With a Content-Length the body streams straight through
  // (FixedLengthStream also fails if fewer or more bytes arrive); without one it is held in
  // memory, which the meter bounds at maxBytes.
  let body: ReadableStream | Uint8Array;
  let piping: Promise<void> = Promise.resolve();
  if (declared !== undefined) {
    const fixed = new FixedLengthStream(declared);
    piping = metered.pipeTo(fixed.writable);
    body = fixed.readable;
  } else {
    try {
      body = await collect(metered);
    } catch {
      return refusal ?? refuse(400, 'upload failed');
    }
  }

  const key = inboxKey(device, file);
  let stored: R2Object | null;
  try {
    // A bundle is never overwritten: the put only happens if no object has the key yet.
    [stored] = await Promise.all([
      env.INBOX.put(key, body, { onlyIf: { etagDoesNotMatch: '*' }, httpMetadata: { contentType: 'application/gzip' } }),
      piping,
    ]);
  } catch (err) {
    return refusal ?? refuse(500, `cannot store bundle: ${(err as Error).message}`);
  }
  if (refusal) {
    // Belt and braces: the meter refused after R2 had already stored the object.
    if (stored) await env.INBOX.delete(key);
    return refusal;
  }
  if (stored === null) return refuse(409, `${device}/${file} already exists`);
  return Response.json({ ok: true, path: `${device}/${file}`, size }, { status: 201 });
}

async function collect(stream: ReadableStream<Uint8Array>): Promise<Uint8Array> {
  const chunks: Uint8Array[] = [];
  let total = 0;
  for await (const chunk of stream) {
    chunks.push(chunk);
    total += chunk.byteLength;
  }
  const out = new Uint8Array(total);
  let pos = 0;
  for (const c of chunks) {
    out.set(c, pos);
    pos += c.byteLength;
  }
  return out;
}
