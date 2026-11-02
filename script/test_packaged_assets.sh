#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

cd "$repo"
zig build install
cd "$tmp"
"$repo/zig-out/bin/unpolished-peas-test-packaged-assets"
