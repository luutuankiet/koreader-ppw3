#!/bin/sh
# Stands in for the Kindle's /mnt/us/koreader/koreader.sh. The gateway's restart
# tool runs `killall luajit; ./koreader.sh`; in the emulator the container's
# supervisor already relaunches KOReader, so a second copy here would fight it
# for the port. The release's own launcher is kept as koreader.sh.orig.
echo "koreader.sh: the emulator supervisor relaunches KOReader; nothing to do"
exit 0
