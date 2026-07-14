#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
out=${1:-"$repo/dist/macos"}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM

rm -rf "$out"
mkdir -p "$out"
sdk=$(xcrun --show-sdk-path)
for target in aarch64-macos x86_64-macos; do
  zig build -Dmacos-sdk="$sdk" -Dtarget="$target" -Doptimize=ReleaseSafe -p "$stage/$target" package-bounce-sdl
done
name=unpolished-peas-bounce-macos-universal
package="$out/$name"
mkdir -p "$package/bin"
lipo -create "$stage/aarch64-macos/bin/unpolished-peas-bounce-sdl" "$stage/x86_64-macos/bin/unpolished-peas-bounce-sdl" -output "$package/bin/unpolished-peas-bounce"
cp -R "$stage/aarch64-macos/assets" "$package/assets"
zig build docs
cp -R zig-out/docs "$package/docs"
cp -R fixtures/content-project "$package/content"
zig build contentc -- "$package/content" "$package/content/cache"
printf '%s\n' '{"version":1,"platform":"macos-universal","runtime":"bin/unpolished-peas-bounce","assets":"assets/","docs":"docs/"}' > "$package/launcher.json"
printf '%s\n' '#!/bin/sh' 'exec "$(dirname "$0")/bin/unpolished-peas-bounce" "$@"' > "$package/run.sh"
chmod +x "$package/run.sh"
printf '%s\n' 'format=unpolished-peas-package' 'version=1' 'platform=macos-universal' 'runtime=bin/unpolished-peas-bounce' 'assets=assets/' 'content=content/' 'caches=content/cache/' 'docs=docs/' 'launcher=launcher.json' 'bundled-runtime=SDL3:static' > "$package/PACKAGE-MANIFEST.txt"
epoch=$(git -C "$repo" log -1 --format=%ct)
mtime=$(date -u -r "$epoch" +%Y%m%d%H%M.%S)
find "$package" -exec touch -t "$mtime" {} +
(
    cd "$out"
    find "$name" -print | LC_ALL=C sort | zip -X -q "$name.zip" -@
)
(
    cd "$out"
    shasum -a 256 "$name.zip" > SHA256SUMS
)
