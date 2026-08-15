# Contributing to 72

72 is a pre-1.0 Go runtime. Contributions should make the smallest coherent
change that preserves its portable game-facing boundaries. Read
[ARCHITECTURE.md](docs/ARCHITECTURE.md), [PUBLIC_API.md](docs/PUBLIC_API.md),
and the package documentation before proposing a new exported API or backend.

## Local setup and verification

The root module requires Go 1.25. The configured release CI uses Go 1.25.13
and runs formatting, `go vet`, root tests, Wukong replay/wasm evidence,
dependency verification, `govulncheck`, the locked browser dependency audit,
and a Chromium smoke. That smoke checks canvas pixels, keyboard input, resize,
blur, hidden-tab behavior, and browser audio status flow; it is not a physical
GPU, device-output audio, or cross-browser certification. The weekly Go 1.26.6
compatibility job is informational only. Root commands do not enter the nested
WebGPU experiment modules.

Run the focused package test first, then run the relevant project checks:

```sh
go test ./engine/...
make fmt
make vet
make test
go test -race ./...
make example-build
make example-wasm
make first-game-build
make first-game-wasm
make wukong-replay
make wukong-benchmark
make wukong-wasm
make support-check
make device-loss-simulation
make workflow-check
go mod verify
go run golang.org/x/vuln/cmd/govulncheck@v1.7.0 ./...
```

`make fmt` modifies Go files. To perform the same non-mutating formatting
check as CI, run:

```sh
test -z "$(gofmt -l $(find . -name '*.go' -not -path './vendor/*'))"
```

Run the relevant nested-module command when changing a WebGPU experiment; its
README is the source of truth for target-specific commands and manual runtime
checks. A successful cross-build must be reported as compile-only unless it
also ran on the claimed platform. For device-output audio changes, the audio
example is a manual check; on Linux it needs ALSA development/runtime support.

For the generated first-game browser bundle smoke, use the locked Playwright
toolchain:

```sh
npm ci
make first-game-wasm
npx playwright install chromium
npx playwright test --config ci/playwright.config.mjs
```

This checks bundle loading, rendered canvas pixels, keyboard input, resize,
blur, visibility behavior, and startup exceptions in Chromium. It does not
certify physical GPU presentation, audible device output, or Firefox/Safari.
Run `npm audit --omit=dev --audit-level=high` before changing browser
dependencies.

`docs/SUPPORT.md` is generated. Record complete, immutable evidence in
`docs/support-evidence.json`, run `make support-doc`, and include
`make support-check` in the relevant verification. Do not add a target claim
with an abbreviated commit, missing GPU/driver or browser details, or a build
result presented as runtime evidence.

Every `uses:` reference in `.github/workflows` must use a full commit SHA;
run `make workflow-check` after changing a workflow. The global workflow token
is read-only. Any additional permission belongs only on the narrow job that
needs it.

Keep `github.com/gogpu/wgpu` and `github.com/jezek/xgb` upgrades isolated from
features or unrelated dependency changes. A graphics or platform dependency
update needs the full graphics/platform matrix in [SUPPORT.md](docs/SUPPORT.md)
before review; a successful cross-build is still build evidence only.

## Change and review expectations

- Explain the problem, intended behavior, scope, and verification in the pull
  request. Separate observed results from inferences and identify skipped or
  unavailable platform tests.
- Add focused tests for behavior and likely failure paths. Do not weaken an
  unrelated test or validation rule to make a change pass.
- Keep public package changes compatible with their support tier. Complete the
  API review checklist in [PUBLIC_API.md](docs/PUBLIC_API.md) when changing an
  exported identifier.
- Update package documentation, examples, and migration notes when behavior or
  a user-facing contract changes. Example and experiment code is not a public
  API commitment.
- Preserve the dependency direction in [ARCHITECTURE.md](docs/ARCHITECTURE.md).
  In particular, no graphics binding, window handle, browser object, or GPU
  type may enter `engine` or `engine/render` public APIs.

## Architecture and release decisions

Use an ADR for a durable technical direction, such as a renderer binding,
platform-support claim, ownership model, public boundary, or artifact process.
[The ADR guide](docs/adr/README.md) defines the required record and review
process. Renderer and host contributors must also follow
[BACKEND_DEVELOPMENT.md](docs/BACKEND_DEVELOPMENT.md).

There is no automated release workflow or released artifact matrix in this
repository today. Do not describe a new platform as supported merely because
it builds locally. A release-facing change needs target-specific evidence,
documented limitations, and the API/deprecation requirements in
[PUBLIC_API.md](docs/PUBLIC_API.md); renderer/platform changes additionally
need the promotion evidence required by the active ADRs.

The planned v0.1 evidence and dry-run procedure are in
[RELEASING.md](docs/RELEASING.md). A license choice, third-party notice record,
and remote CI evidence are release gates, not documentation-only formalities.
