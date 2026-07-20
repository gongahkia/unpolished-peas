# CI

## Required pull-request suite

`stable-core-capability` is the intended required pull-request matrix; `capability-matrix` is its generated-matrix dependency. The matrix is generated from `docs/capabilities/v0.1.json`; it selects only supported desktop SDL GPU rows.

`nightly.yml` consumes the nightly matrix from the same catalog. It runs the documented macOS, Linux, Windows, Chromium, Firefox, and Safari rows, preserving renderer diagnostics and workload artifacts under the matrix identity. Unsupported Firefox and Safari WebGPU rows are absent.

| Job | Rows | Checks | Execution budget |
| --- | --- | --- | --- |
| `capability-matrix` | all selected rows | validates and emits the matrix | 1 minute |
| `stable-core-capability` | macOS, Linux, Windows SDL GPU | formatting; frozen core API; deterministic unit, headless, and test-support checks; starter generation; browser-template compile; documentation links; macOS/Linux generated-project host smoke | 15 minutes per row |

The budget is an operational target, not a wall-clock guarantee. Graphics failures retain `zig-out` diagnostics in the retained non-PR renderer-conformance jobs.

## Non-PR validation

Package, proof-game, renderer, release-compatibility, and next-Zig jobs run outside pull requests until their owning removal or release issue changes that policy. They are not stable-core required checks.
