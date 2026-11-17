"""File names for the Kindle's FAT filesystem."""

from __future__ import annotations

import re
import unicodedata
from urllib.parse import quote

_BAD = re.compile(r'[\\/:*?"<>|\x00-\x1f\x7f]')
MAX_CHARS = 120
EXT = {"doc": ".epub", "epub": ".epub", "pdf": ".pdf"}


def sanitise(title: str, kind: str) -> str:
    ext = EXT[kind]
    name = unicodedata.normalize("NFC", title or "")
    name = _BAD.sub(" ", name)
    name = re.sub(r"\s+", " ", name).strip(" .")
    if name.lower().endswith(ext):
        name = name[: -len(ext)].rstrip(" .")
    name = name[:MAX_CHARS].rstrip(" .")
    return (name or "untitled") + ext


def content_disposition(filename: str) -> str:
    ascii_name = filename.encode("ascii", "replace").decode().replace("?", "_").replace('"', "_")
    return f"attachment; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(filename, safe='')}"


def header_value(filename: str) -> str:
    """X-File-Name is percent-encoded UTF-8, since headers are Latin-1 only."""
    return quote(filename, safe=" ()[]-_.,'!&+")
