#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo/services"
PKG_CONFIG_LIBDIR=/nonexistent zig build test
cd "$repo"
script/run_local_services.sh services/fixtures/local.zon --once
