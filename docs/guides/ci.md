# CI

## Required pull-request suite

Pushes and pull requests also run `browser-host` for the DOM/renderer/audio/
storage host contracts, browser development server, and version/release
wiring, plus `browser-rendering` for real Chromium shell interactions and
the WebGL 2/WebGPU/CPU-reference pixel comparison. These checks catch browser
regressions before the nightly matrix. Renderer failure artifacts are retained
under the checkout even when a test uses a temporary working directory.

`stable-core-capability` is the intended required pull-request matrix; `capability-matrix` is its generated-matrix dependency. The matrix is generated from `docs/capabilities/v1.0.json`; it selects only supported desktop SDL GPU rows.

`nightly.yml` consumes the nightly matrix from the same catalog. It runs the documented macOS, Linux, Windows, Chromium, Firefox, and separately forced Safari WebGL2/WebGPU rows, preserving renderer diagnostics and workload artifacts under the matrix identity. Unsupported Firefox WebGPU is absent.

Safari WebGL checks independently probe rendering and canvas PNG export on a
blank page on the package's origin before loading Peas. A runner whose canvas PNG
export returns an empty data URL still has to pass the Peas Wasm renderer's pixel
readback and every input, audio, storage, diagnostic, and lifecycle check. Its nullable capture
result, independent probe, runtime pixels, and WebDriver screenshot are retained;
working runner canvas PNG export continues to require a valid Peas PNG capture.

Nightly and tag-release capability rows run `script/check_workload_performance.sh` on macOS/Linux and `script/check_workload_performance.ps1` on Windows after their supported SDL GPU checks. Each records a `ReleaseFast` workload artifact, compares it to the exact reviewed target baseline, and fails with target, workload, metric, baseline, observed value, and tolerance. Performance checks are intentionally absent from pull-request CI; baseline changes require a reviewed artifact record.

| Job | Rows | Checks | Execution budget |
| --- | --- | --- | --- |
| `capability-matrix` | all selected rows | validates and emits the matrix | 1 minute |
| `stable-core-capability` | macOS, Linux, Windows SDL GPU | formatting; frozen core API; deterministic unit, headless, and test-support checks; starter generation; clean external native and browser builds; starter browser package; documentation links; macOS/Linux generated-project host smoke | 15 minutes per row |

The budget is an operational target, not a wall-clock guarantee. Graphics failures retain `zig-out` diagnostics in the retained non-PR renderer-conformance jobs.

`zig build test-starter-external` generates a game outside the checkout with
the default local dependency. `zig build test-starter-external-web` generates
from a clean archive checkout with a prepared template, fetching the actual
archive over loopback HTTP and verifying its Zig package hash. Both execute
`zig build`, `zig build test`, `zig build web`, and `zig build package` on the
untouched generated game with separate generator/consumer caches, then verify
that the authored files did not change. Release checks also reject missing
coordinates and a URL paired with a real hash from different archive bytes;
no public release is needed. The bundled-SDL check runs the local case with a
failing `pkg-config` shim and a bounded native host smoke.

## Non-PR validation

Package, proof-game, renderer, release-compatibility, and next-Zig jobs run outside pull requests until their owning removal or release issue changes that policy. They are not stable-core required checks.
