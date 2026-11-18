# gdrive-image-fidelity: snapshot, not maintained

Promoted from the 20261118/gdrive-image-fidelity topic folder (why diagrams in
converted Google Docs were unreadable on the Kindle, and the server 0.5.0 fix).
Frozen when committed; read it as evidence, never as current truth. The decision
is `docs/adr/0008-line-art-images-keep-twice-the-screen-resolution.md`; the
summary is in `docs/reference/drive-to-epub-findings.md`.

## size_check.py
- was: `server2x/size_check.py` in the 20261118/gdrive-image-fidelity topic folder
- handling: snapshot
- pin: sha256 `2b0235fee7b8c03a16118ce4d74990ea0bac1a6bb872748f88754a4cc5c0369f`
- captured: 2026-11-18T01:36:06Z
- rebuild: `cd gdriveepub-server && envscan hydrate ../evidence/20261118-gdrive-image-fidelity/size_check.py | uv run python - <dir holding raw/raw.epub> <out.epub>`

## size_check-0.5.0.log
- was: `server2x/size_check.log` in the 20261118/gdrive-image-fidelity topic folder
- handling: snapshot
- pin: sha256 `23e74269614f912ce906545b9bde18104d039f80bf000f626c3fa693ca9864f3`
- captured: 2026-11-18T01:36:06Z
- rebuild: `none: a recorded run` (the raw Google export of the 27-diagram test doc is private and was not kept)
