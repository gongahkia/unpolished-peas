#!/usr/bin/env python3
"""Exercise native failure evidence through the existing portable consumer."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid


REPO = Path(__file__).resolve().parent.parent
FIXTURE = REPO / "fixtures/portable-conformance"


def run(command, cwd, env=None):
    result = subprocess.run(list(map(str, command)), cwd=cwd, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, timeout=240)
    return result


def no_core_dump():
    import resource
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=REPO / "zig-out/diagnostics/local-logging/native")
    args = parser.parse_args()
    output = args.output.resolve() / ("run-" + uuid.uuid4().hex)
    output.mkdir(parents=True, exist_ok=True)
    print("Native logging run: " + str(output), flush=True)
    report = {"version": 1, "platform": sys.platform, "cases": [], "source_sha256": {}}
    for relative in ("src/runtime_log.zig", "src/diagnostics.zig", "src/backend/sdl_gpu.zig", "fixtures/portable-conformance/src/main.zig"):
        report["source_sha256"][relative] = hashlib.sha256((REPO / relative).read_bytes()).hexdigest()
    roots = set()
    try:
        for phase, expected, failure_phase in (
            ("read", "NativeProgressMismatch", "init"),
            ("fail-update", "ConformanceUpdateRejected", "update"),
            ("fail-draw", "ConformanceDrawRejected", "draw"),
            ("fail-deinit", "ConformanceDeinitRejected", "deinit"),
        ):
            namespace = "peaslogging" + uuid.uuid4().hex
            build = output / phase / "build"
            command = ["zig", "build", "-Doptimize=Debug", "-j1", "--prefix", build,
                       "-Dnative-phase=" + phase, "-Dtest-organization=" + namespace]
            compiled = run(command, FIXTURE)
            (output / phase).mkdir(parents=True, exist_ok=True)
            (output / phase / "build.log").write_text(compiled.stdout + compiled.stderr)
            assert compiled.returncode == 0, compiled.stderr
            executable = build / "bin" / ("portable-conformance.exe" if os.name == "nt" else "portable-conformance")
            variants = ["failure"]
            if phase == "read":
                variants += ["repeat", "blocked-output", "disabled", "video-startup"]
            if phase == "fail-draw":
                variants += ["filtered"]
            for variant in variants:
                directory = output / phase / variant
                directory.mkdir(parents=True, exist_ok=True)
                diagnostics = directory / "incidents"
                env = dict(os.environ, UP_DEVELOPER_TOOLS="1", UP_DEVELOPER_OVERLAY="0",
                           UP_DEVELOPER_DIAGNOSTICS_DUMP="1", SDL_AUDIODRIVER="dummy",
                           UP_DIAGNOSTICS_ROOT=str(diagnostics))
                env.pop("UP_LOG_LEVEL", None)
                env.pop("UP_LOG_CATEGORIES", None)
                if variant == "blocked-output":
                    diagnostics.write_text("caller-owned blocker")
                if variant == "disabled":
                    env["UP_DEVELOPER_TOOLS"] = "0"
                if variant == "filtered":
                    env.update(UP_LOG_LEVEL="err", UP_LOG_CATEGORIES="render")
                if variant == "video-startup":
                    env["SDL_VIDEODRIVER"] = "peas-intentionally-unavailable"
                result = subprocess.run([str(executable), "--frames", "20"], cwd=FIXTURE, env=env,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                        timeout=30, preexec_fn=no_core_dump if os.name == "posix" else None)
                (directory / "stdout.log").write_text(result.stdout)
                (directory / "stderr.log").write_text(result.stderr)
                found = re.search(r"^portable native store: (.+)$", result.stderr, re.M)
                assert found, result.stderr
                data = Path(found.group(1)).resolve()
                assert namespace in data.parts, "refuse cleanup outside the fixture's unique namespace"
                roots.add(data)
                original = "SdlError" if variant == "video-startup" else expected
                assert original in result.stderr, result.stderr
                record = {"phase": phase, "variant": variant, "returncode": result.returncode, "expected_error": original}
                if variant in ("blocked-output", "disabled"):
                    assert not diagnostics.is_dir()
                    if variant == "blocked-output":
                        assert diagnostics.read_text() == "caller-owned blocker"
                        assert "original error=" + original in result.stderr
                    else:
                        # Prior runs use the same compiled namespace; only check
                        # that this disabled run emitted no new session records.
                        assert "unpolished-peas events:" not in result.stderr
                        assert "unpolished-peas incident:" not in result.stderr
                else:
                    incidents = list(diagnostics.glob("session-*-failure-*"))
                    assert len(incidents) == 1, result.stderr
                    incident = incidents[0]
                    failure = (incident / "failure.log").read_text()
                    assert "error=" + original in failure
                    assert "phase=" + ("init" if variant == "video-startup" else failure_phase) in failure
                    operation = "SDL_Init" if variant == "video-startup" else "game." + failure_phase
                    assert "operation=" + operation in failure
                    records = [json.loads(line) for line in (incident / "events.jsonl").read_text().splitlines()]
                    assert records and any(item["fields"].get("error") == original for item in records)
                    assert any(item["fields"].get("error") == original and item["fields"].get("operation") == operation for item in records)
                    session = records[-1]["session_id"]
                    assert all(item["version"] == 1 and item["session_id"] == session for item in records)
                    assert all(isinstance(item["timestamp_ns"], int) and 0 <= item["timestamp_ns"] <= 2**53 - 1 for item in records)
                    if variant == "filtered":
                        assert all(item["level"] in ("err", "fatal") and item["category"] == "render" for item in records)
                    for name in ("metadata.json", "environment.json", "logging.json"):
                        json.loads((incident / name).read_text())
                    if variant != "video-startup":
                        assert (incident / "screenshot.png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
                    else:
                        assert not (incident / "screenshot.png").exists()
                    bundle = directory / "support"
                    exported = run(["zig", "build", "peas", "--", "--json", "--non-interactive", "support-bundle", incident, bundle], REPO)
                    assert exported.returncode == 0, exported.stderr
                    assert json.loads(exported.stdout)["status"] == "ok"
                    manifest = json.loads((bundle / "support-bundle.json").read_text())
                    assert "events.jsonl" in manifest["artifacts"] and "logging.json" in manifest["artifacts"]
                    record.update(session_id=session, incident=str(incident), support_bundle=str(bundle))
                for name in ("unpolished-peas.log", "unpolished-peas.jsonl", "developer-diagnostics.json"):
                    if (data / name).is_file():
                        shutil.copyfile(data / name, directory / name)
                if phase == "fail-deinit":
                    assert result.returncode != 0, "existing native cleanup panic policy must remain visible"
                print("native logging passed: " + phase + "/" + variant, flush=True)
                report["cases"].append(record)
                (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        sessions = [item["session_id"] for item in report["cases"] if "session_id" in item]
        assert len(sessions) == len(set(sessions)), "separate native launches need distinct session IDs"
    finally:
        for root in roots:
            shutil.rmtree(root, ignore_errors=True)
            if re.fullmatch(r"peaslogging[0-9a-f]{32}", root.parent.name):
                try:
                    root.parent.rmdir()
                except OSError:
                    pass
    print("Native logging evidence: " + str(output / "result.json"), flush=True)


if __name__ == "__main__":
    main()
