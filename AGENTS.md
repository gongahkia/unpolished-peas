# Agent Guide

Journey of the Cloud-Born is a deterministic Go/Ebitengine action-roguelite
prototype. Its signature systems are variable staff geometry, rapid form
changes, cloud dodges, and hair clones; do not replace them with generic RPG
stat upgrades. Gameplay is ASCII glyphs and primitives until the combat is
mature—do not add production art or sprite tooling.

## Working rules

- Keep `internal/sim` renderer-independent. It owns fixed-tick input,
  deterministic RNG, combat, AI, bosses, runs, and replay state.
- `cmd/game` only adapts Ebitengine input and draws `RenderSnapshot` values.
  Do not make rendering own gameplay state or random decisions.
- Prefer a tested playable vertical slice over generic engine abstractions.
- Preserve deterministic behavior. Add tests for timing, state transitions,
  seeded generation, or replay effects whenever a simulation rule changes.
- Boss behavior belongs in `data/bosses/*.boss` and the small runtime command
  registry. Validate every authored pattern with `make bosslint`.
- Keep documentation accurate to the code; update the relevant file in `docs/`
  whenever controls, boss mechanics, replay behavior, or architecture changes.

## Commands

```sh
go run ./cmd/game
go test ./...
go vet ./...
make bosslint
make wasm
```

Native Ebitengine builds on Fedora need the development libraries listed in
`README.md`. Before committing a substantive change, run `gofmt`, vet, tests,
and the narrowest relevant smoke check. Check `docs/ROADMAP.md` before choosing
the next milestone.
