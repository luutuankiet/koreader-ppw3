"""Pairing and device keys as pure operations on the state dict.

State shape (one JSON object):
  {"google": {"refresh_token": str, "email": str, "updated_at": float} | absent,
   "device_keys": [{"sha256": hex, "created_at": float}],
   "pairings": {pair_id: {"secret_sha256": hex, "expires_at": float, "status": "pending"|"approved"}}}
Plain device keys are never stored: the key is minted when an approved pairing is polled.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import time

PAIR_TTL = 600
STATE_TTL = 900


def sha(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def prune(state: dict, now: float) -> None:
    pairings = state.setdefault("pairings", {})
    for pid in [p for p, v in pairings.items() if v["expires_at"] <= now]:
        del pairings[pid]


def start(state: dict, now: float) -> tuple[str, str]:
    prune(state, now)
    pair_id = secrets.token_urlsafe(9)
    poll_secret = secrets.token_urlsafe(24)
    state["pairings"][pair_id] = {"secret_sha256": sha(poll_secret), "expires_at": now + PAIR_TTL, "status": "pending"}
    return pair_id, poll_secret


def pending(state: dict, pair_id: str, now: float) -> bool:
    p = state.get("pairings", {}).get(pair_id)
    return bool(p) and p["expires_at"] > now and p["status"] == "pending"


def approve(state: dict, pair_id: str, now: float) -> bool:
    p = state.get("pairings", {}).get(pair_id)
    if not p or p["expires_at"] <= now:
        return False
    p["status"] = "approved"
    return True


def poll(state: dict, pair_id: str, secret: str, now: float) -> dict | None:
    """None = unknown or expired (404). {"status": "forbidden"} = wrong secret."""
    prune(state, now)
    p = state["pairings"].get(pair_id)
    if not p:
        return None
    if not hmac.compare_digest(p["secret_sha256"], sha(secret or "")):
        return {"status": "forbidden"}
    if p["status"] != "approved":
        return {"status": "pending"}
    key = secrets.token_urlsafe(32)
    state.setdefault("device_keys", []).append({"sha256": sha(key), "created_at": now})
    del state["pairings"][pair_id]
    return {"status": "approved", "device_key": key}


def device_ok(state: dict, key: str) -> bool:
    if not key:
        return False
    h = sha(key)
    return any(hmac.compare_digest(d["sha256"], h) for d in state.get("device_keys", []))


# OAuth "state" parameter: signed, so the callback needs no stored session.

def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _unb64(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def sign_state(key: bytes, purpose: str, now: float | None = None) -> str:
    """purpose is "pair:<pair_id>" or "reauth"."""
    now = time.time() if now is None else now
    body = _b64(json.dumps({"p": purpose, "exp": int(now + STATE_TTL), "n": secrets.token_hex(8)}).encode())
    return body + "." + _b64(hmac.new(key, body.encode(), hashlib.sha256).digest())


def verify_state(key: bytes, token: str, now: float | None = None) -> str | None:
    now = time.time() if now is None else now
    try:
        body, sig = token.split(".", 1)
        if not hmac.compare_digest(_unb64(sig), hmac.new(key, body.encode(), hashlib.sha256).digest()):
            return None
        data = json.loads(_unb64(body))
    except (ValueError, TypeError):
        return None
    if data.get("exp", 0) < now:
        return None
    return data.get("p")


def state_key(client_secret: str) -> bytes:
    return hashlib.sha256(b"gdrive-epub-oauth-state:" + client_secret.encode()).digest()
