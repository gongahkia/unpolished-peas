#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/zig-out/shaders}"
mkdir -p "$OUT_DIR"

glslangValidator -V -S vert "$ROOT_DIR/shaders/sprite.vert" -o "$OUT_DIR/sprite.vert.spv"
glslangValidator -V -S frag "$ROOT_DIR/shaders/sprite.frag" -o "$OUT_DIR/sprite.frag.spv"

if [[ "$(uname -s)" == "Darwin" ]]; then
  spirv-cross "$OUT_DIR/sprite.vert.spv" --msl --output "$OUT_DIR/sprite.vert.metal"
  spirv-cross "$OUT_DIR/sprite.frag.spv" --msl --output "$OUT_DIR/sprite.frag.metal"
  xcrun metal -c "$OUT_DIR/sprite.vert.metal" -o "$OUT_DIR/sprite.vert.air"
  xcrun metal -c "$OUT_DIR/sprite.frag.metal" -o "$OUT_DIR/sprite.frag.air"
  xcrun metallib "$OUT_DIR/sprite.vert.air" -o "$OUT_DIR/sprite.vert.metallib"
  xcrun metallib "$OUT_DIR/sprite.frag.air" -o "$OUT_DIR/sprite.frag.metallib"
fi
