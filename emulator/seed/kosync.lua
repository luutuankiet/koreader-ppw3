-- First-run defaults for the built-in progress sync plugin, copied only when
-- the persisted file is missing. Mirrors KOSync.default_settings in
-- plugins/kosync.koplugin/main.lua (v2026.07.1) except checksum_method:
-- 1 = file-name method, so a book's sync key is md5(file name).
-- No server, username or key: those are seeded later, never committed.
return {
    ["settings"] = {
        ["auto_sync"] = false,
        ["sync_forward"] = 1,
        ["sync_backward"] = 3,
        ["checksum_method"] = 1,
        ["send_metadata"] = false,
    },
}
