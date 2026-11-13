#!/usr/bin/env python3
"""Alternate retained before/after binaries; validate workloads before comparing."""
import argparse
import hashlib
import json
import platform
import statistics
import subprocess
from pathlib import Path

VARIABLE_FIELDS = {"sample", "elapsed_ns", "average_ns"}


def signature(row):
    return {key: value for key, value in row.items() if key not in VARIABLE_FIELDS}


def distribution(values):
    median = statistics.median(values)
    return {"median_ns": median, "min_ns": min(values), "max_ns": max(values),
            "mad_ns": statistics.median(abs(value - median) for value in values), "samples_ns": values}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--baseline", type=Path, required=True, help="Original fixed-workload JSONL, captured before optimizing")
    parser.add_argument("--rounds", type=int, default=7)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 3 <= args.rounds <= 100: parser.error("rounds must be between 3 and 100")
    binaries = {name: path.resolve() for name, path in (("before", args.before), ("after", args.after))}
    baseline = {}
    for line in args.baseline.read_text().splitlines():
        row = json.loads(line)
        assert row["mode"] == "ReleaseFast" and row["allocations"] == 0 and row["allocated_bytes"] == 0
        key = row["name"]
        if key in baseline: assert signature(row) == signature(baseline[key]), f"baseline workload changed: {key}"
        baseline[key] = row
    assert baseline, "empty baseline"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    raw = args.output.with_suffix(".jsonl")
    collected = {key: {"before": [], "after": []} for key in baseline}
    with raw.open("w") as log:
        for pair in range(args.rounds):
            order = ("before", "after") if pair % 2 == 0 else ("after", "before")
            for name, original in baseline.items():
                for version in order:
                    result = subprocess.run([binaries[version], "--case", name, "--rounds", "1"], check=True, text=True, capture_output=True)
                    rows = [json.loads(line) for line in result.stdout.splitlines()]
                    assert len(rows) == 1
                    row = rows[0]
                    assert signature(row) == signature(original), f"workload, pixel hash or allocation invariant changed: {name} ({version})"
                    collected[name][version].append(row["average_ns"])
                    log.write(json.dumps({"pair": pair, "version": version, "measurement": row}) + "\n"); log.flush()
            print(f"paired CPU composition samples completed: {pair + 1}/{args.rounds}", flush=True)
    measurements = []
    for name, values in collected.items():
        original = baseline[name]
        measurements.append({"name": name, "workload": signature(original), "before": distribution(values["before"]),
                             "after": distribution(values["after"]), "median_paired_speedup": statistics.median(b / a for b, a in zip(values["before"], values["after"]))})
    output = {"schema": "surface-composition-comparison-v1", "platform": platform.platform(), "rounds": args.rounds,
              "order": "before/after on even pairs; after/before on odd pairs; serial execution",
              "binaries": {name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for name, path in binaries.items()},
              "baseline_sha256": hashlib.sha256(args.baseline.read_bytes()).hexdigest(), "measurements": measurements}
    args.output.write_text(json.dumps(output, indent=2) + "\n")
    for measurement in measurements:
        print(f"{measurement['name']}: {measurement['before']['median_ns'] / 1e6:.3f} -> {measurement['after']['median_ns'] / 1e6:.3f} ms; paired {measurement['median_paired_speedup']:.2f}x")


if __name__ == "__main__": main()
