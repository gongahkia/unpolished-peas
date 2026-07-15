#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
zig test --dep unpolished-peas -Mroot=src/service_integration.zig -Munpolished-peas=src/unpolished_peas.zig
