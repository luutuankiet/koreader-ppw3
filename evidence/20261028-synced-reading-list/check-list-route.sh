#!/usr/bin/env bash
# Independent check of the deployed GET /syncs/list route with the test account.
# Prints only HTTP status and response shape, never credentials or row contents.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/test-user.env"
out="$(curl -sS -m 20 -w $'\n%{http_code}' \
  -H 'Accept: application/vnd.koreader.v1+json' \
  -H "x-auth-user: ${KOSYNC_USER}" -H "x-auth-key: ${KOSYNC_KEY}" \
  "${KOSYNC_URL}/syncs/list")"
status="${out##*$'\n'}"
body="${out%$'\n'*}"
echo "GET /syncs/list status=${status}"
case "$body" in
  \[*) echo "body is a JSON array, first char '[' , rows=$(printf '%s' "$body" | grep -o '"document"' | grep -c .)" ;;
  *) echo "body is not an array (len ${#body})" ;;
esac
out="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' -H 'Accept: application/vnd.koreader.v1+json' "${KOSYNC_URL}/syncs/list")"
echo "GET /syncs/list without auth status=${out}"
