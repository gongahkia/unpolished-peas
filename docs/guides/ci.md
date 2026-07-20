# CI

## Required pull-request suite

`stable-core-capability` is the intended required pull-request matrix; `capability-matrix` is its generated-matrix dependency. The matrix is generated from `docs/capabilities/v0.1.json`; it selects only supported desktop SDL GPU rows.

`browser-renderer-parity` is an extended, non-PR matrix from the same catalog. Its Chromium WebGPU row runs forced browser renderer parity and exports forced WebGL 2/WebGPU workload artifacts; its Firefox WebGL 2 row runs the equivalent packaged smoke path and records an explicit Firefox-WebGPU-unavailable result because that renderer is unsupported in the catalog.

| Job | Rows | Checks | Execution budget |
| --- | --- | --- | --- |
| `capability-matrix` | all selected rows | validates and emits the matrix | 1 minute |
| `stable-core-capability` | macOS, Linux, Windows SDL GPU | formatting; frozen core API; deterministic unit, headless, and test-support checks; starter generation; browser-template compile; documentation links; macOS/Linux generated-project host smoke | 15 minutes per row |

The budget is an operational target, not a wall-clock guarantee. Graphics failures retain `zig-out` diagnostics in the retained non-PR renderer-conformance jobs.

## Extended validation

Package, proof-game, renderer, release-compatibility, and next-Zig jobs run outside pull requests until their owning removal or release issue changes that policy. They are not stable-core required checks.
