#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
zig_exe="${ZIG_EXE:-$(command -v zig)}"
tool="packages/c-abi/src/generate_public_api.zig"
source="${C_API_SOURCE:-packages/c-abi/src/c_abi.zig}"
header="${C_API_HEADER:-packages/c-abi/include/minna_san_api.h}"
library="${C_API_LIBRARY:-zig-out/lib/libminna-san.a}"

"$zig_exe" run "$tool" -- --check "$source" "$header"
expected="$("$zig_exe" run "$tool" -- --symbols | LC_ALL=C sort)"
actual="$(nm -gU "$library" | awk '$NF ~ /^_?minna_san_/ { symbol = $NF; sub(/^_/, "", symbol); print symbol }' | LC_ALL=C sort -u)"
test "$expected" = "$actual"
