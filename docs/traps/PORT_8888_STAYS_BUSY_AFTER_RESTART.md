---
symptom: "address already in use on port 8888 after restarting KOReader"
area: koreader_mcp
verified: 2026-10-28
---

# Port 8888 held by orphaned child processes

`io.popen` in `run_command` spawns children that inherit every open file descriptor, including the listening socket. If KOReader is killed, an orphaned child keeps the port and the restarted plugin cannot bind.

The listening socket is now marked close-on-exec in `koreader_mcp.koplugin/server.lua` (`fcntl` with `F_SETFD=2`, `FD_CLOEXEC=1` via LuaJIT FFI, around line 182-191). `restart_koreader` also kills any stale holder with `netstat -tlnp` before relaunching.

Verify: after a restart, `netstat -tlnp | grep 8888` shows the new luajit process.

General rule: any long-lived listening socket in a process that forks must be close-on-exec.
