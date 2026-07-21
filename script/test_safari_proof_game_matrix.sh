#!/bin/sh
set -eu

for game in bounce topdown puzzle platformer; do
    UP_SAFARI_GAME="$game" zig build test-browser-safari
done
printf '%s\n' 'safari-proof-game-matrix passed: games=bounce,topdown,puzzle,platformer'
