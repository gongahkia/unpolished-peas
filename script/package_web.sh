#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
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
case "$game" in bounce|topdown|platformer) ;; *) exit 64 ;; esac
case "$out" in /*) ;; *) out="$repo/$out" ;; esac
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
cd "$repo"
zig build browser -p "$stage"
package="$out/unpolished-peas-$game-web"
rm -rf "$package"
mkdir -p "$package/assets"
cp "$stage/web/unpolished-peas.wasm" "$package/"
cp src/browser/*.mjs "$package/"
cp -R examples/assets/. "$package/assets/"
printf '%s\n' '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="icon" href="data:,"><title>unpolished-peas</title><canvas data-unpolished-peas width="320" height="180" tabindex="0"></canvas><script type="module" src="./bootstrap.mjs"></script>' > "$package/index.html"
printf '{"version":1,"platform":"web","game":"%s","entry":"index.html","runtime":"unpolished-peas.wasm","assets":"assets/"}\n' "$game" > "$package/web-manifest.json"
(cd "$package" && find . -type f -print | LC_ALL=C sort | while read -r path; do shasum -a 256 "$path"; done) > "$package/SHA256SUMS"
node script/validate_web_bundle.mjs "$package"
