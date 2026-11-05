#!/usr/bin/env python3
"""Exercise a downstream game against a verified archive, with isolated saves."""
import functools
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
    diagnostics = REPO / "zig-out/diagnostics/portable-conformance"
    diagnostics.mkdir(parents=True, exist_ok=True)
    report = {"platform": platform.platform(), "zig": subprocess.check_output(["zig", "version"], text=True).strip(), "commands": []}
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
                for suffix in ([], ["test"], ["web"], ["package"], ["test-replay-wasm"]):
                    command = ["zig", "build", *suffix, "--summary", "all"]
                    output = run(command, project, cache)
                    (diagnostics / ("build-" + (suffix[0] if suffix else "native") + ".log")).write_text(output)
                    report["commands"].append({"command": command, "passed": True})
                    print("portable archive consumer passed: " + " ".join(command), flush=True)
                for phase in ("write", "read"):
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
                environment = dict(os.environ, PEAS_CONFORMANCE_DIAGNOSTICS=str(diagnostics / "browser"))
                browser = subprocess.run([REPO / "script/test_portable_browser.sh", project / "zig-out/web"], cwd=REPO, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                (diagnostics / "browser.log").write_text(browser.stdout)
                assert browser.returncode == 0, browser.stdout
                report["commands"].append({"command": ["script/test_portable_browser.sh", "<external-project>/zig-out/web"], "passed": True})
                assert sources(project) == before, "consumer commands changed authored files"
                assert (project / "zig-out/web/assets/OFL.txt").is_file()
                report["passed"] = True
                print("portable archive consumer passed: native restart, browser interactions/reload, UPR5 replay, lifecycle and failure recovery", flush=True)
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
