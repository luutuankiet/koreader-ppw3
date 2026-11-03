---
symptom: "restart_koreader returns restart_timeout on emu, killall luajit does nothing, and the emulator log ends with Inhibiting user input"
area: emulator
verified: 2026-11-03
---

# A sleeping emulator ignores every restart except kill -9

Once the emulator has suspended (its log, `docker logs koreader-emu`, shows
`Inhibiting user input` with no later restore), it cannot be restarted the
usual ways. `killall luajit` returns and KOReader keeps running.
`restart_koreader` through the gateway returns
`{"restarted": false, "status": "restart_timeout"}`, because it runs that same
`killall luajit` and then waits for a reconnect that never comes. Pressing the
emulator's Power key with `emulator/wake.sh` (F2 through XTest) does not wake
it either. The device link can stay up the whole time, so `list_devices` still
shows `emu` online.

Mechanism: KOReader catches SIGTERM and turns it into an input event so it can
shut down cleanly, and while input is inhibited that event is dropped. Nothing
is logged.

Fix: send SIGKILL to the `luajit` process inside the container, which cannot be
caught:

```sh
docker exec koreader-emu sh -c 'kill -9 $(pidof luajit)'
```

The supervisor logs `KOReader exited with code 137; relaunching in 2 s`, starts
a new KOReader 2 s later, and the bridge is back (`[MCP] live mode online as
emu`) about 3 s after that. Seen twice on 2026-11-03, each time fixed this way.

This is different from the Resume trap
(`EMULATOR_STAYS_ASLEEP_AFTER_RESUME_EVENT.md`): there the emulator can still be
woken with the real Power key once the sleep screen stops holding input; here
neither the Power key nor SIGTERM gets through.
