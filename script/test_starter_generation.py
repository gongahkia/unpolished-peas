#!/usr/bin/env python3
"""Build untouched generated games outside the checkout in both dependency modes."""

import argparse
import functools
import hashlib
import http.server
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import threading


REPO = Path(__file__).resolve().parent.parent


def run(args, cwd, cache, succeeds=True):
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(cache / "global"))
    env["ZIG_LOCAL_CACHE_DIR"] = str(cache / "local")
    result = subprocess.run(
        [str(arg) for arg in args], cwd=cwd, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    if (result.returncode == 0) != succeeds:
        raise RuntimeError(f"{cwd}: {' '.join(map(str, args))}\n{result.stdout}")
    return result.stdout


def sources(project):
    return {
        str(path.relative_to(project)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in project.rglob("*")
        if path.is_file() and not {".zig-cache", "zig-out"}.intersection(path.relative_to(project).parts)
    }


def exercise(project, cache):
    before = sources(project)
    # No replacement manifest or game/build edits after generation.
    for command in ([], ["test"], ["web"], ["package"]):
        label = " ".join(["zig", "build", *command])
        print(f"generated {project.name}: running {label}", flush=True)
        run(["zig", "build", *command], project, cache)
        print(f"generated {project.name}: {label} passed", flush=True)
    executable = "seed-sprint.exe" if os.name == "nt" else "seed-sprint"
    assert (project / "zig-out/bin" / executable).is_file()
    assert (project / "zig-out/assets/README.md").is_file()
    for name in ("index.html", "unpolished-peas.wasm", "bootstrap.mjs", "host.mjs", "debug-font-v1.json", "assets/README.md"):
        assert (project / "zig-out/web" / name).is_file(), name
    assert sources(project) == before, "build commands changed the generated source"
    if os.environ.get("RUN_GENERATED_PROJECT") == "1":
        command = ["zig", "build", "run", "--", "--frames", "2"]
        if os.uname().sysname == "Linux":
            command.insert(0, str(REPO / "script/run_linux_software_gl.sh"))
        run(["env", "SDL_AUDIODRIVER=dummy", *command], project, cache)
        print(f"generated {project.name}: two-frame native smoke passed", flush=True)


def local(scratch):
    project = scratch / "local game with spaces"
    generator_cache = scratch / "generator-cache"
    run(["zig", "build", "peas", "--", "new", str(project) + os.sep], REPO, generator_cache)
    manifest = (project / "build.zig.zon").read_text()
    assert ".path =" in manifest and ".url =" not in manifest
    run(["zig", "build", "peas", "--", "check", project], REPO, generator_cache)
    run(["zig", "build", "peas", "--", "test", "unit", project], REPO, generator_cache)
    exercise(project, scratch / "consumer-cache")
    # The build-step entry point must have the same defaults.
    alias = scratch / "alias game"
    run(["zig", "build", "new", "--", alias], REPO, generator_cache)
    assert (alias / "build.zig.zon").read_bytes() == (project / "build.zig.zon").read_bytes()
    before = sources(project)
    refused = run(["zig", "build", "peas", "--", "new", project], REPO, generator_cache, succeeds=False)
    assert "DestinationExists" in refused
    assert sources(project) == before, "existing project was changed"


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


def prepared_manifest(original, url, package_hash):
    replacement = (
        "    .dependencies = .{\n"
        "        .unpolished_peas = .{\n"
        f'            .url = "{url}",\n'
        f'            .hash = "{package_hash}",\n'
        "        },\n"
        "    },\n"
    )
    manifest, count = re.subn(r"    \.dependencies = .*?(?=    \.paths =)", replacement, original, flags=re.S)
    assert count == 1
    return manifest


def release(scratch):
    tree = run([REPO / "script/worktree_treeish.sh"], REPO, scratch / "tree-cache").strip()
    version = re.search(r'\.version = "([^"]+)"', (REPO / "build.zig.zon").read_text()).group(1)
    archive = Path(run(
        [REPO / "script/create_source_archive.sh", f"v{version}", scratch / "archives", tree],
        REPO, scratch / "archive-cache",
    ).strip())
    with tarfile.open(archive) as package:
        package.extractall(scratch)
    checkout = scratch / f"unpolished-peas-{version}"
    assert not (checkout / ".git").exists()
    template = checkout / "templates/starter/build.zig.zon"
    assert not template.exists(), "source archive must exclude its self-referential release manifest"
    original = (REPO / "templates/starter/build.zig.zon").read_text()
    # Model a tagged checkout: preparation supplies the template coordinates
    # before generation. The resulting game is never patched.
    package_hash = run(["zig", "fetch", archive], scratch, scratch / "verification-cache").strip()
    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(archive.parent)),
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = f"http://127.0.0.1:{server.server_port}/{archive.name}"
        good_manifest = prepared_manifest(original, url, package_hash)
        generator_cache = scratch / "generator-cache"

        template.write_text(".{ .dependencies = .{} }\n")
        missing = scratch / "missing release"
        output = run(["zig", "build", "peas", "--", "new", missing, "--release"], checkout, generator_cache, succeeds=False)
        assert "ReleaseCoordinatesUnavailable" in output
        assert not missing.exists()

        # A real hash of different bytes proves that verification checks the
        # actual URL/hash pair, rather than just accepting plausible strings.
        different = scratch / "different-package"
        different.mkdir()
        (different / "build.zig.zon").write_text(
            '.{ .name = .unpolished_peas, .version = "0.0.0", '
            '.fingerprint = 0x9801f8ecd9290536, .paths = .{ "build.zig.zon" } }\n'
        )
        other_archive = scratch / "different.tar.gz"
        with tarfile.open(other_archive, "w:gz") as package:
            package.add(different, arcname="different-package")
        different_hash = run(["zig", "fetch", other_archive], scratch, scratch / "verification-cache").strip()
        assert package_hash != different_hash
        template.write_text(prepared_manifest(original, url, different_hash))
        mismatch = scratch / "mismatched release"
        output = run(["zig", "build", "peas", "--", "new", mismatch, "--release"], checkout, generator_cache, succeeds=False)
        assert "ReleaseHashMismatch" in output
        assert not mismatch.exists()

        template.write_text(good_manifest)
        project = scratch / "release game with spaces"
        run(["zig", "build", "peas", "--", "new", project, "--release"], checkout, generator_cache)
        assert (project / "build.zig.zon").read_text() == good_manifest
        assert ".path =" not in good_manifest
        assert str(REPO) not in "\n".join(path.read_text() for path in project.rglob("*") if path.is_file())
        exercise(project, scratch / "consumer-cache")
        alias = scratch / "release alias"
        run(["zig", "build", "new", "--", alias, "--release"], checkout, generator_cache)
        assert (alias / "build.zig.zon").read_text() == good_manifest
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("local", "release"))
    mode = parser.parse_args().mode
    with tempfile.TemporaryDirectory(prefix="peas-generation-") as directory:
        {"local": local, "release": release}[mode](Path(directory).resolve())
    print(f"starter generation passed: {mode}, untouched build/test/web/package, external directory")


if __name__ == "__main__":
    main()
