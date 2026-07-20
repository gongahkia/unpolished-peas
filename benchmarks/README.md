# Performance baselines

`script/check_performance_budgets.sh` runs version 1 native `ReleaseFast` headless and bounce workloads, writes metrics to `zig-out/performance/`, and rejects values above the target baseline.

Baseline changes require a recorded run from the same target and a version increment whenever the workload or metric schema changes.

## Rendering workload catalog

`workloads/v1.json` is the canonical stable-core 2D catalog. Its six fixed 160×90 workloads cover primitive fill, sprite batching, alpha blend, clipping, text, and a mixed frame; every entry fixes its assets, four warm-up frames, sixteen measured frames, metric names, and rationale.

`zig build test-workload-catalog` parses and executes every workload through the native headless renderer. `zig build test-browser-workloads` packages the same JSON and executes it in Chromium WebGL 2. Both reject altered versions, required workload IDs, metrics, assets, and unsupported commands. Increment `workload_version` when a workload's visual commands, assets, resolution, warm-up, frame count, or metric schema changes.

`zig build -Doptimize=ReleaseFast benchmark-workloads` emits a bounded (16 KiB) JSON artifact. `script/record_performance_artifacts.sh` records it as `zig-out/performance/workloads-<os>-<architecture>.json` with a same-name `.diagnostics.log` sidecar; an execution failure leaves the sidecar and returns the runner's nonzero status. Schema v1 records the headless renderer, OS, architecture, workload version, per-workload resolution/warm-up/sample count, average frame time, command count, allocation indicators, and a combined canvas hash.

On Windows, run `pwsh -File script/record_performance_artifacts.ps1`; it records the same engine, proof-game, and workload artifacts as `workloads-windows-x86_64.json` without a Unix shell dependency.

## Browser workload artifacts

`zig build benchmark-browser-workloads` records `browser-workloads-<browser>-webgl2.json` and `browser-workloads-<browser>-webgpu.json` under `zig-out/performance/`; the matrix-selected Chromium job uploads both. Set `UP_BROWSER=chromium`, `firefox`, or `webkit` to select the Playwright engine and `UP_RENDERERS` to select forced renderers. The artifact keeps the native workload shape while adding browser name/version and actual renderer selection; allocation metrics are `null` with explicit `unavailable` availability because browser JavaScript allocation counters are not portable.

`frame_time_ns` is CPU submission time around browser host calls. It does not wait for GPU completion, and `performance.now()` can be quantized for privacy, throttled in the background, or affected by compositor scheduling. Browser artifacts are therefore comparable only within the same browser, version, renderer, and workload schema; they are not native comparisons.

## Versioned workload baselines

`workload-baselines/v1/` stores reviewed limits, while `workload-artifacts/v1/` stores the exact measured JSON used to create each baseline. A baseline is selected only when its target identity, browser version where present, renderer, workload version, and timer measurement schema match the observed artifact. Its record must name the stored artifact by a baseline-relative path, include its SHA-256, and give a non-empty reason; validation rejects a changed or missing source artifact.

Record a reviewed update with a measured artifact, not hand-edited limits:

```sh
python3 script/record_workload_baseline.py ARTIFACT RECORDED_ARTIFACT BASELINE 'measured reason for this update'
```

For example, `ARTIFACT` may be `zig-out/performance/workloads-macos-aarch64.json`, `RECORDED_ARTIFACT` may be `benchmarks/workload-artifacts/v1/macos-aarch64-headless.json`, and `BASELINE` may be `benchmarks/workload-baselines/v1/macos-aarch64-headless.json`. Review the stored artifact, SHA-256, reason, tolerance change, and baseline together.

Validate a single baseline with `python3 script/check_workload_baseline.py BASELINE ARTIFACT`, or select by exact identity with `python3 script/check_workload_baseline.py --directory benchmarks/workload-baselines/v1 ARTIFACT`. `script/check_performance_budgets.sh` records and validates the native workload artifact; `script/check_browser_workload_baselines.sh` does the same for selected browser renderers. `python3 script/check_required_workload_baselines.py` validates the supported desktop registry before release eligibility. If a required or observed identity lacks an exact baseline, validation exits nonzero with `release_eligible=false`; release automation can therefore never silently compare different machines, browsers, renderers, or measurement methods.

Never rewrite a historical baseline schema in place. Add matching `workload-artifacts/vN/` and `workload-baselines/vN/` directories for a new schema or workload version, retaining the prior directory and its checker-compatible JSON for review.
