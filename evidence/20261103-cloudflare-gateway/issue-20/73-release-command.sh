#!/usr/bin/env bash
# Releases for issue #20 (was #73 before the history rewrite). Run by the orchestrator AFTER the push freeze lifts
# and BEFORE (or together with) merging the PR that adds registry/index.json.
#
# Uploads the archives saved in this folder, not a fresh build: their sha256 is
# what registry/index.json on the branch already records. The build is
# byte-for-byte reproducible from the same plugin files on this host (two
# builds and the local /pkg/ build all compare equal, see
# 73-github-dry-run.log), but a rebuild after a rebase that touches
# syncedhistory.koplugin/ or pluginpackages.koplugin/, or on a host with a
# different gzip, could differ. If plugin code changes before release, rebuild
# instead with `scripts/publish.sh --github <plugin>` on the final tree and
# commit the registry/index.json it rewrites.
#
# PRECONDITION: devices download the manifest and assets without credentials,
# so luutuankiet/koreader-ppw3 must be PUBLIC (it was private before the
# history rewrite; checked public on 2026-11-03). The check below stops if not.
set -euo pipefail
test "$(gh repo view luutuankiet/koreader-ppw3 --json visibility -q .visibility)" = PUBLIC \
    || { echo "luutuankiet/koreader-ppw3 is not public; stop" >&2; exit 1; }
E=<topic-folder>/73/archives

# 1. Check the saved archives still match the manifest's checksums.
(cd "$E" && sha256sum -c SHA256SUMS)
# expected:
#   5bfca3e141b1590d9cce7f02f07fa825e692dea79f45df704c1afc3e00b2f65d  pluginpackages-0.2.0.tar.gz
#   aad7aa2cd2854d53c70b883270ff860728f80dfa5f17714beb255d6a975f9a1e  syncedhistory-0.2.0.tar.gz

# 2. Create the two releases (exactly what `publish.sh --github` would run).
gh release create syncedhistory-v0.2.0 "$E/syncedhistory-0.2.0.tar.gz" \
    --repo luutuankiet/koreader-ppw3 \
    --title "Synced reading list 0.2.0" \
    --notes "syncedhistory 0.2.0, installable from Plugin packages."
gh release create pluginpackages-v0.2.0 "$E/pluginpackages-0.2.0.tar.gz" \
    --repo luutuankiet/koreader-ppw3 \
    --title "Plugin packages 0.2.0" \
    --notes "pluginpackages 0.2.0, installable from Plugin packages."

# 3. Confirm the public download URLs serve the same bytes.
T="$(mktemp -d)"
curl -fsSL -o "$T/syncedhistory-0.2.0.tar.gz" \
    https://github.com/luutuankiet/koreader-ppw3/releases/download/syncedhistory-v0.2.0/syncedhistory-0.2.0.tar.gz
curl -fsSL -o "$T/pluginpackages-0.2.0.tar.gz" \
    https://github.com/luutuankiet/koreader-ppw3/releases/download/pluginpackages-v0.2.0/pluginpackages-0.2.0.tar.gz
(cd "$T" && sha256sum -c "$E/SHA256SUMS")
rm -rf "$T"

