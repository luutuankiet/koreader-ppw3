# drive-to-epub: snapshot, not maintained

Promoted from the 20261117/$SERVICE topic folder (the first research, build and
large-export work on the Google Drive to EPUB server and plugin). Frozen when
committed; read it as evidence, never as current truth. The write-up is
`docs/reference/drive-to-epub-findings.md`.

## live-dl-0.4.0.log
- was: `$SERVICE/large-export/phase2/live-dl.log` in the 20261117 topic folder
- handling: snapshot
- pin: sha256 `388cc7d47198315e770d099f09388678cdab246a14900cdb07e4002d612d6b11`
- captured: 2026-11-18T01:36:06Z
- rebuild: `none: a recorded run` (download of a large private Google Doc through server 0.4.0 on Cloud Run, then `epubcounts.py` on the result)

## epubcounts.py
- was: `$SERVICE/large-export/scripts/epubcounts.py` in the 20261117 topic folder
- handling: snapshot
- pin: sha256 `6b342cbec8c95a6a6483d38453048c1d427dbaa188dbdcc53107ee1940e3bd90`
- captured: 2026-11-18T01:36:06Z
- rebuild: `envscan hydrate evidence/20261117-drive-to-epub/epubcounts.py | python3 - <file.epub>`
