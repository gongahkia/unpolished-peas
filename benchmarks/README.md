# Performance baselines

`script/check_performance_budgets.sh` runs version 1 native `ReleaseFast` headless and bounce workloads, writes metrics to `zig-out/performance/`, and rejects values above the target baseline.

Baseline changes require a recorded run from the same target and a version increment whenever the workload or metric schema changes.

## Rendering workload catalog

`workloads/v1.json` is the canonical stable-core 2D catalog. Its six fixed 160×90 workloads cover primitive fill, sprite batching, alpha blend, clipping, text, and a mixed frame; every entry fixes its assets, four warm-up frames, sixteen measured frames, metric names, and rationale.

`zig build test-workload-catalog` parses and executes every workload through the native headless renderer. `zig build test-browser-workloads` packages the same JSON and executes it in Chromium WebGL 2. Both reject altered versions, required workload IDs, metrics, assets, and unsupported commands. Increment `workload_version` when a workload's visual commands, assets, resolution, warm-up, frame count, or metric schema changes.

`zig build -Doptimize=ReleaseFast benchmark-workloads` emits a bounded (16 KiB) JSON artifact. `script/record_performance_artifacts.sh` records it as `zig-out/performance/workloads-<os>-<architecture>.json` with a same-name `.diagnostics.log` sidecar; an execution failure leaves the sidecar and returns the runner's nonzero status. Schema v1 records the headless renderer, OS, architecture, workload version, per-workload resolution/warm-up/sample count, average frame time, command count, allocation indicators, and a combined canvas hash.

## Browser workload artifacts

`zig build benchmark-browser-workloads` records `browser-workloads-<browser>-webgl2.json` and `browser-workloads-<browser>-webgpu.json` under `zig-out/performance/`; the matrix-selected Chromium job uploads both. Set `UP_BROWSER=chromium`, `firefox`, or `webkit` to select the Playwright engine and `UP_RENDERERS` to select forced renderers. The artifact keeps the native workload shape while adding browser name/version and actual renderer selection; allocation metrics are `null` with explicit `unavailable` availability because browser JavaScript allocation counters are not portable.

`frame_time_ns` is CPU submission time around browser host calls. It does not wait for GPU completion, and `performance.now()` can be quantized for privacy, throttled in the background, or affected by compositor scheduling. Browser artifacts are therefore comparable only within the same browser, version, renderer, and workload schema; they are not native comparisons.
