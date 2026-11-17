import io
import zipfile

from lxml import etree

from gdriveepub.epubclean import clean_epub

X = "{http://www.w3.org/1999/xhtml}"


def cleaned_doc(epub: bytes):
    out, stats = clean_epub(epub)
    z = zipfile.ZipFile(io.BytesIO(out))
    return z, etree.fromstring(z.read("OEBPS/doc.xhtml")), stats


def test_zip_layout_kept(epub_bytes):
    z, _, _ = cleaned_doc(epub_bytes)
    first = z.infolist()[0]
    assert first.filename == "mimetype" and first.compress_type == zipfile.ZIP_STORED
    assert z.read("mimetype") == b"application/epub+zip"
    assert z.read("OEBPS/images/dot.png") == zipfile.ZipFile(io.BytesIO(epub_bytes)).read("OEBPS/images/dot.png")
    assert z.read("OEBPS/nav.xhtml") == zipfile.ZipFile(io.BytesIO(epub_bytes)).read("OEBPS/nav.xhtml")


def test_stats(epub_bytes):
    _, _, stats = cleaned_doc(epub_bytes)
    assert stats == {"empty_paragraphs_removed": 2, "code_lines": 3, "images": 1, "documents": 1}


def test_empty_paragraphs_dropped_and_text_kept(epub_bytes):
    _, root, _ = cleaned_doc(epub_bytes)
    text = "".join(root.itertext())
    for s in ("Heading one", "Bold intro", "def hello():", "Bullet one", "Cell", "After the code."):
        assert s in text
    paras = [p for p in root.iter(X + "p") if "gde-code" not in (p.get("class") or "")]
    assert all("".join(p.itertext()).strip() or p.find(".//" + X + "img") is not None for p in paras)


def test_code_lines_marked(epub_bytes):
    _, root, _ = cleaned_doc(epub_bytes)
    code = [p for p in root.iter(X + "p") if "gde-code" in (p.get("class") or "")]
    assert ["".join(p.itertext()) for p in code] == ["def hello():", "\u00a0", "    return 1"]
    assert "gde-code-last" in code[-1].get("class") and "gde-code-last" not in code[0].get("class")


def test_inline_spacing_removed_other_styles_kept(epub_bytes):
    _, root, _ = cleaned_doc(epub_bytes)
    styles = " ".join(el.get("style") or "" for el in root.iter())
    for prop in ("padding-top", "height:11pt", "font-size", "font-family", "line-height"):
        assert prop not in styles
    assert "font-weight:700" in styles.replace(" ", "")
    assert "text-align:left" in styles.replace(" ", "")
    assert "border:1px solid #000" in styles


def test_images_unpinned_remote_import_removed_css_injected(epub_bytes):
    _, root, _ = cleaned_doc(epub_bytes)
    img = next(root.iter(X + "img"))
    assert "style" not in img.attrib and img.get("src") == "images/dot.png"
    head_css = "".join(s.text or "" for s in root.find(X + "head").iter(X + "style"))
    assert "@import" not in head_css and "googleusercontent" not in head_css
    assert "injected by gdrive-epub" in head_css


def test_bad_page_left_alone():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("mimetype", "application/epub+zip")
        z.writestr("OEBPS/broken.xhtml", "<html><body><p>unclosed")
    out, stats = clean_epub(buf.getvalue())
    assert zipfile.ZipFile(io.BytesIO(out)).read("OEBPS/broken.xhtml") == b"<html><body><p>unclosed"
    assert stats["documents"] == 0


def test_blank_line_inside_code_kept_but_not_after_it():
    import io as _io
    page = (b'<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head/><body>'
            b'<p><span style="font-family:Courier">a</span></p>'
            b'<p><span style="font-family:Courier"/></p>'
            b'<p><span style="font-family:Courier">b</span></p>'
            b'<p><span style="font-family:Courier"/></p>'
            b'<p><span>prose</span></p></body></html>')
    from gdriveepub.epubclean import clean_xhtml
    out, stats = clean_xhtml(page)
    assert stats["code_lines"] == 3 and stats["empty_paragraphs_removed"] == 1


def _li_texts(root):
    return ["".join(li.itertext()) for li in root.iter(f"{X}li")]


def test_list_numbers_written_into_the_text(epub_bytes):
    # Google numbers lists with CSS counters in li:before; KOReader does not evaluate counter(),
    # so only the ". " was left. The cleanup writes each marker into the item as text.
    _, root, _ = cleaned_doc(epub_bytes)
    texts = _li_texts(root)
    assert texts[:5] == ["1. Number one", "2. Number two", "a. Letter a", "3. Number three", "● Dot item"]
    style = "".join(s.text or "" for s in root.iter(f"{X}style"))
    assert "li:before" not in style and "counter(" not in style


def test_horizontal_rule_kept(epub_bytes):
    # Docs exports a horizontal rule as an empty paragraph with a bottom border.
    _, root, _ = cleaned_doc(epub_bytes)
    hrs = list(root.iter(f"{X}hr"))
    assert len(hrs) == 1
    assert etree.QName(hrs[0].getnext()).localname == "ol"
