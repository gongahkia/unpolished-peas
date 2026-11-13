#!/usr/bin/env python3
import tempfile
import unittest
from pathlib import Path

from check_core_dependency_ceiling import DependencyCeilingError, check


MANIFEST = '''.{
    .dependencies = .{
        .sdl = .{ .lazy = true },
        .sdl_linux_deps = .{ .lazy = true },
    },
}
'''
BUILD = '''const std = @import("std");
pub fn build(b: *std.Build) void {
    const peas = b.addModule("unpolished-peas", .{});
    if (target.result.cpu.arch != .wasm32) addStb(peas);
}
fn addStb(mod: *std.Build.Module) void {
    mod.addIncludePath(mod.owner.path("vendor/stb"));
    mod.addCSourceFile(.{ .file = mod.owner.path("src/vendor/stb_image.c") });
    mod.addCSourceFile(.{ .file = mod.owner.path("src/vendor/stb_truetype.c") });
    mod.addCSourceFile(.{ .file = mod.owner.path("vendor/stb/stb_vorbis.c") });
}
'''


class DependencyCeilingTest(unittest.TestCase):
    def project(self, source: str) -> Path:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        (root / "src").mkdir()
        (root / "build.zig.zon").write_text(MANIFEST)
        (root / "build.zig").write_text(BUILD)
        (root / "src/unpolished_peas.zig").write_text(source)
        return root

    def test_allows_std_and_vendored_stb(self) -> None:
        root = self.project('const std = @import("std");\nconst c = @cImport({ @cInclude("stb_image.h"); });\n')
        check(root)

    def test_reports_unapproved_manifest_dependency_path(self) -> None:
        root = self.project('const std = @import("std");\n')
        manifest = (root / "build.zig.zon").read_text().replace('.sdl = .{ .lazy = true },', '.box2d = .{ .lazy = true },')
        (root / "build.zig.zon").write_text(manifest)
        with self.assertRaisesRegex(DependencyCeilingError, r'build\.zig\.zon\.dependencies\.box2d'):
            check(root)

    def test_reports_unapproved_core_build_import_path(self) -> None:
        root = self.project('const std = @import("std");\n')
        build = (root / "build.zig").read_text().replace('b.addModule("unpolished-peas", .{})', 'b.addModule("unpolished-peas", .{ .imports = &.{} })')
        (root / "build.zig").write_text(build)
        with self.assertRaisesRegex(DependencyCeilingError, r'build\.zig -> unpolished-peas\.imports'):
            check(root)

    def test_reports_unapproved_core_import_chain(self) -> None:
        root = self.project('const game = @import("game.zig");\n')
        (root / "src/game.zig").write_text('const box2d = @import("box2d");\n')
        with self.assertRaisesRegex(DependencyCeilingError, r'src/unpolished_peas\.zig -> src/game\.zig'):
            check(root)


if __name__ == "__main__":
    unittest.main()
