import fs from 'fs';
import path from 'path';
import zlib from 'zlib';
import { BUNDLE_RE, DEVICE_RE } from './package-host';

// Reads the diagnostics bundles koreader_mcp's "Send diagnostics" button uploads
// to the inbox (koreader_mcp.koplugin/diagnostics.lua builds them).

export interface BundleInfo {
  device: string;
  file: string;
  size: number;
  /** When the gateway received it: the device's clock can be wrong. */
  received: string;
}

export interface Bundle extends BundleInfo {
  files: Record<string, Buffer>;
}

// A bundle is capped at 10 MiB gzipped by default; this bounds what it may expand to.
const MAX_UNPACKED_BYTES = 64 * 1024 * 1024;

function bundlesOf(inboxDir: string, device: string): BundleInfo[] {
  const dir = path.join(inboxDir, device);
  let names: string[];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return [];
  }
  return names.filter((n) => BUNDLE_RE.test(n)).map((file) => {
    const st = fs.statSync(path.join(dir, file));
    return { device, file, size: st.size, received: st.mtime.toISOString() };
  });
}

/** Newest first, optionally for one device. An unknown device is an empty list. */
export function listBundles(inboxDir: string, device?: string): BundleInfo[] {
  let devices: string[];
  if (device !== undefined) {
    if (!DEVICE_RE.test(device)) throw new Error(`invalid device name: ${device}`);
    devices = [device];
  } else {
    try {
      devices = fs.readdirSync(inboxDir).filter((n) => DEVICE_RE.test(n));
    } catch {
      return [];
    }
  }
  return devices.flatMap((d) => bundlesOf(inboxDir, d))
    .sort((a, b) => b.received.localeCompare(a.received) || b.file.localeCompare(a.file));
}

/** Regular files of a tar archive (ustar, as GNU and busybox tar write short names). */
export function parseTar(tar: Buffer): Record<string, Buffer> {
  const files: Record<string, Buffer> = {};
  const text = (start: number, len: number) => {
    const raw = tar.subarray(start, start + len);
    const end = raw.indexOf(0);
    return raw.subarray(0, end < 0 ? len : end).toString('utf8');
  };
  for (let pos = 0; pos + 512 <= tar.length;) {
    const name = text(pos, 100);
    if (!name) break; // the all-zero end marker
    const size = parseInt(text(pos + 124, 12).trim(), 8) || 0;
    const type = text(pos + 156, 1);
    if (type === '' || type === '0') {
      files[name.replace(/^\.\//, '')] = tar.subarray(pos + 512, pos + 512 + size);
    }
    pos += 512 + Math.ceil(size / 512) * 512;
  }
  return files;
}

/** One bundle unpacked in memory; the newest of the device when file is omitted. */
export function readBundle(inboxDir: string, device: string, file?: string): Bundle {
  if (!DEVICE_RE.test(device)) throw new Error(`invalid device name: ${device}`);
  if (file !== undefined && !BUNDLE_RE.test(file)) throw new Error(`invalid bundle name: ${file}`);
  const info = file === undefined
    ? listBundles(inboxDir, device)[0]
    : bundlesOf(inboxDir, device).find((b) => b.file === file);
  if (!info) throw new Error(`no bundle ${file ?? ''} for device ${device}`.replace('  ', ' '));
  const gz = fs.readFileSync(path.join(inboxDir, device, info.file));
  return { ...info, files: parseTar(zlib.gunzipSync(gz, { maxOutputLength: MAX_UNPACKED_BYTES })) };
}
