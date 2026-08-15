#!/usr/bin/env sh
set -eu

tag=${1:?usage: scripts/build-release-wasm.sh v0.x.y}
if ! printf '%s\n' "$tag" | grep -Eq '^v0\.[0-9]+\.[0-9]+$'; then
  printf 'release tag must match v0.x.y: %s\n' "$tag" >&2
  exit 1
fi

make first-game-wasm
make wukong-wasm
make audio-wasm

mkdir -p release-artifacts
archive="release-artifacts/72-wasm-demos-$tag.tar.gz"
tar -C dist -czf "$archive" first-game wukong audio
sha256sum "$archive" > release-artifacts/SHA256SUMS
