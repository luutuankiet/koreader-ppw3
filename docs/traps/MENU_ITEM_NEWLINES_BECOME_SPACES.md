---
symptom: "newline in a KOReader menu item text shows as a space, no paragraph break"
area: rssreader
verified: 2026-10-28
---

# Menu items strip newlines unconditionally

KOReader's `frontend/ui/widget/menu.lua` runs `self.text:gsub("\\n", " ")` at the top of `MenuItem:init()`, before choosing single-line or multi-line layout, so a newline can never act as a paragraph break in a menu item. The `multilines_forced` option only changes truncation versus word wrap, not newline handling.

Workarounds: a visible separator character (this repo used a small triangle), a custom widget, or patching KOReader. Item height follows items-per-page: about 15 items per page leaves roughly two text lines each on this screen, so more excerpt text means fewer items per page.

General rule: check a framework widget's input handling before designing content that depends on formatting characters.
