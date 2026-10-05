#!/usr/bin/env python3
"""Exercise the local Peas browser rebuild/server workflow without a browser."""

from __future__ import annotations

import http.client
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parent.parent
SERVER = REPOSITORY / "src/browser/dev_server.py"


def fail(message: str) -> None:
    raise AssertionError(message)


def wait_for(predicate, description: str, timeout: float = 8.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.03)
    fail(f"timed out waiting for {description}")


def read_build_count(path: Path) -> int:
    try:
        return len(path.read_text().splitlines())
    except FileNotFoundError:
        return 0


def fetch(port: int, path: str) -> tuple[int, bytes, dict[str, str]]:
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}")
    try:
        with urllib.request.urlopen(request, timeout=3) as response:
            return response.status, response.read(), dict(response.headers.items())
    except urllib.error.HTTPError as error:
        return error.code, error.read(), dict(error.headers.items())


def read_until(response: http.client.HTTPResponse, expected: bytes) -> None:
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        line = response.readline()
        if expected in line:
            return
    fail(f"timed out waiting for SSE {expected!r}")


def main() -> int:
    temporary = Path(tempfile.mkdtemp(prefix="peas-browser-dev-"))
    process: subprocess.Popen[str] | None = None
    try:
        project = temporary / "project"
        source = project / "src" / "game.zig"
        build_log = project / "build.log"
        pid_file = project / "child.pid"
        source.parent.mkdir(parents=True)
        (project / "build.zig").write_text("// fake browser project\n")
        source.write_text("BROKEN\n")
        static = temporary / "static"
        static.mkdir()
        (static / "index.html").write_text("static\n")
        fake_zig = temporary / "fake-zig.py"
        fake_zig.write_text(
            "#!/usr/bin/env python3\n"
            "import os, pathlib, sys, time\n"
            "root = pathlib.Path.cwd()\n"
            "source = (root / 'src/game.zig').read_text()\n"
            "with (root / 'build.log').open('a') as log: log.write('build\\n')\n"
            "if 'SLOW' in source:\n"
            "    (root / 'child.pid').write_text(str(os.getpid()))\n"
            "    time.sleep(30)\n"
            "if 'BROKEN' in source:\n"
            "    print('synthetic browser build error', file=sys.stderr)\n"
            "    raise SystemExit(1)\n"
            "out = root / 'zig-out/web'\n"
            "out.mkdir(parents=True, exist_ok=True)\n"
            "out.joinpath('index.html').write_text('<!doctype html><body>game-' + source.strip() + '</body>')\n"
            "out.joinpath('game.wasm').write_bytes(b'\\0asm')\n"
        )
        fake_zig.chmod(0o755)
        occupied = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        occupied.bind(("127.0.0.1", 0))
        occupied.listen()
        occupied_port = occupied.getsockname()[1]
        collision = subprocess.run(
            [sys.executable, str(SERVER), "serve", "--web-dir", str(static), "--port", str(occupied_port)],
            capture_output=True,
            text=True,
            timeout=5,
        )
        occupied.close()
        assert collision.returncode == 1
        assert "could not bind browser server" in collision.stderr
        process = subprocess.Popen(
            [
                sys.executable,
                str(SERVER),
                "dev",
                "--project-root",
                str(project),
                "--web-dir",
                "zig-out/web",
                "--port",
                "0",
                "--poll-ms",
                "25",
                "--debounce-ms",
                "25",
                "--zig",
                str(fake_zig),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert process.stdout is not None
        port = None
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            line = process.stdout.readline()
            match = re.search(r"http://127\.0\.0\.1:(\d+)/", line)
            if match:
                port = int(match.group(1))
                break
        if port is None:
            stderr = process.stderr.read() if process.stderr is not None else ""
            fail(f"development server did not start: {stderr}")

        assert fetch(port, "/")[0] == 503
        source.write_text("const version = 1;\n")
        wait_for(lambda: read_build_count(build_log) == 2, "initial failed-build recovery")
        wait_for(lambda: b"game-const version = 1;" in fetch(port, "/")[1], "first successful build")

        status, body, headers = fetch(port, "/")
        assert status == 200 and b"game-const version = 1;" in body
        assert b"/_peas/reload" in body
        assert headers.get("Cache-Control") == "no-store"
        status, _, wasm_headers = fetch(port, "/game.wasm")
        assert status == 200 and wasm_headers.get("Content-Type") == "application/wasm"
        assert fetch(port, "/missing")[0] == 404
        assert fetch(port, "/%2e%2e/%2e%2e/etc/passwd")[0] == 404
        assert b"/_peas/reload" not in (project / "zig-out/web/index.html").read_bytes()

        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=8)
        connection.request("GET", "/_peas/reload")
        events = connection.getresponse()
        assert events.status == 200
        read_until(events, b": connected")
        builds_before_v2 = read_build_count(build_log)
        source.write_text("const version = 2;\n")
        wait_for(lambda: read_build_count(build_log) == builds_before_v2 + 1, "successful rebuild process")
        wait_for(lambda: b"game-const version = 2;" in fetch(port, "/")[1], "successful rebuild")
        read_until(events, b"event: reload")
        builds_after_success = read_build_count(build_log)

        (project / "zig-out/web/generated.txt").write_text("ignore generated output\n")
        time.sleep(0.25)
        assert read_build_count(build_log) == builds_after_success

        source.write_text("BROKEN\n")
        wait_for(lambda: read_build_count(build_log) == builds_after_success + 1, "failed rebuild")
        time.sleep(0.1)
        assert process.poll() is None
        assert b"game-const version = 2;" in fetch(port, "/")[1]

        source.write_text("const version = 3;\n")
        read_until(events, b"event: reload")
        wait_for(lambda: b"game-const version = 3;" in fetch(port, "/")[1], "recovery rebuild")

        source.write_text("SLOW\n")
        wait_for(pid_file.exists, "active child build")
        process.send_signal(signal.SIGINT)
        process.wait(timeout=5)
        child_pid = int(pid_file.read_text())
        try:
            os.kill(child_pid, 0)
        except ProcessLookupError:
            pass
        else:
            fail("development server left a browser build child running")
        process = None
        connection.close()
        print("browser development workflow tests passed")
        return 0
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        shutil.rmtree(temporary, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
