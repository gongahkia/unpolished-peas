#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "validate_wsl.sh requires Linux or WSL" >&2
  exit 2
fi

script/check_zig_version.sh
script/check_third_party_notices.py
script/test_core_without_sdl.sh
zig fmt --check build.zig src examples templates
zig build test
zig build check-examples
if command -v xvfb-run >/dev/null; then
  script/run_linux_software_gl.sh zig build test-sdl
else
  zig build test-sdl
fi
zig build test-scenes
script/test_downstream_fixture.sh
