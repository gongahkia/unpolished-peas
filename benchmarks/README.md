# Performance baselines

`script/check_performance_budgets.sh` runs version 1 native `ReleaseFast` headless and bounce workloads, writes metrics to `zig-out/performance/`, and rejects values above the target baseline.

Baseline changes require a recorded run from the same target and a version increment whenever the workload or metric schema changes.
