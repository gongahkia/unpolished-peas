#!/bin/sh
# Repository-authored Neon Siege music fixture. It contains three generated
# sine tones only; no sampled or third-party audio is used.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output="$root/dogfood/neon-siege/assets/neon-loop.ogg"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=220:sample_rate=48000:duration=2" \
  -f lavfi -i "sine=frequency=277.18:sample_rate=48000:duration=2" \
  -f lavfi -i "sine=frequency=329.63:sample_rate=48000:duration=2" \
  -filter_complex "[0:a][1:a][2:a]amix=inputs=3:weights='0.50 0.32 0.24',volume=0.35,aformat=channel_layouts=stereo" \
  -strict -2 -c:a vorbis -q:a 2 \
  -metadata title="Neon Siege generated loop" \
  -metadata comment="Repository-authored synthesized chord fixture" \
  "$output"
