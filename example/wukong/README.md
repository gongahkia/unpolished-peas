# Wukong

`Wukong` is a deterministic procedural platforming prototype and example game
for the 72 runtime. It is not an engine subsystem: it owns its simulation,
procedural generation, assets, replays, and game-specific presentation. Each
short run recombines ten authored room topologies with readable enemies,
throwable objects, breakable terrain, hazards, and optional treasure. The
player atlas and state-to-frame mapping remain available but its sprite is
intentionally omitted from the playtest view; actors and interactables remain
schematic over renderer-local depth layers.

The HUD and schematic world use 72's high-level command-layer API. Rendering
cannot affect the deterministic simulation or replay hashes.

It requires Go 1.25+. The Linux host uses X11 and WebGPU at runtime; browser
and other desktop runtime support remains subject to the project support matrix.

## Playtest

```sh
go run ./example/wukong --mode=playtest
```

`F1` restarts the same seed. `F2` creates a new seed. `Enter` restarts after death or completing the exit. `F6` saves a deterministic replay, which can be checked with:

```sh
go run ./example/wukong/cmd/replaydump wukong.replay.json
```

## Reproducible proof

The repository has a fixed, headless reference replay for regression evidence.
It uses seed `0x72c0ffee`, contains 240 fixed-timestep input frames, and
checks the final simulation hash without starting a host or renderer:

```sh
make wukong-replay
make wukong-benchmark
make wukong-wasm
```

`make wukong-replay` writes `dist/wukong/reference.replay.json` and verifies
it through `replaydump`. `make wukong-benchmark` measures the same replay,
not a graphics workload. `make wukong-wasm` writes a browser artifact to
`dist/wukong`; inspect it through an HTTP origin:

```sh
python3 -m http.server --directory dist/wukong 8080
```

Then open <http://127.0.0.1:8080>. These commands establish reproducible game
logic and a build artifact; they do not certify browser rendering, input, or
GPU presentation.

## Controls

`A`/`D` run; `W`/`Space` jumps; `S` crouches, drops through a one-way platform with jump, or starts a downward smash in the air; `Shift` rolls. Hold toward a wall to slide, then jump to wall-jump. A ledge briefly catches the player: hold toward it or press jump to mantle, or hold `S` to drop. `E` carries/drops nearby crates and rocks; `J` throws the held object; arrows aim throws. `Tab` shows run topology and links.

Gamepad: left stick moves and lowers, right stick aims; buttons `0`, `1`, `2`, and `3` map to jump, roll, interact, and throw.

## Core loop

- Read a room and start moving immediately along its reliable route.
- Choose whether to take an upper route for visible treasure, use a breakable shortcut, or leave safely.
- Avoid, stomp, bait, or throw objects at chargers, hoppers, and divers.
- Use rocks/crates, pressure plates, doors, spikes, and fragile walls to recover from mistakes or create a shortcut.
- Death and completion restart immediately; a new seed produces a different but reproducible run.

See [the room layout](docs/ARENA.md), [interaction rules](docs/COMBAT.md), [procedural model](docs/PROCEDURAL.md), and [replay contract](docs/REPLAY.md).

## Verification

```sh
make fmt
go vet ./...
go test ./...
go test -race ./example/wukong/internal/...
go build ./example/wukong
make wukong-replay
make wukong-benchmark
make wukong-wasm
```
