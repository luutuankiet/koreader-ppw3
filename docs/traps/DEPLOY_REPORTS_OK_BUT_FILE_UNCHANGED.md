---
symptom: "deploy_plugin says deployed but the device still runs the old code"
area: kindle-gateway
verified: 2026-10-28
---

# Large files silently fail to transfer on devices running an older plugin

`deployPlugin` first sends each file through the device's `write_file` tool, which writes the bytes natively and returns an md5 that the gateway compares with its own (a mismatch is reported as an error). If the device does not know `write_file` (an older `koreader_mcp` build), it falls back to `printf '%s' '<base64>' | base64 -d > file`. BusyBox on the Kindle has an argument-length limit around 64KB, so on that fallback files above roughly 48KB raw are truncated or skipped while still listed as deployed. Observed: a 125KB menu file was reported deployed and its md5 never changed.

Fix: deploy `koreader_mcp` itself first (it is small enough for the fallback) so later deploys use `write_file`. For a large file on an old device, run `python3 -m http.server 8765 --bind 0.0.0.0` on the gateway host, then on the Kindle `wget -q -O <target> http://<host-lan-ip>:8765/<path>` (use the LAN address; Docker bridge addresses are unreachable from the device), then stop the server. Or use `scripts/deploy-rssreader.sh`.

Verify: compare `md5sum` on the device and in the workspace. On the fallback path the returned file list is not proof.

General rule: a transfer is not done until a checksum at the destination says so.
