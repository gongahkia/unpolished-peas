#!/usr/bin/env python3
import copy
import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "script/check_workload_baseline.py"
RECORD = ROOT / "script/record_workload_baseline.py"


def write(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def invoke(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run((sys.executable, *arguments), text=True, capture_output=True, check=False)


def require(result: subprocess.CompletedProcess[str], text: str) -> None:
    if result.returncode != 0 or text not in result.stdout + result.stderr:
        raise AssertionError(f"expected {text!r}: status={result.returncode} output={result.stdout}{result.stderr}")


def artifact() -> dict:
    return {
        "schema_version": 1,
        "status": "ok",
        "target": {"os": "linux", "architecture": "x86_64", "renderer": "headless"},
        "workload_version": "v1",
        "workloads": [{"id": "primitive_fill", "resolution": {"width": 160, "height": 90}, "warmup_frames": 4, "sample_count": 16, "metrics": {"frame_time_ns": 100, "command_count": 7, "frame_allocation_events": 0, "frame_allocated_bytes": 0}}],
        "timer": {"clock": "std.time.Timer", "unit": "nanoseconds", "measurement": "headless_cpu_render"},
        "diagnostics": {"combined_canvas_hash": "fixture"},
    }


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        observed_path = root / "observed.json"
        recorded_path = root / "artifacts/v1/linux.json"
        baseline_path = root / "baselines/v1/linux.json"
        observed = artifact()
        write(observed_path, observed)
        result = invoke(str(RECORD), str(observed_path), str(recorded_path), str(baseline_path), "fixture baseline records a measured artifact")
        require(result, "recorded workload baseline")
        result = invoke(str(CHECK), "--directory", str(baseline_path.parent), str(observed_path))
        require(result, "workload baseline pass")
        require(result, "workload=primitive_fill metric=frame_time_ns")

        slower = copy.deepcopy(observed)
        slower["workloads"][0]["metrics"]["frame_time_ns"] = 1_000_000
        slower_path = root / "slower.json"
        write(slower_path, slower)
        result = invoke(str(CHECK), str(baseline_path), str(slower_path))
        if result.returncode == 0 or "workload=primitive_fill metric=frame_time_ns" not in result.stderr:
            raise AssertionError(f"expected metric failure: {result.stdout}{result.stderr}")

        missing = copy.deepcopy(observed)
        missing["target"]["renderer"] = "other"
        missing_path = root / "missing.json"
        write(missing_path, missing)
        result = invoke(str(CHECK), "--directory", str(baseline_path.parent), str(missing_path))
        if result.returncode == 0 or "release_eligible=false" not in result.stderr:
            raise AssertionError(f"expected explicit missing baseline failure: {result.stdout}{result.stderr}")

        requirements = {"schema_version": 1, "workload_version": "v1", "measurement_schema": {"artifact_schema_version": 1, "timer": observed["timer"]}, "required_targets": [observed["target"]]}
        requirements_path = root / "requirements.json"
        write(requirements_path, requirements)
        required_check = ROOT / "script/check_required_workload_baselines.py"
        result = invoke(str(required_check), str(requirements_path), str(baseline_path.parent))
        require(result, "required workload baselines pass")
        requirements["required_targets"].append(missing["target"])
        write(requirements_path, requirements)
        result = invoke(str(required_check), str(requirements_path), str(baseline_path.parent))
        if result.returncode == 0 or "release_eligible=false" not in result.stderr:
            raise AssertionError(f"expected required target failure: {result.stdout}{result.stderr}")

        recorded_path.write_text("{}\n", encoding="utf-8")
        result = invoke(str(CHECK), str(baseline_path), str(observed_path))
        if result.returncode == 0 or "checksum differs" not in result.stderr:
            raise AssertionError(f"expected recorded artifact checksum failure: {result.stdout}{result.stderr}")
    print("workload baseline tests passed")


if __name__ == "__main__":
    main()
