---
title: Plugin deploy pipeline
covers: how a plugin directory gets onto a Kindle, where the gateway reads plugin source, shell fallbacks
verified: 2026-10-28
---

# Plugin deploy pipeline

`deploy_plugin(device, plugin)` in `kindle-gateway/src/gateway-server.ts` (around lines 400-515, a starting point not an address) takes a bare plugin name, reads `<PLUGINS_SRC>/<name>.koplugin/*.lua`, checks the device is online, runs `mkdir -p` and a `/tmp` cleanup on it, writes each file, restarts KOReader and polls device health (10 tries, 5s apart).

- The container mounts the workspace root read-only at `/workspace` and `PLUGINS_SRC` defaults to that. Any `<name>.koplugin/` directory at the root is deployable with no gateway change; an unknown name returns the list of available ones.
- Optional `source`: a folder relative to the workspace root, for example a plugin inside a git worktree: `deploy_plugin {"device":"emu","plugin":"koreader_mcp","source":".claude/worktrees/<name>/koreader_mcp.koplugin"}`. Absolute paths and any `..` that leaves the workspace are refused (`resolvePluginSource` in `kindle-gateway/src/device-commands.ts`). Only top-level `.lua` files are copied either way.
- Destination is `/mnt/us/koreader/plugins/<name>.koplugin` on the device, named by `plugin` even when `source` is set.
- The restart kills whatever listens on the device's registered port (`buildRestartScript`), then `killall luajit`, then runs `koreader.sh`.
- Fallbacks without the gateway: `scripts/deploy-to-kindle.sh` (the MCP plugin) and `scripts/deploy-rssreader.sh` (tarball path for the reader). Both take an SSH alias as argument.

## After a gateway code change

Rebuild with `docker compose build && docker compose up -d` from `kindle-gateway/`. The registry empties on recreate and refills on the next device phone-home, which only happens when WiFi connects or KOReader starts (there is no periodic heartbeat): a sleeping Kindle stays missing until woken, the emulator until its KOReader restarts; the MCP proxy may quarantine changed tools until they are re-approved.

## Always verify by checksum

The returned file list is not proof; compare `md5sum` of the device file with the workspace file. See the silent-truncation trap for why.
