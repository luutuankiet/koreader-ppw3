"""Settings from the environment. Development-only switches refuse to run on Cloud Run."""

from __future__ import annotations

import hashlib
import os
import re
from dataclasses import dataclass

DEV_ONLY = ("DEV_ACCESS_TOKEN", "DEV_DEVICE_KEY")


class ConfigError(RuntimeError):
    pass


_HEX64 = re.compile(r"[0-9a-f]{64}")


def email_hash(email: str) -> str:
    """SHA-256 hex of a lowercased, stripped email: the form OWNER_EMAIL_SHA256 holds."""
    return hashlib.sha256(email.strip().lower().encode()).hexdigest()


def parse_owner_hashes(value: str) -> frozenset[str]:
    hashes = frozenset(h.strip().lower() for h in value.split(",") if h.strip())
    bad = [h for h in hashes if not _HEX64.fullmatch(h)]
    if bad:
        raise ConfigError("OWNER_EMAIL_SHA256 must be comma-separated SHA-256 hex digests of the allowed emails")
    return hashes


@dataclass(frozen=True)
class Settings:
    base_url: str
    owner_email_sha256: frozenset[str]
    client_id: str
    client_secret: str
    state_bucket: str = ""
    state_object: str = "gdrive-epub/state.json"
    state_file: str = ""
    dev_access_token: str = ""
    dev_quota_project: str = ""
    dev_device_key: str = ""

    def is_owner(self, email: str) -> bool:
        return bool(email.strip()) and email_hash(email) in self.owner_email_sha256

    @property
    def redirect_uri(self) -> str:
        return self.base_url + "/auth/callback"


def load_settings(env: dict[str, str] | None = None) -> Settings:
    env = dict(os.environ if env is None else env)
    on_cloud_run = bool(env.get("K_SERVICE"))
    for name in DEV_ONLY:
        if env.get(name) and on_cloud_run:
            raise ConfigError(f"{name} is for local development only and must not be set on Cloud Run")
    if env.get("OWNER_EMAIL"):
        raise ConfigError("OWNER_EMAIL is no longer read; set OWNER_EMAIL_SHA256 to the SHA-256 of the lowercased email")
    s = Settings(
        base_url=env.get("BASE_URL", "").rstrip("/"),
        owner_email_sha256=parse_owner_hashes(env.get("OWNER_EMAIL_SHA256", "")),
        client_id=env.get("GOOGLE_CLIENT_ID", ""),
        client_secret=env.get("GOOGLE_CLIENT_SECRET", "").strip(),
        state_bucket=env.get("STATE_BUCKET", ""),
        state_object=env.get("STATE_OBJECT", "gdrive-epub/state.json"),
        state_file=env.get("STATE_FILE", ""),
        dev_access_token=env.get("DEV_ACCESS_TOKEN", ""),
        dev_quota_project=env.get("DEV_QUOTA_PROJECT", ""),
        dev_device_key=env.get("DEV_DEVICE_KEY", ""),
    )
    missing = [n for n, v in (("BASE_URL", s.base_url), ("OWNER_EMAIL_SHA256", s.owner_email_sha256)) if not v]
    if not s.dev_access_token:
        missing += [n for n, v in (("GOOGLE_CLIENT_ID", s.client_id), ("GOOGLE_CLIENT_SECRET", s.client_secret)) if not v]
    if missing:
        raise ConfigError("missing settings: " + ", ".join(missing))
    if on_cloud_run and not s.state_bucket:
        raise ConfigError("STATE_BUCKET is required on Cloud Run")
    return s
