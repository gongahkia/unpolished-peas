#!/usr/bin/env python3
"""Replay a complete journey through SDL, then reload it in a second process."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid

REPO = Path(__file__).resolve().parent.parent
GAME = REPO / 'dogfood/ashen-causeway'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=REPO / 'zig-out/diagnostics/ashen-native')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    identity = 'route-' + str(uuid.uuid4())
    report = {'status': 'running', 'application': identity, 'commands': [],
              'input_kind': 'recorded normalized keyboard/mouse, one frame per fixed update',
              'captures': 'CPU Canvas from real SDL callbacks, not GPU readback'}
    def persist():
        (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    persist()
    try:
        env = dict(os.environ, ASHEN_ROUTE_EVIDENCE=str(output / 'replays'))
        command = ['zig', 'build', 'test', '-j2', '--summary', 'all']
        subprocess.run(command, cwd=GAME, env=env, check=True, timeout=180)
        replay = output / 'replays/keyboard_mouse.upr'
        report['replay_sha256'] = hashlib.sha256(replay.read_bytes()).hexdigest()
        env.update(ASHEN_VERIFY_REPLAY=str(replay), UP_DEVELOPER_OVERLAY='0', UP_LOG_LEVEL='warn', UP_DEVELOPER_TOOLS='1')
        for mode, frames in [('route', '7200'), ('continue', '60')]:
            mode_dir = output / mode
            mode_dir.mkdir(exist_ok=True)
            env.update(ASHEN_VERIFY_MODE=mode, ASHEN_VERIFY_OUTPUT=str(mode_dir))
            command = ['zig', 'build', 'verify-native', '-Doptimize=ReleaseFast', '-j2',
                       '-Dverification-id=' + identity, '--', '--frames', frames]
            print('native Ashen Causeway: running ' + mode, flush=True)
            with (output / (mode + '.log')).open('w') as log:
                subprocess.run(command, cwd=GAME, env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=240)
            text = (output / (mode + '.log')).read_text()
            assert f'ashen native passed: mode={mode}' in text
            assert 'ashen native cleanup verified' in text
            for image in (['cloister', 'warden-windup', 'warden-transition', 'warden-shock', 'victory'] if mode == 'route' else ['continued']):
                assert (mode_dir / (image + '.png')).is_file(), image
            report['commands'].append({'command': command, 'status': 'passed', 'log': mode + '.log'})
            persist()
            print('native Ashen Causeway: passed ' + mode, flush=True)
        report['status'] = 'passed'
        persist()
    except Exception as error:
        report['status'] = 'failed'
        report['error'] = str(error)
        persist()
        raise
    finally:
        # Remove only the UUID namespace created by this test, using the path
        # actually reported by SDL. Never derive/delete the production save path.
        for mode in ('route', 'continue'):
            log_path = output / (mode + '.log')
            if not log_path.exists():
                continue
            for line in log_path.read_text().splitlines():
                if line.startswith('unpolished-peas app data: '):
                    path = Path(line.split(': ', 1)[1]).resolve()
                    if path.name == identity and path.parent.name == 'peas-ashen-verification':
                        shutil.rmtree(path, ignore_errors=True)
        print('native evidence retained at ' + str(output), flush=True)


if __name__ == '__main__':
    main()
