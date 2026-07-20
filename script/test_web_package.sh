#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
game=${1:-bounce}
case "$game" in bounce|topdown|puzzle) ;; *) printf '%s\n' 'usage: test_web_package.sh [bounce|topdown|puzzle]' >&2; exit 64 ;; esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cd "$repo"
script/package_web.sh "$tmp/first" --game "$game"
script/package_web.sh "$tmp/second" --game "$game"
first="$tmp/first/unpolished-peas-$game-web"
second="$tmp/second/unpolished-peas-$game-web"
node script/validate_web_bundle.mjs "$first"
cmp "$first/SHA256SUMS" "$second/SHA256SUMS"
printf '%s\n' "web-package passed: game=$game"
