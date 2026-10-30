---
symptom: "list_devices returns an empty list or new tools are not callable after rebuilding the gateway"
area: kindle-gateway
verified: 2026-10-30
---

# Rebuild empties the registry and quarantines tools

The device registry is in memory, so recreating the container clears it; it refills on each device's next phone-home (WiFi reconnect). The MCP proxy also quarantines new or changed tools until they are approved.

Fix: wait for or trigger a device WiFi cycle (or register a device by hand, see the trap about a Kindle that stays offline), then approve any new or changed tools in the proxy. The proxy does not need reconnecting: the gateway issues no MCP session IDs, so the proxy's next call after a rebuild just works. Test code changes first with `PORT=9998 npx tsx src/index.ts` so the running instance is not disturbed.

General rule: state held in memory needs a re-announce path, or a restart looks like data loss.
