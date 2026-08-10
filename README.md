# engine prototype

This repository develops a backend-neutral 2D game-engine core. Its public API is currently available as `github.com/gongahkia/72/engine`; the module and repository name are intentionally temporary and will be chosen before release.

The first backend is Ebitengine. Games provide update behavior, register any number of ordered render layers, and receive backend-neutral action input and drawing primitives. World-space layers use camera parallax; screen-space layers provide the future seam for HUD and layout work.

## Golden proof

[Wukong](example/wukong) is the deterministic procedural platforming example that proves the engine core. It owns its simulation, assets, replay tooling, and presentation while consuming the public engine runtime.

```sh
make run
```

## Verification

```sh
make fmt
make vet
make test
go test -race ./example/wukong/internal/...
make build
make bosslint
make wasm
```

Dynamic HUD/layout authoring and a custom renderer backend are intentionally deferred. HUD work will begin with research into immediate-mode, retained-tree, and hybrid layout approaches before selecting an API.
