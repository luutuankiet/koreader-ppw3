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
curl -s http://thinkpad:8889/health    # koreader_mcp, from any tailnet host
```

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
  `koreader_mcp.koplugin/config.lua` before each launch from `MCP_PORT` (8889),
  `MCP_DEVICE_NAME` (`emu`), `MCP_GATEWAY_URL` and `MCP_ADVERTISE_HOST` (set in
  `docker-compose.yml`). `MCP_ADVERTISE_HOST=thinkpad` makes it register as
  `thinkpad:8889` instead of the LAN IP koreader_mcp discovers.
- No `fbgrab` here: `capture_screenshot` falls back to KOReader's own `Screen:shot`.
- `/mnt/us/koreader/koreader.sh` is a no-op shim: the gateway restart runs
  kills the process on the device's port, then `killall luajit; ./koreader.sh`, and the
  supervisor already relaunches.
- Host networking: 8888 is taken on the thinkpad, hence 8889. Display `:73` because
  X's abstract socket is shared with the host's network namespace.
- The `vnc` service shows the screen live and accepts input, with no password:
  VNC client at `thinkpad:5973`, browser at `http://thinkpad:6073/` (5900 is taken
  on the thinkpad). It waits for `:73` itself, so start it alone with
  `docker compose up -d --build --no-deps vnc` without recreating the emulator.
