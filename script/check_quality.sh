#!/bin/sh
set -eu

cd "$(git rev-parse --show-toplevel)"

files="$(git ls-files -- '*.zig' ':!.zig-cache/**')"
if [ -n "$files" ]; then
    zig fmt --check $files
fi
git diff --check HEAD
