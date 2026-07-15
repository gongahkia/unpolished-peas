# Performance baselines

`script/check_performance_budgets.sh` runs version 1 native `ReleaseFast` headless and proof-game workloads, writes metrics to `zig-out/performance/`, and rejects values above the target baseline. Proof-game baselines cover bounce, top-down, and platformer startup, frame, and allocation metrics.

Baseline changes require a recorded run from the same target and a version increment whenever the workload or metric schema changes.
