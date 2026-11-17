"""Settings from the environment. Development-only switches refuse to run on Cloud Run."""

from __future__ import annotations

import os
from dataclasses import dataclass

DEV_ONLY = ("DEV_ACCESS_TOKEN", "DEV_DEVICE_KEY")


class ConfigError(RuntimeError):
    pass


@dataclass(frozen=True)
class Settings:
    base_url: str
    owner_email: str
    client_id: str
    client_secret: str
    state_bucket: str = ""
    state_object: str = "gdrive-epub/state.json"
    state_file: str = ""
    dev_access_token: str = ""
    dev_quota_project: str = ""
    dev_device_key: str = ""

    @property
    def redirect_uri(self) -> str:
        return self.base_url + "/auth/callback"


def load_settings(env: dict[str, str] | None = None) -> Settings:
    env = dict(os.environ if env is None else env)
    on_cloud_run = bool(env.get("K_SERVICE"))
    for name in DEV_ONLY:
        if env.get(name) and on_cloud_run:
            raise ConfigError(f"{name} is for local development only and must not be set on Cloud Run")
    s = Settings(
        base_url=env.get("BASE_URL", "").rstrip("/"),
        owner_email=env.get("OWNER_EMAIL", "").strip().lower(),
        client_id=env.get("GOOGLE_CLIENT_ID", ""),
        client_secret=env.get("GOOGLE_CLIENT_SECRET", "").strip(),
        state_bucket=env.get("STATE_BUCKET", ""),
        state_object=env.get("STATE_OBJECT", "gdrive-epub/state.json"),
        state_file=env.get("STATE_FILE", ""),
        dev_access_token=env.get("DEV_ACCESS_TOKEN", ""),
        dev_quota_project=env.get("DEV_QUOTA_PROJECT", ""),
        dev_device_key=env.get("DEV_DEVICE_KEY", ""),
    )
    missing = [n for n, v in (("BASE_URL", s.base_url), ("OWNER_EMAIL", s.owner_email)) if not v]
    if not s.dev_access_token:
        missing += [n for n, v in (("GOOGLE_CLIENT_ID", s.client_id), ("GOOGLE_CLIENT_SECRET", s.client_secret)) if not v]
    if missing:
        raise ConfigError("missing settings: " + ", ".join(missing))
    if on_cloud_run and not s.state_bucket:
        raise ConfigError("STATE_BUCKET is required on Cloud Run")
    return s
