---
title: Gateway configuration
summary: environment variables read by the gateway container and where they are set
verified: 2026-10-31
---

# Gateway configuration

Set in `kindle-gateway/.env` (gitignored; copy from `.env.example`), read automatically by `docker compose`.

| variable | default | meaning |
|---|---|---|
| `WORKSPACE_DIR` | `..` (repo root) | host path mounted read-only at `/workspace` |
| `GATEWAY_PORT` | `9999` | port the gateway listens on (host networking) |
| `DEVICE_PORT` | `9990` | port devices dial to hold their connection (host networking, so no port mapping); the LAN must reach it |
| `EINK_DELAY` | `1500` | ms to wait for e-ink refresh before a screenshot |
| `GATEWAY_UID` / `GATEWAY_GID` | `1000` | host user the container runs as, so it can write the inbox and the files it writes are yours |
| `PKG_HOST_DIR` | `../tmp/packages/pkg` (the repo's gitignored `tmp/`; relative paths resolve from `kindle-gateway/`) | host folder of plugin packages, mounted read-only at `/packages`, served at `/pkg/` |
| `INBOX_HOST_DIR` | `../tmp/packages/inbox` | host folder mounted at `/inbox`; device uploads land in `<device>/<file>.tar.gz` |
| `INBOX_MAX_BYTES` | `10485760` (10 MiB) | largest accepted upload; bigger ones get HTTP 413 |

Create both folders as your user before the container starts (`mkdir -p tmp/packages/pkg tmp/packages/inbox` from the repo root): Docker creates a missing bind-mount folder owned by root, and the container, running as `GATEWAY_UID`, then cannot write uploads into it.

`PLUGINS_SRC` is fixed to `/workspace`, `PKG_DIR` to `/packages` and `INBOX_DIR` to `/inbox` inside the container. For a local run outside Docker: `PORT=9998 DEVICE_PORT=9997 npx tsx src/index.ts` (note the gateway process reads `PORT`, compose maps `GATEWAY_PORT` onto it), which avoids disturbing the running instance during iteration.

## On the device

`koreader_mcp.koplugin/config.lua` is optional and holds `device_name`, `gateway_host`, `gateway_port` and `live_mode`. The menu's Rename device and Gateway address write to `<settings>/koreader_mcp.lua` instead, which wins over `config.lua`. The emulator's `config.lua` is rewritten from its environment before each launch (`emulator/README.md`).
