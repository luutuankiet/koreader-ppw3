"""Run the 0.5.0 epubclean on the cached raw export; print EPUB size and the largest decoded image."""
import io, sys, time, zipfile
from PIL import Image
from gdriveepub import __version__
from gdriveepub.epubclean import clean_epub
D, out_path = sys.argv[1], sys.argv[2]
t = time.time(); out, stats = clean_epub(open(f"{D}/raw/raw.epub", "rb").read())
open(out_path, "wb").write(out)
print("version", __version__, "epub_bytes", len(out), "secs", round(time.time() - t, 1), stats)
z = zipfile.ZipFile(io.BytesIO(out)); rows = []
for n in z.namelist():
    if n.lower().endswith((".png", ".jpg", ".jpeg")):
        im = Image.open(io.BytesIO(z.read(n))); rows.append((im.width * im.height, n, im.size, im.format, im.mode))
rows.sort(reverse=True)
print("images", len(rows))
for px, n, size, fmt, mode in rows[:5]:
    print(f"{n.split('/')[-1]:14s} {size[0]}x{size[1]} {fmt} {mode} decoded_8bit_MB={px/1e6:.2f}")
