#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
out=${1:-"$tmp/dist"}
case "$out" in /*) ;; *) out="$repo/$out" ;; esac

cd "$repo"
zig build peas -- package macos "$out"
(
    cd "$out"
    shasum -a 256 --check SHA256SUMS
)
unzip -q "$out/unpolished-peas-bounce-macos-universal.zip" -d "$tmp/unpacked"
package="$tmp/unpacked/unpolished-peas-bounce-macos-universal"
game="$package/bin/unpolished-peas-bounce"
test -x "$game"
test -d "$package/assets"
test -f "$package/docs/api/core.md"
test -x "$package/run.sh"
grep -Fx '{"version":1,"platform":"macos-universal","runtime":"bin/unpolished-peas-bounce","assets":"assets/","docs":"docs/"}' "$package/launcher.json"
manifest="$package/PACKAGE-MANIFEST.txt"
grep -Fx 'format=unpolished-peas-package' "$manifest"
grep -Fx 'version=1' "$manifest"
grep -Fx 'platform=macos-universal' "$manifest"
grep -Fx 'runtime=bin/unpolished-peas-bounce' "$manifest"
grep -Fx 'assets=assets/' "$manifest"
grep -Fx 'docs=docs/' "$manifest"
grep -Fx 'launcher=launcher.json' "$manifest"
grep -Fx 'bundled-runtime=SDL3:static' "$manifest"
lipo -archs "$game" | grep -Eq 'arm64.*x86_64|x86_64.*arm64'
mkdir "$tmp/outside-repository"
cd "$tmp/outside-repository"
SDL_AUDIODRIVER=dummy "$package/run.sh" --frames 2
repeat="$tmp/repeat"
cd "$repo"
zig build peas -- package macos "$repeat"
cmp "$out/SHA256SUMS" "$repeat/SHA256SUMS"
