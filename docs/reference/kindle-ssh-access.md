---
title: Kindle SSH access and ports
summary: the two SSH servers on a jailbroken Paperwhite 3, which survives a KOReader restart, and which ports matter
verified: 2026-10-28
---

# Kindle SSH access

| method | port | server | survives KOReader restart | extra client flag |
|---|---|---|---|---|
| USBNet SSH | 22 | OpenSSH | yes | none |
| KOReader SSH plugin | 2222 | dropbear | no | `-o KexAlgorithms=diffie-hellman-group14-sha256` |

Prefer USBNet SSH for anything scripted. Define one `Host` alias per device in `~/.ssh/config` (user `root`, port 22); the deploy scripts take that alias as their first argument and default to `kindle`.

Other ports: `8888` is `koreader_mcp`, opened by the plugin itself with an `iptables` rule using the full path `/usr/sbin/iptables` because it is not on the default PATH on some firmware.

Device addresses, serials and MAC addresses are deliberately not recorded here; they are local state.
