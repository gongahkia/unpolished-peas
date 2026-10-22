#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

# Exercise the real local HTTP fetch and package hashing without changing the
# checkout, creating release tags, contacting GitHub, or compiling the engine.
for tag in 1.0.7 v1.0.7; do
    fixture="$tmp/$tag"
    mkdir -p "$fixture/script" "$fixture/templates/starter"
    cp "$repo/script/prepare_starter_release.sh" "$repo/script/create_source_archive.sh" "$repo/script/normalize_source_archive.py" "$fixture/script/"
    cat > "$fixture/build.zig.zon" <<'ZON'
.{
    .name = .unpolished_peas,
    .version = "1.0.7",
    .fingerprint = 0x9801f8ecd9290536,
    .minimum_zig_version = "0.15.1",
    .dependencies = .{},
    .paths = .{ "build.zig.zon", "payload.txt" },
}
ZON
    printf '%s\n' 'release preparation fixture' > "$fixture/payload.txt"
    printf '%s\n' 'templates/starter/build.zig.zon export-ignore' > "$fixture/.gitattributes"
    printf '%s\n' '.{}' > "$fixture/templates/starter/build.zig.zon"
    git -C "$fixture" init --quiet
    git -C "$fixture" config user.name 'Release preparation test'
    git -C "$fixture" config user.email 'release-test@example.invalid'
    git -C "$fixture" config commit.gpgsign false
    git -C "$fixture" add .
    git -C "$fixture" commit --quiet -m 'Create release fixture'
    git -C "$fixture" remote add origin "$fixture"

    "$fixture/script/create_source_archive.sh" "$tag" "$tmp/$tag-before" HEAD >/dev/null
    archive="$tmp/$tag-before/unpolished-peas-v1.0.7-source.tar.gz"
    expected_hash="$(ZIG_GLOBAL_CACHE_DIR="$tmp/$tag-cache/global" ZIG_LOCAL_CACHE_DIR="$tmp/$tag-cache/local" zig fetch "$archive")"
    "$fixture/script/prepare_starter_release.sh" "$tag"
    python3 - "$fixture/templates/starter/build.zig.zon" "$tag" "$expected_hash" <<'PY'
import pathlib
import sys

path, tag, expected_hash = sys.argv[1:]
manifest = pathlib.Path(path).read_text()
url = f'https://github.com/gongahkia/unpolished-peas/releases/download/{tag}/unpolished-peas-v1.0.7-source.tar.gz'
assert '.version = "1.0.7"' in manifest, 'generated starter must follow the selected release version'
assert f'.url = "{url}"' in manifest, 'generated dependency must preserve the selected tag spelling'
assert f'.hash = "{expected_hash}"' in manifest, 'HTTP fetch must hash the intended source archive'
PY
    git -C "$fixture" add templates/starter/build.zig.zon
    git -C "$fixture" commit --quiet -m 'Prepare starter manifest'
    "$fixture/script/create_source_archive.sh" "$tag" "$tmp/$tag-after" HEAD >/dev/null
    cmp "$archive" "$tmp/$tag-after/unpolished-peas-v1.0.7-source.tar.gz"
    test -z "$(git -C "$fixture" tag --list)"
done

printf '%s\n' 'starter release preparation passed: real HTTP fetch, plain/prefixed tags, selected version, stable archive'
