#!/usr/bin/env bash
# GitHub mode, dry run only: prints the gh commands, writes registry/index.json.
set -u
W=$HOME/dev/koreader-ppw3/.claude/worktrees/agent-a6042a442d249ba7b
E=<topic-folder>/73
cd "$W"
rm -rf "$E/github-build1" "$E/github-build2" "$E/archives"
echo "--- --dry-run without --github is refused"
bash scripts/publish.sh --dry-run syncedhistory; echo "exit $?"
echo "--- dry run, build 1 (writes registry/index.json)"
rm -f registry/index.json
GH_DIR="$E/github-build1" bash scripts/publish.sh --github --dry-run syncedhistory pluginpackages; echo "exit $?"
echo "--- dry run, build 2 into another folder, manifest to a scratch path"
GH_DIR="$E/github-build2" REGISTRY="$E/github-build2/index.json" bash scripts/publish.sh --github --dry-run syncedhistory pluginpackages; echo "exit $?"
echo "--- reproducible? build 1 vs build 2 vs local /pkg/ mode archives"
for f in syncedhistory-0.2.0.tar.gz pluginpackages-0.2.0.tar.gz; do
  cmp "$E/github-build1/$f" "$E/github-build2/$f" && echo "$f: build1 == build2"
  cmp "$E/github-build1/$f" "$E/local-mode/branch/$f" && echo "$f: github == local /pkg/"
done
echo "--- manifests from both builds identical?"
cmp registry/index.json "$E/github-build2/index.json" && echo "registry identical"
echo "--- saved archives and sha256"
mkdir -p "$E/archives"
cp "$E/github-build1/"*.tar.gz "$E/archives/"
(cd "$E/archives" && sha256sum *.tar.gz | tee SHA256SUMS)
echo "--- registry/index.json"
cat registry/index.json
echo "--- manifest sha256 matches saved archives"
python3 - "$W/registry/index.json" "$E/archives" <<'PY'
import hashlib, json, os, sys
idx = json.load(open(sys.argv[1]))
for p in idx["plugins"]:
    fn = os.path.basename(p["url"])
    data = open(os.path.join(sys.argv[2], fn), "rb").read()
    ok = hashlib.sha256(data).hexdigest() == p["sha256"] and len(data) == p["size"]
    print(p["name"], p["version"], fn, "sha256+size match" if ok else "MISMATCH")
PY
