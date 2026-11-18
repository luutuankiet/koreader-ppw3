---
title: Setting up a new Kindle
summary: jailbreak a Paperwhite 3 with WinterBreak2, prove updates are blocked, install KOReader, and migrate settings and books from another Kindle without cloning its identity or logins
verified: 2026-11-01
---

# Setting up a new Kindle

This route was run end to end once, on a secondhand Paperwhite 3 on firmware `5.16.2.1.1`, unregistered and with no Amazon login. It wipes the Kindle's USB storage. Another model or firmware needs its own check; jailbreak tools change quickly.

## Order, and why

**1. Block updates before any WiFi.** With airplane mode on and the Kindle on USB, delete user content and any `update*.bin`, then run `Filler.sh` from the Kindle-Filler-Disk project until 50-90 MB is free. A full disk stops an update from downloading during the one step that needs WiFi. Read the script first.

**2. Jailbreak with WinterBreak2.** Extract `wb2.zip` from `https://github.com/KindleModding/Winterbreak2` so that `winterbreak2/` sits at the USB root, then eject. Turn airplane mode off and join WiFi. No Amazon login is needed. In the Experimental Browser, open `https://penguins184.xyz/wb2` and press Jailbreak. The Kindle downloads a file, runs the jailbreak and reboots itself. Success is `JAILBROKEN.txt` in the library. Turn airplane mode back on, restart the Kindle fully and check that it is still there.

**3. Prove updates are blocked, on the device.** Only then may the filler go. USB can't see the system partition, so copy this into `documents/` as a `.sh` file and tap it in the library. It runs as root once the jailbreak is in place, and its output lands on USB storage:

```sh
#!/bin/sh
{
    id
    cat /etc/prettyversion.txt
    ls -la /usr/bin/otaupd* /usr/bin/otav3*
    ps -ef | grep -E "otaupd|otav3" | grep -v grep
} > /mnt/us/ota-check.txt 2>&1
sync
```

What passing looked like: `uid=0(root)`, `/usr/bin/otaupd.bck` and `/usr/bin/otav3.bck` with no file of the original names, and no matching process. WinterBreak2 does this renaming itself, so its route needs no separate hotfix, KUAL or manual OTA rename. If the original names are still there, keep the filler in place.

**4. Install KOReader.** Remove any update files, then `fill_disk/`. Unzip the `kindlepw2` package at the USB root and check its sha256 against the release first. Copy the "KOReader launcher" scriptlet from `https://scriptlets.notmarek.com/` into `documents/` and start KOReader from the library. Its one working line is `/mnt/us/koreader/koreader.sh --kual --asap`. `--kual` matters: see the trap on the Kindle clock appearing in screenshots.

KOReader's OTA channel can be ahead of its newest GitHub release. Installing the newest release and updating inside KOReader closes the gap, but settings from a slightly newer version also worked unchanged on the older one.

**5. Migrate.** Close KOReader first, because it rewrites settings when it exits. Then copy over USB.

| copy | do not copy |
|---|---|
| `settings.reader.lua`, `defaults.custom.lua`, `history.lua` | `settings/koreader_mcp.lua`, because it holds that device's bridge state |
| `styletweaks/`, `fonts/`, `data/dict/` | `settings/wallabag.lua` and other files holding logins you are not moving |
| from `settings/`: gestures, profiles, statistics, vocabulary, `opds.lua`, `kosync.lua`, `SSH/authorized_keys` | SSH host keys, `cache/`, `ota/` |
| the books folder, at the same path, so `home_dir`, `history.lua` and `lastfile` stay valid | |

Strip these before copying, and print no values while doing it:

- `device_id` from `settings.reader.lua`
- `username` and `userkey` from `settings/kosync.lua`
- `username` and `password` from `settings/opds.lua`

Also check whether any OPDS URL embeds a login. The new device makes its own `device_id`; two Kindles sharing one refuse each other's reading position.

**6. Install plugins.** Unpack `pluginpackages` and `koreader_mcp` into `koreader/plugins/` over USB, checking each sha256 against the gateway's `/pkg/index.json`. Then install the others from the Plugin packages menu on the device. Name the device and match the other Kindles with a `config.lua` in the `koreader_mcp` plugin folder:

```lua
return {
    device_name = "kindle-3",
    live_mode = "always",
}
```

No menu rename is needed, and plugin upgrades keep this file. A Kindle in `always` mode doesn't sleep by itself while KOReader runs, which is a deliberate trade for permanent agent access.

## Checking the result

| check | passing result |
|---|---|
| Updates still blocked | only the `.bck` names exist, and no `update*.bin` on USB |
| Right package for the firmware | `/lib/ld-linux-armhf.so.3` is absent, so soft-float, so `kindlepw2` |
| Identity | the `device_id` differs from the other Kindle's; compare hashes, not values |
| Status bar | `awesome` shows `State: T` in `/proc/<pid>/status` |
| Migration | a checksum comparison of settings and books against the source finds no difference |
| Bridge | the device is in `list_devices` with the expected plugin versions |

## Traps on this route

- **Inspect copied SQLite files before the copy, on a separate copy.** Opening a WAL-mode database, even with `mode=ro`, created `-wal` and `-shm` files beside it in the source folder, and a later `rsync` carried them along. Those WAL files were empty, so nothing was replayed.
- **A late secret-scan hit isn't necessarily a failed scrub.** `kosync.lua` and `opds.lua` gain credentials as soon as someone logs in on the device. Compare file times with the copy time before raising an alarm.
- **Never factory reset a jailbroken Kindle.** With updates blocked, the KindleModding FAQ warns that a reset can leave "Update Failed". Recovery notes: `https://kindlemodding.org/jailbreaking/faq/recovering-from-a-reset.html`.
- **The fallback is untested here.** LanguageBreak does need a factory reset, plus its own hotfix and OTA rename. This route never had to use it.

## The general rule

Prove each protection on the device before removing the one it replaces. The filler stayed until the Kindle itself reported its update programs disabled, because a USB view can't show the system partition and a tool's documentation may not describe this firmware.
