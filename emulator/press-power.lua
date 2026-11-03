-- Presses F2 (the emulator's Power key) on the Xvfb display through XTest,
-- so a sleeping emulator resumes through its real PowerRelease handler.
-- Run inside koreader-emu: DISPLAY=:73 ./luajit press-power.lua (or run emulator/wake.sh from the host)
local ffi = require("ffi")
ffi.cdef[[
typedef struct _XDisplay Display;
Display *XOpenDisplay(const char *);
unsigned char XKeysymToKeycode(Display *, unsigned long);
int XTestFakeKeyEvent(Display *, unsigned int, int, unsigned long);
int XFlush(Display *);
int XCloseDisplay(Display *);
]]
local X = ffi.load("libX11.so.6")
local Xtst = ffi.load("libXtst.so.6")
local d = X.XOpenDisplay(nil)
assert(d ~= nil, "cannot open display")
local kc = X.XKeysymToKeycode(d, 0xFFBF) -- XK_F2
Xtst.XTestFakeKeyEvent(d, kc, 1, 0)
X.XFlush(d)
Xtst.XTestFakeKeyEvent(d, kc, 0, 50)
X.XFlush(d)
X.XCloseDisplay(d)
print("pressed F2, keycode " .. kc)
