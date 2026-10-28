---
symptom: "every gateway tool says \"Device 'kindle-N' is offline\" while the Kindle is awake and on WiFi"
area: kindle-gateway
verified: 2026-10-28
---

# A Kindle that woke up stays offline in the gateway

The gateway marks a device offline the first time a forwarded call fails (`kindle-gateway/src/gateway-server.ts`, the `catch` in the forwarding helper calls `registry.markOffline`), for example when the Kindle was asleep. From then on every tool for that device returns `Device '<name>' is offline` without trying the device again. Only a new `POST /register` sets it back online, and `koreader_mcp` registers only from `onNetworkConnected` (`koreader_mcp.koplugin/main.lua`). A Kindle that wakes with its WiFi still connected never fires that event, so it stays offline in the gateway for good. Observed: kindle-2 awake for 30 minutes, `list_devices` still showed `offline` with an old `lastSeen`.

Check: the device answers HTTP on its LAN address even though the gateway says offline. ICMP ping does not count; the Kindle drops it.

```
curl -s -o /dev/null -w '%{http_code}\n' http://<kindle-ip>:8888/    # any code, e.g. 404, means the server is up
```

Fix: register it by hand with the same body the plugin sends (name, IP and port from `list_devices`):

```
curl -s -X POST http://<gateway-host>:9999/register -H 'Content-Type: application/json' \
  -d '{"name":"kindle-2","ip":"192.168.1.5","port":8888,"tools":["read_files","run_command","device_status"]}'
```

Toggling WiFi on the Kindle also works, because it fires `onNetworkConnected`.
