#!/usr/bin/env python3
import json
import sys
from pathlib import Path

METRICS = (
    "startup_ns",
    "frame_ns",
    "frame_allocation_events",
    "frame_allocated_bytes",
    "profiler_frame_ns",
    "profiler_frame_allocation_events",
    "profiler_frame_allocated_bytes",
    "runtime_metrics_frame_ns",
    "runtime_metrics_frame_allocation_events",
    "runtime_metrics_frame_allocated_bytes",
    "renderer_ns",
    "renderer_allocation_events",
    "renderer_allocated_bytes",
)
GAME_NAMES = ("bounce", "topdown", "platformer")
GAME_METRICS = (
    "startup_ns",
    "startup_allocation_events",
    "startup_allocated_bytes",
    "frame_ns",
    "frame_allocation_events",
    "frame_allocated_bytes",
)


def load(path: str) -> dict:
    with Path(path).open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected object")
    return value


def fail(message: str) -> None:
    print(f"performance budget failure: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate_metrics(limits: object, metrics: object, names: tuple[str, ...], scope: str) -> None:
    if not isinstance(limits, dict) or not isinstance(metrics, dict):
        raise ValueError(f"{scope}: missing limits or metrics object")
    for name in names:
        limit = limits.get(name)
        actual = metrics.get(name)
        if not isinstance(limit, int) or limit < 0:
            raise ValueError(f"{scope}: invalid limit for {name}")
        if not isinstance(actual, int) or actual < 0:
            raise ValueError(f"{scope}: invalid metric for {name}")
        if actual > limit:
            raise ValueError(f"{scope}: {name}={actual} exceeds {limit}")


def validate(baseline: dict, observed: dict) -> str:
    if baseline.get("version") != 1 or observed.get("version") != 1:
        raise ValueError("unsupported baseline or metrics version")
    if baseline.get("target") != observed.get("target"):
        raise ValueError(f"target mismatch: baseline={baseline.get('target')} observed={observed.get('target')}")
    if "limits" in baseline or "metrics" in observed:
        validate_metrics(baseline.get("limits"), observed.get("metrics"), METRICS, "engine")
        return "engine"
    game_limits = baseline.get("game_limits")
    game_metrics = observed.get("game_metrics")
    if not isinstance(game_limits, dict) or not isinstance(game_metrics, dict):
        raise ValueError("missing proof-game limits or metrics object")
    if set(game_limits) != set(GAME_NAMES) or set(game_metrics) != set(GAME_NAMES):
        raise ValueError("proof-game metrics must include bounce, topdown, and platformer")
    for game in GAME_NAMES:
        validate_metrics(game_limits[game], game_metrics[game], GAME_METRICS, game)
    return "proof games"


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: check_performance_budget.py BASELINE METRICS")
    try:
        baseline = load(sys.argv[1])
        observed = load(sys.argv[2])
        scope = validate(baseline, observed)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        fail(str(error))
    print(f"performance budgets pass for {scope} on {observed['target']}")


if __name__ == "__main__":
    main()
