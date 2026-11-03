import fs from 'fs';
import path from 'path';
import zlib from 'zlib';
import { BUNDLE_RE, BundleInfo, DEVICE_RE, MAX_UNPACKED_BYTES, newestFirst, noBundleMessage, parseTar } from './bundle-format';

export type { BundleInfo };
export { parseTar };

// Reads the diagnostics bundles koreader_mcp's "Send diagnostics" button uploads
// to the inbox (koreader_mcp.koplugin/diagnostics.lua builds them).

export interface Bundle extends BundleInfo {
  files: Record<string, Buffer>;
}

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
    .sort(newestFirst);
}

/** One bundle unpacked in memory; the newest of the device when file is omitted. */
export function readBundle(inboxDir: string, device: string, file?: string): Bundle {
  if (!DEVICE_RE.test(device)) throw new Error(`invalid device name: ${device}`);
  if (file !== undefined && !BUNDLE_RE.test(file)) throw new Error(`invalid bundle name: ${file}`);
  const info = file === undefined
    ? listBundles(inboxDir, device)[0]
    : bundlesOf(inboxDir, device).find((b) => b.file === file);
  if (!info) throw new Error(noBundleMessage(device, file));
  const gz = fs.readFileSync(path.join(inboxDir, device, info.file));
  return { ...info, files: parseTar(zlib.gunzipSync(gz, { maxOutputLength: MAX_UNPACKED_BYTES })) };
}
