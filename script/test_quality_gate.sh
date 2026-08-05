#!/bin/sh
set -eu

cd "$(git rev-parse --show-toplevel)"

sh script/check_quality.sh
if zig fmt --check contracts/fixtures/quality_unformatted.zig.txt >/dev/null 2>&1; then
    exit 1
fi
