#!/usr/bin/env python3
"""Clock-independent association checks; no machine-specific timing gates."""
import copy
import sys
import unittest
sys.dont_write_bytecode = True
from profile_ashen_causeway import correlate


class Association(unittest.TestCase):
    def setUp(self):
        self.host = {'frames': [{'update_calls': n, 'update_ns': ns} for n, ns in [(0, 0), (2, 100), (1, 30)]]}
        self.observation = {'instrumented': True, 'start_tick': 555, 'end_tick': 558,
            'dropped_updates': 0, 'dropped_operations': 0,
            'updates': [{'tick': tick, 'start_ns': t, 'end_ns': t + 30} for tick, t in [(555, 10), (556, 50), (557, 90)]],
            'operations': [{'tick': tick, 'kind': 'write', 'start_ns': t, 'end_ns': t + 10, 'failure': None}
                           for tick, t in [(555, 15), (556, 55)]]}

    def test_catch_up_and_zero_updates(self):
        joined = correlate(self.host, self.observation)
        self.assertEqual([(f['tick_start'], f['tick_end']) for f in joined], [(555, 555), (555, 557), (557, 558)])
        self.assertEqual([f['save_ns'] for f in joined], [0, 20, 0])
        self.assertEqual(joined[1]['residual_update_ns'], 80)
        self.assertEqual([op['tick'] for op in joined[1]['operations']], [555, 556])

    def test_disabled_uses_host_counts_without_fabricating_save_time(self):
        self.observation.update(instrumented=False, updates=[], operations=[])
        self.assertEqual(correlate(self.host, self.observation)[1]['save_ns'], 0)

    def test_rejects_incomplete_or_misattributed_observations(self):
        mutations = [lambda x: x.update(dropped_operations=1), lambda x: x.update(end_tick=559),
            lambda x: x['operations'][0].update(tick=None), lambda x: x['operations'][0].update(end_ns=100),
            lambda x: x['operations'][0].update(failure='Io'), lambda x: x['updates'].pop()]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                value = copy.deepcopy(self.observation); mutate(value)
                with self.assertRaises(AssertionError): correlate(self.host, value)


if __name__ == '__main__':
    unittest.main()
