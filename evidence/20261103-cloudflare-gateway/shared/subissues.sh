#!/usr/bin/env bash
# Creates the spec issue and its sub-issues, then links them as GitHub sub-issues.
set -euo pipefail
cd "$(dirname "$0")"
REPO=luutuankiet/koreader-ppw3

spec_url=$(gh issue create -R "$REPO" --label enhancement \
  --title "Spec: Kindle gateway on Cloudflare (Worker + Durable Object) and a plugin registry on GitHub" \
  --body-file spec.md)
spec=${spec_url##*/}
echo "spec #$spec"

mk() { # title, body
  gh issue create -R "$REPO" --label enhancement --title "$1" --body "Part of #$spec (Kindle gateway on Cloudflare). The spec there has the full facts and decisions.

$2"
}

u1=$(mk "Cloudflare gateway 1: WebSocket client in koreader_mcp and a transport switch" \
'**Goal.** `koreader_mcp` connects to a `wss://` gateway URL with a device key, and still connects over raw TCP when given `host:port`.

- A non-blocking WebSocket client (RFC 6455) on the socket loop `live.lua` already uses: client handshake with `Authorization: Bearer <device key>`, masked text frames out, unmasked text frames in, fragmentation, ping/pong and close. TLS through LuaSec. No new native library; must run on Lua 5.1 / LuaJIT.
- Same messages as today (`hello`, `welcome`/`refused`, calls, replies, ping), one per text frame. Keep the 60 s ping as a text frame with a fixed body so the Worker can auto-answer it.
- Settings: a gateway URL and a device key, set from the existing gateway address dialog (`main.lua:380-392`) and from emulator env vars (`MCP_GATEWAY_URL`, `MCP_GATEWAY_KEY`), next to the existing `MCP_GATEWAY_HOST` / `MCP_GATEWAY_DEVICE_PORT`. A `wss://` or `ws://` URL selects WebSocket; otherwise raw TCP as today.
- Send the device key as a bearer header on the diagnostics upload too (`diagnostics.lua:281-284`; `:62` already redacts `Bearer` values in logs).
- Tests with `luajit test_live.lua`: frame encode and decode, a masked frame round trip, partial reads, handshake rejection (401), and both transports against fakes.

**Done when.** `luajit test_live.lua` passes, and `emu`, pointed at a local `wrangler dev` (sub-issue 2) with `ws://127.0.0.1:8787/device`, shows as connected. The raw TCP path to the thinkpad gateway still works.')

u2=$(mk "Cloudflare gateway 2: Worker and hub Durable Object for the device link" \
'**Goal.** A Worker in `kindle-gateway-worker/` that accepts device WebSockets into one Durable Object, `hub`, which hibernates while idle.

- New package: `package.json`, `wrangler.jsonc` (SQLite-backed Durable Object class, migration), TypeScript, tests with `@cloudflare/vitest-pool-workers`. `wrangler` is a dev dependency only.
- `GET /device`: checks `Authorization: Bearer` against the secret `DEVICE_KEY`, then hands the upgrade to `hub`.
- In `hub`: `ctx.acceptWebSocket` (the Hibernation API, never `ws.accept()`), `setWebSocketAutoResponse` for the device ping, `hello` handling with `welcome` / `refused` for a duplicate name, device identity in `serializeAttachment`, and a registry rebuilt from `ctx.getWebSockets()` after waking.
- A call API used by sub-issue 3: send `{id,method,params}` to a named device and wait for `{id,result|error}` with a timeout; wait for a device to reconnect (60 s) after a restart.
- Import the portable code from `kindle-gateway/src/` (for example `device-commands.ts`) rather than copying it.
- `GET /health` open, returns ok.

**Done when.** Tests cover auth rejection, hello / welcome / refused, a call round trip, a timeout, and a call after the object hibernated and woke. A fake device script can connect to `npx wrangler dev` and answer a call.')

u3=$(mk "Cloudflare gateway 3: MCP tools, agent auth and screenshots on the Worker" \
'**Goal.** `POST /mcp` on the Worker serves every current tool except `deploy_plugin`, stateless, behind the agent key.

- `Authorization: Bearer` checked against the secret `AGENT_KEY` before any MCP work; `401` otherwise.
- Stateless MCP: protocol `2026-07-28` (`server/discover`) and `2025-11-25` (`initialize` answered, no session id ever returned). Use Cloudflare `createMcpHandler` or the MCP SDK web-standard transport, whichever runs cleanly on Workers with the current `@modelcontextprotocol/sdk`.
- Tools from `kindle-gateway/src/gateway-server.ts:72-225` with the same names, schemas and timeouts, calling devices through the hub API from sub-issue 2. Reuse `ui-snapshot.ts` (snapshot ids and stale references) by import.
- Screenshots: replace `sharp` with a WebAssembly encoder inside the object (536x724, grayscale, JPEG q50). Fall back to the original PNG if encoding fails. Check its CPU time on a real screenshot.
- The MCP work runs in the object, not the Worker, because the free Worker gets `10 ms` of CPU per request.

**Done when.** Tests cover agent auth, both protocol versions, and the tool calls against a fake device. With `npx wrangler dev` and `emu` connected (sub-issue 1): `claude mcp add --transport http kindle-dev http://127.0.0.1:8787/mcp --header "Authorization: Bearer <key>"` can list devices, snapshot, tap, take a screenshot (JPEG) and restart KOReader.')

u4=$(mk "Cloudflare gateway 4: diagnostics inbox in R2" \
'**Goal.** Devices upload diagnostics bundles to the Worker, stored in R2, and agents read them with the same two tools.

- `PUT /inbox/<device>/<file>` with the device key, at most 10 MiB, same name rules as `kindle-gateway/src/package-host.ts:45` and `diagnostics.ts`. Stored at R2 key `inbox/<device>/<file>`.
- `list_diagnostics` and `read_diagnostics` read from R2 with the same output shape as today.
- R2 bucket binding in `wrangler.jsonc`; local R2 under `wrangler dev`.

**Done when.** Tests cover auth, the size cap, bad names and a list / read round trip. `emu` uploads a bundle to `wrangler dev` from its menu and the agent reads it back.')

u5=$(mk "Cloudflare gateway 5: plugin registry as a GitHub manifest with Release assets" \
'**Goal.** Plugins are published as GitHub Release assets listed in `registry/index.json`, and "Plugin packages" installs from that manifest.

- Manifest `registry/index.json` on `main`, format 1 plus `url`: entries `name`, `version`, `url` (absolute https), `sha256` (required), `size`, optional `min_koreader`. Served from `https://raw.githubusercontent.com/luutuankiet/koreader-ppw3/main/registry/index.json`.
- `scripts/publish.sh` gains a mode that builds the archive exactly as today, creates the release `<name>-v<version>` with `gh release create` and the archive as its asset, and writes the manifest entry. Publishing to `main` happens by pull request. The local `/pkg/` mode keeps working for the thinkpad gateway.
- `pluginpackages.koplugin`: `Core.parseIndex` (`pluginpackages_core.lua:180-196`) accepts an `https://` `url` and still accepts `file` for the old host; downloads follow the `302` to `release-assets.githubusercontent.com`; certificates are checked with `data/ca-bundle.crt`; the default host (`main.lua:32`) becomes the manifest URL. Self-update keeps working.
- Tests with `luajit test_core.lua` for the new field, rejected URLs (`http://`, odd schemes) and a sha256 mismatch.

**Done when.** One plugin (for example `syncedhistory`) is published as a release with its manifest entry merged, and "Plugin packages" on `emu` installs it from the GitHub manifest with the checksum verified.')

u6=$(mk "Cloudflare gateway 6: deploy to Cloudflare and end to end on emu" \
'**Goal.** The Worker is live at `https://kindle.<domain>` and `emu` is driven through it.

- Needs the owner: a Cloudflare API token (Workers Scripts edit, Workers R2 Storage edit, zone DNS / Workers Routes edit for the custom domain) and the account id, in a gitignored env file read by `wrangler`. No `wrangler login`.
- `wrangler deploy`, `wrangler secret put AGENT_KEY` / `DEVICE_KEY`, R2 bucket created, custom domain attached. Free plan.
- Point `emu` at `wss://kindle.<domain>/device` (after checking on the thinkpad gateway that nobody is using it). Add the agent with `claude mcp add --transport http kindle https://kindle.<domain>/mcp --header "Authorization: Bearer <agent key>"`.
- Run the checks from sub-issues 3 to 5 against the deployed Worker. Leave `emu` idle and connected for 24 hours, then record requests and Durable Object duration from the dashboard or GraphQL analytics.
- Point `emu` back at the thinkpad gateway afterwards unless the owner says otherwise.

**Done when.** The checks pass against the deployed Worker, and the 24 hour numbers are recorded and well inside the free tier.')

u7=$(mk "Cloudflare gateway 7: cutover documentation and decision record" \
'**Goal.** The repo explains the new setup to a cold reader.

- A decision record under `docs/adr/` for the Cloudflare gateway and the GitHub registry, naming what it supersedes in 0005 (device transport) and why (a held socket bills 24/7 on request-billed hosts; a hibernating WebSocket does not).
- Update `docs/architecture/device-bridge.md`, `plugin-installer.md` and `deploy-pipeline.md` (deploy is now through the registry), `emulator/README.md` and `AGENTS.md` (layout, build and check). Run `scripts/gen-docs-index.sh`.
- Steps for the owner to move each Kindle: set the URL and key, install from the registry, and when to retire the thinkpad gateway.

**Done when.** The docs are merged, verified against the running code, and the index is regenerated.')

for u in "$u1" "$u2" "$u3" "$u4" "$u5" "$u6" "$u7"; do
  n=${u##*/}
  id=$(gh api "repos/$REPO/issues/$n" --jq .id)
  gh api -X POST "repos/$REPO/issues/$spec/sub_issues" -F sub_issue_id="$id" --silent
  echo "linked #$n"
done
