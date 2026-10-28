---
symptom: "get_menu_items says no menu is visible while KOReader's main menu is open on screen"
area: koreader_mcp
verified: 2026-10-28
---

# The gateway's menu tools cannot see KOReader's main menu

`get_menu_items` and `select_menu_item` find their target with `findTopMenu()` in `koreader_mcp.koplugin/handlers.lua`, which takes the topmost widget that has both `item_table` and `switchItemTable`. Only the list-style `Menu` widget has `switchItemTable` (`frontend/ui/widget/menu.lua`). The main menu, the top-bar menu opened from the file browser or the reader, is a `TouchMenu`, which has `item_table` but no `switchItemTable`, so it is skipped. Observed on `emu`: after `send_event` `ShowMenu` the main menu is on screen and `get_menu_items` answers "No menu widget is currently visible". So a plugin's main-menu entry cannot be opened through gateway tools alone. Tracked in issue #14.

Workaround, for checks on the emulator only: install a temporary KOReader user patch at `$KO_HOME/patches/<n>-<name>.lua` (on the emulator `/mnt/us/koreader-home/patches/`) that adds an event handler to `FileManager` and `ReaderUI`, for example `function FileManager:onMyEntry() ... end`, whose body finds the entry in `self.menu.menu_items` (call `self.menu:setUpdateItemTable()` first if it is not built yet) and runs its `callback`. User patches load at startup, so restart KOReader (`restart_koreader`) after installing it, then fire the event with `send_event`. Remove the patch and restart again when done. Once the plugin's own list (a `Menu`) is open, `get_menu_items` and `select_menu_item` work on it.

A related gap: `select_menu_item` calls the row's `callback` directly, not `Menu:onMenuSelect`, so a menu that handles taps in `onMenuSelect` or `onMenuChoice` does nothing when driven through the gateway. Give each row its own `callback`.

General rule: a test driver that finds widgets by duck typing sees only the widget shapes it was written against.
