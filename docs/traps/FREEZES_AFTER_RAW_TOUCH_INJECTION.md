---
symptom: "Kindle froze after I sent touch events with evemu-event"
area: device-control
verified: 2026-10-28
---

# Raw touch injection freezes the Kindle

Sending touch input with `evemu-event` froze both test devices. Navigate with the `send_event` tool instead, which calls KOReader's `UIManager:broadcastEvent` (for example `ShowMenu`), and use `select_menu_item` to choose entries.

General rule: drive KOReader through its own event bus, never through the kernel input layer.
