---
title: Installing progress sync serverless on a Kindle
summary: install the serverless progress sync and synced reading list packages through Plugin packages, turn off the built-in Progress sync, log in, and where each setting is stored
verified: 2026-11-03
---

# Installing progress sync serverless and the synced reading list on a Kindle

These steps put two plugins on a Kindle running KOReader:

- **Progress sync serverless** (`kosyncserverless`): a copy of KOReader's
  built-in Progress sync that copes with a server which sleeps when idle. It
  shows "Waking sync server..." while the server starts, retries, keeps a
  queue of positions it could not send, and holds sleep for up to 30 seconds
  so the last page you read reaches the server.
- **Synced reading list** (`syncedhistory`): a list of the books you are
  reading on every device logged into the same server.

Both come from the package host that the gateway serves at `/pkg/`.

## Before you start

- The Kindle runs KOReader and already has the **Plugin packages** plugin
  (`pluginpackages`). If not, copy `pluginpackages.koplugin/` from the
  `pluginpackages-<version>.tar.gz` archive into `koreader/plugins/` over USB
  first, checking the archive's sha256 against the gateway's
  `/pkg/index.json`, then restart KOReader.
- The Kindle is on Wi-Fi and can reach the gateway machine.
- On the computer, build the packages (once per change):

  ```
  scripts/publish.sh kosyncserverless
  scripts/publish.sh syncedhistory
  ```

  Both must then appear in `http://<gateway host>:9999/pkg/index.json`.
- If an older copy of either plugin was copied onto the Kindle by hand (or by
  the deploy tool), delete that folder from `koreader/plugins/` first, so the
  installed folder holds exactly what the package ships. Your settings are in
  `koreader/settings/`, not in the plugin folder, so they survive this.

## 1. Install both packages

1. Open the main menu, go to the **Tools** tab (the wrench), and open
   **Plugin packages**. It is on the second page of Tools.
2. Check the last row, **Package host**. It must point at
   `http://<gateway host>:9999/pkg/`. Tap it to change it.
3. Tap **Progress sync serverless**, then **Install**, then **Install** again
   to confirm the download. When it says "installed. Restart KOReader now to
   use it?", tap **Later**.
4. Tap **Synced reading list**, then **Install**, **Install**, and this time
   tap **Restart**.

After the restart, both rows in Plugin packages show their version with no
arrow, which means they are installed and current.

## 2. Turn off the built-in Progress sync

Running both sync plugins at once makes them send the same position twice
and fight over the same book.

1. Main menu, **Tools** tab, **More tools**, **Plugin management**,
   **Built-in plugins**.
2. Page forward to **Progress sync** and tap it so it is no longer checked.
3. Tap **Restart now**.
4. To confirm, go back to the same place after the restart: **Progress sync**
   is unchecked.

## 3. Set the server and log in

Progress sync serverless copies the server, username and key from the
built-in plugin the first time it starts, if the built-in plugin was logged
in. If it was, you are already logged in and can skip to step 4. Otherwise,
with a book open:

1. Main menu, **Tools** tab, **Progress sync serverless**.
2. **Custom sync server**: enter your progress sync server address, for
   example your Cloud Run service address, starting with `https://`.
3. **Register / Login**: enter your username and password and tap **Login**.
   Use the same account on every device that should share positions.
4. Optional: **Automatically keep documents in sync** pushes your position
   as you read and before sleep, and pulls it when you open a book.

## 4. Check the synced reading list

1. Main menu, **Tools** tab: the entry **Synced reading list backend** should
   read "Progress sync serverless". Its default, **Automatic (serverless when
   installed)**, picks the serverless plugin whenever it is installed and
   enabled, so normally there is nothing to change.
2. Main menu, last tab (the menu icon), **Synced reading list**: the list
   loads from the server. Tap a book that is on this device to open it at
   the latest position from any device.

## Where the settings live

All inside `koreader/settings/` on the Kindle (under the KOReader home folder):

| file | what it holds |
|---|---|
| `kosyncserverless.lua` | server address (`custom_server`), `username`, `userkey`, `auto_sync`, sync behaviour, and `carried_over_from_kosync` (the one-time copy from the built-in plugin has happened) |
| `kosyncserverless_queue.lua` | positions waiting to be sent; it is `return {}` when nothing is waiting |
| `syncedhistory.lua` | the synced reading list's cache and its backend choice (`progress_sync_backend`) |
| `kosync.lua` | the built-in plugin's settings; left alone, and only read once for the copy |

Which plugins are disabled is in `koreader/settings.reader.lua`, under
`plugins_disabled` (`["kosync"] = true` once step 2 is done).

Edit these files only with KOReader closed: KOReader reads them once at start
and writes them back on exit, so a change made while it runs is lost.

## Updating later

Run `scripts/publish.sh` again after bumping `version` in the plugin's
`_meta.lua`, then open Plugin packages on the Kindle: the row shows
`<installed> → <new>`. Tap it and install. The previous version is kept as a
backup, and the same row offers **Roll back** if the new one misbehaves.
