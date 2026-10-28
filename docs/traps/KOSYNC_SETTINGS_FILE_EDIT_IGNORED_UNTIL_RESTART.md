---
symptom: "rewrote settings/kosync.lua on a running KOReader and it still syncs with the old server or account"
area: kosync
verified: 2026-10-28
---

# The built-in progress sync reads its settings file once per process

KOReader's built-in sync plugin (`plugins/kosync.koplugin/main.lua`, `KOSync:loadSettings`) opens `settings/kosync.lua` into a class-level `KOSync.settings_obj` the first time it loads and keeps it for the life of the process. Writing a new server, account or checksum method into that file while KOReader runs changes nothing: the plugin keeps the values it read at startup, and its `onFlushSettings` can later write the old values back over yours. `syncedhistory.koplugin` uses the built-in plugin's live settings while a book is open, so it sees the old account too.

Fix: after seeding or editing `kosync.lua` from outside KOReader (a seed script, `run_command`), restart KOReader with `restart_koreader` before testing. Changes made through KOReader's own sync menu do not need this.

General rule: before editing a running program's settings file from outside, find out whether it reads the file once or on every use.
