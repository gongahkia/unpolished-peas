#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
zig_exe="${ZIG_EXE:-$(command -v zig)}"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

build() {
    target="$1"
    output="$2"
    "$zig_exe" build -Dtarget="$target" -Doptimize=ReleaseFast --prefix "$output" c-sdk-static c-sdk-shared
    test -f "$output/lib/libminna-san.a"
    test -f "$output/lib/libminna-san.dylib"
}

for target in aarch64-macos x86_64-macos; do
    build "$target" "$fixture/$target-first"
    build "$target" "$fixture/$target-second"
    first_static="$(shasum -a 256 "$fixture/$target-first/lib/libminna-san.a" | awk '{print $1}')"
    second_static="$(shasum -a 256 "$fixture/$target-second/lib/libminna-san.a" | awk '{print $1}')"
    first_shared="$(shasum -a 256 "$fixture/$target-first/lib/libminna-san.dylib" | awk '{print $1}')"
    second_shared="$(shasum -a 256 "$fixture/$target-second/lib/libminna-san.dylib" | awk '{print $1}')"
    test "$first_static" = "$second_static"
    test "$first_shared" = "$second_shared"
done
