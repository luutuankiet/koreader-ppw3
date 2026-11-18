"""Re-encode EPUB images for a 16-level grayscale e-ink screen (Kindle Paperwhite 3, 1072x1448).

Google exports Docs images as full-colour PNGs at their source size; a Kindle then scales and
dithers each one on every page turn. Done once here instead: transparency flattened onto white,
grayscale, autocontrast, then either 16 gray levels in a 4-bit PNG (diagrams, screenshots: few
unique colours) or a grayscale JPEG (photos: many colours, where 16 flat levels would band and JPEG
compresses far better). The display has 16 levels anyway. Nothing is ever upscaled. Photos fit
within the screen; line art fits within twice the screen, because a wide diagram fitted to the
screen ends up about 100 px tall and its text is unreadable even when zoomed in.
"""

from __future__ import annotations

import io

from PIL import Image, ImageOps

SCREEN = (1072, 1448)
LINEART_MAX = (2 * SCREEN[0], 2 * SCREEN[1])  # 2144x2896: keeps diagram text legible when zoomed
AUTOCONTRAST_CUTOFF = 1  # percent of darkest and lightest pixels clipped
PHOTO_COLOURS = 4096  # more unique colours than this in a nearest-neighbour sample = photo
SAMPLE = 256
JPEG_QUALITY = 80
GRAY16 = [v for i in range(16) for v in (i * 17,) * 3]
RASTER_EXT = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp")


def _flatten(im: Image.Image) -> Image.Image:
    if im.mode in ("RGBA", "LA", "PA") or (im.mode == "P" and "transparency" in im.info):
        im = im.convert("RGBA")
        bg = Image.new("RGBA", im.size, (255, 255, 255, 255))
        bg.alpha_composite(im)
        return bg.convert("RGB")
    return im


def _is_photo(im: Image.Image) -> bool:
    small = im.convert("RGB")
    if small.width > SAMPLE or small.height > SAMPLE:
        small = small.resize((min(SAMPLE, small.width), min(SAMPLE, small.height)), Image.NEAREST)
    return small.getcolors(maxcolors=PHOTO_COLOURS) is None


def process_image(data: bytes) -> tuple[bytes, str] | None:
    """Return (new bytes, "png" or "jpeg"), or None to keep the original (undecodable, animated,
    or not smaller after processing)."""
    try:
        im = Image.open(io.BytesIO(data))
        if getattr(im, "n_frames", 1) > 1:
            return None
        if im.format == "JPEG":
            im.draft("RGB", LINEART_MAX)  # decode at reduced scale when the JPEG is much bigger
        im.load()
        im = _flatten(im)
        photo = _is_photo(im)
        g = ImageOps.autocontrast(im.convert("L"), cutoff=AUTOCONTRAST_CUTOFF)
        del im
        box = SCREEN if photo else LINEART_MAX
        if g.width > box[0] or g.height > box[1]:
            g.thumbnail(box, Image.LANCZOS)  # never upscales
        out = io.BytesIO()
        if photo:
            g.save(out, "JPEG", quality=JPEG_QUALITY, optimize=True)
            kind = "jpeg"
        else:
            idx = g.point(lambda v: (v * 15 + 127) // 255)
            p = Image.frombytes("P", idx.size, idx.tobytes())
            p.putpalette(GRAY16)
            p.save(out, "PNG", bits=4)  # optimize=True: 6% smaller but 6 s slower on 78 images
            kind = "png"
    except Exception:  # noqa: BLE001 - any decode or encode failure keeps the original image
        return None
    res = out.getvalue()
    if len(res) >= len(data):
        return None
    return res, kind
