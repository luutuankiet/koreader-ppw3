---
name: repo-maintenance
description: This repo keeps a catalogue of its own traps — failure modes that produce no error, so you find them by symptom, not by stack trace — plus its reference pages and its decision records. Use before debugging behaviour that is wrong but not crashing, before editing shared state, and whenever you finish debugging something that cost more than an hour.
---

# Traps in this repo

Most of what has cost time here fails **silently**. There is no stack trace to
search, so the catalogue below is keyed on **the symptom you would observe**, not
on the subsystem at fault.

**Before you debug anything that misbehaves without erroring, scan this table.**
Then open exactly one file. Each page is self-contained — you will not need to
open a second one.

<!-- BEGIN GENERATED INDEX -- edit the pages, not this block -->

## Traps

Failure modes that produce no error message, indexed by the symptom you
would observe. Read before debugging behaviour that is wrong but not
crashing.

| symptom | page | area | verified |
|---|---|---|---|
| deploy_plugin says deployed but the device still runs the old code | [DEPLOY_REPORTS_OK_BUT_FILE_UNCHANGED](../../../docs/traps/DEPLOY_REPORTS_OK_BUT_FILE_UNCHANGED.md) | kindle-gateway | 2026-10-28 |
| koreader_mcp stops responding after run_command that calls curl on the same device | [DEVICE_SERVER_HANGS_ON_SELF_CALL](../../../docs/traps/DEVICE_SERVER_HANGS_ON_SELF_CALL.md) | koreader_mcp | 2026-10-28 |
| Kindle froze after I sent touch events with evemu-event | [FREEZES_AFTER_RAW_TOUCH_INJECTION](../../../docs/traps/FREEZES_AFTER_RAW_TOUCH_INJECTION.md) | device-control | 2026-10-28 |
| git status shows a symlinked plugin directory as untracked although it is in .gitignore | [GITIGNORE_ENTRY_NOT_MATCHING_SYMLINK](../../../docs/traps/GITIGNORE_ENTRY_NOT_MATCHING_SYMLINK.md) | repo-layout | 2026-10-28 |
| every gateway tool says \"Device 'kindle-N' is offline\" while the Kindle is awake and on WiFi | [KINDLE_AWAKE_BUT_GATEWAY_SAYS_OFFLINE](../../../docs/traps/KINDLE_AWAKE_BUT_GATEWAY_SAYS_OFFLINE.md) | kindle-gateway | 2026-10-30 |
| screenshots or deploys fail on the Kindle with no space left on device | [KINDLE_TMP_FULL_SCREENSHOTS_FAIL](../../../docs/traps/KINDLE_TMP_FULL_SCREENSHOTS_FAIL.md) | device-control | 2026-10-28 |
| rewrote settings/kosync.lua on a running KOReader and it still syncs with the old server or account | [KOSYNC_SETTINGS_FILE_EDIT_IGNORED_UNTIL_RESTART](../../../docs/traps/KOSYNC_SETTINGS_FILE_EDIT_IGNORED_UNTIL_RESTART.md) | kosync | 2026-10-28 |
| get_menu_items says no menu is visible while KOReader's main menu is open on screen | [MAIN_MENU_INVISIBLE_TO_GATEWAY_MENU_TOOLS](../../../docs/traps/MAIN_MENU_INVISIBLE_TO_GATEWAY_MENU_TOOLS.md) | koreader_mcp | 2026-10-28 |
| newline in a KOReader menu item text shows as a space, no paragraph break | [MENU_ITEM_NEWLINES_BECOME_SPACES](../../../docs/traps/MENU_ITEM_NEWLINES_BECOME_SPACES.md) | rssreader | 2026-10-28 |
| address already in use on port 8888 after restarting KOReader | [PORT_8888_STAYS_BUSY_AFTER_RESTART](../../../docs/traps/PORT_8888_STAYS_BUSY_AFTER_RESTART.md) | koreader_mcp | 2026-10-28 |
| a second device says 'Latest progress is coming from this device' and will not pull the position another device pushed | [RESTORED_SETTINGS_CLONE_PROGRESS_SYNC_DEVICE_ID](../../../docs/traps/RESTORED_SETTINGS_CLONE_PROGRESS_SYNC_DEVICE_ID.md) | kosync | 2026-10-30 |
| a screenshot shows the Kindle clock, battery or WiFi icon in the top corners of KOReader, but the physical screen is clean | [SCREENSHOT_SHOWS_KINDLE_CLOCK_SCREEN_DOES_NOT](../../../docs/traps/SCREENSHOT_SHOWS_KINDLE_CLOCK_SCREEN_DOES_NOT.md) | kindle-gateway | 2026-10-29 |
| list_devices returns an empty list or new tools are not callable after rebuilding the gateway | [TOOLS_MISSING_AFTER_GATEWAY_REBUILD](../../../docs/traps/TOOLS_MISSING_AFTER_GATEWAY_REBUILD.md) | kindle-gateway | 2026-10-30 |

## Reference

Simply true, and expensive to re-derive.

| page | summary | verified |
|---|---|---|
| [Gateway configuration](../../../docs/reference/configuration.md) | environment variables read by the gateway container and where they are set | 2026-10-31 |
| [Kindle SSH access and ports](../../../docs/reference/kindle-ssh-access.md) | the two SSH servers on a jailbroken Paperwhite 3, which survives a KOReader restart, and which ports matter | 2026-10-28 |

## Decisions

Why the repo is the way it is. A merged decision is immutable -- supersede
it with a new one rather than editing it.

- [Plugins live at the workspace root, with the reader plugin as a separate repository](../../../docs/adr/0001-flat-plugin-layout.md)
- [Make the RSS reader fast by pre-baking content on a server, not by caching on the device](../../../docs/adr/0002-prebake-server-side-for-rss.md)
- [Working notes were promoted to docs/ and the private journal retired](../../../docs/adr/0003-promote-working-notes-into-docs.md)
- [The gateway serves MCP statelessly, with no session IDs](../../../docs/adr/0004-stateless-gateway-mcp-transport.md)

<!-- END GENERATED INDEX -->

The same tables, browsable, are [docs/README.md](../../../docs/README.md).

## Adding a trap

Write one when you have just spent real time on something that would have taken
minutes if someone had told you. Three tests, all must pass:

1. **It has a symptom.** If a fact is merely true, it is reference, not a trap.
   *If it has a symptom it is a trap; if it is just true it is reference.*
2. **Nothing cheaper catches it.** A doc is the *last* resort, because it only
   works if someone reads it. Stop at the first rung that holds:

   | rung | use when | this repo |
   |---|---|---|
   | make it a **type error** | the mistake is expressible in the type system | `cd kindle-gateway && npx tsc --noEmit` (TypeScript only; none for Lua) |
   | make it a **test** | the mistake is an assertable behaviour | `cd kindle-gateway && npm test` (jest, gateway only; the Lua plugin has no automated tests) |
   | **comment at the site** | there is exactly one line where someone could get it wrong | yes: see the firewall-path comment at `koreader_mcp.koplugin/main.lua:78` |
   | **a doc** | the mistake can be made from any of several files, or from a file that does not exist yet | the catalogue above |

   Before adding one, say out loud which single line you would have commented
   instead — if you can name it, comment it and stop.
3. **It is not already in the table.** Extend the existing file. Two docs on one
   fact is how a catalogue rots.

Then:

- **Filename is the identifier.** `SCREAMING_SNAKE.md`, describing the symptom,
  not the fix. It is quoted in code comments and commit messages, so it never
  gets renamed — if the understanding changes, edit the body.
- **`symptom:` is the search key.** The string a frustrated person would paste
  into a search box, not a topic name. If the console prints something, put the
  console text verbatim.
- **Date it.** `verified:` is the day someone last confirmed it in the running
  code. An undated trap is a claim with no expiry.
- **Regenerate the index**: `scripts/gen-docs-index.sh`. The block above is
  generated; hand edits to it are overwritten.

## Writing the body

The reader is a maintainer six months from now who opened this one file from a
search result and has **no other context loaded**. Not you, not this session.

- Resolve every reference inline. No "see the other doc", no ticket numbers, no
  "as discussed". If a line number matters, quote the code.
- Publishing tone. It is a page on the project's documentation site, not a note
  to self.
- Lead with the symptom, then the mechanism, then the fix, then how to verify.
  Someone in the middle of a bug reads the first two lines and stops.
- Include the **evidence** — measured numbers, observed values, verbatim code. A
  trap without evidence gets argued with.
- **Say what is deliberate.** Half of what looks like a bug in a mature codebase
  is a trade someone made on purpose. Write down which, and what the trade was.

## The other collections

`docs/` holds five kinds of page, all generated into the same index by the same
script, all governed by the rules above:

| directory | what belongs there | frontmatter |
|---|---|---|
| `docs/traps/` | it has a symptom | `symptom`, `area`, `verified` |
| `docs/architecture/` | where behaviour lives — one page per area | `title`, `covers`, `verified` |
| `docs/reference/` | simply true, no symptom, worth not re-deriving | `title`, `summary`, `verified` |
| `docs/adr/` | **why the repo is the way it is** — a decision record | none; the `# ` heading is the entry |
| `docs/*.md` | a long-form guide belonging to no single area | `title`, `summary`, `verified` |

The architecture pages are the `codebase-map` skill's index; read that skill
before adding one. The escalation ladder does **not** apply to them — a map is not
a warning. Everything else does: date it, resolve references inline, regenerate
the index.

### Decision records

`docs/adr/NNNN-kebab-slug.md`, sequential, created lazily. Offer one only when
**all three** hold:

1. **hard to reverse** — if it is easy to reverse, skip it; you will just reverse it
2. **surprising without context** — otherwise the code explains itself
3. **the result of a real trade-off** — if there was no genuine alternative, there
   is nothing to record beyond "we did the obvious thing"

One to three sentences is a complete record: the context, what was decided, why.

**A merged record is immutable.** Superseding means a *new* file that names what
it replaces; the old one stays readable, because the reason a decision was made is
not invalidated by the decision changing.

This is the one destination that is append-only and unrecoverable. A trap can be
rewritten later; a rationale never written is gone.

## Removing a trap

**Before trusting a page, check it is still true.** These describe code, and code
moves. If the underlying cause is fixed, **delete the file** and say so in the
commit message. Do not leave it with a "fixed in vX" note — a stale trap costs a
reader the same time as a real one, and costs the catalogue its credibility, which
is the only thing making anyone open the next page. If the fix came with a comment
at the site, that comment is now the record.
