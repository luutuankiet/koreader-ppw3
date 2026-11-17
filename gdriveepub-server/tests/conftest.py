"""Shared test helpers: the synthetic EPUB fixture and a fake Google behind httpx.MockTransport."""

from __future__ import annotations

import base64
import io
import json
import pathlib
import zipfile
from urllib.parse import parse_qs

import httpx
import pytest

FIXTURE = pathlib.Path(__file__).parent / "fixtures" / "synthetic-epub"


def build_epub(root: pathlib.Path = FIXTURE) -> bytes:
    """Zip the fixture folder into an EPUB: `mimetype` first and stored, the rest deflated."""
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), (root / "mimetype").read_bytes(), compress_type=zipfile.ZIP_STORED)
        for path in sorted(root.rglob("*")):
            rel = path.relative_to(root).as_posix()
            if path.is_file() and rel != "mimetype":
                z.writestr(rel, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED)
    return out.getvalue()


@pytest.fixture
def epub_bytes() -> bytes:
    return build_epub()


def id_token(claims: dict) -> str:
    enc = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).decode().rstrip("=")
    return f"{enc({'alg': 'RS256'})}.{enc(claims)}.sig"


class FakeGoogle:
    """Answers the handful of Google endpoints the server calls. Tweak attributes per test."""

    def __init__(self, client_id: str, owner: str, epub: bytes):
        self.claims = {"aud": client_id, "email": owner, "email_verified": True}
        self.epub = epub
        self.dead_refresh = set()
        self.export_too_large = False
        self.files = {
            "doc1": {"id": "doc1", "name": "Plan: Q1/Q2 ünïcode", "mimeType": "application/vnd.google-apps.document",
                     "modifiedTime": "2026-11-01T10:00:00.000Z", "createdTime": "2026-10-01T10:00:00.000Z",
                     "viewedByMeTime": "2026-11-02T10:00:00.000Z"},
            "pdf1": {"id": "pdf1", "name": "Manual.pdf", "mimeType": "application/pdf", "size": "5",
                     "modifiedTime": "2026-11-01T10:00:00.000Z", "createdTime": "2026-10-01T10:00:00.000Z"},
            "sheet1": {"id": "sheet1", "name": "Numbers", "mimeType": "application/vnd.google-apps.spreadsheet",
                       "modifiedTime": "2026-11-01T10:00:00.000Z"},
        }
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        url = request.url
        if url.host == "oauth2.googleapis.com":
            form = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
            if form["grant_type"] == "authorization_code":
                return httpx.Response(200, json={"access_token": "at", "expires_in": 3600,
                                                 "refresh_token": "rt-" + form["code"], "id_token": id_token(self.claims)})
            if form["refresh_token"] in self.dead_refresh:
                return httpx.Response(400, json={"error": "invalid_grant"})
            return httpx.Response(200, json={"access_token": "at", "expires_in": 3600})
        path = url.path.removeprefix("/drive/v3")
        if path == "/files":
            listed = [f for f in self.files.values()]
            return httpx.Response(200, json={"files": listed, "nextPageToken": "next"})
        parts = path.strip("/").split("/")
        f = self.files.get(parts[1]) if len(parts) > 1 else None
        if f is None:
            return httpx.Response(404, json={"error": {"code": 404}})
        if len(parts) == 3 and parts[2] == "export":
            if self.export_too_large:
                return httpx.Response(403, json={"error": {"errors": [{"reason": "exportSizeLimitExceeded"}]}})
            return httpx.Response(200, content=self.epub)
        if url.params.get("alt") == "media":
            return httpx.Response(200, content=b"%PDF-", headers={"content-length": "5"})
        return httpx.Response(200, json=f)
