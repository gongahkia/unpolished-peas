#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
browser=${UP_BROWSER:-chromium}
case "$browser" in
    chromium) browser_test=$repo/script/test_browser_chromium.sh ;;
    firefox) browser_test=$repo/script/test_browser_firefox.sh ;;
    *) printf '%s\n' 'test_web_proof_game_matrix.sh: browser must be chromium or firefox' >&2; exit 64 ;;
esac
for game in bounce topdown puzzle platformer; do
    "$repo/script/test_web_package.sh" "$game"
    "$browser_test" "$game"
done
printf '%s\n' "web-proof-game-matrix passed: browser=$browser games=bounce,topdown,puzzle,platformer"
