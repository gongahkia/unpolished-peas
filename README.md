# Journey of the Cloud-Born

An ASCII-rendered, top-down action roguelite about Sun Wukong. The combat
language is Wukong's: a staff whose geometry changes, rapid transformations,
cloud movement, and hair clones that manipulate the fight.

## Run it

Requires Go 1.25 or newer and the native Ebitengine dependencies for your OS.

```sh
go run ./cmd/game
go test ./...
```

Controls: `WASD`/arrows move, `J` attacks, `K` dashes, `1`/`2`/`3` select
short/medium/long staff, `Q` tiger, `E` sparrow, `R` mantis, `F` cicada,
`G` giant, `T` statue, `C` hair clone, `Tab` toggles debug, `Enter` restarts
after death.

## Current status

The simulation and Ebitengine renderer are deliberately separate. Gameplay
uses glyphs and primitives only; the renderer consumes immutable snapshots so
sprites can replace it later without changing combat rules. See `docs/ROADMAP.md`
for the actively tracked implementation status.

## Repository layout

- `cmd/game`: Ebitengine input adapter and glyph renderer.
- `internal/sim`: deterministic fixed-tick gameplay simulation.
- `internal/bossdsl`: boss-pattern lexer, parser, validator, compiler.
- `data/bosses`: authored boss-pattern sources.
- `docs`: implementation-facing design notes.
