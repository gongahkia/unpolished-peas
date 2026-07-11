#!/usr/bin/env bash
set -euo pipefail

PKG_CONFIG_LIBDIR=/nonexistent zig build -Dsystem-sdl=true test
