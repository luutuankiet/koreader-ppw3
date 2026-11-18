---
title: Google Drive to EPUB: research and measured findings
summary: why no existing KOReader plugin could read Google Docs, the Google API limits the server is built around, how large exports behaved on Cloud Run (0.3.0 and 0.4.0), and why diagrams were unreadable until server 0.5.0
verified: 2026-11-18
---

# Google Drive to EPUB: research and measured findings

Background for the Google Drive plugin (`gdriveepub.koplugin/`) and its server
(`gdriveepub-server/`). How the server works today is in
the "Google Drive to EPUB server" page in `docs/architecture/`; the two decisions are
`docs/adr/0007-google-drive-access-through-a-cloud-run-server.md` and
`docs/adr/0008-line-art-images-keep-twice-the-screen-resolution.md`. This page keeps
what was learned on the way, which those pages do not repeat.

## No existing plugin did this (researched 2026-11-17)

- KOReader core has no Google Drive provider. Cloud storage lives in
  `plugins/cloudstorage.koplugin/` with Dropbox, FTP and WebDAV providers only. Requests
  for Google Drive (koreader/koreader issues 2165 and 7474) were closed unimplemented.
- Six third-party projects were read (read only, nothing run): moohaad/gdrive.koplugin,
  hronek/gdriveplus.koplugin, mewforest/gdriveshelf.koplugin, Fabo2303/drivebooks.koplugin,
  tamvcspk/gdrive.koplugin and dpmwynkoop-arch/koreader-oauth. None exports Google Docs
  to EPUB, none signs in from the Kindle (each needs a computer, or the OAuth Playground
  with the full `drive` scope), and two have no working code.

## Google API limits the design follows

- `files.export` to `application/epub+zip` works for Google Docs, capped at 10 MB of
  exported content. Uploaded PDFs and EPUBs come through `files.get?alt=media` instead.
- Google's device sign-in flow (the one for TVs) allows only `drive.file` and
  `drive.appdata` from Drive, so it cannot list the files a person already has. That is
  why sign-in happens on a phone against a small server that holds the refresh token
  (ADR 0007).
- Refresh tokens of an External app left in Testing mode expire after 7 days, which is
  why the plugin asks for a new Google sign-in about once a week.

## Large exports on Cloud Run (2026-11-17)

Measured on a large private Google Doc through the deployed server:

| server | status | EPUB bytes | first byte | total | images in the EPUB |
|---|---|---|---|---|---|
| 0.3.0 (1800 s timeout, 1 GiB) | 200 | 19373020 | 20.3 s | 21.2 s | as exported |
| 0.4.0 (images re-encoded for e-ink) | 200 | 2201195 | 30.0 s | 30.2 s | 78 PNG, 2036785 bytes |

Re-encoding cut the images from 19197670 to 2036785 bytes, at the cost of cleanup
time (4.2 s to 17.3 s locally, 90 MB peak memory). The 0.4.0 run is kept in
`evidence/20261117-drive-to-epub/live-dl-0.4.0.log`, with the counting script beside it.
The emulator was not used to open these large books.

## Diagrams too small to read (2026-11-18)

A Google Doc with 27 wide diagrams looked grainy and unreadable on the Kindle. Until
server 0.5.0 every image was fitted within the screen, 1072x1448, so a 2048 px wide
diagram lost about half its width and its labels came out about 9 px tall, under 1 mm
on the 300 ppi screen. Zooming in KOReader only enlarges those same pixels.

A first diagnosis blamed KOReader's per-book Image Scaling option (`fast`, nearest
neighbour). Switching it to `best` on the emulator made no visible difference, so no
plugin change shipped. The fix is on the server: 0.5.0 (PR 53) keeps line art up to
2144x2896 in 16-level gray. On the test doc the EPUB grew from 838 KB to 1567037 bytes
and the largest image is 1875x1999 (`evidence/20261118-gdrive-image-fidelity/`).
Still unchecked: the largest page on a real Paperwhite 3.

## Not built yet: refreshing downloaded Docs

The plugin keeps no record of which Drive file a download came from, and names the
local file after the Drive title, so two Docs with the same title overwrite each
other. Refreshing changed Docs would need the plugin to store each download's Drive id
and modified time; the server already sends both (`modified_time` in lists,
`X-Modified-Time` on downloads), so no server change is needed.
