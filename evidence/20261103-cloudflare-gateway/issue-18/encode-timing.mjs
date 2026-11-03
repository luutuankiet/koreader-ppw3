// CPU time of the screenshot encode (photon wasm, same steps as src/screenshot.ts) in Node.
//   node encode-timing.mjs <photon-node-entry> <png> [runs]
import { readFileSync } from 'node:fs';
const [entry, pngPath, runs = '10'] = process.argv.slice(2);
const { PhotonImage, SamplingFilter, grayscale, resize } = await import(entry);
const bytes = new Uint8Array(readFileSync(pngPath));
const times = [];
let out = 0;
for (let i = 0; i < Number(runs); i++) {
  const c0 = process.cpuUsage();
  const img = PhotonImage.new_from_byteslice(bytes);
  const small = resize(img, 536, 724, SamplingFilter.Triangle);
  grayscale(small);
  out = small.get_bytes_jpeg(50).length;
  small.free(); img.free();
  const c = process.cpuUsage(c0);
  times.push(((c.user + c.system) / 1000).toFixed(1));
}
console.log(`input ${bytes.length} bytes PNG -> ${out} bytes JPEG; CPU ms per encode: ${times.join(' ')}`);
