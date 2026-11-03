import { PhotonImage, SamplingFilter, grayscale, resize } from '@cf-wasm/photon/workerd';

/** Half of the Paperwhite 3's 1072x1448 screen, as the Node gateway's sharp pipeline. */
export const SCREENSHOT_WIDTH = 536;
export const SCREENSHOT_HEIGHT = 724;
export const SCREENSHOT_JPEG_QUALITY = 50;

export interface EncodedImage {
  data: string;
  mimeType: string;
}

/**
 * Resize a device screenshot (base64 PNG) to 536x724 grayscale JPEG q50 with photon, a Rust
 * image library compiled to WebAssembly (sharp is native and does not run on Workers). About
 * 110 KB of PNG becomes about 20 KB of JPEG. On any failure the original PNG is returned, as
 * the Node gateway does.
 */
export function resizeScreenshot(base64Png: string): EncodedImage {
  let img: PhotonImage | undefined;
  let small: PhotonImage | undefined;
  try {
    img = PhotonImage.new_from_byteslice(base64ToBytes(base64Png));
    small = resize(img, SCREENSHOT_WIDTH, SCREENSHOT_HEIGHT, SamplingFilter.Triangle);
    grayscale(small);
    return { data: bytesToBase64(small.get_bytes_jpeg(SCREENSHOT_JPEG_QUALITY)), mimeType: 'image/jpeg' };
  } catch (err) {
    console.warn(`[resize] failed, returning the original PNG: ${String(err)}`);
    return { data: base64Png, mimeType: 'image/png' };
  } finally {
    // WebAssembly memory is not garbage collected: free both images explicitly.
    small?.free();
    img?.free();
  }
}

export function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function bytesToBase64(bytes: Uint8Array): string {
  let bin = '';
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    bin += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(bin);
}
