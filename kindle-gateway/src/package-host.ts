import crypto from 'crypto';
import fs from 'fs';
import path from 'path';
import express, { Request, Response, Router } from 'express';
import { BUNDLE_RE, DEFAULT_INBOX_MAX_BYTES, DEVICE_RE } from './bundle-format';

// Package host for Kindles, which reach only the LAN and run no agent server:
//   GET /pkg/<file>                       plugin archives and index.json, read-only,
//                                          built by scripts/publish.sh
//   PUT /inbox/<device>/<timestamp>.tar.gz one diagnostics bundle, at most inboxMaxBytes
// Mount this router before any body parser: the upload is read as a raw stream.

export interface PackageHostOptions {
  pkgDir: string;
  inboxDir: string;
  inboxMaxBytes: number;
}

export function packageHostOptionsFromEnv(env: NodeJS.ProcessEnv = process.env): PackageHostOptions {
  const max = parseInt(env.INBOX_MAX_BYTES || '', 10);
  return {
    pkgDir: env.PKG_DIR || '/packages',
    inboxDir: env.INBOX_DIR || '/inbox',
    inboxMaxBytes: Number.isFinite(max) && max > 0 ? max : DEFAULT_INBOX_MAX_BYTES,
  };
}

// The name rules live in bundle-format.ts, which kindle-gateway-worker shares.
export { BUNDLE_RE, DEFAULT_INBOX_MAX_BYTES, DEVICE_RE } from './bundle-format';

export function packageHostRouter(opts: PackageHostOptions): Router {
  const router = express.Router();

  router.use('/pkg', express.static(opts.pkgDir, {
    index: false,
    dotfiles: 'ignore',
    fallthrough: false, // missing file -> 404 here; a write method -> 405
    setHeaders: (res, filePath) => {
      if (path.basename(filePath) === 'index.json') res.setHeader('Cache-Control', 'no-cache');
    },
  }));

  router.put('/inbox/:device/:file', (req: Request, res: Response) => receiveBundle(req, res, opts));
  router.all('/inbox/*', (_req: Request, res: Response) => {
    res.status(405).json({ error: 'only PUT /inbox/<device>/<timestamp>.tar.gz is accepted' });
  });

  return router;
}

function refuse(req: Request, res: Response, status: number, error: string): void {
  if (res.headersSent) return;
  // The client may still be sending; do not keep reading a body we refused.
  res.setHeader('Connection', 'close');
  res.status(status).json({ error });
  req.unpipe();
  req.resume();
}

async function receiveBundle(req: Request, res: Response, opts: PackageHostOptions): Promise<void> {
  const { device, file } = req.params;
  if (!DEVICE_RE.test(device) || !BUNDLE_RE.test(file)) {
    return refuse(req, res, 400, 'path must be /inbox/<device>/<timestamp>.tar.gz using letters, digits, ".", "_" and "-"');
  }
  if (req.body !== undefined && Object.keys(req.body).length > 0) {
    // An earlier body parser consumed the stream; nothing left to save.
    return refuse(req, res, 415, 'send the bundle as application/gzip or application/octet-stream');
  }
  const declared = req.headers['content-length'];
  if (declared !== undefined && parseInt(declared, 10) > opts.inboxMaxBytes) {
    return refuse(req, res, 413, `bundle larger than ${opts.inboxMaxBytes} bytes`);
  }

  const dir = path.join(opts.inboxDir, device);
  const final = path.join(dir, file);
  const part = path.join(dir, `.${file}.${crypto.randomBytes(4).toString('hex')}.part`);
  try {
    await fs.promises.mkdir(dir, { recursive: true });
  } catch (err) {
    return refuse(req, res, 500, `cannot create inbox folder: ${(err as Error).message}`);
  }

  const out = fs.createWriteStream(part, { flags: 'wx' });
  let size = 0;
  let head = Buffer.alloc(0);
  let failed = false;
  const fail = (status: number, error: string) => {
    if (failed) return;
    failed = true;
    out.destroy();
    fs.promises.unlink(part).catch(() => undefined);
    refuse(req, res, status, error);
  };

  req.on('data', (chunk: Buffer) => {
    if (failed) return;
    size += chunk.length;
    if (head.length < 2) head = Buffer.concat([head, chunk.subarray(0, 2)]).subarray(0, 2);
    if (size > opts.inboxMaxBytes) return fail(413, `bundle larger than ${opts.inboxMaxBytes} bytes`);
    if (!out.write(chunk)) {
      req.pause();
      out.once('drain', () => req.resume());
    }
  });
  req.on('aborted', () => fail(400, 'upload aborted'));
  req.on('error', () => fail(400, 'upload failed'));
  out.on('error', (err) => fail(500, `cannot write bundle: ${err.message}`));

  req.on('end', () => {
    if (failed) return;
    out.end(async () => {
      if (failed) return;
      if (size === 0) return fail(400, 'empty bundle');
      if (head[0] !== 0x1f || head[1] !== 0x8b) return fail(400, 'bundle is not gzip data');
      try {
        // link() fails if the name exists, so a bundle is never overwritten.
        await fs.promises.link(part, final);
      } catch (err) {
        const code = (err as NodeJS.ErrnoException).code;
        return fail(code === 'EEXIST' ? 409 : 500,
          code === 'EEXIST' ? `${device}/${file} already exists` : `cannot store bundle: ${(err as Error).message}`);
      }
      await fs.promises.unlink(part).catch(() => undefined);
      console.log(`[kindle-gateway] inbox: ${device}/${file} (${size} bytes)`);
      res.status(201).json({ ok: true, path: `${device}/${file}`, size });
    });
  });
}
