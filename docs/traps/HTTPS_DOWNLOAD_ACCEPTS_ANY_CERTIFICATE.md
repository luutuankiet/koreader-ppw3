---
symptom: "an https download from a KOReader plugin succeeds against a self-signed, expired or wrong-host certificate, or certificate checking works on the first host and silently stops after a redirect"
area: pluginpackages
verified: 2026-11-03
---

# KOReader's https does not check certificates, and a redirect drops yours

A plain `socket.http.request{ url = "https://..." }` inside KOReader accepts any
certificate. KOReader's bundled LuaSec (`common/ssl/https.lua`) configures TLS
with:

```lua
local cfg = {
  protocol = "any",
  options  = {"all", "no_sslv2", "no_sslv3", "no_tlsv1"},
  verify   = "none",
}
```

Two more gaps sit behind that one:

1. **LuaSec never checks the host name.** Even with `verify = "peer"` and a CA
   file, a valid certificate for any other site is accepted. The caller has to
   compare the certificate's subjectAltName (or common name) with the host.
2. **A redirect throws away the caller's `create`.** In
   `common/socket/http.lua`, `tredirect(reqt, location)` receives the caller's
   own request table, which has a `url` but no `scheme` field:

   ```lua
   if url.parse(newurl).scheme ~= reqt.scheme then
       reqt.port = nil
       reqt.create = nil end
   ```

   `"https" ~= nil` is always true, so every followed redirect falls back to
   the default https socket with `verify = "none"`. GitHub Release downloads
   always redirect (`github.com` answers `302` to
   `release-assets.githubusercontent.com`), so the leg that carries the bytes
   is the one left unchecked.

## Fix

`pluginpackages.koplugin/pluginpackages_core.lua` does all three itself:

- `Core.verifiedTls()` builds a `create` with
  `verify = { "peer", "fail_if_no_peer_cert" }` and
  `cafile = "data/ca-bundle.crt"` (Mozilla's list, shipped in every KOReader
  install folder, which is the working directory), and wraps `connect` to
  check the certificate names with `Core.hostMatches`.
- `Core.httpGet()` passes `redirect = false` and follows `301/302/303/307/308`
  itself, up to 6 hops, reusing the same `create` and refusing a redirect from
  https to http.

Copy those two functions rather than calling `socket.http` directly from any
other plugin that downloads code or credentials over https.

## Verify

Run on the emulator from the KOReader folder, through `Core.httpGet`:

| URL | result |
|---|---|
| a `github.com/.../releases/download/...` asset | downloaded; host checks logged for `github.com` and `release-assets.githubusercontent.com`; sha256 equal to GitHub's |
| `https://self-signed.badssl.com/` | refused: `certificate verify failed` |
| `https://untrusted-root.badssl.com/` | refused: `certificate verify failed` |
| `https://expired.badssl.com/` | refused: `certificate verify failed` |
| `https://wrong.host.badssl.com/` | refused: `certificate is not for wrong.host.badssl.com` |
| `https://badssl.com/` | accepted |

## Deliberate

The installer still checks size and sha256 from the manifest after download.
The TLS checks matter because the manifest itself arrives over https from
`raw.githubusercontent.com`: without them anyone on the network path could
serve a matching manifest and archive together.
