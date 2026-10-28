---
symptom: "list_devices returns an empty list or new tools are not callable after rebuilding the gateway"
area: kindle-gateway
verified: 2026-10-28
---

# Rebuild empties the registry and quarantines tools

The device registry is in memory, so recreating the container clears it; it refills on each device's next phone-home (WiFi reconnect). The MCP proxy also quarantines new or changed tools until they are approved.

Fix: wait for or trigger a device WiFi cycle, then reconnect the gateway upstream in the proxy and approve its tools. Test code changes first with `PORT=9998 npx tsx src/index.ts` so the running instance is not disturbed.

General rule: state held in memory needs a re-announce path, or a restart looks like data loss.
