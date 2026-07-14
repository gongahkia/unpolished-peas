#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
out=${1:-"$tmp/dist"}
game=${2:-bounce}
case "$out" in /*) ;; *) out="$repo/$out" ;; esac
case "$game" in
    bounce|topdown) fixture=topdown ;;
    platformer) fixture=platformer ;;
    *) printf '%s\n' 'usage: test_macos_package.sh [output-directory] [bounce|topdown|platformer]' >&2; exit 64 ;;
esac

cd "$repo"
zig build peas -- package macos "$out" --game "$game"
(
    cd "$out"
    shasum -a 256 --check SHA256SUMS
)
name=unpolished-peas-$game-macos-universal
archive="$out/$name.zip"
unzip -q "$archive" -d "$tmp/unpacked"
package="$tmp/unpacked/$name"
runtime="$package/bin/unpolished-peas-$game"
test -x "$runtime"
test -d "$package/assets"
test -f "$package/docs/api/core.md"
test -f "$package/content/project.up"
test -f "$package/content/cache/scenes/$fixture.upscene.upc"
test -f "$package/content/cache/assets/$fixture.upassets.upc"
test -f "$package/content/cache/maps/$fixture.upmap.upc"
test -x "$package/run.sh"
launcher=$(printf '{"version":1,"platform":"macos-universal","game":"%s","runtime":"bin/unpolished-peas-%s","assets":"assets/","docs":"docs/"}' "$game" "$game")
grep -Fx "$launcher" "$package/launcher.json"
manifest="$package/PACKAGE-MANIFEST.txt"
grep -Fx 'format=unpolished-peas-package' "$manifest"
grep -Fx 'version=1' "$manifest"
grep -Fx 'platform=macos-universal' "$manifest"
grep -Fx "game=$game" "$manifest"
grep -Fx "runtime=bin/unpolished-peas-$game" "$manifest"
grep -Fx 'assets=assets/' "$manifest"
grep -Fx 'content=content/' "$manifest"
grep -Fx 'caches=content/cache/' "$manifest"
grep -Fx 'docs=docs/' "$manifest"
grep -Fx 'launcher=launcher.json' "$manifest"
grep -Fx 'bundled-runtime=SDL3:static' "$manifest"
lipo -archs "$runtime" | grep -Eq 'arm64.*x86_64|x86_64.*arm64'
runtime_libraries=$(otool -L "$runtime")
if printf '%s\n' "$runtime_libraries" | grep -Fq 'SDL3'; then exit 1; fi
checker_stage="$tmp/checker"
cd "$repo"
zig build -p "$checker_stage" package-layout-checker
checker="$package/bin/unpolished-peas-test-packaged-layout"
cp "$checker_stage/bin/unpolished-peas-test-packaged-layout" "$checker"
mkdir "$tmp/outside-repository"
cd "$tmp/outside-repository"
"$checker"
SDL_AUDIODRIVER=dummy "$package/run.sh" --frames 2
corrupt="$tmp/corrupt-cache"
cp -R "$package" "$corrupt"
printf '\0' > "$corrupt/content/cache/scenes/$fixture.upscene.upc"
if "$corrupt/bin/unpolished-peas-test-packaged-layout" > "$tmp/corrupt-cache.out" 2>&1; then exit 1; fi
grep -F 'recovery: restore a checksum-verified package archive' "$tmp/corrupt-cache.out"
missing="$tmp/missing-assets"
cp -R "$package" "$missing"
rm -rf "$missing/assets"
if "$missing/bin/unpolished-peas-test-packaged-layout" > "$tmp/missing-assets.out" 2>&1; then exit 1; fi
grep -F 'recovery: restore a checksum-verified package archive' "$tmp/missing-assets.out"
repeat="$tmp/repeat"
cd "$repo"
zig build peas -- package macos "$repeat" --game "$game"
cmp "$out/SHA256SUMS" "$repeat/SHA256SUMS"
printf '%s\n' "platform=macos-universal" "game=$game" "archive=$name.zip" 'checksum=verified' 'layout=passed' 'runtime-smoke=passed' 'cache-recovery=passed' > "$out/SMOKE-REPORT.txt"
cat "$out/SMOKE-REPORT.txt"
