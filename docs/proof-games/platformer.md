# Platformer proof game

![Deterministic platformer reference](../../examples/assets/proof-platformer-reference.png)

`examples/platformer_game.zig` owns the fixed player, one-way platforms, gravity, jump edge, goal state, and deterministic rules. `examples/platformer_sdl.zig` owns the callback loop, raw image/sound assets, and presentation. The level is hand-authored rectangles; no core controller API, ECS, physics system, tile system, collision API, UI framework, particles, or engine-owned level data was added.

## Setup and checks

```sh
zig build test-platformer
zig build test-platformer-scene
env SDL_AUDIODRIVER=dummy zig build smoke-platformer-sdl
script/test_platformer_native_fixture.sh
script/test_proof_game_matrix.sh platformer
script/test_web_package.sh platformer
script/test_browser_chromium.sh platformer
```

`test-platformer-scene` compares the deterministic frame to the PNG above. Refresh intentionally with `zig build test-platformer-scene -- --update-golden`.

Desktop packages use `zig build peas -- package <linux|macos|windows> OUT --game platformer`. The capability matrix has package and proof-game lanes for macOS, Linux, and Windows. This checkout passed the macOS universal package, SDL GPU/OpenGL smokes, and package-layout recovery check; Linux and Windows remain remote-matrix evidence until CI runs.

`script/package_web.sh OUT --game platformer` builds a platformer-specific Wasm adapter. It parses normalized left/right/action input, advances `examples/platformer_game.zig`, and draws the level through the shared rectangle contract. This checkout passed Chromium WebGL2 and Chromium WebGPU; Safari requires its local WebDriver remote-automation setting and is not verified here.

## Performance result

`zig build -Doptimize=ReleaseFast benchmark-proofs` records a `platformer` workload beside `bounce` and `puzzle`: Canvas allocation at startup plus a fixed 240-frame loop that executes input, movement/collision, four platforms, flag, player, and text. The macOS arm64 ReleaseFast run for this change reported startup `17393 ns`, `2` allocations / `61560 B`, and `13202 ns` per frame with `240` allocations / `28800 B` across the loop. The one allocation / `120 B` per rendered frame is the shared text path. Reviewed baseline limits remain bounce-only until platformer results are reviewed on every required native target. Values are target-specific and are not portable frame-rate claims.

## Limitations

The proof intentionally has one fixed screen, one player, one-way vertical landing, no moving hazards, no camera, no levels, no pause UI, no accessibility remapping UI, no particles, and no reusable controller extraction. Native presentation uses `ball.png` for the player and `blip.wav` on jump/landing. Browser presentation uses contract rectangles and host-level audio coverage, so it does not render the native sprite or play the desktop sound effect.
