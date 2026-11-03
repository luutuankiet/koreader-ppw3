import { formatSnapshot, UiSnapshot } from './ui-snapshot';

// The diagnostics bundle format, shared with kindle-gateway-worker: keep this file free of
// Node imports and of Buffer, so it runs in a Cloudflare Worker as well.
// koreader_mcp.koplugin/diagnostics.lua builds the bundles.

// One path segment each, so a name can never climb out of the inbox folder.
export const DEVICE_RE = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$/;
export const BUNDLE_RE = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}\.tar\.gz$/;

export const DEFAULT_INBOX_MAX_BYTES = 10 * 1024 * 1024;

// A bundle is capped at 10 MiB gzipped by default; this bounds what it may expand to.
export const MAX_UNPACKED_BYTES = 64 * 1024 * 1024;

export interface BundleInfo {
  device: string;
  file: string;
  size: number;
  /** When the gateway received it: the device's clock can be wrong. */
  received: string;
}

/** Sort order of list_diagnostics: newest first, then by file name. */
export function newestFirst(a: BundleInfo, b: BundleInfo): number {
  return b.received.localeCompare(a.received) || b.file.localeCompare(a.file);
}

const utf8 = new TextDecoder();

/** Regular files of a tar archive (ustar, as GNU and busybox tar write short names). */
export function parseTar<T extends Uint8Array>(tar: T): Record<string, T> {
  const files: Record<string, T> = {};
  const text = (start: number, len: number) => {
    const raw = tar.subarray(start, start + len);
    const end = raw.indexOf(0);
    return utf8.decode(raw.subarray(0, end < 0 ? len : end));
  };
  for (let pos = 0; pos + 512 <= tar.length;) {
    const name = text(pos, 100);
    if (!name) break; // the all-zero end marker
    const size = parseInt(text(pos + 124, 12).trim(), 8) || 0;
    const type = text(pos + 156, 1);
    if (type === '' || type === '0') {
      files[name.replace(/^\.\//, '')] = tar.subarray(pos + 512, pos + 512 + size) as T;
    }
    pos += 512 + Math.ceil(size / 512) * 512;
  }
  return files;
}

/** The text part of read_diagnostics; the screenshot, if any, goes in an image block after it. */
export function bundleText(info: BundleInfo, files: Record<string, Uint8Array>): string {
  const text = (name: string) => (files[name] ? utf8.decode(files[name]) : undefined);
  const parts = [`${info.device}/${info.file}, received ${info.received}, ${info.size} bytes`];
  parts.push(`--- manifest.json\n${text('manifest.json') ?? '(missing)'}`);
  parts.push(`--- crash.log (new lines only)\n${text('crash.log') || '(no new lines)'}`);
  const snapshot = text('snapshot.json');
  // All lines: unlike a live snapshot, this one cannot be asked for again.
  parts.push(`--- snapshot\n${snapshot ? formatSnapshot(JSON.parse(snapshot) as UiSnapshot, Number.MAX_SAFE_INTEGER).join('\n') : '(missing)'}`);
  return parts.join('\n\n');
}

/** The error text when no bundle matches (an omitted file means "the newest"). */
export function noBundleMessage(device: string, file?: string): string {
  return `no bundle ${file ?? ''} for device ${device}`.replace('  ', ' ');
}
