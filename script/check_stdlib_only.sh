#!/bin/sh
set -eu

cd "$(git rev-parse --show-toplevel)"

source_roots="${V1_SOURCE_ROOTS:-packages/core/src packages/protocol/src packages/transport/src packages/topology/src packages/state/src packages/runtime/src packages/c-abi/src}"
imports="$(rg -n -o '@import\("[^"]+"\)' $source_roots || true)"
bad=""

while IFS= read -r record; do
    [ -n "$record" ] || continue
    module="$(printf '%s\n' "$record" | sed -E 's/.*@import\("([^"]+)"\).*/\1/')"
    case "$module" in
        std|minna-san-*|*.zig) ;;
        *) bad="${bad}${record}\n" ;;
    esac
done <<EOF
$imports
EOF

if [ -n "$bad" ]; then
    printf '%b' "$bad" >&2
    exit 1
fi
