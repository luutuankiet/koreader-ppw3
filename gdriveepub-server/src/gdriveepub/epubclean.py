"""Light cleanup of Google Docs' EPUB export for a small e-ink screen.

Google writes every style inline: each paragraph carries padding, a fixed height and
font sizes in pt, blank lines become empty paragraphs, code-block lines are one
paragraph each with full spacing, and images get fixed pixel sizes. Inline styles beat
a stylesheet, so the spacing properties are removed from the inline styles and one
small stylesheet is injected. Images, tables, links, lists and emphasis are kept.
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
p, li { margin: 0 0 0.45em 0; padding-top: 0; padding-bottom: 0; }
li > p { margin: 0; }
ul, ol { margin: 0.2em 0 0.5em 0; }
li { margin-bottom: 0.15em; }
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


def clean_xhtml(data: bytes) -> tuple[bytes, dict]:
    parser = etree.XMLParser(resolve_entities=False, no_network=True, huge_tree=True)
    root = etree.fromstring(data, parser)
    stats = {"empty_paragraphs_removed": 0, "code_lines": 0, "images": 0}
    body = root.find("x:body", NS)
    if body is None:
        return data, stats

    for p in list(body.iter(f"{{{XHTML}}}p")):
        if _is_empty_block(p) and _blank_code_line(p):
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

    head = root.find("x:head", NS)
    if head is not None:
        for st in head.findall("x:style", NS):
            if st.text:
                st.text = re.sub(r"@import\s+url\([^)]*\)\s*;?", "", st.text)  # remote fonts: no network on the Kindle
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
