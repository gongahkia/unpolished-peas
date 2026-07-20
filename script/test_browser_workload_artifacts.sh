#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
UP_PERFORMANCE_ROOT="$tmp/artifacts" "$repo/script/record_browser_workload_artifacts.sh"
test -f "$tmp/artifacts/browser-workloads-chromium-webgl2.json"
test -f "$tmp/artifacts/browser-workloads-chromium-webgpu.json"
printf '%s\n' 'browser-workload-artifacts passed: chromium webgl2 webgpu'
