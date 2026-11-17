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
"""

from __future__ import annotations

import io
import re
import zipfile

from lxml import etree

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


def _is_mono(el) -> bool:
    return bool(MONO.search(dict(_parse_style(el.get("style", ""))).get("font-family", "")))


def _mono_spans(p, with_text: bool) -> bool:
    spans = [s for s in p.iter(f"{{{XHTML}}}span") if not with_text or (s.text or "").strip("\u00a0 ")]
    return bool(spans) and all(_is_mono(s) for s in spans)


def _blank_code_line(p) -> bool:
    """An empty monospace paragraph between two code lines is a blank line inside a code block."""
    prev, nxt = p.getprevious(), p.getnext()
    return (_mono_spans(p, False) and prev is not None and nxt is not None and _tag(prev) == "p"
            and _tag(nxt) == "p" and _mono_spans(prev, True) and _mono_spans(nxt, True))


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


def _is_rule_paragraph(p) -> bool:
    """Docs exports a horizontal rule as an empty paragraph with a visible bottom or top border."""
    st = dict(_parse_style(p.get("style", "")))
    return any(st.get(f"border-{side}-style", "none") not in ("none", "hidden")
               and st.get(f"border-{side}-width", "1pt") not in ("0", "0pt", "0px") for side in ("bottom", "top"))


def clean_xhtml(data: bytes) -> tuple[bytes, dict]:
    parser = etree.XMLParser(resolve_entities=False, no_network=True, huge_tree=True)
    root = etree.fromstring(data, parser)
    stats = {"empty_paragraphs_removed": 0, "code_lines": 0, "images": 0}
    body = root.find("x:body", NS)
    if body is None:
        return data, stats

    head = root.find("x:head", NS)
    google_css = "".join(st.text or "" for st in head.findall("x:style", NS)) if head is not None else ""
    _write_list_markers(body, google_css)

    for p in list(body.iter(f"{{{XHTML}}}p")):
        if _is_empty_block(p) and _is_rule_paragraph(p):
            hr = etree.Element(f"{{{XHTML}}}hr")
            hr.set("class", "gde-hr")
            hr.tail = p.tail
            p.getparent().replace(p, hr)
        elif _is_empty_block(p) and _blank_code_line(p):
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
            mono = _is_mono(el)
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
        style = etree.SubElement(head, f"{{{XHTML}}}style")
        style.set("type", "text/css")
        style.text = CSS
    return etree.tostring(root, xml_declaration=True, encoding="UTF-8"), stats


def clean_epub(data: bytes) -> tuple[bytes, dict]:
    src = zipfile.ZipFile(io.BytesIO(data))
    out = io.BytesIO()
    totals = {"empty_paragraphs_removed": 0, "code_lines": 0, "images": 0, "documents": 0}
    with zipfile.ZipFile(out, "w") as dst:
        names = src.namelist()
        if "mimetype" in names:  # must be first and stored uncompressed
            dst.writestr(zipfile.ZipInfo("mimetype"), src.read("mimetype"), compress_type=zipfile.ZIP_STORED)
        for info in src.infolist():
            if info.filename == "mimetype":
                continue
            body = src.read(info.filename)
            low = info.filename.lower()
            if low.endswith((".xhtml", ".html", ".htm")) and not low.endswith("nav.xhtml"):
                try:
                    body, stats = clean_xhtml(body)
                    totals["documents"] += 1
                    for k, v in stats.items():
                        totals[k] += v
                except etree.XMLSyntaxError:
                    pass  # leave a page we cannot parse exactly as Google wrote it
            dst.writestr(info.filename, body, compress_type=zipfile.ZIP_DEFLATED)
    return out.getvalue(), totals
