#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
out=${1:-"$tmp/dist"}
case "$out" in /*) ;; *) out="$repo/$out" ;; esac

"$repo/script/package_macos.sh" "$out"
(
    cd "$out"
    shasum -a 256 --check SHA256SUMS
)
unzip -q "$out/unpolished-peas-bounce-macos-universal.zip" -d "$tmp/unpacked"
game="$tmp/unpacked/unpolished-peas-bounce.app/Contents/MacOS/unpolished-peas-bounce"
test -x "$game"
test -d "$tmp/unpacked/unpolished-peas-bounce.app/Contents/assets"
lipo -archs "$game" | grep -Eq 'arm64.*x86_64|x86_64.*arm64'
