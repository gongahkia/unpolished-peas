# 72

`72` is currently a deterministic movement laboratory. It is a compact, seed-generated platforming world for testing how one player body, terrain, and physical objects fit together. Its first visual pass gives that player an animated pixel-art texture atlas; terrain and objects remain deliberately schematic. Combat, enemies, bosses, Echo, staff modes, and Wukong transformations are intentionally inactive.

It requires Go 1.25+ and native Ebitengine dependencies for the host platform.

## Run the laboratory

```sh
go run ./cmd/game
```

`F1` restarts the same seed. `F2` creates a new seed. `Enter` restarts after a hazard or completing the exit. `F6` saves a deterministic replay, which can be checked with:

```sh
go run ./cmd/replaydump 72.replay.json
```

## Controls

The movement bindings follow a Dead Cells-style keyboard layout: `A`/`D` run; `W`/`Space` jump; `S` crouches, and `S`+jump drops through a one-way platform or starts a downward smash in the air; `Shift` rolls. Wall-slide by holding toward a wall, then wall-jump with jump. A ledge briefly catches the player: hold toward it or press jump to climb, or hold `S` to drop. `E` interacts, carries/drops objects, activates vines, switches, and teleporters. `J` throws; `F` toggles the tether probe; arrows aim throws and the probe. `Tab` shows deterministic lab state and links.

Gamepad: left stick moves and lowers, right stick aims; buttons `0`, `1`, `2`, `3`, and `6` map to jump, roll, interact, throw, and tether respectively.

## What the lab tests

- Variable jump height, coyote time, jump buffering, double jump, wall slide/jump with a brief input grace window, ledge grabs, crouch, drop-through, and ground/air roll.
- Downward smash breaks marked floors; activated vines, paired teleporters, and the bounded tether probe create alternate routes.
- Crates and rocks can be pushed, carried, dropped, thrown, and used on pressure plates to open linked doors.
- Every seed contains the same required movement syllabus, but platform heights, object positions, and trial geometry vary deterministically.

See [the lab layout](docs/ARENA.md), [movement rules](docs/COMBAT.md), [procedural model](docs/PROCEDURAL.md), and [replay contract](docs/REPLAY.md).

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
