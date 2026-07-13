#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$repo/script/package_linux.sh" "$tmp/dist"
cd "$tmp"
SDL_AUDIODRIVER=dummy "$tmp/dist/unpolished-peas-bounce-linux-x86_64/unpolished-peas-bounce" --frames 2
