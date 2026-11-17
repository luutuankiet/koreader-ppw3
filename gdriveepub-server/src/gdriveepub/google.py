"""Google OAuth and Drive v3 calls over httpx. The transport is injectable for tests."""

from __future__ import annotations

import base64
import json
import time
from urllib.parse import urlencode

import httpx

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
DRIVE = "https://www.googleapis.com/drive/v3"
SCOPES = "openid email https://www.googleapis.com/auth/drive.readonly"
EXPORT_LIMIT = 10 * 1024 * 1024
EPUB = "application/epub+zip"
# The export link (what Drive's "Download as" uses) has no 10 MB cap, but Google can take
# 30 s or more to build a big EPUB before the first byte, so its read timeout is long.
LINK_TIMEOUT = httpx.Timeout(600, connect=10)
LINK_HOSTS = {"docs.google.com", "www.googleapis.com"}
CHUNK = 1024 * 1024


class ReauthNeeded(Exception):
    """The stored refresh token is missing, expired or revoked."""


class TooLarge(Exception):
    pass


class GoogleError(Exception):
    def __init__(self, status: int, body: str):
        super().__init__(f"Google returned {status}: {body[:300]}")
        self.status = status
        self.body = body


def auth_url(client_id: str, redirect_uri: str, state: str) -> str:
    q = {"client_id": client_id, "redirect_uri": redirect_uri, "response_type": "code", "scope": SCOPES,
         "access_type": "offline", "prompt": "consent", "state": state}
    return AUTH_URL + "?" + urlencode(q)


def id_token_claims(id_token: str) -> dict:
    """Claims of an id_token received directly from Google's token endpoint over TLS.

    OpenID Connect Core 3.1.3.7 allows skipping the signature check in that case; the
    audience is still checked by the caller.
    """
    payload = id_token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))


class Google:
    def __init__(self, client_id: str, client_secret: str, transport: httpx.AsyncBaseTransport | None = None,
                 quota_project: str = ""):
        self.client_id = client_id
        self.client_secret = client_secret
        self.http = httpx.AsyncClient(transport=transport, timeout=httpx.Timeout(60, connect=10))
        self.quota_project = quota_project
        self._cache: tuple[str, str, float] | None = None  # (refresh_token, access_token, expires_at)

    async def exchange_code(self, code: str, redirect_uri: str) -> dict:
        r = await self.http.post(TOKEN_URL, data={"code": code, "client_id": self.client_id,
                                                  "client_secret": self.client_secret,
                                                  "redirect_uri": redirect_uri, "grant_type": "authorization_code"})
        if r.status_code != 200:
            raise GoogleError(r.status_code, r.text)
        return r.json()

    async def access_token(self, refresh_token: str | None) -> str:
        if not refresh_token:
            raise ReauthNeeded()
        c = self._cache
        if c and c[0] == refresh_token and c[2] > time.time() + 60:
            return c[1]
        r = await self.http.post(TOKEN_URL, data={"refresh_token": refresh_token, "client_id": self.client_id,
                                                  "client_secret": self.client_secret, "grant_type": "refresh_token"})
        if r.status_code != 200:
            if r.status_code in (400, 401) and "invalid_grant" in r.text:
                raise ReauthNeeded()
            raise GoogleError(r.status_code, r.text)
        data = r.json()
        self._cache = (refresh_token, data["access_token"], time.time() + int(data.get("expires_in", 3600)))
        return data["access_token"]

    def _headers(self, token: str) -> dict:
        h = {"Authorization": f"Bearer {token}"}
        if self.quota_project:
            h["x-goog-user-project"] = self.quota_project
        return h

    async def list_files(self, token: str, params: dict) -> dict:
        r = await self.http.get(DRIVE + "/files", params=params, headers=self._headers(token))
        if r.status_code == 401:
            raise ReauthNeeded()
        if r.status_code != 200:
            raise GoogleError(r.status_code, r.text)
        return r.json()

    async def get_meta(self, token: str, file_id: str) -> dict:
        r = await self.http.get(f"{DRIVE}/files/{file_id}", headers=self._headers(token),
                                params={"fields": "id,name,mimeType,modifiedTime,size,trashed,exportLinks",
                                        "supportsAllDrives": "true"})
        if r.status_code == 401:
            raise ReauthNeeded()
        if r.status_code != 200:
            raise GoogleError(r.status_code, r.text)
        return r.json()

    async def export_epub(self, token: str, file_id: str) -> bytes:
        """`files.export` as EPUB. Raises TooLarge past Google's 10 MB export cap."""
        r = await self.http.get(f"{DRIVE}/files/{file_id}/export", headers=self._headers(token),
                                params={"mimeType": EPUB})
        if r.status_code == 401:
            raise ReauthNeeded()
        if r.status_code == 403 and "exportSizeLimitExceeded" in r.text:
            raise TooLarge()
        if r.status_code != 200:
            raise GoogleError(r.status_code, r.text)
        if len(r.content) > EXPORT_LIMIT:
            raise TooLarge()
        return r.content

    async def download_export_link(self, token: str, url: str, fh) -> int:
        """Stream an `exportLinks` URL into the open binary file `fh`; returns the byte count.

        Google answers with a redirect to a signed download host; httpx drops the
        Authorization header when a redirect leaves the origin, which that host does not need.
        """
        host = httpx.URL(url).host
        if httpx.URL(url).scheme != "https" or host not in LINK_HOSTS:
            raise GoogleError(502, f"unexpected export link host {host}")
        req = self.http.build_request("GET", url, headers=self._headers(token), timeout=LINK_TIMEOUT)
        r = await self.http.send(req, stream=True, follow_redirects=True)
        try:
            if r.status_code != 200:
                body = (await r.aread()).decode(errors="replace")
                if r.status_code == 401:
                    raise ReauthNeeded()
                raise GoogleError(r.status_code, body)
            n = 0
            async for chunk in r.aiter_bytes(CHUNK):
                fh.write(chunk)
                n += len(chunk)
            return n
        finally:
            await r.aclose()

    async def open_media(self, token: str, file_id: str) -> httpx.Response:
        req = self.http.build_request("GET", f"{DRIVE}/files/{file_id}", headers=self._headers(token),
                                      params={"alt": "media", "supportsAllDrives": "true"})
        r = await self.http.send(req, stream=True)
        if r.status_code != 200:
            body = (await r.aread()).decode(errors="replace")
            await r.aclose()
            if r.status_code == 401:
                raise ReauthNeeded()
            raise GoogleError(r.status_code, body)
        return r
