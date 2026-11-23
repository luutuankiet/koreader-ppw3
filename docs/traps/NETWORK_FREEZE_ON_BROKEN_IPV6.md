---
symptom: "opening an OPDS catalog (or any HTTPS fetch) freezes KOReader for minutes, then times out, on one network only"
area: koreader-patches
verified: 2026-11-23
---

# KOReader freezes for minutes on a network whose IPv6 is broken

Some home networks assign IPv6 addresses to devices but cannot route IPv6 traffic. KOReader's HTTP and HTTPS requests go through LuaSocket's `socket.tcp()`, whose `connect` walks the DNS answers in order, IPv6 first, waiting the full block timeout on each (10 s for OPDS, `socketutil.LARGE_BLOCK_TIMEOUT`) on the UI thread. A server that publishes eight IPv6 addresses therefore freezes the reader for well over a minute per request before an IPv4 address is tried, and the server never logs a request. Devices without an IPv6 address on the same network (the Kindle) are not affected, so the fault looks device-specific.

Confirm: from the device shell, a TCP connect to one of the server's IPv6 addresses hangs while one to an IPv4 address connects at once (`toybox nc -w 12 <ipv6> 443` versus `<ipv4> 443` over adb on Android).

Fix without touching the network: install `koreader-patches/1-force-ipv4.lua` into the device's `koreader/patches/` folder and restart KOReader. It makes `socket.tcp` build IPv4-only sockets. It must stay at priority `1`: KOReader's `socketutil` captures `socket.tcp` when it first loads to add its timeouts, so a later patch would either be ignored or drop those timeouts. Check `crash.log` for `force-ipv4: socket.tcp now creates IPv4-only sockets`.

KOReader patches are a no-op on the F-Droid build.
