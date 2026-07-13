#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
out=${1:-"$tmp/dist"}
case "$out" in /*) ;; *) out="$repo/$out" ;; esac

"$repo/script/package_linux.sh" "$out"
(
    cd "$out"
    sha256sum --check SHA256SUMS
)
mkdir "$tmp/unpacked"
tar -C "$tmp/unpacked" -xzf "$out/unpolished-peas-bounce-linux-x86_64.tar.gz"
game="$tmp/unpacked/unpolished-peas-bounce-linux-x86_64/unpolished-peas-bounce"
test -x "$game"
test -d "$tmp/unpacked/unpolished-peas-bounce-linux-x86_64/assets"
runtime=$(ldd "$game" 2>&1 || true)
if printf '%s\n' "$runtime" | grep -Fq 'not found'; then exit 1; fi
if printf '%s\n' "$runtime" | grep -Fq 'libSDL'; then exit 1; fi
mkdir "$tmp/outside-repository"
cd "$tmp/outside-repository"
env SDL_VIDEODRIVER=offscreen SDL_GPU_DRIVER=vulkan SDL_AUDIODRIVER=dummy "$game" --frames 2
