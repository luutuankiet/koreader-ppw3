from datetime import datetime, timezone

import pytest

from gdriveepub import config, driveq, names, pairing

NOW = datetime(2026, 11, 17, 12, 0, tzinfo=timezone.utc)


def test_recent_default_query():
    p = driveq.build_list_params({}, NOW)
    assert "viewedByMeTime > '1970-01-01T00:00:00'" in p["q"]
    assert "trashed = false" in p["q"] and "application/epub+zip" in p["q"]
    assert p["orderBy"] == "viewedByMeTime desc" and p["pageSize"] == "25"


def test_search_escapes_and_has_no_order():
    p = driveq.build_list_params({"view": "search", "q": "it's a\\b", "modified_within": "1w"}, NOW)
    assert "fullText contains 'it\\'s'" in p["q"] and "name contains 'a\\\\b'" in p["q"]
    assert "modifiedTime > '2026-11-10T12:00:00'" in p["q"]
    assert "orderBy" not in p


@pytest.mark.parametrize("args", [{"view": "x"}, {"view": "search"}, {"sort": "size"}, {"created_within": "2y"}, {"page_size": "x"}])
def test_bad_queries(args):
    with pytest.raises(driveq.BadQuery):
        driveq.build_list_params(args, NOW)


def test_to_item_and_sort():
    a = driveq.to_item({"id": "1", "name": "b", "mimeType": "application/pdf", "size": "10", "modifiedTime": "2026-01-02"})
    b = driveq.to_item({"id": "2", "name": "A", "mimeType": "application/vnd.google-apps.document", "modifiedTime": "2026-01-03"})
    assert a["kind"] == "pdf" and a["size"] == 10 and b["size"] is None
    assert [i["id"] for i in driveq.sort_page([a, b], "modified")] == ["2", "1"]
    assert [i["id"] for i in driveq.sort_page([a, b], "name")] == ["2", "1"]


@pytest.mark.parametrize("title,kind,want", [
    ("a/b: c?", "doc", "a b c.epub"), ("report.pdf", "pdf", "report.pdf"), ("  ..", "epub", "untitled.epub"),
    ("Tiếng Việt", "doc", "Tiếng Việt.epub"), ("x" * 300, "pdf", "x" * 120 + ".pdf")])
def test_sanitise(title, kind, want):
    assert names.sanitise(title, kind) == want


def test_header_encoding():
    assert names.header_value("Tiếng.epub") == "Ti%E1%BA%BFng.epub"
    assert "filename*=UTF-8''Ti%E1%BA%BFng.epub" in names.content_disposition("Tiếng.epub")


def test_pairing_flow():
    st = {}
    pid, secret = pairing.start(st, 1000)
    assert pairing.pending(st, pid, 1001)
    assert pairing.poll(st, pid, "wrong", 1001) == {"status": "forbidden"}
    assert pairing.poll(st, pid, secret, 1001) == {"status": "pending"}
    assert pairing.approve(st, pid, 1002)
    r = pairing.poll(st, pid, secret, 1003)
    assert r["status"] == "approved" and pairing.device_ok(st, r["device_key"])
    assert r["device_key"] not in str(st)  # only the hash is stored
    assert pairing.poll(st, pid, secret, 1004) is None  # returned once


def test_pairing_expires():
    st = {}
    pid, secret = pairing.start(st, 0)
    assert not pairing.approve(st, pid, pairing.PAIR_TTL + 1)
    assert pairing.poll(st, pid, secret, pairing.PAIR_TTL + 1) is None


def test_state_token():
    k = pairing.state_key("s")
    t = pairing.sign_state(k, "pair:abc", 100)
    assert pairing.verify_state(k, t, 101) == "pair:abc"
    assert pairing.verify_state(pairing.state_key("other"), t, 101) is None
    assert pairing.verify_state(k, t, 100 + pairing.STATE_TTL + 1) is None
    assert pairing.verify_state(k, "garbage", 101) is None


BASE = {"BASE_URL": "https://x", "OWNER_EMAIL": "Me@Example.com", "GOOGLE_CLIENT_ID": "id", "GOOGLE_CLIENT_SECRET": "s"}


def test_dev_token_refused_on_cloud_run():
    with pytest.raises(config.ConfigError):
        config.load_settings({**BASE, "DEV_ACCESS_TOKEN": "t", "K_SERVICE": "gdrive-epub", "STATE_BUCKET": "b"})
    with pytest.raises(config.ConfigError):
        config.load_settings({**BASE, "DEV_DEVICE_KEY": "k", "K_SERVICE": "gdrive-epub", "STATE_BUCKET": "b"})
    s = config.load_settings({**BASE, "DEV_ACCESS_TOKEN": "t"})
    assert s.owner_email == "me@example.com" and s.redirect_uri == "https://x/auth/callback"
