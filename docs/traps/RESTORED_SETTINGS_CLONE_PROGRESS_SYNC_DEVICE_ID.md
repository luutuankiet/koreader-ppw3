---
symptom: "a second device says 'Latest progress is coming from this device' and will not pull the position another device pushed"
area: kosync
verified: 2026-10-30
---

# A restored settings file clones the progress sync device id

KOReader makes the progress sync `device_id` once, at random, and keeps it in `settings.reader.lua` (`reader.lua` in v2026.07.1, `kosync.koplugin/main.lua` up to v2024.11). Copy that file to a second device, for example by restoring a settings backup, and both devices push the same id. The built-in sync decides "this progress is mine" on the client by comparing the server row's device model and `device_id` with its own, so when the two devices are the same model one refuses to pull the other's position, with the message "Latest progress is coming from this device". Nothing fails and the server can't tell them apart: both push the same model, id and often the same address.

Fix on Kindles: `syncedhistory.koplugin` (`syncedhistory_deviceid.lua`) sets the id to the uppercase md5 of `"kosync:"` plus the hardware serial in `/proc/usid` every time the plugin loads, so a restored id is replaced on the next start. It runs when the plugin file loads, before KOReader builds any plugin instance, so the built-in sync already uses the new id at the first book open. The synced reading list shows the last 4 characters of each row's id, which tells two devices of one model apart.

Elsewhere (Android, the emulator: no `/proc/usid`): delete the `device_id` line from the restored `settings.reader.lua` while KOReader is stopped; KOReader makes a new one at the next start. Keep `device_id` out of any settings backup.
