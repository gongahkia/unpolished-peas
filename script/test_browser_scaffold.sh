#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -f "$stage/web/unpolished-peas.wasm"; rmdir "$stage/web" 2>/dev/null || true; rmdir "$stage" 2>/dev/null || true' EXIT HUP INT TERM

cd "$repo"
zig build browser -p "$stage"
[ -f "$stage/web/unpolished-peas.wasm" ]
[ "$(od -An -tx1 -N4 "$stage/web/unpolished-peas.wasm" | tr -d ' \n')" = 0061736d ]
