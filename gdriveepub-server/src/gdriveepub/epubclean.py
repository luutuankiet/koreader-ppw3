"""Light cleanup of Google Docs' EPUB export for a small e-ink screen.

Google writes every style inline: each paragraph carries padding, a fixed height and
font sizes in pt, blank lines become empty paragraphs, code-block lines are one
paragraph each with full spacing, and images get fixed pixel sizes. Inline styles beat
a stylesheet, so the spacing properties are removed from the inline styles and one
small stylesheet is injected. Images, tables, links, lists and emphasis are kept.

Google numbers lists with CSS counters (`li:before { content: counter(...) ". " }`). KOReader's
engine does not evaluate counter(), so it showed only the ". ". The markers are computed here and
written into each list item as text, and the li:before rules are removed. A horizontal rule is
exported as an empty paragraph with a bottom border; it becomes an <hr> instead of being dropped.

A Kindle cannot follow a web link, and a tap on one only gets in the way of turning the page, so
every external link (http, https, mailto, Google's google.com/url redirects, any other scheme)
becomes an underlined <span class="gde-link">; links inside the book (#anchors, other EPUB files:
the table of contents, heading links, footnotes) stay. Images are re-encoded for e-ink by einkimg;
a photo becomes a .jpg, so the manifest and every <img src> are renamed to match.
"""

from __future__ import annotations

import io
import posixpath
import re
import zipfile
from urllib.parse import unquote

from lxml import etree

from .einkimg import RASTER_EXT, process_image

XHTML = "http://www.w3.org/1999/xhtml"
NS = {"x": XHTML}
MONO = re.compile(r"mono|courier|consolas|menlo|source code|inconsolata|fira code", re.I)

# Inline properties removed per element kind; anything not listed is kept.
DROP_BLOCK = {"padding-top", "padding-bottom", "padding-right", "margin", "margin-top", "margin-bottom",
              "height", "line-height", "font-size", "font-family", "orphans", "widows"}
DROP_SPAN = {"font-size", "font-family", "line-height"}
DROP_IMG_WRAPPER = {"overflow", "display", "margin", "border", "transform", "-webkit-transform", "width", "height"}
DROP_CELL = {"width", "padding"}

CSS = """
/* injected by gdrive-epub */
body { margin: 0; padding: 0 0.2em; line-height: 1.3; }
p, li { margin: 0 0 0.6em 0; padding-top: 0; padding-bottom: 0; }
li > p { margin: 0; }
ul, ol { margin: 0.2em 0 0.6em 0; list-style-type: none; }
li { margin-bottom: 0.35em; }
hr.gde-hr { border: 0; border-top: 1px solid #888; margin: 0.6em 0; height: 0; }
h1 { font-size: 1.6em; margin: 0.6em 0 0.35em 0; }
h2 { font-size: 1.35em; margin: 0.8em 0 0.3em 0; }
h3 { font-size: 1.15em; margin: 0.7em 0 0.25em 0; }
h4, h5, h6 { font-size: 1em; margin: 0.6em 0 0.2em 0; }
h1, h2, h3, h4, h5, h6 { line-height: 1.2; padding: 0; }
.gde-mono { font-family: monospace; }
p.gde-code { font-family: monospace; font-size: 0.85em; line-height: 1.25; margin: 0; }
p.gde-code span { white-space: pre-wrap; }
p.gde-code-last { margin-bottom: 0.5em; }
table { border-collapse: collapse; margin: 0.3em 0 0.6em 0; width: 100%; }
td, th { padding: 0.15em 0.3em; vertical-align: top; overflow-wrap: anywhere; word-wrap: break-word; }
td p, th p { margin: 0; }
img { max-width: 100%; height: auto; }
.gde-link { text-decoration: underline; }
"""


def _parse_style(s: str) -> list[tuple[str, str]]:
    out = []
    for part in s.split(";"):
        if ":" in part:
            k, v = part.split(":", 1)
            out.append((k.strip().lower(), v.strip()))
    return out


def _restyle(el, drop: set[str], extra_keep=None) -> list[tuple[str, str]]:
    props = _parse_style(el.get("style", ""))
    kept = [(k, v) for k, v in props if k not in drop or (extra_keep and extra_keep(k, v))]
    if kept:
        el.set("style", ";".join(f"{k}:{v}" for k, v in kept))
    elif "style" in el.attrib:
        del el.attrib["style"]
    return props


def _add_class(el, cls: str) -> None:
    el.set("class", (el.get("class", "") + " " + cls).strip())


def _tag(el) -> str:
    return etree.QName(el).localname if isinstance(el.tag, str) else ""


def _is_empty_block(p) -> bool:
    if (p.text or "").strip("  \t\r\n"):
        return False
    for d in p.iterdescendants():
        if _tag(d) not in ("span", "br", "a") or (d.text or "").strip("  \t\r\n") or (d.tail or "").strip("  \t\r\n"):
            return False
        if _tag(d) == "a" and d.get("id"):  # bookmark anchors are link targets
            return False
    return True


RULE = re.compile(r"([^{}@]+)\{([^{}]*)\}")
SIMPLE_CLASS = re.compile(r"^\.([\w-]+)$")
# Some Docs exports carry no inline style at all and put everything in class rules in <head>
# (.c0{font-size:12pt}); a size in pt ignores the reader's font size setting, so these go too.
DROP_RULE = DROP_BLOCK | DROP_SPAN

def _class_styles(css: str) -> dict[str, list[tuple[str, str]]]:
    """Declarations of each simple class rule (.c12{...}), so a class-styled export is read like an inline one."""
    out: dict[str, list[tuple[str, str]]] = {}
    for sel, body in RULE.findall(css):
        m = SIMPLE_CLASS.match(sel.strip())
        if m:
            out.setdefault(m.group(1), []).extend(_parse_style(body))
    return out


def _strip_rules(css: str) -> str:
    def fix(m):
        kept = [(k, v) for k, v in _parse_style(m.group(2)) if k not in DROP_RULE]
        return m.group(1) + "{" + ";".join(f"{k}:{v}" for k, v in kept) + "}"
    return RULE.sub(fix, css)


def _style(el, classes: dict) -> dict[str, str]:
    """Class rules first, then the inline style on top, as the cascade would."""
    props = []
    for cls in (el.get("class") or "").split():
        props.extend(classes.get(cls, ()))
    props.extend(_parse_style(el.get("style", "")))
    return dict(props)


def _is_mono(el, classes: dict) -> bool:
    return bool(MONO.search(_style(el, classes).get("font-family", "")))


def _mono_spans(p, with_text: bool, classes: dict) -> bool:
    spans = [s for s in p.iter(f"{{{XHTML}}}span") if not with_text or (s.text or "").strip("\u00a0 ")]
    return bool(spans) and all(_is_mono(s, classes) for s in spans)


def _blank_code_line(p, classes: dict) -> bool:
    """An empty monospace paragraph between two code lines is a blank line inside a code block."""
    prev, nxt = p.getprevious(), p.getnext()
    return (_mono_spans(p, False, classes) and prev is not None and nxt is not None and _tag(prev) == "p"
            and _tag(nxt) == "p" and _mono_spans(prev, True, classes) and _mono_spans(nxt, True, classes))


MARKER_RULE = re.compile(r"\.(lst-[\w-]+)\s*>\s*li:before\s*\{([^}]*)\}")
BEFORE_RULE = re.compile(r"[^{}]*li:before\s*\{[^}]*\}")
CONTENT_TOKEN = re.compile(r'"((?:[^"\\]|\\.)*)"|counter\(\s*([\w-]+)\s*(?:,\s*([\w-]+)\s*)?\)')
ROMAN = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
         (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]


def _css_string(s: str) -> str:
    s = re.sub(r"\\([0-9a-fA-F]{1,6}) ?", lambda m: chr(int(m.group(1), 16)), s)
    return re.sub(r"\\(.)", r"\1", s)


def _counter_text(n: int, style: str | None) -> str:
    style = (style or "decimal").lower()
    if style in ("lower-latin", "lower-alpha", "upper-latin", "upper-alpha"):
        out = ""
        while n > 0:
            n, r = divmod(n - 1, 26)
            out = chr(97 + r) + out
        return out.upper() if style.startswith("upper") else out
    if style in ("lower-roman", "upper-roman") and 0 < n < 4000:
        out = ""
        for v, sym in ROMAN:
            while n >= v:
                out, n = out + sym, n - v
        return out.upper() if style.startswith("upper") else out
    return str(n)


def _marker_rules(css: str) -> dict[str, list]:
    """Map a Google list class (lst-kix_<id>-<level>) to its li:before content tokens."""
    rules = {}
    for cls, body in MARKER_RULE.findall(css):
        m = re.search(r"content\s*:\s*(.*)", body, re.S)
        if m:
            rules[cls] = [(_css_string(a), None, None) if c == "" else (None, c, st)
                          for a, c, st in CONTENT_TOKEN.findall(m.group(1))]
    return rules


def _write_list_markers(body, css: str) -> int:
    rules = _marker_rules(css)
    counters: dict[str, int] = {}
    written = 0
    for lst in body.iter(f"{{{XHTML}}}ol", f"{{{XHTML}}}ul"):
        classes = (lst.get("class") or "").split()
        cls = next((c for c in classes if c in rules), None)
        if cls is None:
            continue
        name = "lst-ctn-" + cls[len("lst-"):]
        if "start" in classes or name not in counters:
            try:
                counters[name] = int(lst.get("start", "1")) - 1
            except ValueError:
                counters[name] = 0
        for li in lst.findall("x:li", NS):
            counters[name] += 1
            text = "".join(lit if lit is not None else _counter_text(counters.get(c, 0), st)
                           for lit, c, st in rules[cls]).strip()
            if not text:
                continue
            span = etree.Element(f"{{{XHTML}}}span")
            span.set("class", "gde-marker")
            span.text = text + " "
            span.tail, li.text = li.text, None
            li.insert(0, span)
            written += 1
    return written


def _is_rule_paragraph(p, classes: dict) -> bool:
    """Docs exports a horizontal rule as an empty paragraph with a visible bottom or top border."""
    st = _style(p, classes)
    return any(st.get(f"border-{side}-style", "none") not in ("none", "hidden")
               and st.get(f"border-{side}-width", "1pt") not in ("0", "0pt", "0px") for side in ("bottom", "top"))


SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")


def _is_external(href: str) -> bool:
    href = href.strip()
    return bool(SCHEME.match(href)) or href.startswith("//")


def _unwrap_links(body) -> int:
    n = 0
    for a in list(body.iter(f"{{{XHTML}}}a")):
        href = a.get("href")
        if href is None or not _is_external(href):
            continue
        span = etree.Element(f"{{{XHTML}}}span")
        span.set("class", "gde-link")
        if a.get("id"):
            span.set("id", a.get("id"))
        span.text, span.tail = a.text, a.tail
        for child in a:
            span.append(child)
        a.getparent().replace(a, span)
        n += 1
    return n


def _renamed(href: str, base_dir: str, renames: dict) -> str | None:
    """New href if `href` (relative to `base_dir` in the zip) points at a renamed file."""
    if not href or _is_external(href) or href.startswith("#"):
        return None
    path, frag = (href.split("#", 1) + [""])[:2]
    target = posixpath.normpath(posixpath.join(base_dir, unquote(path)))
    new = renames.get(target)
    if new is None:
        return None
    old_ext, new_ext = posixpath.splitext(target)[1], posixpath.splitext(new)[1]
    return path[: len(path) - len(old_ext)] + new_ext + (("#" + frag) if frag else "")


def clean_xhtml(data: bytes, renames: dict | None = None, base_dir: str = "") -> tuple[bytes, dict]:
    parser = etree.XMLParser(resolve_entities=False, no_network=True, huge_tree=True)
    root = etree.fromstring(data, parser)
    stats = {"empty_paragraphs_removed": 0, "code_lines": 0, "images": 0, "links_unwrapped": 0}
    body = root.find("x:body", NS)
    if body is None:
        return data, stats
    stats["links_unwrapped"] = _unwrap_links(body)
    if renames:
        for img in body.iter(f"{{{XHTML}}}img"):
            new = _renamed(img.get("src", ""), base_dir, renames)
            if new:
                img.set("src", new)

    head = root.find("x:head", NS)
    google_css = "".join(st.text or "" for st in head.findall("x:style", NS)) if head is not None else ""
    classes = _class_styles(google_css)
    _write_list_markers(body, google_css)

    for p in list(body.iter(f"{{{XHTML}}}p")):
        if _is_empty_block(p) and _is_rule_paragraph(p, classes):
            hr = etree.Element(f"{{{XHTML}}}hr")
            hr.set("class", "gde-hr")
            hr.tail = p.tail
            p.getparent().replace(p, hr)
        elif _is_empty_block(p) and _blank_code_line(p, classes):
            _add_class(p, "gde-code")
            span = next(p.iter(f"{{{XHTML}}}span"))
            span.text = "\u00a0"
        elif _is_empty_block(p):
            parent = p.getparent()
            if p.tail and p.tail.strip():
                prev = p.getprevious()
                if prev is not None:
                    prev.tail = (prev.tail or "") + p.tail
                else:
                    parent.text = (parent.text or "") + p.tail
            parent.remove(p)
            stats["empty_paragraphs_removed"] += 1

    for el in body.iter():
        t = _tag(el)
        if t == "span":
            if el.find("x:img", NS) is not None:
                _restyle(el, DROP_IMG_WRAPPER)
                continue
            mono = _is_mono(el, classes)
            _restyle(el, DROP_SPAN)
            if mono:
                _add_class(el, "gde-mono")
        elif t in ("p", "li", "h1", "h2", "h3", "h4", "h5", "h6"):
            _restyle(el, DROP_BLOCK)
        elif t == "img":
            stats["images"] += 1
            if "style" in el.attrib:
                del el.attrib["style"]
        elif t in ("td", "th"):
            _restyle(el, DROP_CELL)
        elif t == "body":
            _restyle(el, {"padding", "max-width"})

    # A paragraph whose every non-blank span is monospace is a code line.
    paras = list(body.iter(f"{{{XHTML}}}p"))
    code = []
    for p in paras:
        spans = [s for s in p.iter(f"{{{XHTML}}}span") if (s.text or "").strip("  ")]
        if "gde-code" in (p.get("class") or ""):  # blank code line kept above
            code.append(p)
        elif spans and all("gde-mono" in (s.get("class") or "") for s in spans) and not (p.text or "").strip():
            _add_class(p, "gde-code")
            code.append(p)
    for p in code:
        nxt = p.getnext()
        if nxt is None or "gde-code" not in (nxt.get("class") or ""):
            _add_class(p, "gde-code-last")
    stats["code_lines"] = len(code)

    if head is not None:
        for st in head.findall("x:style", NS):
            if st.text:
                st.text = re.sub(r"@import\s+url\([^)]*\)\s*;?", "", st.text)  # remote fonts: no network on the Kindle
                st.text = BEFORE_RULE.sub("", st.text)  # markers are now real text
                st.text = _strip_rules(st.text)
        style = etree.SubElement(head, f"{{{XHTML}}}style")
        style.set("type", "text/css")
        style.text = CSS
    return etree.tostring(root, xml_declaration=True, encoding="UTF-8"), stats


# Already compressed; deflating them again costs seconds on a big doc and saves almost nothing.
STORED_EXT = (".png", ".jpg", ".jpeg", ".gif", ".webp")
OPF = "http://www.idpf.org/2007/opf"


def _rewrite_opf(data: bytes, base_dir: str, renames: dict) -> bytes:
    root = etree.fromstring(data, etree.XMLParser(resolve_entities=False, no_network=True))
    for item in root.iter(f"{{{OPF}}}item"):
        new = _renamed(item.get("href", ""), base_dir, renames)
        if new:
            item.set("href", new)
            item.set("media-type", "image/jpeg")
    return etree.tostring(root, xml_declaration=True, encoding="UTF-8")


def _images(zsrc, zdst, names: list[str], totals: dict) -> dict:
    """Re-encode every raster image, one at a time, writing it to `zdst`. Returns {old: new} renames."""
    renames, taken = {}, set(names)
    for name in names:
        if not name.lower().endswith(RASTER_EXT):
            continue
        data = zsrc.read(name)
        totals["image_bytes_before"] += len(data)
        res = process_image(data)
        new = name
        if res is not None:
            data, kind = res
            totals["images_processed"] += 1
            if kind == "jpeg" and not name.lower().endswith((".jpg", ".jpeg")):
                stem, i = posixpath.splitext(name)[0], 0
                new = stem + ".jpg"
                while new in taken:
                    i += 1
                    new = f"{stem}-{i}.jpg"
                taken.add(new)
                renames[name] = new
        totals["image_bytes_after"] += len(data)
        zdst.writestr(new, data, compress_type=zipfile.ZIP_STORED)
        del data
    return renames


def clean_epub_file(src, dst) -> dict:
    """Clean the EPUB at `src` (path or seekable binary file) into `dst` (path or binary file).

    Entries are read and written one at a time, so only one entry is in memory at once. Images go
    first, so the pages and the manifest can be rewritten for any image whose extension changed.
    """
    totals = {"empty_paragraphs_removed": 0, "code_lines": 0, "images": 0, "links_unwrapped": 0, "documents": 0,
              "images_processed": 0, "image_bytes_before": 0, "image_bytes_after": 0}
    with zipfile.ZipFile(src) as zsrc, zipfile.ZipFile(dst, "w") as zdst:
        names = zsrc.namelist()
        if "mimetype" in names:  # must be first and stored uncompressed
            zdst.writestr(zipfile.ZipInfo("mimetype"), zsrc.read("mimetype"), compress_type=zipfile.ZIP_STORED)
        renames = _images(zsrc, zdst, names, totals)
        for info in zsrc.infolist():
            low = info.filename.lower()
            if info.filename == "mimetype" or low.endswith(RASTER_EXT):
                continue
            body = zsrc.read(info.filename)
            base_dir = posixpath.dirname(info.filename)
            if low.endswith((".xhtml", ".html", ".htm")) and not low.endswith("nav.xhtml"):
                try:
                    body, stats = clean_xhtml(body, renames, base_dir)
                    totals["documents"] += 1
                    for k, v in stats.items():
                        totals[k] += v
                except etree.XMLSyntaxError:
                    pass  # leave a page we cannot parse exactly as Google wrote it
            elif low.endswith(".opf") and renames:
                try:
                    body = _rewrite_opf(body, base_dir, renames)
                except etree.XMLSyntaxError:
                    pass
            method = zipfile.ZIP_STORED if low.endswith(STORED_EXT) else zipfile.ZIP_DEFLATED
            zdst.writestr(info.filename, body, compress_type=method)
            del body
    return totals


def clean_epub(data: bytes) -> tuple[bytes, dict]:
    out = io.BytesIO()
    totals = clean_epub_file(io.BytesIO(data), out)
    return out.getvalue(), totals
