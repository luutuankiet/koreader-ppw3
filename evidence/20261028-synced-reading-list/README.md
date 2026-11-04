# synced-reading-list: snapshot, not maintained

Promoted from the 20261028/synced-reading-list topic folder. Frozen when
committed; read it as evidence, never as current truth.

## gw.mjs
- was: `gw.mjs` in the 20261028/synced-reading-list topic folder
- handling: snapshot
- pin: sha256 `06e31bb7394a09caa7b8e179baccbea978b02d9c475ed5e7d885b02c3afc4ce0`
- captured: 2026-10-28 (file copied 2026-10-28T13:46:15Z)
- rebuild: `envscan hydrate evidence/20261028-synced-reading-list/gw.mjs > gw.mjs && node gw.mjs list`

Calls one kindle-gateway MCP tool from the shell (`node gw.mjs <tool> '<json>' [out.png]`),
saving any image content to a file. `GATEWAY_URL` overrides the default
`http://thinkpad:9999/mcp`. It loads the MCP SDK from the repo's
`kindle-gateway/package.json`, so it needs `npm install` there first. Saved to a
file rather than piped because it is an ES module that takes arguments.

## check-list-route.sh
- was: `check-list-route.sh` in the 20261028/synced-reading-list topic folder
- handling: snapshot
- pin: sha256 `7dc3d931bbdeebb138e0960e5fa4626a2d7528620f4fd62c606fc50372952760`
- captured: 2026-10-28 (file copied 2026-10-28T13:46:15Z)
- rebuild: `envscan hydrate evidence/20261028-synced-reading-list/check-list-route.sh | bash -s`

Independent check of the deployed `GET /syncs/list` route: status and response
shape with the test account, then status without auth. Prints no credentials or
row contents. It sources a `test-user.env` beside itself holding `KOSYNC_URL`,
`KOSYNC_USER` and `KOSYNC_KEY`; that file was not promoted, so when piped, export
those three names first and drop the `.` line, or save the hydrated copy next to
your own `test-user.env`.
