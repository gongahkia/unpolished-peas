#!/usr/bin/env sh
set -eu

version=${1:?usage: scripts/release-dry-run.sh v0.x.y}
if ! printf '%s\n' "$version" | grep -Eq '^v0\.[0-9]+\.[0-9]+$'; then
  printf 'release version must match v0.x.y: %s\n' "$version" >&2
  exit 1
fi
if ! go version | grep -Eq '^go version go1\.25\.13( |$)'; then
  printf 'v0.1 release dry run requires Go 1.25.13: %s\n' "$(go version)" >&2
  exit 1
fi
if test -n "$(git status --porcelain)"; then
  printf 'release dry run requires a clean worktree\n' >&2
  exit 1
fi
if ! test -f LICENSE; then
  printf 'release dry run requires a selected project LICENSE\n' >&2
  exit 1
fi
if ! test -f NOTICE; then
  printf 'release dry run requires a reviewed NOTICE file\n' >&2
  exit 1
fi
if ! grep -Fq "## [$version]" CHANGELOG.md; then
  printf 'release dry run requires a CHANGELOG.md entry for %s\n' "$version" >&2
  exit 1
fi

test -z "$(gofmt -l $(find . -name '*.go' -not -path './vendor/*'))"
go vet ./...
go test ./...
go test -race ./...
make example-build
make example-wasm
make wukong-wasm
make wukong-replay
make wukong-benchmark
make audio-wasm
make first-game-build
make first-game-wasm
make benchmark
