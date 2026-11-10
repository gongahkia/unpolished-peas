#!/usr/bin/env python3
"""Exercise Ashen Causeway outside the checkout with a hashed source archive."""
import argparse
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import threading
import sys
sys.dont_write_bytecode = True

from test_starter_generation import REPO, QuietHandler, prepared_manifest, run, sources


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=REPO / 'zig-out/diagnostics/ashen-external')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {'status': 'running', 'commands': [], 'archive_requests': [],
              'zig': run(['zig', 'version'], REPO, output / 'version-cache').strip(),
              'platform': os.uname().sysname + ' ' + os.uname().machine}
    def persist():
        (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    persist()
    with tempfile.TemporaryDirectory(prefix='peas-ashen-consumer-') as directory:
        scratch = Path(directory)
        tree = run([REPO / 'script/worktree_treeish.sh'], REPO, scratch / 'seed-cache').strip()
        report['source_tree'] = tree
        report['commit'] = run(['git', 'rev-parse', 'HEAD'], REPO, scratch / 'seed-cache').strip()
        version = re.search(r'\.version = "([^"]+)"', (REPO / 'build.zig.zon').read_text()).group(1)
        archive = Path(run([REPO / 'script/create_source_archive.sh', f'v{version}', scratch / 'archive', tree], REPO, scratch / 'seed-cache').strip())
        report['archive_sha256'] = hashlib.sha256(archive.read_bytes()).hexdigest()
        package_hash = run(['zig', 'fetch', archive], scratch, scratch / 'seed-cache').strip()
        report['package_hash'] = package_hash
        class Handler(QuietHandler):
            def do_GET(self):
                report['archive_requests'].append(self.path)
                super().do_GET()
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(archive.parent)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            project = scratch / 'ashen game with spaces'
            shutil.copytree(REPO / 'dogfood/ashen-causeway', project,
                            ignore=shutil.ignore_patterns('.zig-cache', 'zig-out', '__pycache__'))
            manifest = project / 'build.zig.zon'
            url = f'http://127.0.0.1:{server.server_port}/{archive.name}'
            manifest.write_text(prepared_manifest(manifest.read_text(), url, package_hash))
            before = sources(project)
            report['authored_sources_sha256'] = before
            persist()
            commands = [
                ['zig', 'build', 'test', '-j2', '--summary', 'all'],
                ['zig', 'build', 'package', '-j2', '--summary', 'all'],
                ['zig', 'build', 'web', '-j2', '--summary', 'all'],
                ['zig', 'build', 'run', '-j2', '--', '--frames', '120'],
            ]
            for index, command in enumerate(commands):
                print('external Ashen Causeway: running ' + ' '.join(command), flush=True)
                log = run(command, project, scratch / 'consumer-cache')
                (output / f'command-{index}.log').write_text(log)
                report['commands'].append({'command': command, 'status': 'passed', 'log': f'command-{index}.log'})
                persist()
                print('external Ashen Causeway: passed ' + ' '.join(command), flush=True)
            assert sources(project) == before, 'consumer builds changed authored source'
            assert report['archive_requests'], 'consumer did not fetch the archive over loopback'
            required = ['bin/ashen-causeway', 'assets/SourceSansOFL.txt', 'web/index.html',
                        'web/unpolished-peas.wasm', 'web/host.mjs', 'web/bootstrap.mjs',
                        'web/assets/SourceSansOFL.txt']
            report['built_sha256'] = {}
            for name in required:
                path = project / 'zig-out' / name
                assert path.is_file(), name
                report['built_sha256'][name] = hashlib.sha256(path.read_bytes()).hexdigest()
            assert '.path =' not in manifest.read_text()
            # Copy the served browser artifact for later real-host checks without
            # changing its content or bringing the engine checkout into the bundle.
            shutil.copytree(project / 'zig-out/web', output / 'web', dirs_exist_ok=True)
            report['source_unchanged'] = True
            report['status'] = 'passed'
            persist()
            print('external Ashen Causeway passed: archive fetch, tests, native package/run, browser, source unchanged', flush=True)
        except Exception as error:
            report['status'] = 'failed'
            report['error'] = str(error)
            persist()
            raise
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == '__main__':
    main()
