#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
zig build test-sdl
script/test_support_bundle_cli.sh
zig build test-desktop-package-matrix
script/test_web_package.sh bounce
node script/test_browser_host.mjs
script/test_browser_chromium.sh bounce
printf '%s\n' 'cross-target-integrity passed: desktop,chromium'
