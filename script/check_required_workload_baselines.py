#!/usr/bin/env python3
import json
import sys
from pathlib import Path

import check_workload_baseline as baseline


ROOT = Path(__file__).resolve().parents[1]


def fail(message: str) -> None:
    print(f"required workload baseline failure: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    arguments = sys.argv[1:]
    if len(arguments) == 0:
        requirements_path = ROOT / "benchmarks/workload-baselines/required-targets-v1.json"
        baselines_path = ROOT / "benchmarks/workload-baselines/v1"
    elif len(arguments) == 2:
        requirements_path, baselines_path = map(Path, arguments)
    else:
        fail("usage: check_required_workload_baselines.py [REQUIREMENTS BASELINE_DIRECTORY]")
    try:
        requirements = baseline.load(requirements_path)
        if requirements.get("schema_version") != 1 or requirements.get("workload_version") != "v1" or not isinstance(requirements.get("measurement_schema"), dict) or not isinstance(requirements.get("required_targets"), list):
            raise ValueError("invalid required workload baseline registry")
        targets = requirements["required_targets"]
        if not targets or not all(isinstance(target, dict) for target in targets):
            raise ValueError("required workload baseline registry needs target objects")
        candidates = [(path, baseline.load(path)) for path in sorted(baselines_path.glob("*.json"))]
        failures: list[str] = []
        for target in targets:
            matches = [item for item in candidates if item[1].get("baseline_schema_version") == 1 and baseline.identity(item[1].get("target")) == baseline.identity(target) and item[1].get("workload_version") == requirements["workload_version"] and baseline.identity(item[1].get("measurement_schema")) == baseline.identity(requirements["measurement_schema"])]
            if len(matches) != 1:
                failures.append(f"target={baseline.identity(target)} release_eligible=false")
                continue
            baseline.validate(matches[0][1], baseline.source_artifact(matches[0][0], matches[0][1]))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        fail(str(error))
    if failures:
        fail("missing baseline: " + "; ".join(failures))
    print("required workload baselines pass")


if __name__ == "__main__":
    main()
