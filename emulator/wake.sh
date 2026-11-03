#!/bin/sh
# Wakes the sleeping emulator with its Power key (F2), the real resume path.
# A Resume event sent through the gateway does not wake it: see
# docs/traps/EMULATOR_STAYS_ASLEEP_AFTER_RESUME_EVENT.md.
D=$(cd "$(dirname "$0")" && pwd)
docker cp "$D/press-power.lua" koreader-emu:/tmp/press-power.lua
docker exec koreader-emu sh -c 'cd /mnt/us/koreader && DISPLAY=:73 ./luajit /tmp/press-power.lua'
