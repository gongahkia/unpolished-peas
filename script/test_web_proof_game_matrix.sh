#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
for game in bounce topdown; do
    "$repo/script/test_web_package.sh" "$game"
    "$repo/script/test_browser_chromium.sh" "$game"
done
printf '%s\n' 'web-proof-game-matrix passed: games=bounce,topdown'
