#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
config=${1:?usage: run_local_services.sh <config.zon> [--once]}
shift
case "$config" in /*) ;; *) config="$repo/$config" ;; esac
cd "$repo/services"
exec zig build run -- --config "$config" "$@"
