# Performance baselines

`script/check_performance_budgets.sh` runs version 1 native `ReleaseFast` headless and bounce workloads, writes metrics to `zig-out/performance/`, and rejects values above the target baseline.

Baseline changes require a recorded run from the same target and a version increment whenever the workload or metric schema changes.

## Rendering workload catalog

`workloads/v1.json` is the canonical stable-core 2D catalog. Its six fixed 160×90 workloads cover primitive fill, sprite batching, alpha blend, clipping, text, and a mixed frame; every entry fixes its assets, four warm-up frames, sixteen measured frames, metric names, and rationale.

`zig build test-workload-catalog` parses and executes every workload through the native headless renderer. `zig build test-browser-workloads` packages the same JSON and executes it in Chromium WebGL 2. Both reject altered versions, required workload IDs, metrics, assets, and unsupported commands. Increment `workload_version` when a workload's visual commands, assets, resolution, warm-up, frame count, or metric schema changes.
