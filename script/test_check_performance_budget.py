#!/usr/bin/env python3
import copy
import unittest

from check_performance_budget import validate


class PerformanceBudgetTest(unittest.TestCase):
    def test_proof_games_require_all_metrics_within_limits(self) -> None:
        metrics = {
            "startup_ns": 1,
            "startup_allocation_events": 2,
            "startup_allocated_bytes": 3,
            "frame_ns": 4,
            "frame_allocation_events": 5,
            "frame_allocated_bytes": 6,
        }
        baseline = {
            "version": 1,
            "target": "test",
            "game_limits": {game: dict(metrics) for game in ("bounce",)},
        }
        observed = {
            "version": 1,
            "target": "test",
            "game_metrics": {game: dict(metrics) for game in ("bounce",)},
        }
        self.assertEqual("proof games", validate(baseline, observed))

        regressed = copy.deepcopy(observed)
        regressed["game_metrics"]["bounce"]["frame_ns"] = 7
        with self.assertRaisesRegex(ValueError, "bounce: frame_ns=7 exceeds 4"):
            validate(baseline, regressed)


if __name__ == "__main__":
    unittest.main()
