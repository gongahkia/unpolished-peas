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
test -x "$package/run.sh"
grep -Fx '{"version":1,"platform":"linux-x86_64","runtime":"bin/unpolished-peas-bounce","assets":"assets/","docs":"docs/"}' "$package/launcher.json"
manifest="$package/PACKAGE-MANIFEST.txt"
grep -Fx 'format=unpolished-peas-package' "$manifest"
grep -Fx 'version=1' "$manifest"
grep -Fx 'platform=linux-x86_64' "$manifest"
grep -Fx 'runtime=bin/unpolished-peas-bounce' "$manifest"
grep -Fx 'assets=assets/' "$manifest"
grep -Fx 'docs=docs/' "$manifest"
grep -Fx 'launcher=launcher.json' "$manifest"
grep -Fx 'bundled-runtime=SDL3:static' "$manifest"
runtime=$(ldd "$game" 2>&1 || true)
if printf '%s\n' "$runtime" | grep -Fq 'not found'; then exit 1; fi
if printf '%s\n' "$runtime" | grep -Fq 'libSDL'; then exit 1; fi
mkdir "$tmp/outside-repository"
cd "$tmp/outside-repository"
xvfb-run -a env SDL_VIDEODRIVER=x11 SDL_AUDIODRIVER=dummy "$package/run.sh" --frames 2
repeat="$tmp/repeat"
cd "$repo"
zig build peas -- package linux "$repeat"
cmp "$out/SHA256SUMS" "$repeat/SHA256SUMS"
