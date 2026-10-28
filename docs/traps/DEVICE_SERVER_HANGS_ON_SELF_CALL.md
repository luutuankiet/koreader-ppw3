---
symptom: "koreader_mcp stops responding after run_command that calls curl on the same device"
area: koreader_mcp
verified: 2026-10-28
---

# Self-calls deadlock the device server

`koreader_mcp` is single-threaded Lua. A `run_command` that makes an HTTP request back to the device's own port 8888 waits on a server that is busy waiting for it, and both hang until KOReader is restarted.

Fix: never nest requests through the device. Run the `curl` from the gateway host instead.

General rule: a single-threaded server cannot be its own client.
