#!/usr/bin/env bash
# Local /pkg/ mode: main's publish.sh vs the branch's, same plugins, separate
# PKG_DIRs, compared byte for byte (archives and index.json) plus stdout.
set -u
W=$HOME/dev/koreader-ppw3/.claude/worktrees/agent-a6042a442d249ba7b
E=<topic-folder>/73
OUT=$E/local-mode
rm -rf "$OUT"; mkdir -p "$OUT/main" "$OUT/branch"
# main's script must run from the worktree so it packages the same plugin files
cp "$E/main-publish/publish.sh" "$W/scripts/publish-main.sh"
PKG_DIR="$OUT/main" bash "$W/scripts/publish-main.sh" syncedhistory pluginpackages > "$OUT/main.stdout" 2>&1
echo "main exit $?"
PKG_DIR="$OUT/branch" bash "$W/scripts/publish.sh" syncedhistory pluginpackages > "$OUT/branch.stdout" 2>&1
echo "branch exit $?"
rm -f "$W/scripts/publish-main.sh"
echo "--- diff -r of PKG_DIRs (empty = identical)"
diff -r "$OUT/main" "$OUT/branch"; echo "diff exit $?"
echo "--- stdout diff, PKG_DIR path replaced by <PKG_DIR>"
diff <(sed "s|$OUT/main|<PKG_DIR>|g" "$OUT/main.stdout") <(sed "s|$OUT/branch|<PKG_DIR>|g" "$OUT/branch.stdout"); echo "stdout diff exit $?"
echo "--- branch stdout"; cat "$OUT/branch.stdout"
echo "--- index.json"; cat "$OUT/branch/index.json"
echo "--- second run of branch script (idempotent)"
PKG_DIR="$OUT/branch" bash "$W/scripts/publish.sh" syncedhistory pluginpackages
