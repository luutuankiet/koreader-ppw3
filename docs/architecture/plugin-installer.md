---
verified: 2026-10-31
---

# Plugin installer

`pluginpackages.koplugin` adds the menu entry "Plugin packages". It reads
`index.json` from the package host (`scripts/publish.sh` builds it, the gateway
serves it at `/pkg/`) and installs, upgrades and rolls back plugins, itself included.

| where | what |
|---|---|
| `pluginpackages_core.lua` | all disk work, no UI; tested by `test_core.lua` |
| `main.lua` | menu, dialogs, the subprocess that downloads |

Run the tests from a KOReader install folder: `./luajit <path>/test_core.lua`.

## What an install does

1. `prepare()` runs in a subprocess: download to `plugins/pluginpackages.stage/`, check size and sha256, unpack, check the version matches the index, write the manifest. It touches nothing else, so a kill or a bad file leaves the installed plugin alone.
2. `swapIn()` runs in the UI process: copy local files into the new folder, then rename `.bak` aside, current to `.bak`, new to current. A failed rename undoes the earlier ones.

A power cut between those renames can leave a plugin with only `.bak`. The list still offers Roll back for it, unless the plugin was the installer itself.

## Local files

Archives leave out personal files such as `rssreader_configuration.lua`. Each install writes `.package-files` into the plugin folder, listing what the package brought. Any other file is local and is copied across installs and rollbacks. A folder with no manifest was deployed by hand, so everything in it not supplied by the new package is kept.

## Unpacking differs by KOReader version

`ffi/archiver` exists in `v2026.07.1` but not in `v2024.11` or `v2025.04`, so the dictionary downloader's pattern cannot be copied exactly. Without it the installer runs KOReader's bundled `./tar`, then the system `tar`.
