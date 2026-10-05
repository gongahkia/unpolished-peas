#!/usr/bin/env python3
"""Small local server and rebuild loop for Peas browser development.

This is deliberately build tooling, not browser-runtime code.  Production
``zig build web`` output stays a normal static directory; ``dev`` publishes a
private snapshot only after a successful build and injects a tiny SSE reload
client while serving that snapshot.
"""

from __future__ import annotations

import argparse
import http.server
import mimetypes
import os
import signal
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
from pathlib import Path, PurePosixPath
from typing import Dict, Iterable, Optional, Tuple


WATCHED_SUFFIXES = {
    ".zig",
    ".zon",
    ".png",
    ".jpg",
    ".jpeg",
    ".tga",
    ".ttf",
    ".otf",
    ".wav",
    ".ogg",
    ".glsl",
    ".vert",
    ".frag",
    ".wgsl",
    ".json",
}
IGNORED_DIRECTORIES = {".git", ".zig-cache", "zig-cache", "zig-out", "node_modules"}
DEV_CLIENT = b"""<script>(function(){
const reload = new EventSource('/_peas/reload');
reload.addEventListener('reload', function(){ location.reload(); });
})();</script>"""


def relative_to(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


class ServerState:
    def __init__(self, development: bool) -> None:
        self.development = development
        self.root: Optional[Path] = None
        self.generation = 0
        self.condition = threading.Condition()

    def publish(self, root: Path) -> None:
        with self.condition:
            self.root = root
            self.generation += 1
            self.condition.notify_all()


class LocalHTTPServer(http.server.ThreadingHTTPServer):
    # A long-lived SSE request is intentionally independent of the server's
    # accept loop.  Ctrl-C must not wait for a browser tab to close before the
    # development process can terminate its active Zig child.
    daemon_threads = True
    block_on_close = False


def content_type(path: Path) -> str:
    if path.suffix == ".wasm":
        return "application/wasm"
    if path.suffix == ".mjs":
        return "text/javascript; charset=utf-8"
    return mimetypes.guess_type(str(path))[0] or "application/octet-stream"


def safe_file(root: Path, request_path: str) -> Optional[Path]:
    decoded = urllib.parse.unquote(urllib.parse.urlsplit(request_path).path)
    if decoded in ("", "/"):
        decoded = "/index.html"
    parts = PurePosixPath(decoded.lstrip("/")).parts
    if not parts or any(part in ("", ".", "..") for part in parts):
        return None
    candidate = (root.joinpath(*parts)).resolve()
    if not relative_to(candidate, root.resolve()) or not candidate.is_file():
        return None
    return candidate


def make_handler(state: ServerState):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format: str, *args: object) -> None:
            # Keep the useful build/reload status readable.  HTTP request logs
            # are available through a normal browser inspector when needed.
            return

        def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
            if state.development and urllib.parse.urlsplit(self.path).path == "/_peas/reload":
                self.serve_reload_events()
                return
            with state.condition:
                root = state.root
            if root is None:
                self.send_error(503, "Peas is waiting for a successful browser build")
                return
            path = safe_file(root, self.path)
            if path is None:
                self.send_error(404, "Not found")
                return
            try:
                body = path.read_bytes()
            except OSError:
                self.send_error(404, "Not found")
                return
            if state.development and path.name == "index.html":
                body = inject_dev_client(body)
            self.send_response(200)
            self.send_header("Content-Type", content_type(path))
            self.send_header("Content-Length", str(len(body)))
            if state.development:
                self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(body)
            except BrokenPipeError:
                pass

        def serve_reload_events(self) -> None:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            with state.condition:
                generation = state.generation
            try:
                # This confirms the subscription is active before a client
                # edits a file; otherwise a very fast rebuild could happen
                # between the HTTP response headers and the initial snapshot.
                self.wfile.write(b": connected\n\n")
                self.wfile.flush()
                while True:
                    with state.condition:
                        current = state.generation
                    if current != generation:
                        generation = current
                        self.wfile.write(f"event: reload\ndata: {generation}\n\n".encode())
                    else:
                        self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    # SSE browsers reconnect automatically. Polling the small
                    # in-memory generation here avoids tying a long-lived
                    # socket to the watcher thread or a condition wakeup.
                    time.sleep(1.0)
            except (BrokenPipeError, ConnectionResetError):
                return

    return Handler


def inject_dev_client(body: bytes) -> bytes:
    if b"/_peas/reload" in body:
        return body
    marker = b"</body>"
    if marker in body:
        return body.replace(marker, DEV_CLIENT + marker, 1)
    return body + DEV_CLIENT


class ProjectWatcher:
    def __init__(self, project_root: Path) -> None:
        self.project_root = project_root.resolve()
        self.signature = self.scan()

    def scan(self) -> Dict[str, Tuple[int, int]]:
        result: Dict[str, Tuple[int, int]] = {}
        for directory, children, files in os.walk(self.project_root):
            children[:] = [child for child in children if child not in IGNORED_DIRECTORIES]
            for filename in files:
                path = Path(directory, filename)
                if path.suffix.lower() not in WATCHED_SUFFIXES:
                    continue
                try:
                    stat = path.stat()
                except OSError:
                    continue
                result[str(path.relative_to(self.project_root))] = (stat.st_mtime_ns, stat.st_size)
        return result

    def poll(self) -> bool:
        current = self.scan()
        if current == self.signature:
            return False
        self.signature = current
        return True


class BuildRunner:
    def __init__(self, project_root: Path, zig: str) -> None:
        self.project_root = project_root
        self.zig = zig
        self.child: Optional[subprocess.Popen[bytes]] = None
        self.count = 0
        self.successes = 0
        self.failures = 0

    def build(self) -> bool:
        self.count += 1
        started = time.monotonic()
        try:
            self.child = subprocess.Popen(
                [self.zig, "build", "web"],
                cwd=self.project_root,
                # Let shutdown terminate Zig and any compiler descendants as
                # one unit. Windows falls back to the normal child handle.
                start_new_session=os.name == "posix",
            )
            result = self.child.wait()
        except OSError as error:
            elapsed_ms = round((time.monotonic() - started) * 1000)
            self.failures += 1
            print(f"[peas] browser build {self.count} could not start in {elapsed_ms} ms: {error}", file=sys.stderr, flush=True)
            return False
        finally:
            # A Ctrl-C can interrupt wait() while the compiler still exists.
            # Preserve that handle for run_dev's shutdown path instead of
            # orphaning the child process.
            if self.child is not None and self.child.poll() is not None:
                self.child = None
        elapsed_ms = round((time.monotonic() - started) * 1000)
        if result == 0:
            self.successes += 1
            print(f"[peas] browser build {self.count} succeeded in {elapsed_ms} ms", flush=True)
            return True
        self.failures += 1
        print(f"[peas] browser build {self.count} failed in {elapsed_ms} ms; serving the last successful build", file=sys.stderr, flush=True)
        return False

    def stop(self) -> None:
        if self.child is not None and self.child.poll() is None:
            if os.name == "posix":
                os.killpg(self.child.pid, signal.SIGTERM)
            else:
                self.child.terminate()
            try:
                self.child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                if os.name == "posix":
                    os.killpg(self.child.pid, signal.SIGKILL)
                else:
                    self.child.kill()
                self.child.wait()


class SnapshotPublisher:
    def __init__(self, web_directory: Path, state: ServerState) -> None:
        self.web_directory = web_directory
        self.state = state
        self.snapshots = web_directory.parent / ".peas-dev-web"
        self.published: list[Path] = []

    def publish(self, sequence: int) -> bool:
        index = self.web_directory / "index.html"
        if not index.is_file():
            print(f"[peas] browser build succeeded but did not produce {index}", file=sys.stderr, flush=True)
            return False
        self.snapshots.mkdir(parents=True, exist_ok=True)
        target = self.snapshots / f"snapshot-{sequence}"
        shutil.rmtree(target, ignore_errors=True)
        try:
            shutil.copytree(self.web_directory, target)
        except OSError as error:
            print(f"[peas] could not publish browser development output: {error}", file=sys.stderr, flush=True)
            return False
        self.published.append(target)
        self.state.publish(target)
        # The active root remains stable for in-flight requests while a newer
        # snapshot is copied. Keep a tiny tail for those requests, without
        # letting a long development session accumulate every old web build.
        while len(self.published) > 3:
            shutil.rmtree(self.published.pop(0), ignore_errors=True)
        print("[peas] browser refreshed", flush=True)
        return True

    def cleanup(self) -> None:
        for snapshot in self.published:
            shutil.rmtree(snapshot, ignore_errors=True)


def run_static_server(web_directory: Path, host: str, port: int) -> int:
    state = ServerState(False)
    root = web_directory.resolve()
    if not (root / "index.html").is_file():
        print(f"peas serve: browser bundle is missing {root / 'index.html'}", file=sys.stderr)
        return 1
    state.root = root
    return serve(state, host, port)


def serve(state: ServerState, host: str, port: int) -> int:
    try:
        server = LocalHTTPServer((host, port), make_handler(state))
    except OSError as error:
        print(f"[peas] could not bind browser server at {host}:{port}: {error}", file=sys.stderr, flush=True)
        return 1
    with server:
        actual_host, actual_port = server.server_address[:2]
        print(f"[peas] browser server: http://{actual_host}:{actual_port}/", flush=True)
        try:
            server.serve_forever(poll_interval=0.2)
        except KeyboardInterrupt:
            return 0
    return 0


def run_dev(arguments: argparse.Namespace) -> int:
    project_root = Path(arguments.project_root).resolve()
    web_directory = Path(arguments.web_dir)
    if not web_directory.is_absolute():
        web_directory = project_root / web_directory
    web_directory = web_directory.resolve()
    state = ServerState(True)
    watcher = ProjectWatcher(project_root)
    runner = BuildRunner(project_root, arguments.zig)
    publisher = SnapshotPublisher(web_directory, state)

    def rebuild() -> bool:
        before = watcher.scan()
        success = runner.build()
        after = watcher.scan()
        watcher.signature = after
        changed_during_build[0] = after != before
        if success:
            return publisher.publish(runner.count)
        return False

    changed_during_build = [False]
    if rebuild() and arguments.once:
        publisher.cleanup()
        return 0
    if arguments.once:
        return 1

    try:
        server = LocalHTTPServer((arguments.host, arguments.port), make_handler(state))
    except OSError as error:
        runner.stop()
        publisher.cleanup()
        print(f"[peas] could not bind browser development server at {arguments.host}:{arguments.port}: {error}", file=sys.stderr, flush=True)
        return 1
    with server:
        actual_host, actual_port = server.server_address[:2]
        print(f"[peas] browser development server: http://{actual_host}:{actual_port}/", flush=True)
        print(f"[peas] watching {project_root} every {arguments.poll_ms} ms", flush=True)
        server_thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.2}, daemon=True)
        server_thread.start()
        dirty = changed_during_build[0]
        changed_at = time.monotonic() if dirty else 0.0
        try:
            while True:
                time.sleep(arguments.poll_ms / 1000.0)
                if watcher.poll():
                    dirty = True
                    changed_at = time.monotonic()
                if dirty and time.monotonic() - changed_at >= arguments.debounce_ms / 1000.0:
                    dirty = False
                    rebuild()
                    if changed_during_build[0]:
                        dirty = True
                        changed_at = time.monotonic()
        except KeyboardInterrupt:
            return 0
        finally:
            runner.stop()
            server.shutdown()
            server_thread.join(timeout=2)
            publisher.cleanup()


def parse_arguments(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Peas local browser server and development rebuild loop")
    modes = parser.add_subparsers(dest="mode", required=True)
    serve_parser = modes.add_parser("serve", help="serve an existing static browser directory")
    serve_parser.add_argument("--web-dir", required=True)
    serve_parser.add_argument("--host", default="127.0.0.1")
    serve_parser.add_argument("--port", type=int, default=8000)
    dev = modes.add_parser("dev", help="watch, rebuild, serve, and refresh a browser project")
    dev.add_argument("--project-root", required=True)
    dev.add_argument("--web-dir", default="zig-out/web")
    dev.add_argument("--host", default="127.0.0.1")
    dev.add_argument("--port", type=int, default=8000)
    dev.add_argument("--poll-ms", type=int, default=200)
    dev.add_argument("--debounce-ms", type=int, default=150)
    dev.add_argument("--zig", default="zig", help=argparse.SUPPRESS)
    dev.add_argument("--once", action="store_true", help=argparse.SUPPRESS)
    arguments = parser.parse_args(list(argv))
    if not 0 <= arguments.port <= 65535:
        parser.error("--port must be in 0..65535")
    if getattr(arguments, "poll_ms", 1) <= 0 or getattr(arguments, "debounce_ms", 1) < 0:
        parser.error("poll and debounce values must be non-negative, with poll greater than zero")
    return arguments


def main(argv: Iterable[str]) -> int:
    arguments = parse_arguments(argv)
    if arguments.mode == "serve":
        return run_static_server(Path(arguments.web_dir), arguments.host, arguments.port)
    return run_dev(arguments)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
