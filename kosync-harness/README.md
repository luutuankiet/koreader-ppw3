# kosync harness

A local progress sync server that behaves like a cold Cloud Run instance, for
testing a cold-start tolerant sync client on the emulator.

- `kosyncd` is built from the omv-move repo's `kosync-serverless/kosyncd/`
  source (read only; set `KOSYNCD_SRC` if it lives elsewhere) and starts on an
  empty SQLite file in `data/`. Registration is on.
- `proxy` (`proxy/delayproxy.py`, Python standard library only) sits in front.
  The first request after `IDLE_S` seconds without traffic is held `HOLD_S`
  seconds before it is forwarded. Requests that arrive during that hold wait for
  the same hold to end, as on Cloud Run, where one instance boots and every
  queued request waits for it. The proxy starts cold.

`kosyncd` itself starts in about 0.2 s here, so the proxy hold is the whole
simulated cold start. A real cold start of the Cloud Run service is dominated by
the Litestream restore from B2.

## Start

```sh
cd kosync-harness
docker compose up -d --build        # HOLD_S=12 IDLE_S=60 by default
HOLD_S=20 docker compose up -d      # other defaults at start
```

| URL | what |
|---|---|
| `http://127.0.0.1:17200` | proxy: the sync server URL for clients |
| `http://127.0.0.1:17201` | `kosyncd` direct, never held |

Both ports bind to `127.0.0.1` (`HARNESS_BIND`, `PROXY_PORT`, `KOSYNCD_PORT`
change that). The emulator container `koreader-emu` uses host networking, so it
reaches the proxy at `http://127.0.0.1:17200`: put that in the emulator's
`settings/kosync.lua` as `custom_server`, then restart KOReader (the built-in
plugin reads that file once per process). Restarting through the gateway fails
while the emulator shows the Sleep screen; send the `Resume` event first.

`data/` and `logs/` are gitignored and written by root from the containers.
Delete `data/` for a fresh database. Every route needs the header
`accept: application/vnd.koreader.v1+json`; a register body sends the md5 of
the password, as KOReader does.

## Control at runtime

Control routes start with `/_harness/`, are never forwarded and never count as
traffic. GET or POST both work.

```sh
curl -s 127.0.0.1:17200/_harness/state                 # phase cold|booting|warm, config
curl -s 127.0.0.1:17200/_harness/cold                  # next request starts a hold
curl -s 127.0.0.1:17200/_harness/warm                  # warm now, cancels a running hold
curl -s '127.0.0.1:17200/_harness/config?hold_s=40&idle_s=60'
curl -s '127.0.0.1:17200/_harness/config?forward_abandoned=1'
```

`forward_abandoned` (env `FORWARD_ABANDONED`, default off) decides what happens
to a request whose client hung up during the hold: off drops it, so a push the
client saw time out is really lost; on forwards it anyway. Runtime config is
lost when the proxy restarts.

## Proxy log

One JSON line per request on the proxy's stdout and in `logs/proxy.log`:

```sh
tail -f kosync-harness/logs/proxy.log
docker logs -f kosync-harness-proxy
```

| field | meaning |
|---|---|
| `ts_arrive`, `ts_forward`, `ts_done` | UTC, milliseconds |
| `held`, `hold_s` | whether the request waited, and for how long |
| `reason` | `warm`, `forced_cold`, `idle_<n>s`, `cold_start_of_proxy`, or `joined_boot` |
| `client_gone_during_hold` | the client hung up before the hold ended |
| `outcome` | `ok`, `abandoned_not_forwarded`, `client_gone_on_reply: ...`, `upstream_error: ...` |
| `status`, `total_s` | upstream status and time from arrival to done |

Control calls other than `state` are logged too, with a `control` field.
