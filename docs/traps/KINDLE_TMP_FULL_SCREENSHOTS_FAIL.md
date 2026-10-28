---
symptom: "screenshots or deploys fail on the Kindle with no space left on device"
area: device-control
verified: 2026-10-28
---

# The 64MB /tmp fills with framebuffer dumps

The Kindle `/tmp` is a 64MB tmpfs. Screenshot capture leaves `mcp_ss.png`, `koreader-fb.dump` and `fm-out-*` files. `capture_screenshot`, `deploy_plugin` and `restart_koreader` all clean these up; manual `fbgrab` runs or interrupted calls do not.

Fix: `rm -f /tmp/mcp_ss.png /tmp/koreader-fb.dump /tmp/fm-out-*` on the device.

General rule: any tool that writes temp files on a small tmpfs must delete them in the same call.
