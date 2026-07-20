#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
out=${1:-"$tmp/dist"}
game=${2:-bounce}
case "$out" in /*) ;; *) out="$repo/$out" ;; esac
case "$game" in bounce|topdown|puzzle) ;; *) printf '%s\n' 'usage: test_linux_package.sh [output-directory] [bounce|topdown|puzzle]' >&2; exit 64 ;; esac

cd "$repo"
zig build peas -- package linux "$out" --game "$game"
(
    cd "$out"
    sha256sum --check SHA256SUMS
)
mkdir "$tmp/unpacked"
name=unpolished-peas-$game-linux-x86_64
archive="$out/$name.tar.gz"
tar -C "$tmp/unpacked" -xzf "$archive"
package="$tmp/unpacked/$name"
runtime="$package/bin/unpolished-peas-$game"
test -x "$runtime"
test -d "$package/assets"
test -f "$package/docs/api/core.md"
test -x "$package/run.sh"
launcher=$(printf '{"version":1,"platform":"linux-x86_64","game":"%s","runtime":"bin/unpolished-peas-%s","assets":"assets/","docs":"docs/"}' "$game" "$game")
grep -Fx "$launcher" "$package/launcher.json"
manifest="$package/PACKAGE-MANIFEST.txt"
grep -Fx 'format=unpolished-peas-package' "$manifest"
grep -Fx 'version=1' "$manifest"
grep -Fx 'platform=linux-x86_64' "$manifest"
grep -Fx "game=$game" "$manifest"
grep -Fx "runtime=bin/unpolished-peas-$game" "$manifest"
grep -Fx 'assets=assets/' "$manifest"
grep -Fx 'docs=docs/' "$manifest"
grep -Fx 'launcher=launcher.json' "$manifest"
grep -Fx 'bundled-runtime=SDL3:static' "$manifest"
runtime_libraries=$(ldd "$runtime" 2>&1 || true)
if printf '%s\n' "$runtime_libraries" | grep -Fq 'not found'; then exit 1; fi
if printf '%s\n' "$runtime_libraries" | grep -Fq 'libSDL'; then exit 1; fi
checker_stage="$tmp/checker"
cd "$repo"
zig build -p "$checker_stage" package-layout-checker
checker="$package/bin/unpolished-peas-test-packaged-layout"
cp "$checker_stage/bin/unpolished-peas-test-packaged-layout" "$checker"
mkdir "$tmp/outside-repository"
cd "$tmp/outside-repository"
"$checker"
"$repo/script/run_linux_software_gl.sh" "$package/run.sh" --frames 2 --renderer sdl-gpu
"$repo/script/run_linux_software_gl.sh" "$package/run.sh" --frames 2 --renderer opengl
missing="$tmp/missing-assets"
cp -R "$package" "$missing"
rm -rf "$missing/assets"
if "$missing/bin/unpolished-peas-test-packaged-layout" > "$tmp/missing-assets.out" 2>&1; then exit 1; fi
grep -F 'recovery: restore a checksum-verified package archive' "$tmp/missing-assets.out"
repeat="$tmp/repeat"
cd "$repo"
zig build peas -- package linux "$repeat" --game "$game"
cmp "$out/SHA256SUMS" "$repeat/SHA256SUMS"
printf '%s\n' "platform=linux-x86_64" "game=$game" "archive=$name.tar.gz" 'checksum=verified' 'layout=passed' 'runtime-smoke=passed' 'renderer-sdl-gpu=passed' 'renderer-opengl=passed' > "$out/SMOKE-REPORT.txt"
cat "$out/SMOKE-REPORT.txt"
