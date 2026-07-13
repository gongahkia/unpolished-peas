#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$repo/script/package_macos.sh" "$tmp/dist"
cd "$tmp"
SDL_AUDIODRIVER=dummy "$tmp/dist/unpolished-peas-bounce.app/Contents/MacOS/unpolished-peas-bounce" --frames 2
