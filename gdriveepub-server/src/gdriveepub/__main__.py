"""Entry point: `gdriveepub` (Cloud Run sets PORT)."""

from __future__ import annotations

import logging
import os
import sys

from .config import ConfigError, load_settings
from .store import FileStore, GcsStore, MemoryStore


def build():
    from .app import create_app

    s = load_settings()
    if s.state_bucket:
        store = GcsStore(s.state_bucket, s.state_object)
    elif s.state_file:
        store = FileStore(s.state_file)
    else:
        store = MemoryStore()
    return create_app(s, store)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s")
    try:
        app = build()
    except ConfigError as e:
        print(f"gdriveepub: {e}", file=sys.stderr)
        sys.exit(2)
    import uvicorn

    uvicorn.run(app, host=os.environ.get("HOST", "0.0.0.0"), port=int(os.environ.get("PORT", "8080")),
                proxy_headers=True, forwarded_allow_ips="*")


if __name__ == "__main__":
    main()
