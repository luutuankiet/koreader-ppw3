#!/usr/bin/env bash
# Build KOReader plugin packages for the on-device installer and regenerate
# the package index the gateway serves at http://<gateway>:9999/pkg/.
#
# Usage: scripts/publish.sh [--force] <plugin>...
#   <plugin>  a bare name (rssreader), a folder name (rssreader.koplugin)
#             or a path to a *.koplugin folder anywhere on disk.
#   --force   replace an archive of the same version whose content changed.
#
# Writes <name>-<version>.tar.gz into $PKG_DIR (default
# ~/kindle-packages/pkg, mounted read-only into the gateway container), then
# rebuilds $PKG_DIR/index.json from every archive in that folder.
#
# What goes into an archive:
#   - files git would commit (tracked, or untracked but not ignored), so
#     gitignored personal config such as rssreader_configuration.lua never
#     leaves this machine; without git, every file in the folder;
#   - minus dev files: dotfiles, tests (test_*.lua, *_test.lua, *_spec.lua,
#     spec/, tests/, run_tests.sh), *.patch and *.md.
# The archive's only top-level entry is <name>.koplugin/.
#
# The version comes from `version = "..."` in the plugin's _meta.lua; a
# plugin without one is refused. An optional `min_koreader = "v2024.11"` in
# _meta.lua is copied into the index.
#
# Needs bash, git, GNU tar, gzip and python3.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="${PKG_DIR:-$HOME/kindle-packages/pkg}"
FORCE=0

die() { echo "publish: $*" >&2; exit 1; }

plugins=()
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $arg" ;;
        *) plugins+=("$arg") ;;
    esac
done
[ "${#plugins[@]}" -gt 0 ] || die "usage: publish.sh [--force] <plugin>..."
[ -d "$PKG_DIR" ] || die "package folder $PKG_DIR does not exist (create it, or set PKG_DIR)"
STAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGE_ROOT"' EXIT

resolve_plugin() {
    local arg="$1"
    if [ -d "$arg" ] && [[ "$(basename "$arg")" == *.koplugin ]]; then
        (cd "$arg" && pwd); return
    fi
    local name="${arg%.koplugin}"
    if [ -d "$REPO_ROOT/$name.koplugin" ]; then
        echo "$REPO_ROOT/$name.koplugin"; return
    fi
    die "no plugin folder for '$arg' (looked for $REPO_ROOT/$name.koplugin)"
}

# Prints the files to package, one path per line, relative to the plugin folder.
list_files() {
    local dir="$1"
    if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$dir" ls-files -z --cached --others --exclude-standard -- . \
            | tr '\0' '\n'
    else
        (cd "$dir" && find . -type f | sed 's|^\./||')
    fi | while IFS= read -r f; do
        [ -f "$dir/$f" ] || continue          # tracked but deleted in the working tree
        case "/$f" in
            */.*) continue ;;                 # dotfiles and dot-folders
            */test_*.lua|*_test.lua|*_spec.lua|*/run_tests.sh) continue ;;
            */spec/*|*/tests/*) continue ;;
            *.patch|*.md) continue ;;
        esac
        printf '%s\n' "$f"
    done | LC_ALL=C sort
}

# Reads key = "value" from _meta.lua (plain strings, _("...") and [[...]]).
meta_field() {
    python3 - "$1" "$2" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
key = sys.argv[2]
m = re.search(r'\b' + key + r'\s*=\s*(?:_\(\s*)?(?:"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'|\[\[(.*?)\]\])', src, re.S)
if m:
    print(next(g for g in m.groups() if g is not None))
PY
}

publish_one() {
    local dir name meta version archive tmp stage
    dir="$(resolve_plugin "$1")"
    name="$(basename "$dir" .koplugin)"
    meta="$dir/_meta.lua"
    [ -f "$meta" ] || die "$name: no _meta.lua"
    version="$(meta_field "$meta" version)"
    [ -n "$version" ] || die "$name: _meta.lua declares no version = \"...\"; add one"
    [[ "$version" =~ ^[0-9A-Za-z._+-]+$ ]] || die "$name: version '$version' is not filename-safe"
    local meta_name; meta_name="$(meta_field "$meta" name)"
    if [ -n "$meta_name" ] && [ "$meta_name" != "$name" ]; then
        echo "publish: warning: $name.koplugin/_meta.lua says name = \"$meta_name\"" >&2
    fi

    archive="$PKG_DIR/$name-$version.tar.gz"
    stage="$STAGE_ROOT/$name"
    rm -rf "$stage"
    mkdir -p "$stage/$name.koplugin"
    list_files "$dir" > "$stage/files"
    [ -s "$stage/files" ] || die "$name: nothing to package"
    grep -qx '_meta.lua' "$stage/files" || die "$name: _meta.lua is ignored by git; it must ship"
    grep -qx 'main.lua' "$stage/files" || die "$name: main.lua is ignored by git; it must ship"
    # Copy into a staging folder so the archive's root is exactly <name>.koplugin/.
    tar -C "$dir" -cf - --verbatim-files-from -T "$stage/files" | tar -C "$stage/$name.koplugin" -xf -

    # Same content always gives the same bytes: fixed order, owner and mtime,
    # ustar format (busybox tar reads it), gzip without a timestamp.
    tmp="$stage/$name-$version.tar.gz"
    tar -C "$stage" --format=ustar --sort=name --owner=0 --group=0 --numeric-owner \
        --mtime='@0' --mode='u+rwX,go+rX,go-w' -cf - "$name.koplugin" | gzip -n -9 > "$tmp"

    if [ -f "$archive" ] && ! cmp -s "$tmp" "$archive"; then
        if [ "$FORCE" -ne 1 ]; then
            die "$name: $archive exists with different content; bump version in _meta.lua or pass --force"
        fi
        echo "publish: replacing $archive (--force)" >&2
    fi
    if [ -f "$archive" ] && cmp -s "$tmp" "$archive"; then
        echo "$name $version: unchanged"
    else
        cp "$tmp" "$archive.part"
        mv -f "$archive.part" "$archive"
        echo "$name $version: $(wc -l < "$stage/files") files -> $archive"
    fi
}

for p in "${plugins[@]}"; do
    publish_one "$p"
done

# index.json is derived only from the archives in $PKG_DIR: one entry per
# plugin, its highest version. Older archives stay on disk, unlisted.
python3 - "$PKG_DIR" <<'PY'
import hashlib, json, os, re, sys, tarfile

pkg_dir = sys.argv[1]
FIELD = r'\b{}\s*=\s*(?:_\(\s*)?(?:"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'|\[\[(.*?)\]\])'

def field(src, key):
    m = re.search(FIELD.format(key), src, re.S)
    return next((g for g in m.groups() if g is not None), None) if m else None

def version_key(v):
    return [(0, int(p), "") if p.isdigit() else (1, 0, p) for p in re.split(r"[.+-]", v)]

latest = {}
for fn in sorted(os.listdir(pkg_dir)):
    m = re.fullmatch(r"(.+)-([0-9A-Za-z._+-]+)\.tar\.gz", fn)
    if not m:
        continue
    path = os.path.join(pkg_dir, fn)
    try:
        with tarfile.open(path, "r:gz") as tf:
            names = tf.getnames()
            roots = {n.split("/", 1)[0] for n in names}
            if len(roots) != 1 or not next(iter(roots)).endswith(".koplugin"):
                raise ValueError("archive root is not a single .koplugin folder")
            root = next(iter(roots))
            meta = tf.extractfile(root + "/_meta.lua").read().decode("utf-8")
    except Exception as e:  # a stray or broken file never breaks the index
        print(f"publish: skipping {fn}: {e}", file=sys.stderr)
        continue
    name = root[: -len(".koplugin")]
    version = field(meta, "version")
    if version is None or fn != f"{name}-{version}.tar.gz":
        print(f"publish: skipping {fn}: name or version does not match its _meta.lua", file=sys.stderr)
        continue
    with open(path, "rb") as f:
        data = f.read()
    entry = {
        "name": name,
        "version": version,
        "file": fn,
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "description": " ".join((field(meta, "description") or "").split()),
    }
    fullname = field(meta, "fullname")
    if fullname:
        entry["fullname"] = fullname
    min_ko = field(meta, "min_koreader")
    if min_ko:
        entry["min_koreader"] = min_ko
    if name not in latest or version_key(version) > version_key(latest[name]["version"]):
        latest[name] = entry

index = {"format": 1, "plugins": [latest[k] for k in sorted(latest)]}
tmp = os.path.join(pkg_dir, ".index.json.part")
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(index, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.chmod(tmp, 0o644)
os.replace(tmp, os.path.join(pkg_dir, "index.json"))
print(f"index.json: {len(latest)} plugin(s) in {pkg_dir}")
PY
