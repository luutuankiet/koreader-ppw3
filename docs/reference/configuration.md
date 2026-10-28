---
title: Gateway configuration
summary: environment variables read by the gateway container and where they are set
verified: 2026-10-28
---

# Gateway configuration

Set in `kindle-gateway/.env` (gitignored; copy from `.env.example`), read automatically by `docker compose`.

| variable | default | meaning |
|---|---|---|
| `WORKSPACE_DIR` | `..` (repo root) | host path mounted read-only at `/workspace` |
| `GATEWAY_PORT` | `9999` | port the gateway listens on (host networking) |
| `EINK_DELAY` | `1500` | ms to wait for e-ink refresh before a screenshot |

`PLUGINS_SRC` is fixed to `/workspace` inside the container. For a local run outside Docker: `PORT=9998 npx tsx src/index.ts` (note the gateway process reads `PORT`, compose maps `GATEWAY_PORT` onto it), which avoids disturbing the running instance during iteration.
