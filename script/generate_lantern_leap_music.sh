#!/bin/sh
# Repository-authored Lantern Leap loop: generated sine tones only, with no
# sampled or third-party music. It is a compact Vorbis fixture for streaming.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output="$root/dogfood/lantern-leap/assets/lantern-loop.ogg"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=174.61:sample_rate=48000:duration=2" \
  -f lavfi -i "sine=frequency=261.63:sample_rate=48000:duration=2" \
  -f lavfi -i "sine=frequency=349.23:sample_rate=48000:duration=2" \
  -filter_complex "[0:a][1:a][2:a]amix=inputs=3:weights='0.48 0.30 0.20',volume=0.27,aformat=channel_layouts=stereo" \
  -strict -2 -c:a vorbis -q:a 2 \
  -metadata title="Lantern Leap generated loop" \
  -metadata comment="Repository-authored synthesized platformer fixture" \
  "$output"
