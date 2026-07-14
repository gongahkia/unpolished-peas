#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
out=${1:-"$repo/dist/linux"}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM

rm -rf "$out"
package="$out/unpolished-peas-bounce-linux-x86_64"
mkdir -p "$package"
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe -p "$stage" package-bounce-sdl
cp "$stage/bin/unpolished-peas-bounce-sdl" "$package/unpolished-peas-bounce"
cp -R "$stage/assets" "$package/assets"
zig build docs
cp -R zig-out/docs "$package/docs"
printf '%s\n' 'runtime=unpolished-peas-bounce' 'assets=assets/' 'docs=docs/' > "$package/PACKAGE-MANIFEST.txt"
epoch=$(git -C "$repo" log -1 --format=%ct)
if date --version >/dev/null 2>&1; then
    mtime=$(date -u -d "@$epoch" +%Y%m%d%H%M.%S)
else
    mtime=$(date -u -r "$epoch" +%Y%m%d%H%M.%S)
fi
find "$package" -exec touch -t "$mtime" {} +
(
    cd "$out"
    tar --format ustar -cf unpolished-peas-bounce-linux-x86_64.tar unpolished-peas-bounce-linux-x86_64
    gzip -n unpolished-peas-bounce-linux-x86_64.tar
    sha256sum unpolished-peas-bounce-linux-x86_64.tar.gz > SHA256SUMS
)
