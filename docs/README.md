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
| [Plugin deploy pipeline](architecture/deploy-pipeline.md) | how a plugin directory gets onto a Kindle, where the gateway reads plugin source, shell fallbacks | 2026-10-28 |
| [Device bridge (agent to Kindle)](architecture/device-bridge.md) | how an agent call reaches a Kindle, which file owns the gateway tools, the on-device server, registration and screenshots | 2026-10-28 |

## Traps

Failure modes that produce no error message, indexed by the symptom you
would observe. Read before debugging behaviour that is wrong but not
crashing.

| symptom | page | area | verified |
|---|---|---|---|
| deploy_plugin says deployed but the device still runs the old code | [DEPLOY_REPORTS_OK_BUT_FILE_UNCHANGED](traps/DEPLOY_REPORTS_OK_BUT_FILE_UNCHANGED.md) | kindle-gateway | 2026-10-28 |
| koreader_mcp stops responding after run_command that calls curl on the same device | [DEVICE_SERVER_HANGS_ON_SELF_CALL](traps/DEVICE_SERVER_HANGS_ON_SELF_CALL.md) | koreader_mcp | 2026-10-28 |
| Kindle froze after I sent touch events with evemu-event | [FREEZES_AFTER_RAW_TOUCH_INJECTION](traps/FREEZES_AFTER_RAW_TOUCH_INJECTION.md) | device-control | 2026-10-28 |
| git status shows a symlinked plugin directory as untracked although it is in .gitignore | [GITIGNORE_ENTRY_NOT_MATCHING_SYMLINK](traps/GITIGNORE_ENTRY_NOT_MATCHING_SYMLINK.md) | repo-layout | 2026-10-28 |
| screenshots or deploys fail on the Kindle with no space left on device | [KINDLE_TMP_FULL_SCREENSHOTS_FAIL](traps/KINDLE_TMP_FULL_SCREENSHOTS_FAIL.md) | device-control | 2026-10-28 |
| rewrote settings/kosync.lua on a running KOReader and it still syncs with the old server or account | [KOSYNC_SETTINGS_FILE_EDIT_IGNORED_UNTIL_RESTART](traps/KOSYNC_SETTINGS_FILE_EDIT_IGNORED_UNTIL_RESTART.md) | kosync | 2026-10-28 |
| get_menu_items says no menu is visible while KOReader's main menu is open on screen | [MAIN_MENU_INVISIBLE_TO_GATEWAY_MENU_TOOLS](traps/MAIN_MENU_INVISIBLE_TO_GATEWAY_MENU_TOOLS.md) | koreader_mcp | 2026-10-28 |
| newline in a KOReader menu item text shows as a space, no paragraph break | [MENU_ITEM_NEWLINES_BECOME_SPACES](traps/MENU_ITEM_NEWLINES_BECOME_SPACES.md) | rssreader | 2026-10-28 |
| address already in use on port 8888 after restarting KOReader | [PORT_8888_STAYS_BUSY_AFTER_RESTART](traps/PORT_8888_STAYS_BUSY_AFTER_RESTART.md) | koreader_mcp | 2026-10-28 |
| list_devices returns an empty list or new tools are not callable after rebuilding the gateway | [TOOLS_MISSING_AFTER_GATEWAY_REBUILD](traps/TOOLS_MISSING_AFTER_GATEWAY_REBUILD.md) | kindle-gateway | 2026-10-28 |

## Reference

Simply true, and expensive to re-derive.

| page | summary | verified |
|---|---|---|
| [Gateway configuration](reference/configuration.md) | environment variables read by the gateway container and where they are set | 2026-10-28 |
| [Kindle SSH access and ports](reference/kindle-ssh-access.md) | the two SSH servers on a jailbroken Paperwhite 3, which survives a KOReader restart, and which ports matter | 2026-10-28 |

## Decisions

Why the repo is the way it is. A merged decision is immutable -- supersede
it with a new one rather than editing it.

- [Plugins live at the workspace root, with the reader plugin as a separate repository](adr/0001-flat-plugin-layout.md)
- [Make the RSS reader fast by pre-baking content on a server, not by caching on the device](adr/0002-prebake-server-side-for-rss.md)
- [Working notes were promoted to docs/ and the private journal retired](adr/0003-promote-working-notes-into-docs.md)

<!-- END GENERATED INDEX -->
