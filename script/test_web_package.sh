#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cd "$repo"
script/package_web.sh "$tmp/first" --game bounce
script/package_web.sh "$tmp/second" --game bounce
first="$tmp/first/unpolished-peas-bounce-web"
second="$tmp/second/unpolished-peas-bounce-web"
node script/validate_web_bundle.mjs "$first"
cmp "$first/SHA256SUMS" "$second/SHA256SUMS"
