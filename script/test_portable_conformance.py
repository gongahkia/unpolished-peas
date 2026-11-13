#!/usr/bin/env python3
"""Exercise a downstream game against a verified archive, with isolated saves."""
import argparse
import functools
import hashlib
import http.server
import json
import os
import platform
import re
import shutil
import subprocess
import tempfile
import threading
import uuid
from pathlib import Path

from test_starter_generation import REPO, QuietHandler, prepared_manifest, run, sources


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser-workflows", action="store_true")
    parser.add_argument("--browsers")
    parser.add_argument("--font-bundle", type=Path, default=REPO / "zig-out/font-layout")
    parser.add_argument("--audio-bundle", type=Path, default=REPO / "zig-out/audio-lifetime")
    parser.add_argument("--references", type=Path, default=REPO / "zig-out/browser-authoring-reference")
    parser.add_argument("--diagnostics", type=Path)
    parser.add_argument("--logging", action="store_true")
    args = parser.parse_args()
    browsers = args.browsers or os.environ.get("PEAS_AUTHORING_BROWSERS", "chromium,firefox,safari" if args.browser_workflows else "chromium")
    diagnostics = args.diagnostics or REPO / ("zig-out/diagnostics/browser-authoring/consumer" if args.browser_workflows else "zig-out/diagnostics/portable-conformance")
    diagnostics.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "browser_workflows": args.browser_workflows, "requested_browsers": browsers.split(","), "platform": platform.platform(), "zig": subprocess.check_output(["zig", "version"], text=True).strip(), "commands": []}
    native_directory = None
    namespace = "peas-conformance-" + uuid.uuid4().hex
    report["native_namespace"] = namespace
    try:
        with tempfile.TemporaryDirectory(prefix="peas-portable-consumer-") as directory:
            scratch = Path(directory)
            tree = run([REPO / "script/worktree_treeish.sh"], REPO, scratch / "archive-cache").strip()
            version = re.search(r'\.version = "([^"]+)"', (REPO / "build.zig.zon").read_text()).group(1)
            archive = Path(run([REPO / "script/create_source_archive.sh", f"v{version}", scratch / "archive", tree], REPO, scratch / "archive-cache").strip())
            package_hash = run(["zig", "fetch", archive], scratch, scratch / "verification-cache").strip()
            report.update(tree=tree, archive=archive.name, package_hash=package_hash)
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(archive.parent)))
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            try:
                project = scratch / "portable game"
                shutil.copytree(REPO / "fixtures/portable-conformance", project, ignore=shutil.ignore_patterns(".zig-cache", "zig-out"))
                manifest = project / "build.zig.zon"
                url = f"http://127.0.0.1:{server.server_port}/{archive.name}"
                manifest.write_text(prepared_manifest(manifest.read_text(), url, package_hash))
                before = sources(project)
                cache = scratch / "consumer-cache"
                commands = (["web"], ["test-replay-wasm"]) if args.browser_workflows else ([], ["test"], ["web"], ["package"], ["test-replay-wasm"])
                for suffix in commands:
                    command = ["zig", "build", *suffix, "--summary", "all"]
                    output = run(command, project, cache)
                    (diagnostics / ("build-" + (suffix[0] if suffix else "native") + ".log")).write_text(output)
                    report["commands"].append({"command": command, "passed": True})
                    print("portable archive consumer passed: " + " ".join(command), flush=True)
                for phase in (() if args.browser_workflows else ("write", "read")):
                    command = ["zig", "build", "run", f"-Dtest-organization={namespace}", f"-Dnative-phase={phase}", "--", "--frames", "3"]
                    if platform.system() == "Linux": command.insert(0, str(REPO / "script/run_linux_software_gl.sh"))
                    try:
                        output = run(command, project, cache)
                    except RuntimeError as error:
                        output = str(error)
                        (diagnostics / f"native-{phase}.log").write_text(output)
                        failed_path = re.search(r"^portable native store: (.+)$", output, re.M)
                        if failed_path:
                            actual = Path(failed_path.group(1)).resolve()
                            assert actual.name == namespace
                            native_directory = actual
                        raise
                    (diagnostics / f"native-{phase}.log").write_text(output)
                    path = re.search(r"^portable native store: (.+)$", output, re.M)
                    assert path, "native host must report its actual isolated store"
                    actual = Path(path.group(1)).resolve()
                    assert actual.name == namespace, f"native test storage was not isolated: {actual}"
                    if native_directory is not None: assert actual == native_directory
                    native_directory = actual
                    expected = "write" if phase == "write" else "restart"
                    assert f"portable native {expected} passed: score=4 name=Zoë你好 rebound=R" in output
                    assert "portable native cleanup passed: exactly once" in output
                    assert "game allocation leak" not in output
                    report["commands"].append({"command": command, "passed": True})
                    print(f"portable native {phase} and cleanup passed", flush=True)
                bundle = project / "zig-out/web"
                bundle_hashes = {str(path.relative_to(bundle)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(bundle.rglob("*")) if path.is_file()}
                report["bundle_sha256"] = bundle_hashes
                browser_directory = diagnostics / "browser"
                command = [REPO / "script/browser-authoring/run.sh", "--consumer", bundle, "--browsers", browsers, "--diagnostics", browser_directory]
                if args.logging:
                    command += ["--logging"]
                if args.browser_workflows:
                    command += ["--font", args.font_bundle, "--audio", args.audio_bundle, "--references", args.references]
                browser = subprocess.run(command, cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=600)
                (diagnostics / "browser.log").write_text(browser.stdout)
                if (browser_directory / "result.json").exists():
                    report["browsers"] = json.loads((browser_directory / "result.json").read_text())
                if browser.returncode != 0:
                    shutil.copytree(bundle, diagnostics / "failed-external-web", dirs_exist_ok=True)
                assert browser.returncode == 0, browser.stdout
                report["commands"].append({"command": ["script/browser-authoring/run.sh", "--consumer", "<external-project>/zig-out/web", "--browsers", browsers], "passed": True})
                assert sources(project) == before, "consumer commands changed authored files"
                assert bundle_hashes == {str(path.relative_to(bundle)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(bundle.rglob("*")) if path.is_file()}, "browser harness changed built consumer files"
                assert (project / "zig-out/web/assets/OFL.txt").is_file()
                report["passed"] = True
                print("portable archive consumer passed: " + ("authoring browser matrix " + browsers if args.browser_workflows else "native restart, browser interactions/reload, UPR5 replay, lifecycle and failure recovery"), flush=True)
            finally:
                server.shutdown(); server.server_close(); thread.join()
    finally:
        if native_directory is not None:
            # Delete only this run's UUID namespace, never another game's data.
            assert native_directory.name == namespace
            shutil.rmtree(native_directory)
            if native_directory.parent.name == namespace: native_directory.parent.rmdir()
        (diagnostics / "result.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__": main()
