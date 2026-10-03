#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
tag="${1:-}"
out="${2:-$repo/dist/source}"
ref="${3:-$tag}"
case "$tag" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) printf '%s\n' 'usage: script/create_source_archive.sh vMAJOR.MINOR.PATCH [output-directory]' >&2; exit 64 ;;
esac
case "$out" in /*) ;; *) out="$repo/$out" ;; esac
version="${tag#v}"
name="unpolished-peas-${tag}-source.tar.gz"
manifest_version="$(sed -n 's/^    \.version = "\([0-9][0-9.]*\)",$/\1/p' "$repo/build.zig.zon" | head -n 1)"
if [ "$manifest_version" != "$version" ]; then
    printf 'source archive: build.zig.zon version %s does not match tag %s\n' "$manifest_version" "$tag" >&2
    exit 65
fi
mkdir -p "$out"
# `git archive` stamps members with the commit time. Release preparation must
# calculate the package hash before it commits the generated starter manifest,
# so normalize every tar member and gzip header instead of relying on that
# changing timestamp. The manifest itself is export-ignored.
git -C "$repo" archive --format=tar --prefix="unpolished-peas-${version}/" "$ref" | python3 "$repo/script/normalize_source_archive.py" "$out/$name"
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$out" && sha256sum "$name" > "${name}.sha256")
else
    (cd "$out" && shasum -a 256 "$name" > "${name}.sha256")
fi
printf '%s\n' "$out/$name"
