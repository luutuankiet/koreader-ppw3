#!/usr/bin/env bash
# Build KOReader plugin packages for the on-device installer, then either
# regenerate the package index the gateway serves at http://<gateway>:9999/pkg/
# or publish them as GitHub Release assets listed in registry/index.json.
#
# Usage: scripts/publish.sh [--force] <plugin>...
#        scripts/publish.sh --github [--dry-run] [--force] <plugin>...
#   <plugin>   a bare name (rssreader), a folder name (rssreader.koplugin)
#              or a path to a *.koplugin folder anywhere on disk.
#   --force    replace an archive of the same version whose content changed.
#   --github   publish to GitHub instead of $PKG_DIR (see below).
#   --dry-run  with --github: print the gh commands and write the manifest
#              entries, but call nothing.
#
# Local mode writes <name>-<version>.tar.gz into $PKG_DIR (default
# tmp/packages/pkg in this repo, gitignored, mounted read-only into the
# gateway container), then rebuilds $PKG_DIR/index.json from every archive
# in that folder.
#
# GitHub mode writes the same archive into $GH_DIR (default
# tmp/packages/github), runs `gh release create <name>-v<version> <archive>`
# on $GH_REPO (default luutuankiet/koreader-ppw3), then adds or replaces the
# plugin's entry in $REGISTRY (default registry/index.json) with the asset's
# download url. The manifest reaches devices once that file is merged to main.
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
# Needs bash, git, GNU tar, gzip and python3; GitHub mode also needs gh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="${PKG_DIR:-$REPO_ROOT/tmp/packages/pkg}"
GH_DIR="${GH_DIR:-$REPO_ROOT/tmp/packages/github}"
GH_REPO="${GH_REPO:-luutuankiet/koreader-ppw3}"
REGISTRY="${REGISTRY:-$REPO_ROOT/registry/index.json}"
FORCE=0
GITHUB=0
DRY_RUN=0

die() { echo "publish: $*" >&2; exit 1; }

plugins=()
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --github) GITHUB=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $arg" ;;
        *) plugins+=("$arg") ;;
    esac
done
[ "${#plugins[@]}" -gt 0 ] || die "usage: publish.sh [--github [--dry-run]] [--force] <plugin>..."
[ "$DRY_RUN" -eq 0 ] || [ "$GITHUB" -eq 1 ] || die "--dry-run only applies to --github"
# Archives for GitHub go to their own folder so the gateway's /pkg/ index
# never lists them by accident.
if [ "$GITHUB" -eq 1 ]; then OUT_DIR="$GH_DIR"; else OUT_DIR="$PKG_DIR"; fi
mkdir -p "$OUT_DIR" || die "cannot create package folder $OUT_DIR"
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

# What this run built, one plugin per index: for the GitHub releases.
built_name=(); built_version=(); built_archive=(); built_title=()

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

    archive="$OUT_DIR/$name-$version.tar.gz"
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
    local fullname; fullname="$(meta_field "$meta" fullname)"
    built_name+=("$name"); built_version+=("$version"); built_archive+=("$archive")
    built_title+=("${fullname:-$name} $version")
}

for p in "${plugins[@]}"; do
    publish_one "$p"
done

# Builds one index entry from an archive. Shared by both modes so the GitHub
# manifest and the /pkg/ index describe a package the same way.
cat > "$STAGE_ROOT/pkgentry.py" <<'PY'
import hashlib, re, sys, tarfile

FIELD = r'\b{}\s*=\s*(?:_\(\s*)?(?:"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'|\[\[(.*?)\]\])'

def field(src, key):
    m = re.search(FIELD.format(key), src, re.S)
    return next((g for g in m.groups() if g is not None), None) if m else None

def version_key(v):
    return [(0, int(p), "") if p.isdigit() else (1, 0, p) for p in re.split(r"[.+-]", v)]

def entry_for(path, fn):
    """Entry for the archive at path (named fn), or raises ValueError."""
    with tarfile.open(path, "r:gz") as tf:
        names = tf.getnames()
        roots = {n.split("/", 1)[0] for n in names}
        if len(roots) != 1 or not next(iter(roots)).endswith(".koplugin"):
            raise ValueError("archive root is not a single .koplugin folder")
        root = next(iter(roots))
        meta = tf.extractfile(root + "/_meta.lua").read().decode("utf-8")
    name = root[: -len(".koplugin")]
    version = field(meta, "version")
    if version is None or fn != f"{name}-{version}.tar.gz":
        raise ValueError("name or version does not match its _meta.lua")
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
    return entry
PY

if [ "$GITHUB" -eq 0 ]; then
# index.json is derived only from the archives in $PKG_DIR: one entry per
# plugin, its highest version. Older archives stay on disk, unlisted.
PYTHONPATH="$STAGE_ROOT" python3 - "$PKG_DIR" <<'PY'
import json, os, re, sys
from pkgentry import entry_for, version_key

pkg_dir = sys.argv[1]
latest = {}
for fn in sorted(os.listdir(pkg_dir)):
    m = re.fullmatch(r"(.+)-([0-9A-Za-z._+-]+)\.tar\.gz", fn)
    if not m:
        continue
    try:
        entry = entry_for(os.path.join(pkg_dir, fn), fn)
    except Exception as e:  # a stray or broken file never breaks the index
        print(f"publish: skipping {fn}: {e}", file=sys.stderr)
        continue
    name, version = entry["name"], entry["version"]
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
exit 0
fi

# GitHub mode: one release per plugin version, tagged <name>-v<version>, with
# the archive as its only asset. The release is created before the manifest
# entry is written, so a manifest never points at an asset that is missing.
[ "$DRY_RUN" -eq 1 ] || command -v gh >/dev/null || die "gh is not installed"
for i in "${!built_name[@]}"; do
    name="${built_name[$i]}"; version="${built_version[$i]}"; archive="${built_archive[$i]}"
    tag="$name-v$version"
    cmd=(gh release create "$tag" "$archive" --repo "$GH_REPO"
         --title "${built_title[$i]}" --notes "$name $version, installable from Plugin packages.")
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'dry run:'; printf ' %q' "${cmd[@]}"; printf '\n'
    else
        "${cmd[@]}"
    fi
    url="https://github.com/$GH_REPO/releases/download/$tag/$(basename "$archive")"
    PYTHONPATH="$STAGE_ROOT" python3 - "$REGISTRY" "$archive" "$url" <<'PY'
import json, os, sys
from pkgentry import entry_for

registry, path, url = sys.argv[1:4]
entry = entry_for(path, os.path.basename(path))
del entry["file"]
entry = {"name": entry.pop("name"), "version": entry.pop("version"), "url": url, **entry}
index = {"format": 1, "plugins": []}
if os.path.exists(registry):
    with open(registry, encoding="utf-8") as f:
        index = json.load(f)
plugins = {p["name"]: p for p in index.get("plugins", [])}
plugins[entry["name"]] = entry
index = {"format": 1, "plugins": [plugins[k] for k in sorted(plugins)]}
os.makedirs(os.path.dirname(registry), exist_ok=True)
tmp = registry + ".part"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(index, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.chmod(tmp, 0o644)
os.replace(tmp, registry)
print(f"{registry}: {entry['name']} {entry['version']} -> {url}")
PY
done
