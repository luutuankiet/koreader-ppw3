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

- No `fbgrab` here: `capture_screenshot` falls back to KOReader's own `Screen:shot`.
- `/mnt/us/koreader/koreader.sh` is a no-op shim: the gateway restart runs
  `killall luajit; ./koreader.sh`, and the supervisor already relaunches.
- Host networking, so `127.0.0.1` reaches a gateway on the same host. Display `:73`
  because X's abstract socket is shared with the host's network namespace.
- The `vnc` service shows the screen live and accepts input, with no password:
  VNC client at `thinkpad:5973`, browser at `http://thinkpad:6073/` (5900 is taken
  on the thinkpad). It waits for `:73` itself, so start it alone with
  `docker compose up -d --build --no-deps vnc` without recreating the emulator.
