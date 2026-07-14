# Performance baselines

`script/check_performance_budgets.sh` runs the version 1 native `ReleaseFast` headless workload, writes metrics to `zig-out/performance/`, and rejects values above the baseline for the current target.

Baseline changes require a recorded run from the same target and a version increment whenever the workload or metric schema changes.
