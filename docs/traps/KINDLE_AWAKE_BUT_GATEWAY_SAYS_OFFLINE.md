---
symptom: "every gateway tool says \"Device 'kindle-N' is not connected\", or the device is missing from list_devices, while the Kindle is awake and on WiFi"
area: kindle-gateway
verified: 2026-10-31
---

# A Kindle that is awake is not in the gateway

The gateway lists a device exactly while that device holds its connection to `DEVICE_PORT`. An awake Kindle on WiFi is missing because no live session is running, and that is the normal state: outside a session `koreader_mcp` has no socket and no timer, and nothing dials the gateway on its own.

A session ends without any message on the gateway side when any of these happen: the owner turned it off, 15 minutes passed without an agent command, the battery fell below 30%, or reconnecting failed after 5 s, 15 s and 60 s (for example the gateway was rebuilt while the Kindle slept). The reason is in the Kindle's `crash.log` as `[MCP] session over (<reason>)`.

Fix: on the Kindle, top menu, network tab, Agent bridge, Live mode. If it still does not appear, check Agent bridge, Gateway address, and that the host can be reached on `DEVICE_PORT` from the LAN.

A name refused while another device holds it also looks like this: the gateway logs `refused '<name>'`. Rename one of them in the same menu.

Before live mode the same symptom had a different cause (a sticky offline flag cleared only by `POST /register`). Neither that flag, that route nor port 8888 exists now; decision record 0005 explains the change.
