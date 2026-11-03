---
title: Plugin installer
covers: where the on-device plugin installer reads the package list, downloads and checks an archive, swaps the plugin folder, keeps the backup and rolls back
verified: 2026-11-03
---

# Plugin installer

`pluginpackages.koplugin` adds the menu entry "Plugin packages". It reads a
package list and installs, upgrades and rolls back plugins, itself included.

## Where the package list comes from

The "Package host" setting (`pluginpackages_host`) holds one of two things, told
apart by `Core.indexLocation`:

| setting | list read from | a `file` entry is relative to |
|---|---|---|
| empty or unset | `Core.DEFAULT_INDEX`, `https://raw.githubusercontent.com/luutuankiet/koreader-ppw3/main/registry/index.json` | the folder of that URL |
| ends in `.json` | that URL | the folder of that URL |
| anything else, such as the gateway's `http://<host>:9999/pkg/` (what earlier versions saved) | `<setting>/index.json` | the setting |

Both lists are format 1 (`scripts/publish.sh` writes both, see the deploy
pipeline page). `Core.parseIndex` keeps an entry only if it has a safe `name`, a
string `version`, a numeric `size`, a 64-hex `sha256`, and either:

- `url`: absolute `https://` to a plain host name, no credentials, spaces or `..`
  (the GitHub manifest, pointing at a Release asset), or
- `file`: a bare file name, no `/`, `:` or `..` (the gateway's `/pkg/`).

`Core.packageUrl` prefers `url`. Plain `http://` is refused in `url` because the
checksum comes from the same untrusted path as the archive.

## Downloads and certificates

`Core.httpGet` is the only network call. For `https` it passes a `create` from
`Core.verifiedTls`: the chain is checked against `data/ca-bundle.crt` (shipped in
every KOReader install folder) and the host name against the certificate's
names with `Core.hostMatches`, because KOReader's LuaSec uses `verify = "none"`
and never checks host names. It sets `redirect = false` and follows up to 6
redirects itself, refusing https to http: `socket.http` drops the caller's
`create` on a redirect, and GitHub sends every Release download from
`github.com` to `release-assets.githubusercontent.com`, so that leg would
otherwise go unchecked. The trap page
`HTTPS_DOWNLOAD_ACCEPTS_ANY_CERTIFICATE.md` has the source lines.

| where | what |
|---|---|
| `pluginpackages_core.lua` | all disk work, no UI; tested by `test_core.lua` |
| `main.lua` | menu, dialogs, the subprocess that downloads |

Run the tests from a KOReader install folder: `./luajit <path>/test_core.lua`.

## What an install does

1. `prepare()` runs in a subprocess: download to `plugins/pluginpackages.stage/` (as `file`, or `<name>.tar.gz` for a `url` entry), check size and sha256, unpack, check the version matches the index, write the manifest. It touches nothing else, so a kill or a bad file leaves the installed plugin alone.
2. `swapIn()` runs in the UI process: copy local files into the new folder, then rename `.bak` aside, current to `.bak`, new to current. A failed rename undoes the earlier ones.

A power cut between those renames can leave a plugin with only `.bak`. The list still offers Roll back for it, unless the plugin was the installer itself.

## Local files

Archives leave out personal files such as `rssreader_configuration.lua`. Each install writes `.package-files` into the plugin folder, listing what the package brought. Any other file is local and is copied across installs and rollbacks. A folder with no manifest was deployed by hand, so everything in it not supplied by the new package is kept.

## Unpacking differs by KOReader version

`ffi/archiver` exists in `v2026.07.1` but not in `v2024.11` or `v2025.04`, so the dictionary downloader's pattern cannot be copied exactly. Without it the installer runs KOReader's bundled `./tar`, then the system `tar`.
