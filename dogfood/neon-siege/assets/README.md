# Neon Siege assets

The dogfood game's playable sprites and WAV effects are small source-authored
byte arrays in `src/art.zig` and `src/sounds.zig`. That makes the reference
project self-contained on desktop and browser while still exercising Peas's
public `Image.decode`, `Atlas`, and `Audio.loadWav` APIs.

This directory remains part of the packaged project to demonstrate where a
normal game would place copied runtime assets. It deliberately contains no
third-party media.
