#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
case "$(uname -s)" in
    Linux) xvfb-run -a env SDL_AUDIODRIVER=dummy UP_CROSS_BACKEND_CONFORMANCE=1 zig build test-renderer-cross-backend ;;
    Darwin) env SDL_AUDIODRIVER=dummy UP_CROSS_BACKEND_CONFORMANCE=1 zig build test-renderer-cross-backend ;;
    *) printf 'renderer corpus: unsupported host %s\n' "$(uname -s)" >&2; exit 69 ;;
esac
"$repo/script/test_browser_renderer_corpus.sh"
printf '%s\n' 'renderer-three-backend passed: sdl-gpu,opengl,webgl2,webgpu'
