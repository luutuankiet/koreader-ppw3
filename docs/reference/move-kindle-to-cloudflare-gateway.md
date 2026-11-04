---
title: Moving a Kindle to the Cloudflare gateway
summary: give a Kindle a koreader_mcp that speaks WebSocket, point it at wss://kindle.kenluu.org/device with the device key, install plugins from the GitHub registry, connect an agent, and when the home server's LAN gateway can be retired
verified: 2026-11-04
---

# Moving a Kindle to the Cloudflare gateway

The gateway that agents use to reach a Kindle now runs on Cloudflare at
`https://kindle.kenluu.org`. Devices connect to `wss://kindle.kenluu.org/device`
with a device key; agents call `https://kindle.kenluu.org/mcp` with an agent key.
The old gateway in Docker on the home server (raw TCP on port 9990, MCP on
9999, no keys) keeps working on the LAN until it is retired. Both keys are the
Worker secrets `DEVICE_KEY` and `AGENT_KEY`; the owner keeps their values
outside the repo. Below they are written `<device key>` and `<agent key>`.

## 1. Give the Kindle a koreader_mcp that speaks WebSocket

The Kindle needs `koreader_mcp.koplugin` with `ws.lua` (version 0.3.1 or later
in `_meta.lua`). Any one of these gets it there:

- on the Kindle, Tools, **Plugin packages**, with **Package host** empty (step
  3): install or upgrade `koreader_mcp`, then restart KOReader. The new code
  loads only after the restart, so turn Live mode off first;
- with a live session open on the Kindle, call `deploy_plugin` with
  `{"device":"<kindle name>","plugin":"koreader_mcp"}` on the LAN gateway, from
  a checkout of `main`; or
- over SSH, `scripts/deploy-to-kindle.sh <ssh alias>`, then restart KOReader.
  Leave out its optional second argument: it overwrites the plugin's
  `config.lua` with an old-style `gateway_url = "http://..."`, which is not a
  WebSocket URL.

Check: Agent bridge in the main menu (network tab) shows a **Device key** row.
That row only exists in a version with WebSocket support.

## 2. Point the bridge at the Cloudflare gateway

On the Kindle, main menu, network tab, **Agent bridge**:

1. **Gateway address**: enter `wss://kindle.kenluu.org/device`, path included.
   A URL is saved as `gateway_url` and removes any saved `host:port`.
2. **Device key**: enter `<device key>`.
3. Turn **Live mode** on, or off and on again if it was running.

Both values land in `koreader/settings/koreader_mcp.lua` and survive plugin
upgrades. Send diagnostics then goes to `https://kindle.kenluu.org/inbox/...`
with the same key.

How to tell it worked:

| what you see | means |
|---|---|
| `list_devices` on the Cloudflare gateway lists the Kindle | connected; `remoteAddress` is your network's public address |
| `crash.log` has `[MCP] live mode online as <name>` | connected |
| a Kindle session ends at once; in `always` mode, `live mode rejected` and a 300 s wait | the key was refused (401); re-enter it |
| retries after 5 s, 15 s, 60 s, then the session ends | no network path, or a TLS failure; the Kindle checks the certificate against `data/ca-bundle.crt` in the KOReader folder |

To go back to the LAN gateway, enter `<home server address>:9990` as the
Gateway address.

## 3. Install plugins from the registry

On the Kindle: Tools, **Plugin packages**. Leave **Package host** empty: the
installer then reads `registry/index.json` from the `main` branch on GitHub
and downloads archives from GitHub Releases, checking size and sha256. A
Package host of `http://<home server>:9999/pkg/` stops working when the LAN
gateway is retired, so clear it. Clearing it needs pluginpackages 0.2.1 or
later; earlier versions ignore an empty Save. A plugin reaches the registry by
`scripts/publish.sh --github <plugin>` and the manifest change merged to
`main`; `registry/index.json` is the list of what is there.

## 4. Connect an agent

```sh
claude mcp add --transport http kindle https://kindle.kenluu.org/mcp --header "Authorization: Bearer <agent key>"
```

## 5. When to retire the LAN gateway on the home server

Not before all of these hold:

1. Every Kindle and the emulator connect to the Cloudflare gateway (steps 1
   and 2; the emulator's settings are in `emulator/README.md`).
2. Send diagnostics works on the Cloudflare gateway. This already holds: the
   R2 bucket `kindle-gateway-inbox` is bound as `INBOX`, its lifecycle rule
   `expire-30d` deletes bundles after 30 days, and the Worker refuses an
   upload with 507 once 200 bundles are stored (2 GB at most, inside R2's
   10 GB free storage). Check with
   `npx wrangler r2 bucket lifecycle list kindle-gateway-inbox` from
   `kindle-gateway-worker/`.
3. A 24 hour idle measurement with a device connected confirms the cost.
   Only 17 minutes have been measured so far: 0.00484 GB-s of Durable Object
   duration and 3 Durable Object requests (the hub's 5 minute sweep alarm), 0
   billed WebSocket messages. Read the same numbers for a full day from
   Cloudflare's GraphQL analytics (`durableObjectsPeriodicGroups` for
   duration and WebSocket messages, `durableObjectsInvocationsAdaptiveGroups`
   for requests, `workersInvocationsAdaptive` for Worker requests). The free
   plan allows 13,000 GB-s and 100,000 requests a day.
4. Nothing still needs `deploy_plugin` or `/pkg/`; both exist only on the LAN
   gateway.
