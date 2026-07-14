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
game="$tmp/unpacked/unpolished-peas-bounce.app/Contents/MacOS/unpolished-peas-bounce"
test -x "$game"
test -d "$tmp/unpacked/unpolished-peas-bounce.app/Contents/assets"
manifest="$tmp/unpacked/unpolished-peas-bounce.app/Contents/PACKAGE-MANIFEST.txt"
grep -Fx 'runtime=Contents/MacOS/unpolished-peas-bounce' "$manifest"
grep -Fx 'assets=Contents/assets/' "$manifest"
lipo -archs "$game" | grep -Eq 'arm64.*x86_64|x86_64.*arm64'
mkdir "$tmp/outside-repository"
cd "$tmp/outside-repository"
SDL_AUDIODRIVER=dummy "$game" --frames 2
