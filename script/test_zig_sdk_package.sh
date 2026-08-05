#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

sh script/package_zig_sdk.sh "$fixture/first.tar.gz"
sh script/package_zig_sdk.sh "$fixture/second.tar.gz"
test "$(shasum -a 256 "$fixture/first.tar.gz" | awk '{print $1}')" = "$(shasum -a 256 "$fixture/second.tar.gz" | awk '{print $1}')"
ZIG_SDK_PACKAGE="$fixture/first.tar.gz" sh script/check_zig_sdk_package.sh
python3 -c 'import gzip, pathlib, sys; path = pathlib.Path(sys.argv[1]); path.write_bytes(gzip.compress(b"invalid", mtime=0))' "$fixture/second.tar.gz"
if ZIG_SDK_PACKAGE="$fixture/second.tar.gz" sh script/check_zig_sdk_package.sh >/dev/null 2>&1; then
    exit 1
fi
