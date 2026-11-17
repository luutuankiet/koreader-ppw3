"""Link unwrapping and e-ink image processing, on synthetic EPUBs only."""

import io
import random
import zipfile

from lxml import etree
from PIL import Image

from gdriveepub.einkimg import process_image
from gdriveepub.epubclean import clean_epub

X = "{http://www.w3.org/1999/xhtml}"
OPF = "{http://www.idpf.org/2007/opf}"

PAGE = """<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head><body>
<p id="p1">See <a href="https://example.com/a?b=1"><span>the site</span></a> now.</p>
<p><a href="https://www.google.com/url?q=https://example.org&amp;sa=D">redirect</a>
 <a href="mailto:someone@example.com">mail</a> <a href="ftp://example.net/x">ftp</a></p>
<p><a href="#h1">jump</a> <a href="other.xhtml#n2">footnote</a> <a id="anchor"></a> https://bare.example.com</p>
<p><img src="images/photo.png" alt="p"/><img src="images/flat.png" alt="f"/><img src="images/bad.png" alt="b"/>
<img src="images/pic.svg" alt="s"/></p>
</body></html>"""

OPF_DOC = """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0"><manifest>
<item id="doc" href="doc.xhtml" media-type="application/xhtml+xml"/>
<item id="i1" href="images/photo.png" media-type="image/png"/>
<item id="i2" href="images/flat.png" media-type="image/png"/>
<item id="i3" href="images/bad.png" media-type="image/png"/>
<item id="i4" href="images/pic.svg" media-type="image/svg+xml"/>
</manifest><spine><itemref idref="doc"/></spine></package>"""

NAV = b'<html xmlns="http://www.w3.org/1999/xhtml"><body><nav><a href="https://x.example">x</a></nav></body></html>'
SVG = b'<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>'


def png(im) -> bytes:
    out = io.BytesIO()
    im.save(out, "PNG")
    return out.getvalue()


def photo_png(w=2000, h=1500) -> bytes:
    rnd = random.Random(1)
    im = Image.frombytes("RGB", (w, h), rnd.randbytes(w * h * 3))
    return png(im)


def flat_png() -> bytes:
    im = Image.new("RGBA", (600, 400), (0, 0, 0, 0))  # transparent background
    for x in range(100, 300):
        for y in range(100, 200):
            im.putpixel((x, y), (200, 30, 30, 255))
    return png(im)


def make_epub(images: dict) -> bytes:
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), b"application/epub+zip")
        z.writestr("OEBPS/content.opf", OPF_DOC)
        z.writestr("OEBPS/doc.xhtml", PAGE)
        z.writestr("OEBPS/nav.xhtml", NAV)
        for name, data in images.items():
            z.writestr("OEBPS/images/" + name, data)
    return out.getvalue()


def run():
    src = make_epub({"photo.png": photo_png(), "flat.png": flat_png(), "bad.png": b"not an image", "pic.svg": SVG})
    out, stats = clean_epub(src)
    return zipfile.ZipFile(io.BytesIO(out)), stats


def test_external_links_unwrapped_internal_kept():
    z, stats = run()
    root = etree.fromstring(z.read("OEBPS/doc.xhtml"))
    hrefs = [a.get("href") for a in root.iter(X + "a") if a.get("href")]
    assert hrefs == ["#h1", "other.xhtml#n2"]
    spans = [s for s in root.iter(X + "span") if s.get("class") == "gde-link"]
    assert ["".join(s.itertext()) for s in spans] == ["the site", "redirect", "mail", "ftp"]
    assert stats["links_unwrapped"] == 4
    p1 = root.find(f".//{X}p[@id='p1']")
    assert "".join(p1.itertext()) == "See the site now."
    assert any(a.get("id") == "anchor" for a in root.iter(X + "a"))
    assert "https://bare.example.com" in "".join(root.itertext())
    assert b"text-decoration: underline" in z.read("OEBPS/doc.xhtml")
    assert z.read("OEBPS/nav.xhtml") == NAV


def test_photo_becomes_grayscale_jpeg_within_screen_and_renamed():
    z, stats = run()
    assert "OEBPS/images/photo.png" not in z.namelist()
    im = Image.open(io.BytesIO(z.read("OEBPS/images/photo.jpg")))
    assert im.format == "JPEG" and im.mode == "L"
    assert im.size == (1072, 804)  # 2000x1500 fitted to 1072 wide, aspect kept
    opf = etree.fromstring(z.read("OEBPS/content.opf"))
    items = {i.get("id"): (i.get("href"), i.get("media-type")) for i in opf.iter(OPF + "item")}
    assert items["i1"] == ("images/photo.jpg", "image/jpeg")
    assert items["i2"] == ("images/flat.png", "image/png")
    srcs = [i.get("src") for i in etree.fromstring(z.read("OEBPS/doc.xhtml")).iter(X + "img")]
    assert srcs == ["images/photo.jpg", "images/flat.png", "images/bad.png", "images/pic.svg"]
    assert stats["images_processed"] == 2 and stats["image_bytes_after"] < stats["image_bytes_before"]


def test_flat_image_is_16_gray_png_on_white_not_upscaled():
    z, _ = run()
    im = Image.open(io.BytesIO(z.read("OEBPS/images/flat.png")))
    assert im.format == "PNG" and im.size == (600, 400)
    g = im.convert("L")
    assert len(g.getcolors()) <= 16
    assert g.getpixel((10, 10)) == 255  # transparency flattened onto white
    assert g.getpixel((150, 150)) < 128


def test_undecodable_and_svg_kept_byte_for_byte():
    z, _ = run()
    assert z.read("OEBPS/images/bad.png") == b"not an image"
    assert z.read("OEBPS/images/pic.svg") == SVG
    assert z.infolist()[0].filename == "mimetype"


def test_small_image_never_upscaled_or_grown():
    tiny = png(Image.new("RGB", (4, 4), (10, 200, 10)))
    res = process_image(tiny)
    assert res is None or Image.open(io.BytesIO(res[0])).size == (4, 4)
    assert process_image(b"garbage") is None
