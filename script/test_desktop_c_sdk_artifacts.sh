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
}

compare() {
    first="$1"
    second="$2"
    test "$(shasum -a 256 "$first" | awk '{print $1}')" = "$(shasum -a 256 "$second" | awk '{print $1}')"
}

build x86_64-linux "$fixture/linux-first"
build x86_64-linux "$fixture/linux-second"
compare "$fixture/linux-first/lib/libminna-san.a" "$fixture/linux-second/lib/libminna-san.a"
compare "$fixture/linux-first/lib/libminna-san.so" "$fixture/linux-second/lib/libminna-san.so"
build x86_64-windows "$fixture/windows-first"
build x86_64-windows "$fixture/windows-second"
compare "$fixture/windows-first/lib/minna-san.lib" "$fixture/windows-second/lib/minna-san.lib"
compare "$fixture/windows-first/bin/minna-san.dll" "$fixture/windows-second/bin/minna-san.dll"
