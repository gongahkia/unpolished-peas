#!/usr/bin/env python3
"""Observe actual RPG callbacks and short SDL segments; no timing budgets."""
import argparse
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'dogfood/ashen-causeway'


def command(args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def distribution(values):
    values = sorted(values)
    assert values and all(math.isfinite(x) and x >= 0 for x in values)
    return {'count': len(values), 'median_ms': values[math.ceil(len(values) * .5) - 1] / 1e6,
            'p95_ms': values[math.ceil(len(values) * .95) - 1] / 1e6,
            'p99_ms': values[math.ceil(len(values) * .99) - 1] / 1e6,
            'max_ms': values[-1] / 1e6}


def correlate(host, observation):
    """Host update_calls partitions the replay ticks, including zero/catch-up frames.

    Clock origins need not match: containment uses the collector clock and the
    host association uses exact ordinal calls, never a guessed 1:1 frame mapping.
    """
    assert observation['dropped_updates'] == observation['dropped_operations'] == 0
    updates = observation['updates']
    enabled = observation['instrumented']
    start, end = observation['start_tick'], observation['end_tick']
    assert sum(frame['update_calls'] for frame in host['frames']) == end - start
    if enabled:
        assert [u['tick'] for u in updates] == list(range(start, end))
        assert all(u['end_ns'] >= u['start_ns'] for u in updates)
    else:
        assert not updates and not observation['operations']
    by_tick = {}
    for operation in observation['operations']:
        tick = operation['tick']
        assert tick is not None and start <= tick < end
        update = updates[tick - start]
        assert update['start_ns'] <= operation['start_ns'] <= operation['end_ns'] <= update['end_ns']
        assert operation['failure'] is None, 'storage failure in measured workload'
        by_tick.setdefault(tick, []).append(operation)
    result, tick = [], start
    for index, frame in enumerate(host['frames']):
        next_tick = tick + frame['update_calls']
        operations = [op for t in range(tick, next_tick) for op in by_tick.get(t, [])]
        save_ns = sum(op['end_ns'] - op['start_ns'] for op in operations)
        assert save_ns <= frame['update_ns']
        result.append(dict(frame, frame=index, tick_start=tick, tick_end=next_tick,
                           operations=operations, save_ns=save_ns,
                           residual_update_ns=frame['update_ns'] - save_ns))
        tick = next_tick
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT / 'zig-out/diagnostics/ashen-profile')
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--identity', required=True, help='profile-UUID used by build-profiling -Dverification-id')
    parser.add_argument('--compare-saves', action='store_true', help='paired baseline/instrumented native windows and controlled observer cost')
    args = parser.parse_args()
    assert 1 <= args.rounds <= 10
    assert args.identity == "profile-" + str(uuid.UUID(args.identity.removeprefix("profile-")))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    assert not (output / 'result.json').exists(), 'use a fresh output directory; preserve previous evidence'
    replay = GAME / 'zig-out/evidence/routes/keyboard_mouse.upr'
    assert replay.is_file(), 'generate ASHEN_ROUTE_EVIDENCE before profiling'
    tools = GAME / 'zig-out/verification'
    report = {'status': 'running', 'head': command(['git', 'rev-parse', 'HEAD']),
              'source_tree': command([ROOT / 'script/worktree_treeish.sh']), 'command': sys.argv,
              'status_before': command(['git', 'status', '--short']), 'rounds': args.rounds, 'compare_saves': args.compare_saves,
              'method': 'serial native CPU full-route runs, then real SDL segments; 120 warmup + 240 retained SDL frames',
              'quantiles': 'nearest rank', 'machine': {'platform': platform.platform(), 'zig': command(['zig', 'version'])},
              'replay_sha256': hashlib.sha256(replay.read_bytes()).hexdigest(),
              'sources_sha256': {}, 'binaries_sha256': {}, 'cpu': [], 'native': [],
              'limits': ['CPU observations only; no GPU completion or display scanout',
                         'Headless allocator includes game resources, logical audio and in-memory saves; no SDL/driver/JS allocations',
                         'CPU samples detach structural Canvas tracing; fixed input and audio mixing at 48000 Hz, 800 stereo frames/tick',
                         'Native scene preparation replays earlier inputs before timed loop; excludes loading and menu startup']}
    for name in ['build.zig', 'src/game.zig', 'src/world.zig', 'src/profile_route.zig', 'src/profile_allocator.zig', 'src/verify_native.zig', 'src/profile_saves.zig', 'src/profile_state.zig', 'src/profile_observer_bench.zig']:
        report['sources_sha256'][name] = hashlib.sha256((GAME / name).read_bytes()).hexdigest()
    for name in ['ashen-profile-route', 'ashen-native-verification', 'ashen-profile-observer']:
        report['binaries_sha256'][name] = hashlib.sha256((tools / name).read_bytes()).hexdigest()
    report['engine_and_runner_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in
        [ROOT / 'src/save_data.zig', ROOT / 'src/native_save_data.zig', ROOT / 'src/backend/sdl_gpu.zig', Path(__file__)]}
    historical = ROOT / 'zig-out/diagnostics/ashen-profile-polish'
    report['historical_evidence_sha256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in historical.iterdir() if p.is_file()} if historical.exists() else {}
    if platform.system() == 'Darwin':
        report['machine'].update(cpu=command(['sysctl', '-n', 'machdep.cpu.brand_string']),
                                 graphics=command(['system_profiler', 'SPDisplaysDataType']),
                                 power=command(['pmset', '-g', 'batt']))
    def persist():
        (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    persist()
    try:
        oracle = None
        for round_id in range(args.rounds):
            raw = output / f'cpu-{round_id}.json'
            subprocess.run([tools / 'ashen-profile-route', replay, raw], check=True, timeout=120)
            data = json.loads(raw.read_text())
            samples = data.pop('samples')
            if oracle is None: oracle = samples
            else:
                assert [(s['state_hash'], s['save_bytes']) for s in samples] == [(s['state_hash'], s['save_bytes']) for s in oracle]
            assert data['optimize'] == 'ReleaseFast'
            groups = {'ordinary': [s for s in samples[120:] if s['room'] < 2],
                      'crown': [s for s in samples[120:] if s['room'] == 2],
                      'shock': [s for s in samples[120:] if s['rings'] > 0]}
            result = {'round': round_id, 'configuration': data, 'groups': {},
                      'all_update_allocation_events': sum(s['update_allocations'] for s in samples),
                      'all_draw_allocation_events': sum(s['draw_allocations'] for s in samples),
                      'all_audio_allocation_events': sum(s['audio_allocations'] for s in samples),
                      'allocation_ticks': [s['tick'] for s in samples if s['allocated_bytes']],
                      'allocated_bytes_after_init': sum(s['allocated_bytes'] for s in samples)}
            for name, group in groups.items():
                result['groups'][name] = {key: distribution([s[key] for s in group]) for key in ['update_ns', 'draw_ns', 'audio_ns']}
                result['groups'][name]['max_workload'] = {key: max(s[key] for s in group) for key in ['enemies', 'shots', 'rings']}
            assert result['all_draw_allocation_events'] == 0
            report['cpu'].append(result)
            with gzip.open(str(raw) + '.gz', 'wb') as compressed:
                compressed.write(raw.read_bytes())
            raw.unlink()
            persist()
            print(f'CPU route round {round_id + 1} passed', flush=True)
        if args.compare_saves:
            overhead = output / 'observer-overhead.json'
            subprocess.run([tools / 'ashen-profile-observer', overhead], check=True, timeout=30)
            samples = json.loads(overhead.read_text())
            report['observer_overhead'] = {mode: distribution([s['elapsed_ns'] / s['calls'] for s in samples[4:] if s['instrumented'] == enabled])
                for mode, enabled in [('baseline', False), ('instrumented', True)]}
            report['observer_overhead']['method'] = '36 retained batches of 200 no-op writes; first four batches warmup; includes update/save clocks, wrapper and bounded recording; not a disk measurement'
            persist()
        # Builds are already complete; all CPU/native cases run serially.
        for round_id in range(args.rounds):
            cases = [('ordinary', 300), ('boss-shock', 5950)]
            modes = ['baseline', 'instrumented'] if args.compare_saves else ['baseline']
            if round_id % 2: cases.reverse(); modes.reverse()
            for name, skip in cases:
                for mode in modes:
                    label = f'native-{name}-{round_id}-{mode}'
                    log_path = output / (label + '.log')
                    case_output = output / label
                    case_output.mkdir()
                    env = dict(os.environ, ASHEN_VERIFY_MODE='profile', ASHEN_PROFILE_SKIP=str(skip),
                               ASHEN_VERIFY_REPLAY=str(replay), ASHEN_VERIFY_OUTPUT=str(case_output),
                               UP_NATIVE_TIMING_SAMPLES='1', UP_DEVELOPER_TOOLS='1',
                               UP_DEVELOPER_OVERLAY='0', UP_LOG_LEVEL='warn')
                    env.pop('ASHEN_PROFILE_SAVES', None)
                    if mode == 'instrumented': env['ASHEN_PROFILE_SAVES'] = '1'
                    try:
                        with log_path.open('w') as log:
                            subprocess.run([tools / 'ashen-native-verification', '--frames', '360'], env=env,
                                           cwd=GAME, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
                        text = log_path.read_text()
                        reported_path = Path(next(line.split(': ', 1)[1] for line in text.splitlines() if line.startswith('unpolished-peas app data: '))).resolve()
                        assert reported_path.name == args.identity and reported_path.parent.name == 'peas-ashen-verification'
                        host = json.loads(next(line[len('peas-host-samples '):] for line in text.splitlines() if line.startswith('peas-host-samples ')))
                        assert len(host['frames']) == 360 and host['dropped'] == 0
                        assert all(f['pass_count'] == 2 for f in host['frames'][120:]), 'unpresented SDL frame'
                        assert 'ashen native cleanup verified' in text
                        assert 'ashen native progress:' not in text, 'observer progress I/O inside profile window'
                        observation = json.loads((case_output / 'profile-observations.json').read_text())
                        assert observation['optimize'] == 'ReleaseFast'
                        assert observation['instrumented'] == (mode == 'instrumented')
                        assert observation['start_tick'] == skip
                        expected = oracle[observation['end_tick'] - 1]
                        assert observation['state_hash'] == expected['state_hash'], 'native gameplay differs from CPU oracle'
                        assert observation['save_hex'] == bytes(expected['save_bytes']).hex(), 'saved bytes differ from CPU oracle'
                        joined = correlate(host, observation)
                        (case_output / 'correlated-frames.json').write_text(json.dumps(joined, indent=2) + '\n')
                        retained = joined[120:]
                        operations = [op for f in retained for op in f['operations']]
                        writes = [op for op in operations if op['kind'] == 'write']
                        entry = {'round': round_id, 'case': name, 'mode': mode, 'replay_start_tick': skip,
                            'end_tick': observation['end_tick'], 'framebuffer': host['framebuffer'], 'presented_frames_verified': True,
                            'state_and_saved_bytes_match_cpu': True, 'log': log_path.name,
                            'observations': label + '/profile-observations.json', 'correlated_frames': label + '/correlated-frames.json',
                            'stages': {key: distribution([f[key] for f in retained]) for key in ['update_ns', 'draw_ns', 'present_ns', 'frame_ns', 'interval_ns', 'residual_update_ns']},
                            'multi_update_frames': sum(f['update_calls'] > 1 for f in retained),
                            'frame_outlier_counts': {str(ms): sum(f['frame_ns'] > ms * 1e6 for f in retained) for ms in [20, 33.333333, 41.210248]},
                            'update_over_5ms': sum(f['update_ns'] > 5e6 for f in retained),
                            'outliers': [f for f in retained if f['frame_ns'] > 20e6 or f['update_ns'] > 5e6],
                            'save_calls': len(writes), 'save_durations': distribution([op['end_ns'] - op['start_ns'] for op in writes]) if writes else None,
                            'save_frames': sum(bool(f['operations']) for f in retained)}
                        report['native'].append(entry)
                        persist()
                        print(f'SDL {name} {mode} round {round_id + 1} passed', flush=True)
                    finally:
                        # Cleanup only after successful empty-namespace preparation,
                        # and only the exact UUID path reported by this owned process.
                        if log_path.exists() and 'ashen profile start:' in log_path.read_text():
                            for line in log_path.read_text().splitlines():
                                if line.startswith('unpolished-peas app data: '):
                                    app_path = Path(line.split(': ', 1)[1]).resolve()
                                    if app_path.name == args.identity and app_path.parent.name == 'peas-ashen-verification':
                                        shutil.rmtree(app_path, ignore_errors=True)
                                        assert not app_path.exists(), 'test namespace cleanup failed'
        if args.compare_saves:
            report['paired_update_median_difference_ms'] = []
            for round_id in range(args.rounds):
                for case in ['ordinary', 'boss-shock']:
                    pair = {entry['mode']: entry for entry in report['native'] if entry['round'] == round_id and entry['case'] == case}
                    report['paired_update_median_difference_ms'].append({'round': round_id, 'case': case,
                        'instrumented_minus_baseline': pair['instrumented']['stages']['update_ns']['median_ms'] - pair['baseline']['stages']['update_ns']['median_ms']})
        report['status'] = 'passed'
        persist()
    except Exception as error:
        report['status'] = 'failed'
        report['error'] = str(error)
        persist()
        raise


if __name__ == '__main__':
    main()
