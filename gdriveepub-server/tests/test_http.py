"""HTTP-level tests: the real app over Starlette's TestClient, Google faked with httpx.MockTransport."""

from __future__ import annotations

import hashlib
import io
import zipfile
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from starlette.testclient import TestClient

from gdriveepub import pairing
from gdriveepub.app import create_app
from gdriveepub.config import Settings
from gdriveepub.google import Google
from gdriveepub.store import MemoryStore

from conftest import FakeGoogle

BASE = "https://gdrive-epub.example.test"
OWNER = "owner@example.com"
SECOND = "second@example.com"
CLIENT_ID = "test-client.apps.example"


class Env:
    def __init__(self, epub: bytes):
        self.settings = Settings(base_url=BASE, owner_email_sha256=frozenset({hashlib.sha256(OWNER.encode()).hexdigest(), hashlib.sha256(SECOND.encode()).hexdigest()}), client_id=CLIENT_ID, client_secret="test-secret")
        self.store = MemoryStore()
        self.fake = FakeGoogle(CLIENT_ID, OWNER, epub)
        google = Google(CLIENT_ID, "test-secret", transport=httpx.MockTransport(self.fake))
        self.client = TestClient(create_app(self.settings, self.store, google), follow_redirects=False)

    def pair(self, code: str = "c1") -> str:
        """Run the whole pairing flow and return the device key."""
        start = self.client.post("/pair/start").json()
        loc = self.client.get(urlparse(start["url"]).path).headers["location"]
        state = parse_qs(urlparse(loc).query)["state"][0]
        r = self.client.get("/auth/callback", params={"code": code, "state": state})
        assert r.status_code == 200, r.text
        poll = self.client.get(f"/pair/{start['pair_id']}/poll", params={"secret": start["poll_secret"]}).json()
        assert poll["status"] == "approved"
        return poll["device_key"]


@pytest.fixture
def env(epub_bytes) -> Env:
    return Env(epub_bytes)


def auth(key: str) -> dict:
    return {"Authorization": f"Bearer {key}"}


def test_health(env):
    r = env.client.get("/health")
    assert r.status_code == 200 and r.json()["status"] == "ok" and r.json()["version"]


def test_pair_start_shape(env):
    r = env.client.post("/pair/start").json()
    assert set(r) == {"pair_id", "poll_secret", "url", "expires_in"}
    assert r["url"] == f"{BASE}/pair/{r['pair_id']}" and r["expires_in"] == 600


def test_pair_page_redirects_to_google_with_bound_state(env):
    start = env.client.post("/pair/start").json()
    r = env.client.get(f"/pair/{start['pair_id']}")
    assert r.status_code == 302
    loc = urlparse(r.headers["location"])
    q = {k: v[0] for k, v in parse_qs(loc.query).items()}
    assert loc.netloc == "accounts.google.com"
    assert q["client_id"] == CLIENT_ID and q["redirect_uri"] == BASE + "/auth/callback"
    assert "drive.readonly" in q["scope"] and q["access_type"] == "offline" and "login_hint" not in q
    assert pairing.verify_state(pairing.state_key("test-secret"), q["state"]) == "pair:" + start["pair_id"]


def test_pair_flow_end_to_end(env):
    start = env.client.post("/pair/start").json()
    poll = lambda secret: env.client.get(f"/pair/{start['pair_id']}/poll", params={"secret": secret})
    assert poll(start["poll_secret"]).json() == {"status": "pending"}
    assert poll("wrong").status_code == 403 and poll("wrong").json()["error"] == "bad_secret"
    loc = env.client.get(f"/pair/{start['pair_id']}").headers["location"]
    state = parse_qs(urlparse(loc).query)["state"][0]
    r = env.client.get("/auth/callback", params={"code": "abc", "state": state})
    assert r.status_code == 200 and "Kindle paired" in r.text
    first = poll(start["poll_secret"]).json()
    assert first["status"] == "approved" and len(first["device_key"]) > 30
    assert poll(start["poll_secret"]).status_code == 404  # key handed out once
    state_now = env.store.read()
    assert state_now["google"]["refresh_token"] == "rt-abc" and state_now["google"]["email_sha256"] == hashlib.sha256(OWNER.encode()).hexdigest()
    assert OWNER not in str(state_now)  # the signed-in email is stored only as a hash
    assert first["device_key"] not in str(state_now)  # only its hash is stored
    assert env.client.get("/api/status", headers=auth(first["device_key"])).json() == {"google": "ok"}


def test_second_allowed_account_and_case(env):
    env.fake.claims.update({"email": "Second@Example.com"})
    start = env.client.post("/pair/start").json()
    loc = env.client.get(f"/pair/{start['pair_id']}").headers["location"]
    state = parse_qs(urlparse(loc).query)["state"][0]
    r = env.client.get("/auth/callback", params={"code": "abc", "state": state})
    assert r.status_code == 200 and "Kindle paired" in r.text
    assert env.store.read()["google"]["email_sha256"] == hashlib.sha256(SECOND.encode()).hexdigest()


def test_reauth_has_no_login_hint(env):
    r = env.client.get("/reauth")
    assert r.status_code == 302 and "login_hint" not in r.headers["location"]


def test_unknown_pairing(env):
    assert env.client.get("/pair/nope").status_code == 404
    assert env.client.get("/pair/nope/poll", params={"secret": "x"}).json()["error"] == "pairing_expired"


@pytest.mark.parametrize("claims, why", [
    ({"email": "someone@example.com"}, "non-owner email"),
    ({"aud": "other-client"}, "wrong audience"),
    ({"email_verified": False}, "unverified email"),
])
def test_callback_rejects(env, claims, why):
    env.fake.claims.update(claims)
    start = env.client.post("/pair/start").json()
    loc = env.client.get(f"/pair/{start['pair_id']}").headers["location"]
    state = parse_qs(urlparse(loc).query)["state"][0]
    r = env.client.get("/auth/callback", params={"code": "abc", "state": state})
    assert r.status_code == 403, why
    assert "google" not in env.store.read()
    assert env.client.get(f"/pair/{start['pair_id']}/poll", params={"secret": start["poll_secret"]}).json() == \
        {"status": "pending"}


def test_callback_rejects_forged_state(env):
    r = env.client.get("/auth/callback", params={"code": "abc", "state": "forged.state"})
    assert r.status_code == 400
    assert not any(req.url.host == "oauth2.googleapis.com" for req in env.fake.requests)


def test_reauth_renews_token_without_pairing(env):
    key = env.pair("first")
    env.fake.dead_refresh.add("rt-first")
    r = env.client.get("/api/files", headers=auth(key))
    assert r.status_code == 401 and r.json() == {"error": "google_reauth", "signin_url": BASE + "/reauth",
                                                 "message": r.json()["message"]}
    assert env.client.get("/api/status", headers=auth(key)).json() == \
        {"google": "reauth_needed", "signin_url": BASE + "/reauth"}
    loc = env.client.get("/reauth").headers["location"]
    state = parse_qs(urlparse(loc).query)["state"][0]
    r = env.client.get("/auth/callback", params={"code": "second", "state": state})
    assert r.status_code == 200 and "Signed in again" in r.text
    assert env.client.get("/api/files", headers=auth(key)).status_code == 200


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer nope"}, {"Authorization": "Basic x"}])
def test_device_unauthorized(env, headers):
    env.pair()
    for path in ("/api/files", "/api/status", "/api/files/doc1/download"):
        r = env.client.get(path, headers=headers)
        assert r.status_code == 401 and r.json()["error"] == "device_unauthorized"


def test_list_files_filters_kinds(env):
    key = env.pair()
    r = env.client.get("/api/files", headers=auth(key))
    body = r.json()
    assert [f["kind"] for f in body["files"]] == ["doc", "pdf"]  # the spreadsheet is dropped
    assert body["next_page_token"] == "next"
    drive_q = [req for req in env.fake.requests if req.url.path == "/drive/v3/files"][-1].url.params["q"]
    assert "trashed = false" in drive_q


def test_list_files_bad_query(env):
    key = env.pair()
    r = env.client.get("/api/files", params={"view": "search"}, headers=auth(key))
    assert r.status_code == 400 and r.json()["error"] == "bad_request" and r.json()["field"] == "q"


def test_download_doc_is_cleaned_epub(env):
    key = env.pair()
    r = env.client.get("/api/files/doc1/download", headers=auth(key))
    assert r.status_code == 200 and r.headers["content-type"] == "application/epub+zip"
    assert "filename*=UTF-8''" in r.headers["content-disposition"]
    assert r.headers["x-file-name"].endswith(".epub") and "%" in r.headers["x-file-name"]
    assert r.headers["x-modified-time"] == "2026-11-01T10:00:00.000Z"
    doc = zipfile.ZipFile(io.BytesIO(r.content)).read("OEBPS/doc.xhtml")
    assert b"injected by gdrive-epub" in doc


def test_download_pdf_passthrough(env):
    key = env.pair()
    r = env.client.get("/api/files/pdf1/download", headers=auth(key))
    assert r.status_code == 200 and r.content == b"%PDF-" and r.headers["content-type"] == "application/pdf"
    assert r.headers["x-file-name"] == "Manual.pdf"


def test_download_errors(env):
    key = env.pair()
    assert env.client.get("/api/files/missing/download", headers=auth(key)).json()["error"] == "not_found"
    r = env.client.get("/api/files/sheet1/download", headers=auth(key))
    assert r.status_code == 415 and r.json()["error"] == "unsupported"
    env.fake.export_too_large = True
    r = env.client.get("/api/files/doc1/download", headers=auth(key))
    assert r.status_code == 413 and r.json()["error"] == "too_large"


def test_download_serves_raw_export_if_cleanup_fails(env):
    env.fake.epub = b"not a zip"
    key = env.pair()
    r = env.client.get("/api/files/doc1/download", headers=auth(key))
    assert r.status_code == 200 and r.content == b"not a zip"
