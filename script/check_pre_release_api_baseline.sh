#!/bin/sh
set -eu

root="${PRE_RELEASE_API_BASELINE_ROOT:-$(git rev-parse --show-toplevel)}"
baseline="$root/contracts/pre_release_api_baseline.sha256"
actual="$(mktemp)"
trap 'rm -f "$actual"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[ -f "$baseline" ] || fail "missing pre-release API baseline"

write_entry() {
    path="$1"
    if [ -f "$root/$path" ]; then
        (cd "$root" && shasum -a 256 "$path")
    else
        printf 'absent  %s\n' "$path"
    fi
}

for path in \
    packages/core/src/core.zig \
    packages/protocol/src/protocol.zig \
    packages/transport/src/transport.zig \
    packages/topology/src/topology.zig \
    packages/state/src/state.zig \
    packages/runtime/src/runtime.zig \
    packages/c-abi/src/c_abi.zig \
    packages/c-abi/include/minna_san.h \
    packages/c-abi/include/minna_san_api.h \
    packages/cpp-abi/include/minna_san.hpp; do
    write_entry "$path" >> "$actual"
done

cmp -s "$baseline" "$actual" || fail "pre-release public API changed; update contracts/pre_release_api_baseline.sha256 explicitly"
