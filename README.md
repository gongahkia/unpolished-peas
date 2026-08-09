# 72

`72` is a deterministic procedural platforming prototype. Each short run recombines ten authored room topologies with readable enemies, throwable objects, breakable terrain, hazards, and optional treasure. The player sprite is animated pixel art; all other visuals remain deliberately schematic.

It requires Go 1.25+ and native Ebitengine dependencies for the host platform.

## Playtest

```sh
go run ./cmd/game --mode=playtest
```

`F1` restarts the same seed. `F2` creates a new seed. `Enter` restarts after death or completing the exit. `F6` saves a deterministic replay, which can be checked with:

```sh
go run ./cmd/replaydump 72.replay.json
```

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
go test -race ./internal/...
go build ./cmd/game
make bosslint
make wasm
```
