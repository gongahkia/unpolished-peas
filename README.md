# 72

`72` is currently a deterministic ASCII movement laboratory. It is a compact, seed-generated platforming world for testing how one player body, terrain, and physical objects fit together. Combat, enemies, bosses, Echo, staff modes, and Wukong transformations are intentionally inactive.

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

`A`/`D` run; `W`/`Space` jump; `S` crouches, drops through platforms, or dives while falling; `K` rolls. `E` interacts, carries/drops objects, activates vines, switches, and teleporters. `J` throws; `Q` deploys a bomb; `R` places a rope; `F` launches/retracts the tether probe; arrows aim throws and the probe. `Tab` shows deterministic lab state and links.

Gamepad: left stick moves and lowers, right stick aims, buttons `0–6` map to jump, roll, interact, throw, bomb, rope, and tether respectively.

## What the lab tests

- Variable jump height, coyote time, jump buffering, double jump, wall cling/jump, wall climb, mantle, crouch, drop-through, and ground/air roll.
- Dive/slam floor breaks, climbable spawned ropes and activated vines, paired teleporters, and the bounded tether probe.
- Crates and rocks can be pushed, carried, dropped, thrown, and used on pressure plates to open linked doors. Bombs break marked terrain and push nearby objects.
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
