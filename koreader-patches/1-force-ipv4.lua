--[[
Force KOReader's network connections onto IPv4.

Why: on a network that hands out IPv6 addresses but drops IPv6 traffic, a
server that publishes several IPv6 and IPv4 addresses makes
KOReader try every IPv6 address first, one at a time, each until the 10 s
timeout, on the UI thread. Opening an OPDS catalog then freezes the reader
for minutes before it gives up. Creating IPv4-only sockets skips the dead
addresses entirely.

How: socket.http and LuaSec's ssl.https create their sockets through
socket.tcp() at request time, and KOReader's socketutil wraps whatever
socket.tcp is when it first loads. This patch uses priority 1 ("early"), which
runs before socketutil is loaded, so the timeout wrapper ends up wrapping the
IPv4 constructor and every later HTTP or HTTPS request uses it.

Install: copy to <KOReader data dir>/patches/ and restart KOReader.
]]

local logger = require("logger")
local socket = require("socket")

if socket.tcp4 then
    if package.loaded["socketutil"] then
        logger.warn("force-ipv4: socketutil already loaded, its timeout wrapper keeps the old socket.tcp")
    end
    socket.tcp = socket.tcp4
    logger.info("force-ipv4: socket.tcp now creates IPv4-only sockets")
else
    logger.warn("force-ipv4: socket.tcp4 not available, patch not applied")
end
