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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT / 'zig-out/diagnostics/ashen-profile')
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--identity', required=True, help='profile-UUID used by build-profiling -Dverification-id')
    args = parser.parse_args()
    assert 1 <= args.rounds <= 10
    assert args.identity == "profile-" + str(uuid.UUID(args.identity.removeprefix("profile-")))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    replay = GAME / 'zig-out/evidence/routes/keyboard_mouse.upr'
    assert replay.is_file(), 'generate ASHEN_ROUTE_EVIDENCE before profiling'
    tools = GAME / 'zig-out/verification'
    report = {'status': 'running', 'head': command(['git', 'rev-parse', 'HEAD']),
              'status_before': command(['git', 'status', '--short']), 'rounds': args.rounds,
              'method': 'serial native CPU full-route runs, then real SDL segments; 120 warmup + 240 retained SDL frames',
              'quantiles': 'nearest rank', 'machine': {'platform': platform.platform(), 'zig': command(['zig', 'version'])},
              'replay_sha256': hashlib.sha256(replay.read_bytes()).hexdigest(),
              'sources_sha256': {}, 'binaries_sha256': {}, 'cpu': [], 'native': [],
              'limits': ['CPU observations only; no GPU completion or display scanout',
                         'Headless allocator includes game resources, logical audio and in-memory saves; no SDL/driver/JS allocations',
                         'CPU samples detach structural Canvas tracing; fixed input and audio mixing at 48000 Hz, 800 stereo frames/tick',
                         'Native scene preparation replays earlier inputs before timed loop; excludes loading and menu startup']}
    for name in ['src/game.zig', 'src/world.zig', 'src/profile_route.zig', 'src/profile_allocator.zig', 'src/verify_native.zig']:
        report['sources_sha256'][name] = hashlib.sha256((GAME / name).read_bytes()).hexdigest()
    for name in ['ashen-profile-route', 'ashen-native-verification']:
        report['binaries_sha256'][name] = hashlib.sha256((tools / name).read_bytes()).hexdigest()
    if platform.system() == 'Darwin':
        report['machine'].update(cpu=command(['sysctl', '-n', 'machdep.cpu.brand_string']),
                                 graphics=command(['system_profiler', 'SPDisplaysDataType']),
                                 power=command(['pmset', '-g', 'batt']))
    def persist():
        (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    persist()
    try:
        for round_id in range(args.rounds):
            raw = output / f'cpu-{round_id}.json'
            subprocess.run([tools / 'ashen-profile-route', replay, raw], check=True, timeout=120)
            data = json.loads(raw.read_text())
            samples = data.pop('samples')
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
        # Existing host reporter serializes only after the timed loop. No captures,
        # readbacks or file writes are introduced into measured SDL frames.
        for round_id in range(args.rounds):
            for name, skip in ([('ordinary', 300), ('boss-shock', 5950)] if round_id % 2 == 0 else [('boss-shock', 5950), ('ordinary', 300)]):
                log_path = output / f'native-{name}-{round_id}.log'
                env = dict(os.environ, ASHEN_VERIFY_MODE='profile', ASHEN_PROFILE_SKIP=str(skip),
                           ASHEN_VERIFY_REPLAY=str(replay), ASHEN_VERIFY_OUTPUT=str(output),
                           UP_NATIVE_TIMING_SAMPLES='1', UP_DEVELOPER_TOOLS='0', UP_LOG_LEVEL='off')
                # Init refuses a non-empty namespace; cleanup is allowed only
                # after that guard and successful profile preparation are logged.
                env.update(UP_DEVELOPER_TOOLS='1', UP_DEVELOPER_OVERLAY='0', UP_LOG_LEVEL='warn')
                try:
                    with log_path.open('w') as log:
                        subprocess.run([tools / 'ashen-native-verification', '--frames', '360'], env=env,
                                       cwd=GAME, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
                    text = log_path.read_text()
                    reported_path = Path(next(line.split(': ', 1)[1] for line in text.splitlines() if line.startswith('unpolished-peas app data: '))).resolve()
                    assert reported_path.name == args.identity and reported_path.parent.name == 'peas-ashen-verification'
                    host = json.loads(next(line[len('peas-host-samples '):] for line in text.splitlines() if line.startswith('peas-host-samples ')))
                    assert len(host['frames']) == 360 and host['dropped'] == 0
                    retained = host['frames'][120:]
                    assert all(f['pass_count'] == 2 for f in retained), 'unpresented SDL frame'
                    assert 'ashen native cleanup verified' in text
                    report['native'].append({'round': round_id, 'case': name, 'replay_start_tick': skip,
                        'framebuffer': host['framebuffer'], 'presented_frames_verified': True,
                        'stages': {key: distribution([s[key] for s in retained]) for key in ['update_ns', 'draw_ns', 'present_ns', 'frame_ns', 'interval_ns']}})
                    persist()
                    print(f'SDL {name} round {round_id + 1} passed', flush=True)
                finally:
                    if log_path.exists() and 'ashen profile start:' in log_path.read_text():
                        for line in log_path.read_text().splitlines():
                            if line.startswith('unpolished-peas app data: '):
                                path = Path(line.split(': ', 1)[1]).resolve()
                                if path.name == args.identity and path.parent.name == 'peas-ashen-verification':
                                    shutil.rmtree(path, ignore_errors=True)
        report['status'] = 'passed'
        persist()
    except Exception as error:
        report['status'] = 'failed'
        report['error'] = str(error)
        persist()
        raise


if __name__ == '__main__':
    main()
