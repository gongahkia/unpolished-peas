#!/usr/bin/env python3
"""Build the portable asset game outside the repo against a real source archive."""
import functools
import http.server
import re
import shutil
import tempfile
import threading
from pathlib import Path

from test_starter_generation import REPO, QuietHandler, prepared_manifest, run, sources


def main():
    with tempfile.TemporaryDirectory(prefix="peas-assets-consumer-") as directory:
        scratch = Path(directory)
        cache = scratch / "cache"
        tree = run([REPO / "script/worktree_treeish.sh"], REPO, cache).strip()
        version = re.search(r'\.version = "([^"]+)"', (REPO / "build.zig.zon").read_text()).group(1)
        archive = Path(run([REPO / "script/create_source_archive.sh", f"v{version}", scratch / "archive", tree], REPO, cache).strip())
        package_hash = run(["zig", "fetch", archive], scratch, cache).strip()
        # A real loopback archive and its computed package hash exercise the
        # distributed package boundary without requiring a published release.
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(archive.parent)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            project = scratch / "asset game"
            run(["zig", "build", "peas", "-Dwith_sdl=false", "--", "new", project], REPO, cache)
            manifest = project / "build.zig.zon"
            url = f"http://127.0.0.1:{server.server_port}/{archive.name}"
            manifest.write_text(prepared_manifest(manifest.read_text(), url, package_hash))
            for source, target in (("asset_workbench_game.zig", "game.zig"), ("asset_recipes.zig", "asset_recipes.zig")):
                shutil.copyfile(REPO / "examples" / source, project / "src" / target)
            entry = project / "src/main.zig"
            entry.write_text(entry.read_text() + '''
test "generated native wrapper forwards asset cleanup" {
    const std = @import("std");
    var input = up.input.Input{};
    var ctx = up.core.GameContext.init(&input);
    ctx.allocator = std.testing.allocator;
    var desktop = Game{};
    try desktop.init(&ctx);
    try desktop.deinit(&ctx);
    try std.testing.expect(desktop.state.assets == null);
}
''')
            assets = project / "src/assets"
            (assets / "fonts").mkdir(parents=True)
            for asset in ("ball.png", "blip.wav", "fonts/Basic-Regular.ttf", "fonts/OFL.txt"):
                shutil.copyfile(REPO / "examples/assets" / asset, assets / asset)
            before = sources(project)
            for command in (["zig", "build"], ["zig", "build", "test"], ["zig", "build", "web"], ["zig", "build", "package"]):
                run(command, project, scratch / "consumer-cache")
                print(f"external asset collection: {' '.join(command)} passed", flush=True)
            assert sources(project) == before, "consumer builds changed authored files"
            assert (project / "zig-out/web/unpolished-peas.wasm").is_file()
            assert (project / "zig-out/web/host.mjs").is_file()
            print("external asset collection passed: verified source archive, native, tests, browser, package", flush=True)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    main()
