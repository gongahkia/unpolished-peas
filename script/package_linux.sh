#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$repo/dist/linux"}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM

rm -rf "$out"
mkdir -p "$out/unpolished-peas-bounce-linux-x86_64"
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe -p "$stage" install
cp "$stage/bin/unpolished-peas-bounce-sdl" "$out/unpolished-peas-bounce-linux-x86_64/unpolished-peas-bounce"
cp -R "$stage/assets" "$out/unpolished-peas-bounce-linux-x86_64/assets"
tar -C "$out" -czf "$out/unpolished-peas-bounce-linux-x86_64.tar.gz" unpolished-peas-bounce-linux-x86_64
sha256sum "$out/unpolished-peas-bounce-linux-x86_64.tar.gz" > "$out/SHA256SUMS"
