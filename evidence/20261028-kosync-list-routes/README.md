# kosync-list-routes: snapshot, not maintained

Promoted from the 20261028/kosync-list-routes topic folder. Frozen when
committed; read it as evidence, never as current truth.

## stock-push-then-list.sh
- was: `stock-push-then-list.sh` in the 20261028/kosync-list-routes topic folder
- handling: snapshot
- pin: sha256 `a2d0dc6f5d450dda91fd36d875db9de903af23e9b4d1fc56efe4944d674fd425`
- captured: 2026-10-28 (file copied 2026-10-28T13:46:15Z)
- rebuild: `envscan hydrate evidence/20261028-kosync-list-routes/stock-push-then-list.sh | bash -s "$KOSYNC_URL"`

Registers a throwaway user, pushes progress exactly as stock KOReader does
(`PUT /syncs/progress`, no file name), then reads `GET /syncs/list`.

## stock-push-then-list.txt
- was: `stock-push-then-list.txt` in the 20261028/kosync-list-routes topic folder
- handling: snapshot
- pin: sha256 `a8492866011c1cfe8d66964cd58c2615718ef48a0c3807d6c7b79f83dae69c46`
- captured: 2026-10-28T12:23:19Z (the server timestamp in the output)
- rebuild: none: a recorded run

Output of the script above against the deployed server. The decisive line is the
last one: a row pushed the stock way comes back from `/syncs/list` with
`"filename":null`.
