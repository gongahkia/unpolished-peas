#!/bin/sh
set -eu

: "${UP_SERVICES_DATABASE_URL:?test_services_provider.sh: UP_SERVICES_DATABASE_URL is required}"
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo/packages/services"
zig build test
