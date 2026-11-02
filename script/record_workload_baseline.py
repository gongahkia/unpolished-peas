#!/usr/bin/env python3
import datetime
import hashlib
import json
import os
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"record workload baseline failure: {message}", file=sys.stderr)
    raise SystemExit(1)


def measurement_schema(artifact: dict) -> dict:
    timer = artifact.get("timer")
    if not isinstance(timer, dict) or not all(isinstance(timer.get(field), str) and timer[field] for field in ("clock", "unit", "measurement")):
        fail("artifact requires a timer measurement schema")
    return {"artifact_schema_version": artifact["schema_version"], "timer": timer}


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: record_workload_baseline.py ARTIFACT RECORDED_ARTIFACT BASELINE REASON")
    artifact_path, recorded_path, baseline_path, reason = (Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
    if not reason.strip():
        fail("reason is required")
    try:
        artifact = json.loads(artifact_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(str(error))
    if artifact.get("schema_version") != 1 or artifact.get("status") != "ok" or not isinstance(artifact.get("target"), dict) or not isinstance(artifact.get("workload_version"), str) or not isinstance(artifact.get("workloads"), list):
        fail("artifact is not a completed workload artifact v1")
    measurement = measurement_schema(artifact)
    browser = artifact["target"].get("os") == "browser"
    tolerances = {
        "frame_time_ns": {"relative": 0.50, "absolute": 500_000 if browser else 100_000},
        "command_count": {"relative": 0.0, "absolute": 0},
        "frame_allocation_events": {"relative": 0.0, "absolute": 0},
        "frame_allocated_bytes": {"relative": 0.0, "absolute": 0},
    }
    recorded_path.parent.mkdir(parents=True, exist_ok=True)
    recorded_path.write_text(json.dumps(artifact, indent=2) + "\n", encoding="utf-8")
    source_path = os.path.relpath(recorded_path, baseline_path.parent)
    source_sha256 = hashlib.sha256(recorded_path.read_bytes()).hexdigest()
    baseline = {
        "baseline_schema_version": 1,
        "workload_artifact_schema_version": 1,
        "workload_version": artifact["workload_version"],
        "target": artifact["target"],
        "measurement_schema": measurement,
        "record": {"source_artifact": source_path, "source_artifact_sha256": source_sha256, "reason": reason, "recorded_at": datetime.datetime.now(datetime.UTC).date().isoformat()},
        "tolerances": tolerances,
        "workloads": artifact["workloads"],
    }
    baseline_path.parent.mkdir(parents=True, exist_ok=True)
    baseline_path.write_text(json.dumps(baseline, indent=2) + "\n", encoding="utf-8")
    print(f"recorded workload baseline: artifact={recorded_path} baseline={baseline_path}")


if __name__ == "__main__":
    main()
