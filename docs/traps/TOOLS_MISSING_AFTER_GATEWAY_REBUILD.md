---
symptom: "list_devices returns an empty list or new tools are not callable after rebuilding the gateway"
area: kindle-gateway
verified: 2026-10-30
---

# Rebuild empties the registry and quarantines tools

The device registry is in memory, so recreating the container clears it; it refills as each device in a live session dials back (within about 60 s for the emulator; a Kindle session gives up after 5 s, 15 s and 60 s and must be started again in its menu). The MCP proxy also quarantines new or changed tools until they are approved.

Fix: wait for or trigger a device WiFi cycle (or register a device by hand, see the trap about a Kindle that stays offline), then approve any new or changed tools in the proxy. The proxy does not need reconnecting: the gateway issues no MCP session IDs, so the proxy's next call after a rebuild just works. Test code changes first with `PORT=9998 npx tsx src/index.ts` so the running instance is not disturbed.

General rule: state held in memory needs a re-announce path, or a restart looks like data loss.
