#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
UP_BROWSER=firefox UP_ALLOW_WEBGPU_UNAVAILABLE=1 exec "$repo/script/test_browser_chromium.sh" "$@"
