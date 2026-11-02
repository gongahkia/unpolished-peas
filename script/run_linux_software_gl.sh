#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
    printf '%s\n' 'usage: run_linux_software_gl.sh <command> [args...]' >&2
    exit 64
fi
if ! command -v xvfb-run >/dev/null; then
    printf '%s\n' 'run_linux_software_gl.sh: xvfb-run is required' >&2
    exit 69
fi

# Explicitly select the X11 and Mesa software paths. Xvfb alone only supplies
# a display; it does not guarantee that SDL can create a usable OpenGL context.
# EGL avoids GLX visual-selection failures with Mesa's software renderer.
exec xvfb-run -a -s '-screen 0 1280x1024x24 +extension GLX +render -noreset' \
    env SDL_VIDEODRIVER=x11 SDL_VIDEO_FORCE_EGL=1 LIBGL_ALWAYS_SOFTWARE=1 SDL_AUDIODRIVER=dummy "$@"
