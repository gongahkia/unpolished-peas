# Journey of the Cloud-Born

An ASCII-rendered, top-down action roguelite about Sun Wukong. The combat
language is Wukong's: a staff whose geometry changes, rapid transformations,
cloud movement, and hair clones that manipulate the fight.

## Run it

Requires Go 1.25 or newer and the native Ebitengine dependencies for your OS.
On Fedora, install the missing development libraries with:

```sh
sudo dnf install libXcursor-devel libXinerama-devel libXrandr-devel libXi-devel libXxf86vm-devel mesa-libGL-devel
```

```sh
go run ./cmd/game
go test ./...
```

Controls: `WASD`/arrows move, `J` attacks, `K` dashes, `1`/`2`/`3` select
short/medium/long staff, `Q` tiger, `E` sparrow, `R` mantis, `F` cicada,
`G` giant, `T` statue, `0` monkey, `C` hair clone, `Tab` toggles debug, and
`P` pauses (`.` advances one tick). At an encounter clear, `Z`/`X` select a
branch and `Enter` continues; shrines use `1`/`2`/`3` to take a vow.

## Current status

The prototype currently includes the deterministic combat foundation, seven
rule-changing forms, three staff geometries, clone delayed strikes and aggro,
a branching three-boss pilgrimage, vows, replay recording primitives, debug
overlays, and a tested boss-pattern DSL. Gameplay uses glyphs and primitives;
the renderer consumes immutable snapshots so sprites can replace it later
without changing combat rules. See `docs/ROADMAP.md` for the actively tracked
implementation status.

## Repository layout

- `cmd/game`: Ebitengine input adapter and glyph renderer.
- `internal/sim`: deterministic fixed-tick gameplay simulation.
- `internal/bossdsl`: boss-pattern lexer, parser, validator, compiler.
- `data/bosses`: authored boss-pattern sources.
- `docs`: implementation-facing design notes.
