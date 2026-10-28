---
symptom: "git status shows a symlinked plugin directory as untracked although it is in .gitignore"
area: repo-layout
verified: 2026-10-28
---

# Trailing slash in .gitignore skips symlinks

An entry such as `rssreader.koplugin/` matches directories only, not a symlink to a directory. Drop the trailing slash (`rssreader.koplugin`), which matches both. This repo's `.gitignore` uses the slashless form for that reason.

General rule: use the slashless form whenever the path might be a symlink.
