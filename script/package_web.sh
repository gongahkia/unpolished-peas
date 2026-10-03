#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
checksum() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1"
    else
        printf '%s\n' 'package_web.sh: requires sha256sum or shasum' >&2
        return 69
    fi
}
out="$repo/dist/web"
game=bounce
out_set=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --game) shift; [ "$#" -gt 0 ] || exit 64; game=$1 ;;
        *) [ "$out_set" -eq 0 ] || exit 64; out=$1; out_set=1 ;;
    esac
    shift
done
case "$game" in starter|bounce|topdown|puzzle|platformer) ;; *) exit 64 ;; esac
case "$out" in /*) ;; *) out="$repo/$out" ;; esac
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
cd "$repo"
case "$game" in
    starter) browser_step=browser-starter ;;
    bounce) browser_step=browser ;;
    topdown) browser_step=browser-topdown ;;
    puzzle) browser_step=browser-puzzle ;;
    platformer) browser_step=browser-platformer ;;
esac
zig build "$browser_step" -p "$stage"
package="$out/unpolished-peas-$game-web"
rm -rf "$package"
mkdir -p "$package/assets"
cp "$stage/web/unpolished-peas.wasm" "$package/"
cp src/browser/*.mjs "$package/"
cp benchmarks/workloads/v1.json "$package/workloads-v1.json"
cp src/fixtures/renderer/stable-core-v1.json "$package/renderer-contract-v1.json"
cp src/fixtures/text/debug-5x7-v1.json "$package/debug-font-v1.json"
cp -R examples/assets/. "$package/assets/"
printf '%s\n' "<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><link rel=\"icon\" href=\"data:,\"><title>unpolished-peas $game</title><canvas data-unpolished-peas data-game=\"$game\" width=\"320\" height=\"180\" tabindex=\"0\"></canvas><script type=\"module\" src=\"./bootstrap.mjs\"></script>" > "$package/index.html"
printf '{"version":1,"platform":"web","game":"%s","entry":"index.html","runtime":"unpolished-peas.wasm","assets":"assets/","renderer_selection":"query:auto|webgpu|webgl2"}\n' "$game" > "$package/web-manifest.json"
(cd "$package" && find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | while read -r path; do checksum "$path"; done) > "$package/SHA256SUMS"
node script/validate_web_bundle.mjs "$package"
