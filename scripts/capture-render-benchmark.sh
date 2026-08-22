#!/usr/bin/env sh
set -eu

report=${1:?usage: scripts/capture-render-benchmark.sh REPORT.md}
if test -e "$report"; then
  printf 'refusing to overwrite %s\n' "$report" >&2
  exit 1
fi
parent=$(dirname "$report")
if ! test -d "$parent"; then
  printf 'report directory does not exist: %s\n' "$parent" >&2
  exit 1
fi

{
  printf '# 72 render benchmark report\n\n'
  printf '%s\n' '## environment'
  printf '\n'
  printf '%s\n' "- revision: $(git rev-parse HEAD)"
  printf '%s\n' "- branch: $(git branch --show-current)"
  printf '%s\n' "- go: $(go version)"
  printf '%s\n' "- os: $(uname -srm)"
  printf '%s\n' "- cpu: $(getconf _NPROCESSORS_ONLN) logical processors"
  printf '\n%s\n\n' '## results'
  printf '%s\n' '```text'
  go test -run '^$' -bench '^BenchmarkReference' -benchmem -count=5 ./engine/render
  printf '%s\n' '```'
} > "$report"
