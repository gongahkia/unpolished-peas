#!/usr/bin/env bash
set -euo pipefail

target="${1:?sample target required}"
case "$target" in
  run-bounce|test-scenes)
    zig build "$target"
    ;;
  run-bounce-sdl|dev-bounce|run-minimal|run-audio|run-atlas|run-camera|run-tilemap|run-primitives|run-breakout-sdl|run-topdown-sdl|run-platformer-sdl|stress-audio-sdl)
    SDL_AUDIODRIVER=dummy zig build "$target" -- --frames 2
    ;;
  *)
    echo "unknown sample target: $target" >&2
    exit 2
    ;;
esac
