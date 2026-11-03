# koreader-ppw3

Workspace for developing KOReader plugins for Kindle Paperwhite 3 devices, plus an MCP bridge so an agent can deploy to real devices over WiFi, drive the UI and read back screenshots.

## Hard constraints

- KOReader plugins run on Lua 5.1 (LuaJIT). No 5.2+ syntax.
- The Kindle has a weak CPU and a 64MB `/tmp` tmpfs. Measure performance on the device, not only in an emulator.
- `koreader_mcp` is single-threaded Lua on KOReader's UI loop: never route a request back through the device to itself.
- Plugins sit at the workspace root as `<name>.koplugin/`; the gateway deploys any such directory by bare name.
- `rssreader.koplugin/` is its own git repository and is gitignored here.

## Layout

- `koreader_mcp.koplugin/` - agent bridge inside KOReader, dialling out to the gateway during a live session (`handlers.lua` tools, `live.lua` session and connection, `main.lua` entry and menu, `server.lua` JSON codec, `ui_agent.lua` widget snapshot and actions, tests with `luajit test_ui_agent.lua` and `luajit test_live.lua`)
- `kindle-gateway/` - Node/TypeScript MCP relay, now the LAN fallback on the home server (`src/gateway-server.ts` tools, `src/device-link.ts` device connections, `src/device-registry.ts` in-memory registry of connected devices, `src/ui-snapshot.ts` snapshot formatting and stale references)
- `kindle-gateway-worker/` - the gateway on Cloudflare: a Worker in front of one Durable Object (`src/hub.ts`) that holds every device's WebSocket and serves stateless MCP on `/mcp` behind `AGENT_KEY` (`src/mcp.ts` tool groups, `src/tools/` tools, `src/screenshot.ts` photon JPEG encode, `src/inbox.ts` diagnostics upload to R2 on `PUT /inbox/<device>/<file>` behind `DEVICE_KEY`, `src/diagnostics-tools.ts` list and read diagnostics); `npm test` (vitest in workerd), `npx tsc --noEmit`, `scripts/fake-device.mjs` plus `scripts/mcp-client.mjs` against `npx wrangler dev`
- `rssreader.koplugin/` - FreshRSS reader plugin (separate repo)
- `syncedhistory.koplugin/` - synced reading list plugin (map: `docs/architecture/synced-reading-list.md`; each module has a `test_*.lua`, run with `luajit test_<name>.lua`, or `--koreader` from a KOReader install folder for the real md5 and lfs)
- `pluginpackages.koplugin/` - on-device plugin installer with rollback and self-update (map: `docs/architecture/plugin-installer.md`; `pluginpackages_core.lua` does the disk work, tests with `luajit test_core.lua`)
- `emulator/` - KOReader `v2026.07.1` in Docker, permanently connected to the gateway as device `emu` (`emulator/README.md`); its `state/` and `library/` are gitignored
- `scripts/` - shell deploy fallbacks, `publish.sh` (plugin packages: `--github` publishes a GitHub Release and its entry in `registry/index.json`, otherwise the LAN gateway's `/pkg/`) and the docs index generator
- `registry/index.json` - the plugin manifest the on-device installer reads from `main` by default
- `kosettings_backup/` - gitignored device settings backup

## Build and check

- `cd kindle-gateway && npx tsc --noEmit` - typecheck
- `cd kindle-gateway && npm test` - jest suite (registry, client, end to end against a fake Kindle)
- `cd kindle-gateway && docker compose build && docker compose up -d` - rebuild the gateway
- Configuration: copy `kindle-gateway/.env.example` to `kindle-gateway/.env` (gitignored).
- `cd kindle-gateway-worker && npx tsc --noEmit` - typecheck the Worker
- `cd kindle-gateway-worker && npx vitest run` - vitest suite inside workerd (hub, MCP tools, inbox)
- `cd kindle-gateway-worker && npx wrangler dev` - local Worker on `http://127.0.0.1:8787`; keys from `.dev.vars` (copy `.dev.vars.example`, gitignored); drive it with `scripts/fake-device.mjs` and `scripts/mcp-client.mjs`
- `cd kindle-gateway-worker && npx wrangler deploy` - deploy to `https://kindle.kenluu.org`, with `CLOUDFLARE_API_TOKEN` (the `cf` CLI's OAuth token works) and `CLOUDFLARE_ACCOUNT_ID` in the environment, never in a file; keys with `npx wrangler secret put AGENT_KEY` and `DEVICE_KEY`

<!-- Standard block. Everything above belongs to this project; everything below is
     the pointer every repo laid out this way carries. -->

## Documentation

Indexed in [docs/README.md](docs/README.md). Every page is self-contained: it
assumes you opened that one file and have nothing else loaded.

| where | what | read it |
|---|---|---|
| [architecture/](docs/architecture/) | where behaviour lives, one page per area | before going looking for something |
| [traps/](docs/traps/) | failure modes with no error message, indexed by symptom | before debugging something wrong but not crashing |
| [reference/](docs/reference/) | simply true, expensive to re-derive | when you need the detail |
| [adr/](docs/adr/) | why the repo is the way it is | before changing something that looks odd |

## Before you wrap up

Leave the repo holding what this session cost you to find out. Four rules.

1. **Sort it, and expect most of it to go nowhere.** A next action is an issue. A
   durable, expensive-to-re-derive fact is a page. A choice that was hard to
   reverse, surprising without context and a real trade-off is a decision record
   under `docs/adr/`. Status, dates, version pins and plans are none of those -
   delete them.
2. **A doc is the last resort.** Type error, then test, then comment at the site,
   then doc. Name the single line you would have commented instead; if you can
   name it, comment it and stop.
3. **Verify against running code before writing, and date the page `verified:`.**
   Anything remembered from earlier in the session is stale until re-read. Deleting
   a draft because the problem is already fixed is a success.
4. **Append, never rewrite.** Supersede a merged decision record with a new one
   naming what it replaces. A trap filename is an identifier quoted elsewhere:
   edit the body, never the name.

Then run `scripts/gen-docs-index.sh`. Never hand-maintain an index.
