---
symptom: "deploy_plugin says deployed but the device still runs the old code"
area: kindle-gateway
verified: 2026-10-28
---

# Large files silently fail to transfer

The shell fallback in `deployPlugin` sends each file as `printf '%s' '<base64>' | base64 -d > file`. BusyBox on the Kindle has an argument-length limit around 64KB, so files above roughly 48KB raw (64KB base64) are truncated or skipped while the file is still listed as deployed. Observed: a 125KB menu file was reported deployed and its md5 never changed.

Fix for a large file: on the gateway host run `python3 -m http.server 8765 --bind 0.0.0.0`, then on the Kindle `wget -q -O <target> http://<host-lan-ip>:8765/<path>` (use the LAN address; Docker bridge addresses are unreachable from the device), then stop the server. Or use `scripts/deploy-rssreader.sh`.

Verify: compare `md5sum` on the device and in the workspace. Trust the checksum, not the returned file list.

General rule: a transfer is not done until a checksum at the destination says so.
