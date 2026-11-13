#!/usr/bin/env python3
import hashlib
import json
import math
import sys
from pathlib import Path


def load(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected object")
    return value


def identity(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def fail(message: str) -> None:
    print(f"workload baseline failure: {message}", file=sys.stderr)
    raise SystemExit(1)


def measurement_schema(artifact: dict) -> dict:
    timer = artifact.get("timer")
    if not isinstance(timer, dict):
        raise ValueError("workload artifact requires a timer measurement schema")
    clock = timer.get("clock")
    unit = timer.get("unit")
    measurement = timer.get("measurement")
    if not all(isinstance(value, str) and value for value in (clock, unit, measurement)):
        raise ValueError("workload artifact timer requires clock, unit, and measurement")
    return {"artifact_schema_version": artifact.get("schema_version"), "timer": timer}


def source_artifact(baseline_path: Path, baseline: dict) -> dict:
    record = baseline.get("record")
    if not isinstance(record, dict):
        raise ValueError("baseline record requires source_artifact, source_artifact_sha256, and reason")
    relative_path = record.get("source_artifact")
    checksum = record.get("source_artifact_sha256")
    reason = record.get("reason")
    if not isinstance(relative_path, str) or not relative_path or Path(relative_path).is_absolute():
        raise ValueError("baseline source_artifact must be a non-absolute path relative to the baseline")
    if not isinstance(checksum, str) or len(checksum) != 64 or any(value not in "0123456789abcdef" for value in checksum):
        raise ValueError("baseline record requires a lowercase SHA-256 source_artifact_sha256")
    if not isinstance(reason, str) or not reason.strip():
        raise ValueError("baseline record requires a non-empty reason")
    path = baseline_path.parent / relative_path
    try:
        content = path.read_bytes()
    except OSError as error:
        raise ValueError(f"recorded source artifact unavailable: {path}: {error}") from error
    canonical_content = content.replace(b"\r\n", b"\n")
    if hashlib.sha256(canonical_content).hexdigest() != checksum:
        raise ValueError(f"recorded source artifact checksum differs: {path}")
    value = json.loads(canonical_content)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected object")
    return value


def validate(baseline: dict, observed: dict) -> list[str]:
    if baseline.get("baseline_schema_version") != 1:
        raise ValueError("unsupported baseline schema")
    if baseline.get("workload_artifact_schema_version") != 1 or observed.get("schema_version") != 1:
        raise ValueError("unsupported workload artifact schema")
    if observed.get("status") != "ok":
        raise ValueError(f"observed artifact is not usable: status={observed.get('status')}")
    if baseline.get("workload_version") != observed.get("workload_version"):
        raise ValueError(f"workload version mismatch: baseline={baseline.get('workload_version')} observed={observed.get('workload_version')}")
    if identity(baseline.get("target")) != identity(observed.get("target")):
        raise ValueError(f"target mismatch: baseline={identity(baseline.get('target'))} observed={identity(observed.get('target'))}")
    if identity(baseline.get("measurement_schema")) != identity(measurement_schema(observed)):
        raise ValueError("measurement schema differs from baseline")
    tolerances = baseline.get("tolerances")
    expected_workloads = baseline.get("workloads")
    actual_workloads = observed.get("workloads")
    if not isinstance(tolerances, dict) or not isinstance(expected_workloads, list) or not isinstance(actual_workloads, list):
        raise ValueError("baseline requires tolerances and workloads")
    expected = {entry.get("id"): entry for entry in expected_workloads if isinstance(entry, dict) and isinstance(entry.get("id"), str)}
    actual = {entry.get("id"): entry for entry in actual_workloads if isinstance(entry, dict) and isinstance(entry.get("id"), str)}
    if set(expected) != set(actual) or len(expected) != len(expected_workloads) or len(actual) != len(actual_workloads):
        raise ValueError("workload IDs differ between baseline and observation")
    report: list[str] = []
    for workload_id, baseline_workload in expected.items():
        observed_workload = actual[workload_id]
        for field in ("resolution", "warmup_frames", "sample_count", "metric_availability"):
            if field in baseline_workload and baseline_workload.get(field) != observed_workload.get(field):
                raise ValueError(f"{workload_id}: {field} differs from baseline")
        baseline_metrics = baseline_workload.get("metrics")
        observed_metrics = observed_workload.get("metrics")
        if not isinstance(baseline_metrics, dict) or not isinstance(observed_metrics, dict) or set(baseline_metrics) != set(observed_metrics):
            raise ValueError(f"{workload_id}: metrics differ from baseline")
        for metric, baseline_value in baseline_metrics.items():
            observed_value = observed_metrics[metric]
            if baseline_value is None:
                if observed_value is not None:
                    raise ValueError(f"{workload_id}: {metric} availability changed")
                continue
            if not isinstance(baseline_value, int) or baseline_value < 0 or not isinstance(observed_value, int) or observed_value < 0:
                raise ValueError(f"{workload_id}: invalid {metric} value")
            tolerance = tolerances.get(metric)
            if not isinstance(tolerance, dict):
                raise ValueError(f"missing tolerance for {metric}")
            relative = tolerance.get("relative")
            absolute = tolerance.get("absolute")
            if not isinstance(relative, (int, float)) or relative < 0 or not isinstance(absolute, int) or absolute < 0:
                raise ValueError(f"invalid tolerance for {metric}")
            allowance = math.ceil(baseline_value * relative) + absolute
            maximum = baseline_value + allowance
            if observed_value > maximum:
                raise ValueError(f"target={identity(observed['target'])} workload={workload_id} metric={metric} baseline={baseline_value} observed={observed_value} tolerance=+{allowance} max={maximum}")
            report.append(f"target={identity(observed['target'])} workload={workload_id} metric={metric} baseline={baseline_value} observed={observed_value} tolerance=+{allowance} max={maximum}")
    return report


def select_baseline(directory: Path, observed: dict) -> Path:
    observed_target = identity(observed.get("target"))
    observed_version = observed.get("workload_version")
    observed_measurement = identity(measurement_schema(observed))
    matches: list[Path] = []
    for path in sorted(directory.glob("*.json")):
        try:
            baseline = load(path)
        except (OSError, ValueError, json.JSONDecodeError) as error:
            raise ValueError(f"invalid baseline candidate {path}: {error}") from error
        if baseline.get("baseline_schema_version") == 1 and identity(baseline.get("target")) == observed_target and baseline.get("workload_version") == observed_version and identity(baseline.get("measurement_schema")) == observed_measurement:
            matches.append(path)
    if not matches:
        raise ValueError(f"missing baseline: target={observed_target} workload_version={observed_version} measurement_schema={observed_measurement} release_eligible=false")
    if len(matches) != 1:
        raise ValueError(f"ambiguous baselines for target={observed_target}: {', '.join(str(path) for path in matches)}")
    return matches[0]


def main() -> None:
    args = sys.argv[1:]
    try:
        if len(args) == 2:
            baseline_path = Path(args[0])
            observed = load(Path(args[1]))
        elif len(args) == 3 and args[0] == "--directory":
            observed = load(Path(args[2]))
            baseline_path = select_baseline(Path(args[1]), observed)
        else:
            fail("usage: check_workload_baseline.py BASELINE ARTIFACT | --directory BASELINE_DIRECTORY ARTIFACT")
        baseline = load(baseline_path)
        validate(baseline, source_artifact(baseline_path, baseline))
        report = validate(baseline, observed)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        fail(str(error))
    print("workload baseline pass")
    print("\n".join(report))


if __name__ == "__main__":
    main()
