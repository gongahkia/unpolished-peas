#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$repo/script/package_linux.sh" "$tmp/dist"
(
    cd "$tmp/dist"
    sha256sum --check SHA256SUMS
)
mkdir "$tmp/unpacked"
tar -C "$tmp/unpacked" -xzf "$tmp/dist/unpolished-peas-bounce-linux-x86_64.tar.gz"
game="$tmp/unpacked/unpolished-peas-bounce-linux-x86_64/unpolished-peas-bounce"
test -x "$game"
test -d "$tmp/unpacked/unpolished-peas-bounce-linux-x86_64/assets"
ldd "$game" 2>&1 | grep -Fq 'not a dynamic executable'
mkdir "$tmp/outside-repository"
cd "$tmp/outside-repository"
xvfb-run -a env SDL_AUDIODRIVER=dummy "$game" --frames 2
