#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
out=${1:-"$tmp/dist"}
case "$out" in /*) ;; *) out="$repo/$out" ;; esac

"$repo/script/package_macos.sh" "$out"
cd "$tmp"
SDL_AUDIODRIVER=dummy "$out/unpolished-peas-bounce.app/Contents/MacOS/unpolished-peas-bounce" --frames 2
