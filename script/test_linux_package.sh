#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
out=${1:-"$tmp/dist"}
case "$out" in /*) ;; *) out="$repo/$out" ;; esac

cd "$repo"
zig build peas -- package linux "$out"
(
    cd "$out"
    sha256sum --check SHA256SUMS
)
mkdir "$tmp/unpacked"
tar -C "$tmp/unpacked" -xzf "$out/unpolished-peas-bounce-linux-x86_64.tar.gz"
package="$tmp/unpacked/unpolished-peas-bounce-linux-x86_64"
game="$package/bin/unpolished-peas-bounce"
test -x "$game"
test -d "$package/assets"
test -f "$package/docs/api/core.md"
test -f "$package/content/project.up"
test -f "$package/content/cache/scenes/topdown.upscene.upc"
test -f "$package/content/cache/assets/topdown.upassets.upc"
test -f "$package/content/cache/maps/topdown.upmap.upc"
test -x "$package/run.sh"
grep -Fx '{"version":1,"platform":"linux-x86_64","runtime":"bin/unpolished-peas-bounce","assets":"assets/","docs":"docs/"}' "$package/launcher.json"
manifest="$package/PACKAGE-MANIFEST.txt"
grep -Fx 'format=unpolished-peas-package' "$manifest"
grep -Fx 'version=1' "$manifest"
grep -Fx 'platform=linux-x86_64' "$manifest"
grep -Fx 'runtime=bin/unpolished-peas-bounce' "$manifest"
grep -Fx 'assets=assets/' "$manifest"
grep -Fx 'content=content/' "$manifest"
grep -Fx 'caches=content/cache/' "$manifest"
grep -Fx 'docs=docs/' "$manifest"
grep -Fx 'launcher=launcher.json' "$manifest"
grep -Fx 'bundled-runtime=SDL3:static' "$manifest"
runtime=$(ldd "$game" 2>&1 || true)
if printf '%s\n' "$runtime" | grep -Fq 'not found'; then exit 1; fi
if printf '%s\n' "$runtime" | grep -Fq 'libSDL'; then exit 1; fi
checker_stage="$tmp/checker"
cd "$repo"
zig build -p "$checker_stage" package-layout-checker
checker="$package/bin/unpolished-peas-test-packaged-layout"
cp "$checker_stage/bin/unpolished-peas-test-packaged-layout" "$checker"
mkdir "$tmp/outside-repository"
cd "$tmp/outside-repository"
"$checker"
xvfb-run -a env SDL_VIDEODRIVER=x11 SDL_AUDIODRIVER=dummy "$package/run.sh" --frames 2
corrupt="$tmp/corrupt-cache"
cp -R "$package" "$corrupt"
printf '\0' > "$corrupt/content/cache/scenes/topdown.upscene.upc"
if "$corrupt/bin/unpolished-peas-test-packaged-layout" > "$tmp/corrupt-cache.out" 2>&1; then exit 1; fi
grep -F 'recovery: restore a checksum-verified package archive' "$tmp/corrupt-cache.out"
missing="$tmp/missing-assets"
cp -R "$package" "$missing"
rm -rf "$missing/assets"
if "$missing/bin/unpolished-peas-test-packaged-layout" > "$tmp/missing-assets.out" 2>&1; then exit 1; fi
grep -F 'recovery: restore a checksum-verified package archive' "$tmp/missing-assets.out"
repeat="$tmp/repeat"
cd "$repo"
zig build peas -- package linux "$repeat"
cmp "$out/SHA256SUMS" "$repeat/SHA256SUMS"
