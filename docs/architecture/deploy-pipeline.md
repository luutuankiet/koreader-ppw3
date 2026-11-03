---
title: Plugin deploy pipeline
covers: how a plugin directory gets onto a Kindle: the GitHub registry (registry/index.json and Releases) read by the on-device installer, deploy_plugin on the LAN fallback gateway, shell fallbacks, the gateway's /pkg/ and the upload inbox
verified: 2026-11-03
---

# Plugin deploy pipeline

The gateway on Cloudflare (`kindle-gateway-worker/`) has no `deploy_plugin`: it has no checkout to read plugin source from. A plugin reaches a device by being published to the GitHub registry and installed with the on-device installer, "Plugin packages" (next section). `deploy_plugin` still exists on the LAN fallback gateway (`kindle-gateway/` on the home server) for a device connected to it, and is how a Kindle gets a `koreader_mcp` that can speak WebSocket before it moves.

## Publish and install through the registry

1. Bump `version = "..."` in the plugin's `_meta.lua`; a version already released is never replaced.
2. `scripts/publish.sh --github <plugin>` builds the archive, creates the GitHub Release `<name>-v<version>` with it attached, and writes the plugin's entry (with `url`, `size`, `sha256`) into `registry/index.json`.
3. Commit `registry/index.json` and merge it to `main`. Devices read the manifest from `main`, so nothing is offered until the merge.
4. On the device: Tools, Plugin packages, tap the plugin, Install, then restart KOReader.

`registry/index.json` lists `pluginpackages` and `syncedhistory` today. `koreader_mcp` and `kosyncserverless` are not in it, so on a device connected to the Cloudflare gateway they can only be updated by publishing them first, over SSH (`scripts/deploy-to-kindle.sh`), or over USB.

## deploy_plugin on the LAN fallback

`deploy_plugin(device, plugin)` in `kindle-gateway/src/gateway-server.ts` (around lines 460-576, a starting point not an address) takes a bare plugin name, reads `<PLUGINS_SRC>/<name>.koplugin/*.lua`, checks the device is connected, runs `mkdir -p` and a `/tmp` cleanup on it, writes each file over the device's connection, restarts KOReader and waits up to 60 s for a new connection under that name.

- The container mounts the workspace root read-only at `/workspace` and `PLUGINS_SRC` defaults to that. Any `<name>.koplugin/` directory at the root is deployable with no gateway change; an unknown name returns the list of available ones.
- Optional `source`: a folder relative to the workspace root, for example a plugin inside a git worktree: `deploy_plugin {"device":"emu","plugin":"koreader_mcp","source":".claude/worktrees/<name>/koreader_mcp.koplugin"}`. Absolute paths and any `..` that leaves the workspace are refused (`resolvePluginSource` in `kindle-gateway/src/device-commands.ts`). Only top-level `.lua` files are copied either way.
- Destination is `/mnt/us/koreader/plugins/<name>.koplugin` on the device, named by `plugin` even when `source` is set.
- The restart (`buildRestartScript`) runs `killall luajit`, then `koreader.sh`. The session resumes at the next start, because `session_open` is still set after a kill.
- Fallbacks without the gateway: `scripts/deploy-to-kindle.sh` (the MCP plugin) and `scripts/deploy-rssreader.sh` (tarball path for the reader). Both take an SSH alias as argument.

## Packages for the on-device installer

Kindles run no agent server, so they pull plugins instead of receiving pushes: from GitHub Releases listed in `registry/index.json` (the installer's default), or from the LAN fallback gateway's `/pkg/`.

- `scripts/publish.sh <plugin>...` (bare name, `<name>.koplugin`, or a path to a `.koplugin` folder such as the separate `rssreader.koplugin` repo) writes `<name>-<version>.tar.gz` into `PKG_DIR` (default `tmp/packages/pkg` in the repo, gitignored, created if missing), then rebuilds `index.json` from every archive there: one entry per plugin, its highest version, with `size`, `sha256`, `description`, `fullname` and `min_koreader` from `_meta.lua`.
- An archive holds only the files git would commit, so gitignored personal config (rssreader's `rssreader_configuration.lua`, which holds credentials) never ships; dotfiles, tests, `*.patch` and `*.md` are dropped too. Its only top-level entry is `<name>.koplugin/`.
- The version is `version = "..."` in `_meta.lua`; a plugin without one is refused. Builds are byte-for-byte reproducible, and changed content under an already-published version is refused unless `--force`: bump the version.
- The gateway serves the folder read-only at `GET /pkg/` and stores `PUT /inbox/<device>/<timestamp>.tar.gz` in `INBOX_HOST_DIR` (gzip only, never overwrites, `INBOX_MAX_BYTES` cap). Both routes live in `kindle-gateway/src/package-host.ts`, mounted in `src/index.ts` ahead of the gateway app, whose JSON body parser would otherwise swallow an upload.
- `scripts/publish.sh --github <plugin>...` builds the same archive into `GH_DIR` (default `tmp/packages/github`, so the gateway's `/pkg/` index never lists it), runs `gh release create <name>-v<version> <archive> --repo luutuankiet/koreader-ppw3`, then adds or replaces that plugin's entry in `registry/index.json` (sorted by name). The entry has `url` `https://github.com/luutuankiet/koreader-ppw3/releases/download/<name>-v<version>/<name>-<version>.tar.gz` instead of `file`; the other fields are the same as in `/pkg/`. The release is created before the entry is written. `--dry-run` prints the `gh` command and writes the entry without calling `gh`. `GH_REPO` and `REGISTRY` override the repository and the manifest path.
- `registry/index.json` reaches devices only once merged to `main`: the installer's default list is `https://raw.githubusercontent.com/luutuankiet/koreader-ppw3/main/registry/index.json`. A release tag's asset is immutable in practice, so ship changes as a new version, never a replaced asset.
- Installing replaces the whole `<name>.koplugin/` folder, so a plugin that keeps user config inside its folder (rssreader does) loses it unless the installer carries those files across.

## After a gateway code change

Cloudflare: from `kindle-gateway-worker/`, `npx wrangler deploy`. The hub object restarts and every device's WebSocket closes; a device in `always` mode dials back within 60 s, a Kindle session retries after 5 s, 15 s and 60 s. Deploying needs a Cloudflare API token in `CLOUDFLARE_API_TOKEN` and the account id in `CLOUDFLARE_ACCOUNT_ID`; the OAuth token of a logged-in `cf` CLI works as the API token and was enough for everything except creating the R2 bucket (R2 must first be enabled in the dashboard). Never write either value into a file in the repo.

LAN fallback: rebuild with `docker compose build && docker compose up -d` from `kindle-gateway/`. The registry empties on recreate and refills as devices in a live session dial back: the emulator keeps retrying every 60 s, a Kindle session gives up after 5 s, 15 s and 60 s and must be started again in its menu. The MCP proxy may quarantine changed tools until they are re-approved.

## Always verify by checksum

The returned file list is not proof; compare `md5sum` of the device file with the workspace file. See the silent-truncation trap for why.
