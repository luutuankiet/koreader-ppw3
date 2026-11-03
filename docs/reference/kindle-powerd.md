---
title: Kindle power daemon (powerd) properties and sleep timers
summary: what com.lab126.powerd exposes on a Paperwhite 3 for delaying suspend, and the timers between the power button and sleep
verified: 2026-11-03
---

# Kindle power daemon (powerd)

On a Kindle, Amazon's `powerd` owns sleep. KOReader only reacts to its lipc events. Sleep that KOReader starts itself (the Sleep menu, AutoSuspend) can wait first. Sleep from the power button or the cover goes straight to powerd. Measured on a Paperwhite 3, firmware Kindle 5.14.2.

## Properties that touch suspend

From `lipc-probe -v com.lab126.powerd`. Write-only properties can't be read back. Their current values show up in `lipc-get-prop com.lab126.powerd status` as `defer_suspend:N` and `suspend_grace:N`.

| property | access | what `/usr/bin/powerd` logs for it |
|---|---|---|
| `deferSuspend` | w Int | `Defer suspend request delay=%d`, `deferSuspend: %d secs` |
| `suspendGrace` | w Int | `Setting suspend grace timeout (seconds)`, `Suspend grace is set.  Waiting for %d secs` |
| `abortSuspend` | w Int | event `e_abort_suspend` |
| `addSuspendLevels` | w Int | event `e_add_suspend_levels` |
| `preventScreenSaver` | rw Int | blocks the idle screensaver; the agent bridge sets it to `1` in Live mode |
| `powerButton` | w Int | simulates a press; KOReader uses it to start sleep |

`deferSuspend` and `suspendGrace` have not been tested on a device yet. Issue #80 tracks whether they hold power button sleep.

## Timers

Read with `kdb get system/daemon/powerd/<key>`:

| key | value | meaning |
|---|---|---|
| `t1_timeout` | `600` | idle seconds before the screensaver |
| `t2_timeout` | `60` | seconds in screensaver before powerd moves toward suspend |
| `r2s_grace_timeout` | `5` | seconds from ready-to-suspend to suspend |

The binary logs `e_stop_charging in SCREEN SAVER: starting t2 timer`, so the t2 timer most likely does not run while the device is charging. Time sleep only with the device unplugged.

## Seen on the device

A power button sleep with auto sync on, against a warm server: Cloud Run received the background progress push 2.7 s after KOReader logged `onSuspend`. On wake, Wi-Fi had to be restored (`Wi-Fi successfully restored (after 4.75 seconds)!` in `crash.log`).
