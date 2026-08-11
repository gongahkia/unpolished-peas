# Contributing to 72

72 is a pre-1.0 Go runtime. Contributions should make the smallest coherent
change that preserves its portable game-facing boundaries. Read
[ARCHITECTURE.md](docs/ARCHITECTURE.md), [PUBLIC_API.md](docs/PUBLIC_API.md),
and the package documentation before proposing a new exported API or backend.

## Local setup and verification

The root module requires Go 1.25. The current CI uses `ubuntu-latest` with Go
1.25.x and runs formatting, `go vet`, the root tests, the Wukong race tests,
and the Wukong wasm build. Root commands do not enter the nested WebGPU
experiment modules.

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

This checks bundle loading and startup exceptions in Chromium. It does not
verify a rendered frame, gameplay input, or WebGPU presentation. `npm audit`
must be clean before changing the browser test dependency.

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
