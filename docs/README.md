# Documentation

Every page here is written for a maintainer six months from now who opened
exactly this file from a search result and has nothing else loaded.

This index is generated. Run `scripts/gen-docs-index.sh` after adding or
renaming a page; `--check` fails if it is stale.

<!-- BEGIN GENERATED INDEX -- edit the pages, not this block -->

## Where things live

One page per area of the system. Read before going looking for where
something is implemented.

| page | covers | verified |
|---|---|---|
| [Plugin deploy pipeline](architecture/deploy-pipeline.md) | how a plugin directory gets onto a Kindle, where the gateway reads plugin source, shell fallbacks, plugin packages and the upload inbox | 2026-10-31 |
| [Device bridge (agent to Kindle)](architecture/device-bridge.md) | how an agent call reaches a Kindle, which file owns the gateway tools, the stateless MCP transport, the dial-out connection and live sessions, screenshots and running on Android | 2026-11-03 |
| [Plugin installer](architecture/plugin-installer.md) | where the on-device plugin installer reads the package list, downloads and checks an archive, swaps the plugin folder, keeps the backup and rolls back | 2026-10-31 |
| [Synced reading list plugin](architecture/synced-reading-list.md) | where the synced reading list sets the progress sync device id from the Kindle serial, fetches the server list, maps books to local files under any of their merged file names, builds rows, filters and searches, refreshes, shows the long-press pop-up, removes a book from the list, chooses which progress sync plugin it works with, and opens a book at its synced position | 2026-11-03 |

## Traps

Failure modes that produce no error message, indexed by the symptom you
would observe. Read before debugging behaviour that is wrong but not
crashing.

| symptom | page | area | verified |
|---|---|---|---|
| deploy_plugin says deployed but the device still runs the old code | [DEPLOY_REPORTS_OK_BUT_FILE_UNCHANGED](traps/DEPLOY_REPORTS_OK_BUT_FILE_UNCHANGED.md) | kindle-gateway | 2026-10-28 |
| koreader_mcp stops responding after run_command that calls curl on the same device | [DEVICE_SERVER_HANGS_ON_SELF_CALL](traps/DEVICE_SERVER_HANGS_ON_SELF_CALL.md) | koreader_mcp | 2026-10-28 |
| emulator stays on the sleep screen after sending Resume, and the next Power press puts it back to sleep | [EMULATOR_STAYS_ASLEEP_AFTER_RESUME_EVENT](traps/EMULATOR_STAYS_ASLEEP_AFTER_RESUME_EVENT.md) | emulator | 2026-11-03 |
| Kindle froze after I sent touch events with evemu-event | [FREEZES_AFTER_RAW_TOUCH_INJECTION](traps/FREEZES_AFTER_RAW_TOUCH_INJECTION.md) | device-control | 2026-10-28 |
| git status shows a symlinked plugin directory as untracked although it is in .gitignore | [GITIGNORE_ENTRY_NOT_MATCHING_SYMLINK](traps/GITIGNORE_ENTRY_NOT_MATCHING_SYMLINK.md) | repo-layout | 2026-10-28 |
| every gateway tool says \"Device 'kindle-N' is not connected\", or the device is missing from list_devices, while the Kindle is awake and on WiFi | [KINDLE_AWAKE_BUT_GATEWAY_SAYS_OFFLINE](traps/KINDLE_AWAKE_BUT_GATEWAY_SAYS_OFFLINE.md) | kindle-gateway | 2026-10-31 |
| screenshots or deploys fail on the Kindle with no space left on device | [KINDLE_TMP_FULL_SCREENSHOTS_FAIL](traps/KINDLE_TMP_FULL_SCREENSHOTS_FAIL.md) | device-control | 2026-10-28 |
| rewrote settings/kosync.lua on a running KOReader and it still syncs with the old server or account | [KOSYNC_SETTINGS_FILE_EDIT_IGNORED_UNTIL_RESTART](traps/KOSYNC_SETTINGS_FILE_EDIT_IGNORED_UNTIL_RESTART.md) | kosync | 2026-10-28 |
| get_menu_items says no menu is visible while KOReader's main menu is open on screen | [MAIN_MENU_INVISIBLE_TO_GATEWAY_MENU_TOOLS](traps/MAIN_MENU_INVISIBLE_TO_GATEWAY_MENU_TOOLS.md) | koreader_mcp | 2026-10-28 |
| newline in a KOReader menu item text shows as a space, no paragraph break | [MENU_ITEM_NEWLINES_BECOME_SPACES](traps/MENU_ITEM_NEWLINES_BECOME_SPACES.md) | rssreader | 2026-10-28 |
| address already in use on port 8888 after restarting KOReader | [PORT_8888_STAYS_BUSY_AFTER_RESTART](traps/PORT_8888_STAYS_BUSY_AFTER_RESTART.md) | koreader_mcp | 2026-10-28 |
| a second device says 'Latest progress is coming from this device' and will not pull the position another device pushed | [RESTORED_SETTINGS_CLONE_PROGRESS_SYNC_DEVICE_ID](traps/RESTORED_SETTINGS_CLONE_PROGRESS_SYNC_DEVICE_ID.md) | kosync | 2026-10-30 |
| a screenshot shows the Kindle clock, battery or WiFi icon in the top corners of KOReader, but the physical screen is clean | [SCREENSHOT_SHOWS_KINDLE_CLOCK_SCREEN_DOES_NOT](traps/SCREENSHOT_SHOWS_KINDLE_CLOCK_SCREEN_DOES_NOT.md) | kindle-gateway | 2026-10-29 |
| list_devices returns an empty list or new tools are not callable after rebuilding the gateway | [TOOLS_MISSING_AFTER_GATEWAY_REBUILD](traps/TOOLS_MISSING_AFTER_GATEWAY_REBUILD.md) | kindle-gateway | 2026-10-30 |

## Reference

Simply true, and expensive to re-derive.

| page | summary | verified |
|---|---|---|
| [Gateway configuration](reference/configuration.md) | environment variables read by the gateway container and where they are set | 2026-10-31 |
| [Kindle power daemon (powerd) properties and sleep timers](reference/kindle-powerd.md) | what com.lab126.powerd exposes on a Paperwhite 3 for delaying suspend, and the timers between the power button and sleep | 2026-11-03 |
| [Kindle SSH access and ports](reference/kindle-ssh-access.md) | the two SSH servers on a jailbroken Paperwhite 3, which survives a KOReader restart, and which ports matter | 2026-10-28 |
| [Installing progress sync serverless on a Kindle](reference/progress-sync-serverless-install.md) | install the serverless progress sync and synced reading list packages through Plugin packages, turn off the built-in Progress sync, log in, and where each setting is stored | 2026-11-03 |

## Decisions

Why the repo is the way it is. A merged decision is immutable -- supersede
it with a new one rather than editing it.

- [Plugins live at the workspace root, with the reader plugin as a separate repository](adr/0001-flat-plugin-layout.md)
- [Make the RSS reader fast by pre-baking content on a server, not by caching on the device](adr/0002-prebake-server-side-for-rss.md)
- [Working notes were promoted to docs/ and the private journal retired](adr/0003-promote-working-notes-into-docs.md)
- [The gateway serves MCP statelessly, with no session IDs](adr/0004-stateless-gateway-mcp-transport.md)
- [Devices dial out to the gateway, and only during a live session](adr/0005-devices-dial-out-live-mode.md)

<!-- END GENERATED INDEX -->
