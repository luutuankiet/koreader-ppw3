# KOReader emulator (Kindle Paperwhite 3 shape)

Official KOReader `v2026.07.1` Linux x86_64 release under Xvfb, 1072x1448 at 300 dpi,
installed at the Kindle's paths so the gateway's deploy and restart work unchanged.

## Run

```sh
cd emulator
mkdir -p state/koreader-home library   # create as your user before the first start
docker compose up -d --build           # start (rebuilds on change)
docker compose logs -f                 # supervisor + KOReader log
docker compose down                    # stop
```

The emulator opens no port for the agent: `koreader_mcp` dials out to the gateway and
stays connected. To see that it is up, call the gateway's `list_devices`; `emu` is listed
exactly while its connection is open. No connection appears in `docker compose logs` as
`[MCP] live mode connection lost: connect failed: connection refused`, 5 s and then 15 s
after the loss, then every 60 s; `[MCP] live mode online as emu` marks it back.

Screenshot of the virtual screen (until koreader_mcp's own screenshot works here):

```sh
docker exec koreader-emu sh -c 'xwd -root -silent -display "$DISPLAY" | convert xwd:- png:-' > screen.png
```

## Layout

| container path | what | host |
|---|---|---|
| `/mnt/us/koreader` | KOReader install, built-in plugins, `koreader_mcp.koplugin` | image (deploys land here, lost on recreate) |
| `/mnt/us/koreader-home` | `KO_HOME`: `settings.reader.lua`, `settings/kosync.lua`, history, cache | `emulator/state/koreader-home/` (gitignored) |
| `/mnt/us/documents` | home folder, test books | `emulator/library/` (gitignored) |

- First start copies `seed/` into an empty `KO_HOME`: home folder `/mnt/us/documents`,
  quickstart guide off, and the built-in progress sync on the file-name method
  (`checksum_method = 1`) with no server or account. Delete `state/koreader-home` to reseed.
- `supervisor.sh` is the entrypoint: starts Xvfb on `:73`, then relaunches
  `./luajit ./reader.lua` 2 s after every exit. It rewrites
  `koreader_mcp.koplugin/config.lua` before each launch from the variables below (set
  in `docker-compose.yml`), so a gateway deploy of `koreader_mcp` keeps these values.

  | variable | default | what |
  |---|---|---|
  | `MCP_LIVE_MODE` | `always` | `always`: stay connected, never end on idle or battery, keep retrying. `off`: no connection and no timers, as a Kindle outside a session |
  | `MCP_DEVICE_NAME` | `emu` | name in `list_devices` |
  | `MCP_GATEWAY_HOST` | `127.0.0.1` | gateway host to dial |
  | `MCP_GATEWAY_DEVICE_PORT` | `9990` | the gateway's `DEVICE_PORT` |
  | `MCP_GATEWAY_URL` | unset | a `ws://` or `wss://` gateway URL; when set the bridge speaks WebSocket to it and ignores host and port |
  | `MCP_GATEWAY_KEY` | unset | device key sent as `Authorization: Bearer` on the WebSocket handshake and the diagnostics upload |

  Two ways to reach a gateway, chosen by whether `MCP_GATEWAY_URL` is set:

  | to reach | set | transport |
  |---|---|---|
  | the Cloudflare gateway | `MCP_GATEWAY_URL: "wss://kindle.kenluu.org/device"`, `MCP_GATEWAY_KEY: "<device key>"` | WebSocket over TLS, certificate checked |
  | a local `npx wrangler dev` | `MCP_GATEWAY_URL: "ws://127.0.0.1:8787/device"`, `MCP_GATEWAY_KEY` matching `DEVICE_KEY` in `.dev.vars` | WebSocket, no TLS |
  | the LAN gateway on the home server | `MCP_GATEWAY_URL` unset or empty, `MCP_GATEWAY_HOST` and `MCP_GATEWAY_DEVICE_PORT` | raw TCP, newline-delimited JSON, no key |

  `docker-compose.yml` is committed, so a key set there must never be committed with it;
  the settings file below lives under the gitignored `state/` and is the safer place. The variables
  are read by `supervisor.sh`, which is baked into the image: a container built before
  `MCP_GATEWAY_URL` existed ignores it, so rebuild (`docker compose up -d --build`) after
  pulling. To switch without a rebuild, write `gateway_url` and `gateway_key` into
  `state/koreader-home/settings/koreader_mcp.lua`, which beats `config.lua`; delete the
  file and restart KOReader to go back. A host and port saved from the Agent bridge menu
  also beat a URL from `config.lua`.

- No `fbgrab` here: `capture_screenshot` falls back to KOReader's own `Screen:shot`.
- `/mnt/us/koreader/koreader.sh` is a no-op shim: the gateway restart runs
  `killall luajit; ./koreader.sh`, and the supervisor already relaunches.
- Host networking, so `127.0.0.1` reaches a gateway on the same host. Display `:73`
  because X's abstract socket is shared with the host's network namespace.
- The `vnc` service shows the screen live and accepts input, with no password:
  VNC client at `thinkpad:5973`, browser at `http://thinkpad:6073/` (5900 is taken
  on the thinkpad). It waits for `:73` itself, so start it alone with
  `docker compose up -d --build --no-deps vnc` without recreating the emulator.
