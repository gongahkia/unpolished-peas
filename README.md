# 72

`72` is a deterministic ASCII combat prototype built around one replayable 1280×720 arena and one boss. The 640×360 follow viewport and minimap make it a bounded combat world with routes and distance, not a campaign or open-world expansion.

## Run the validation encounter

Requires Go 1.25+ and the native Ebitengine dependencies. On Fedora:

```sh
sudo dnf install libXcursor-devel libXinerama-devel libXrandr-devel libXi-devel libXxf86vm-devel mesa-libGL-devel
go run ./cmd/game
```

The application opens directly in the validation arena. `F1` restarts it immediately; `Enter` also retries after defeat. `F6` saves a deterministic recording to `72.replay.json`, which can be verified with:

```sh
go run ./cmd/replaydump 72.replay.json
```

## Controls

`WASD` moves. Arrow keys set combat aim independently, so movement does not turn the staff. `J` attacks and holds/releases the long staff; `K` dodges; `C` summons Echo. `1`/`2`/`3` select short, medium, or long staff. `Q` is Bird, `E` Tiger, `R` Mantis, and `0` returns to Monkey. `Tab` toggles combat debugging; `P` pauses and `.` advances one simulation tick. A connected gamepad uses the left stick for movement and right stick for aim.

## The combat slice

- Short staff is a quick close-range deflecting strike with minimal recovery.
- Medium staff is a three-step sweeping chain with growing coverage that can clear clustered projectile fans.
- Long staff charges an extending line while movement is constrained, then releases a high-knockback attack with long recovery.
- Bird crosses water, becomes tiny and fast, replaces staff attacks with a dive, and carries momentum back to Monkey.
- Tiger replaces dodge/staff with a committed pounce that breaks armor and cracked walls.
- Mantis replaces staff with a counter stance that exposes a long weak-point.
- Echo waits briefly, then deterministically replays the previous two seconds of movement, aim, staff choices, transformations, and attacks from its own spawn point.

The Warden begins beyond the starting viewport, so reaching the fight means choosing around water, through cover, or with a form-specific shortcut. It first demands a charged long-staff guard break, then switches to an Echo-only seal. Water, pillars, and the cracked wall create routes, cover, and form-specific opportunities. See `docs/COMBAT.md` for the exact interactions.

Staff visibility is stateful: a compact side-carried staff is brown when ready, its planned range is orange and dashed during windup, and its damaging line is bright yellow only during active frames. Recovery returns the staff to a compact muted blue-grey carry position. Long charge is orange—not damaging—and shows both its current extension and the maximum forecast; transformed forms explicitly show that staff actions are replaced.

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

- `cmd/game`: direct validation-arena input adapter and primitive renderer.
- `internal/sim`: deterministic 60 Hz arena simulation and replay hashing.
- `data/bosses`: the single linted Warden encounter contract.
- `internal/bossdsl`: parser and validator retained for `bosslint`.
- `docs`: current mechanics and verification notes.
