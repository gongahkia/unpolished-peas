# Warden encounter contract

`data/bosses/warden.boss` is the single linted pacing contract for the validation encounter. Run `make bosslint` to parse, validate, and compile it. The deterministic runtime keeps mechanism-specific guard, terrain, Echo, and counter rules in `internal/sim/boss.go`; the contract documents the authored phase order and named telegraphs that the runtime exposes.
