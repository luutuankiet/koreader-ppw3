---
symptom: "emulator stays on the sleep screen after sending Resume, and the next Power press puts it back to sleep"
area: emulator
verified: 2026-11-03
---

# A Resume event does not wake the emulator

Sending a `Resume` event through the gateway's `send_event` only tells plugins
that the device woke. The emulator's sleep screen stays up and input stays
locked, so KOReader still believes it is asleep: the next Power press is read
as "go to sleep" and the device suspends again. No error is logged; the only
trace is a second `onSuspend` in `docker logs koreader-emu` where you expected
a wake.

Fix: press the emulator's real Power key (F2) with `emulator/wake.sh`, which
injects the key into the Xvfb display through XTest so KOReader runs its own
resume path. Presses in the first 13 to 25 seconds after sleep are dropped
while the sleep screen holds input locked, so wait about 25 seconds after a
sleep before waking.
