---
title: Setting up the Google Drive plugin on a Kindle
summary: install the gdriveepub plugin through Plugin packages, set the server URL, pair by QR code, delete downloaded files from the Kindle, and sign in again when Google asks (about once a week)
verified: 2026-11-17
---

# Setting up the Google Drive plugin on a Kindle

The Google Drive plugin (`gdriveepub`) lists your recent Google Drive files,
searches them, and downloads Google Docs as EPUB books (PDFs and EPUBs come
down as they are). It talks only to your own gdrive-epub server
(`gdriveepub-server/`, see `docs/architecture/gdrive-epub-server.md`), never
to Google directly.

## 1. Install

1. On the Kindle, open **Tools > Plugin packages**.
2. Pick **Google Drive** (`gdriveepub`) and install it.
3. Restart KOReader when asked.

## 2. Set the server URL

1. Open **Tools > Google Drive > Server URL**.
2. Enter your server's address, for example `https://<your-server-host>`.
   The plugin adds nothing to it; use the address the server prints after
   deploy.
3. **Check connection** confirms the server answers.

## 3. Pair by QR code

1. Open **Tools > Google Drive > Open**.
2. The first time, a QR code appears. Scan it with your phone and sign in to
   Google there. The Kindle checks every 3 seconds and opens the file list
   once your phone is done.
3. The plugin stores its device key in `settings/gdriveepub.lua` in the
   KOReader home folder. **Pair again** forgets the key and shows a new QR.

## 4. Use it

- **Recent** lists files by when you last opened them; **Search** matches
  words in the title or the text.
- **Filter** limits by updated or created date (1 day, 1 week, 1 month,
  3 months); **Sort** orders by opened, updated, created or name.
- Tap a file to download it to `GDrive/` in your home folder, then choose
  **Open** to read it now. Long-press a file for its details.
- Large Google Docs (over 10 MB) download too, but Google can take 30 s or
  more before the first byte; the plugin waits up to 2 minutes for it.

## 5. Clean up downloaded files

1. Open **Tools > Google Drive > Downloaded files** (it also works from the
   reader's menu). It lists every book in `GDrive/`, newest first, with its
   size and download date. Unfinished downloads (`*.part`) are hidden.
2. Tap files to select them, or use **Select all** / **Select none**.
3. **Delete** asks once ("Delete 2 files and their reading data?") and then
   removes each file with its reading data: progress, highlights and
   bookmarks in the book's `.sdr` folder.
4. The result names any file it skipped and why.

What to expect:

- **The book you are reading is never deleted**; it is skipped with "open in
  the reader". Close it first.
- **Same-named books share reading data.** KOReader keeps `Book.epub` and
  `Book.pdf` in one `Book.sdr` folder, so deleting one keeps the folder for
  the other; the folder goes once nothing else uses it.
- **History** follows KOReader's own setting for deleted files: the entry is
  removed, or kept and dimmed, exactly as when you delete from the file
  browser. Collections drop the file.
- Deleting only frees space on the Kindle. Nothing changes in Google Drive,
  and you can download the file again at any time.

## 6. Sign in again (about weekly)

Google ends the server's sign-in from time to time (roughly every 7 days for
an app in testing mode). When that happens any list or download shows
**Sign in again on your phone** with a QR code. Scan it, sign in, then tap
**Done, retry**. The device does not need to pair again.

## Known issues (0.1.2)

- Images in converted Google Docs are followed by a stray visible link.
- Numbered lists lose their numbers in converted Google Docs.
