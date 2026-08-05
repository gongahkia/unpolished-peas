#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/contracts" "$fixture/packages/core/src" "$fixture/packages/protocol/src" "$fixture/packages/transport/src" "$fixture/packages/topology/src" "$fixture/packages/state/src" "$fixture/packages/runtime/src" "$fixture/packages/c-abi/src" "$fixture/packages/c-abi/include"

for path in \
    contracts/pre_release_api_baseline.sha256 \
    packages/core/src/core.zig \
    packages/protocol/src/protocol.zig \
    packages/transport/src/transport.zig \
    packages/topology/src/topology.zig \
    packages/state/src/state.zig \
    packages/runtime/src/runtime.zig \
    packages/c-abi/src/c_abi.zig \
    packages/c-abi/include/minna_san.h \
    packages/c-abi/include/minna_san_api.h; do
    cp "$root/$path" "$fixture/$path"
done

write_baseline() {
    (
        cd "$fixture"
        shasum -a 256 \
            packages/core/src/core.zig \
            packages/protocol/src/protocol.zig \
            packages/transport/src/transport.zig \
            packages/topology/src/topology.zig \
            packages/state/src/state.zig \
            packages/runtime/src/runtime.zig \
            packages/c-abi/src/c_abi.zig \
            packages/c-abi/include/minna_san.h \
            packages/c-abi/include/minna_san_api.h
        if [ -f packages/cpp-abi/include/minna_san.hpp ]; then
            shasum -a 256 packages/cpp-abi/include/minna_san.hpp
        else
            printf 'absent  packages/cpp-abi/include/minna_san.hpp\n'
        fi
    ) > "$fixture/contracts/pre_release_api_baseline.sha256"
}

PRE_RELEASE_API_BASELINE_ROOT="$fixture" sh "$root/script/check_pre_release_api_baseline.sh"
printf '\npub const UnapprovedPublicProbe = struct {};\n' >> "$fixture/packages/core/src/core.zig"
if PRE_RELEASE_API_BASELINE_ROOT="$fixture" sh "$root/script/check_pre_release_api_baseline.sh" >/dev/null 2>&1; then
    exit 1
fi
write_baseline
PRE_RELEASE_API_BASELINE_ROOT="$fixture" sh "$root/script/check_pre_release_api_baseline.sh"
printf '\nint minna_san_unapproved_probe(void);\n' >> "$fixture/packages/c-abi/include/minna_san_api.h"
if PRE_RELEASE_API_BASELINE_ROOT="$fixture" sh "$root/script/check_pre_release_api_baseline.sh" >/dev/null 2>&1; then
    exit 1
fi
write_baseline
PRE_RELEASE_API_BASELINE_ROOT="$fixture" sh "$root/script/check_pre_release_api_baseline.sh"
mkdir -p "$fixture/packages/cpp-abi/include"
printf 'namespace minna_san { struct Probe {}; }\n' > "$fixture/packages/cpp-abi/include/minna_san.hpp"
if PRE_RELEASE_API_BASELINE_ROOT="$fixture" sh "$root/script/check_pre_release_api_baseline.sh" >/dev/null 2>&1; then
    exit 1
fi
write_baseline
PRE_RELEASE_API_BASELINE_ROOT="$fixture" sh "$root/script/check_pre_release_api_baseline.sh"
