---
symptom: "a screenshot shows the Kindle clock, battery or WiFi icon in the top corners of KOReader, but the physical screen is clean"
area: kindle-gateway
verified: 2026-10-29
---

# A screenshot shows the Kindle status bar that the screen does not

When KOReader runs with the Kindle framework still up (the normal KUAL launch), the Kindle status bar service keeps drawing its clock, battery and WiFi icon into the framebuffer every minute. `koreader.sh --kual` SIGSTOPs the window manager `awesome` (FW >= 5.7.2), and with `awesome` stopped nothing asks the e-ink panel to refresh that area, so the drawing never reaches the glass. The `screenshot` tool reads the framebuffer (`fbgrab`), not the panel, so it still captures the status bar. Observed on kindle-1 (FW 5.14.2): a screenshot at `00:03` showed `00:03` top-left and `81%` top-right while the reader saw a clean page.

Check: whether `awesome` is stopped. `T` means the screen is clean and only the framebuffer is dirty.

```
grep State /proc/$(pidof awesome)/status
```

If it says `S`, the clock really is on the screen: KOReader was started without `--kual`. The gateway restart passes it (`kindle-gateway/src/device-commands.ts`); a launch from anywhere else may not.
