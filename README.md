# 72

`72` is a deterministic ASCII Wukong platform-brawler prototype. It contains one bounded 1280×720 side-view stage, a 640×360 follow camera, and one replayable boss encounter. It is deliberately a combat slice, not a campaign, open world, or content framework.

## Run the validation encounter

Requires Go 1.25+ and the native Ebitengine dependencies. On Fedora:

```sh
sudo dnf install libXcursor-devel libXinerama-devel libXrandr-devel libXi-devel libXxf86vm-devel mesa-libGL-devel
go run ./cmd/game
```

The game opens directly in the Warden validation stage. `F1` restarts it immediately; `Enter` retries after defeat. `F6` saves `72.replay.json`, which can be checked with:

```sh
go run ./cmd/replaydump 72.replay.json
```

## Controls

`A`/`D` run. `W` or `Space` jumps. Arrow keys aim the staff independently of movement: run one way while holding any attack direction. `J` attacks and holds/releases Long; `K` dodges; `C` summons Echo. `1`/`2`/`3` select Short, Medium, or Long. `Q` is Bird, `E` Tiger, `R` Mantis, and `0` returns to Monkey. `Tab` toggles collision/aim/Echo debug data; `P` pauses and `.` advances one tick.

A gamepad uses the left stick to run and jump upward, and the right stick to aim. Attack/dodge still have to be mapped by the host or keyboard for now.

## The platform-brawler slice

- Short is a fast close strike with a small, precise deflection window.
- Medium is the conventional three-part Wukong sweep chain, useful for projectile fans and crowd space.
- Long is a held directional extension. It constrains running while charging, then commits to a strong thrust/sweep with long recovery. It crosses water but stops at solid cover.
- Bird replaces staff combat with a dive, has a tiny collision body, can repeatedly flap-jump and glide over water, and preserves flight momentum when returning to Monkey.
- Tiger replaces staff and dodge with a committed pounce that breaks armor and cracked walls.
- Mantis replaces staff combat with a precision counter stance that staggers and exposes a weak point.
- Echo waits 20 ticks then deterministically replays the last two seconds of movement, jumps, aim, staff selections, forms, and attacks from its spawn position.

The stage is a vertical route across a water gap: landing platforms give the ordinary route, Bird can bypass the hazard, Tiger can open the cracked wall, pillars block lines, and the raised east platform holds the Warden. The Warden first requires a charged Long guard break and later an Echo strike. See [the arena layout](docs/ARENA.md) and [combat rules](docs/COMBAT.md).

Combat visuals distinguish information from damage: the cyan chevron and `AIM` label are always-safe direction indicators; the compact brown/grey staff is only carried; orange dashes forecast windup; bright yellow full-length staff is damaging; orange Long extension is charging and non-damaging. The bottom readout names `READY`, `WINDUP`, `ACTIVE`, `RECOVERY`, or `CHARGING`.

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

## Layout

- `cmd/game`: direct validation-stage input adapter and ASCII/primitive renderer.
- `internal/sim`: deterministic 60 Hz platform physics, combat, and replay hashing.
- `data/bosses`: the single linted Warden encounter contract.
- `internal/bossdsl`: parser and validator retained for `bosslint`.
- `docs`: current stage, mechanics, replay, and verification notes.
