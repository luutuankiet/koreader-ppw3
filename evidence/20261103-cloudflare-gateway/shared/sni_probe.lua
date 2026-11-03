-- HTTPS through KOReader's own socket.http + LuaSec to hosts behind Cloudflare,
-- which refuse a TLS handshake without SNI.
-- Run inside koreader-emu from /mnt/us/koreader: ./luajit sni_probe.lua
package.path = "common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
local http = require("socket.http")
local ltn12 = require("ltn12")
for _, url in ipairs({ "https://developers.cloudflare.com/", "https://workers.cloudflare.com/" }) do
  local t = {}
  local ok, code, headers = http.request{ url = url, method = "HEAD", sink = ltn12.sink.table(t) }
  print(url, ok, code, headers and headers["server"], headers and headers["cf-ray"])
end
