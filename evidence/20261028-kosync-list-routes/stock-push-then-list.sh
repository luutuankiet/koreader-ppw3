#!/usr/bin/env bash
# Register a throwaway user, push progress exactly as stock KOReader does
# (PUT /syncs/progress, no file name), then GET /syncs/list.
#   ./stock-push-then-list.sh <base-url>
set -euo pipefail
BASE=${1%/}
A='Accept: application/vnd.koreader.v1+json'
RUN="$(date +%s)$RANDOM"
U="stocklist${RUN}"
K=$(printf '%s' "pw-$RUN" | md5sum | cut -d' ' -f1)
DOC=$(printf '%s' "Stock Book $RUN.epub" | md5sum | cut -d' ' -f1)
echo "user: $U  document: $DOC"
curl -sS -m 30 -X POST -H "$A" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$U\",\"password\":\"$K\"}" "$BASE/users/create"
curl -sS -m 30 -X PUT -H "$A" -H "x-auth-user: $U" -H "x-auth-key: $K" -H 'Content-Type: application/json' \
  -d "{\"document\":\"$DOC\",\"progress\":\"/body/DocFragment[3]/body/p[1]/text().0\",\"percentage\":0.25,\"device\":\"Kindle\",\"device_id\":\"STOCK$RUN\"}" \
  "$BASE/syncs/progress"
curl -sS -m 30 -H "$A" -H "x-auth-user: $U" -H "x-auth-key: $K" "$BASE/syncs/list"
