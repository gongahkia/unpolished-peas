#!/usr/bin/env python3
"""Enforce the v0.1 core dependency ceiling.

Approved package/build dependencies:
- `sdl` and `sdl_linux_deps`: lazy desktop-runtime dependencies only.
- vendored `stb_image`, `stb_truetype`, and `stb_vorbis`: core image, font, and audio decoding.
- Zig `std` and `builtin`: core source imports.

The core module must not import a package dependency. This rejects Box2D and every
removed-subsystem dependency by default, and reports the root-to-import path.
"""

from __future__ import annotations

from pathlib import Path
import re
import sys


APPROVED_MANIFEST_DEPENDENCIES = {"sdl", "sdl_linux_deps"}
APPROVED_CORE_MODULES = {"std", "builtin"}
APPROVED_CORE_C_INCLUDES = {"stb_image.h", "stb_truetype.h", "stb_vorbis.c"}
APPROVED_STB_BUILD_PATHS = {
    "vendor/stb",
    "src/vendor/stb_image.c",
    "src/vendor/stb_truetype.c",
    "vendor/stb/stb_vorbis.c",
}
IMPORT = re.compile(r'@import\("([^"]+)"\)')
C_INCLUDE = re.compile(r'@cInclude\("([^"]+)"\)')
DEPENDENCY = re.compile(r"\.([A-Za-z_][A-Za-z0-9_]*)\s*=")


class DependencyCeilingError(ValueError):
    pass


def fail(message: str) -> None:
    raise DependencyCeilingError(f"core dependency ceiling: {message}")


def project_path(root: Path, path: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def enclosing_brace(text: str, opening: int) -> str:
    depth = 0
    quoted = False
    escaped = False
    comment = False
    for index in range(opening, len(text)):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ""
        if comment:
            if char == "\n":
                comment = False
            continue
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
            continue
        if char == "/" and next_char == "/":
            comment = True
            continue
        if char == '"':
            quoted = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[opening : index + 1]
    fail("unterminated build.zig.zon dependencies object")


def manifest_dependencies(manifest: str) -> list[str]:
    section = re.search(r"\.dependencies\s*=\s*\.\s*\{", manifest)
    if section is None:
        fail("missing build.zig.zon.dependencies")
    opening = manifest.find("{", section.start())
    body = enclosing_brace(manifest, opening)
    names: list[str] = []
    depth = 0
    index = 0
    while index < len(body):
        char = body[index]
        if char == "{":
            depth += 1
            index += 1
            continue
        if char == "}":
            depth -= 1
            index += 1
            continue
        if depth == 1:
            match = DEPENDENCY.match(body, index)
            if match:
                names.append(match.group(1))
                index = match.end()
                continue
        index += 1
    return names


def require_manifest_dependencies(root: Path) -> None:
    manifest = (root / "build.zig.zon").read_text()
    names = manifest_dependencies(manifest)
    actual = set(names)
    for name in sorted(actual - APPROVED_MANIFEST_DEPENDENCIES):
        fail(f'unexpected package dependency "{name}" at build.zig.zon.dependencies.{name}')
    for name in sorted(APPROVED_MANIFEST_DEPENDENCIES - actual):
        fail(f'missing approved package dependency at build.zig.zon.dependencies.{name}')
    for name in names:
        start = manifest.find(f".{name} =", manifest.find(".dependencies"))
        dependency = enclosing_brace(manifest, manifest.find("{", start))
        if not re.search(r"\.lazy\s*=\s*true\b", dependency):
            fail(f"runtime dependency must remain lazy at build.zig.zon.dependencies.{name}.lazy")


def require_build_ceiling(root: Path) -> None:
    build = (root / "build.zig").read_text()
    core_start = build.find('const peas = b.addModule("unpolished-peas", .{')
    if core_start < 0:
        fail('missing core module at build.zig -> unpolished-peas')
    core_module = enclosing_brace(build, build.find("{", core_start))
    if re.search(r"\.imports\s*=", core_module):
        fail("unexpected core module import at build.zig -> unpolished-peas.imports")
    if 'if (target.result.cpu.arch != .wasm32) addStb(peas);' not in build:
        fail('missing approved stb wiring at build.zig -> unpolished-peas -> addStb')
    direct_core_configuration = re.findall(r"\bpeas\.(addImport|addIncludePath|addCSourceFile|addCSourceFiles|linkLibrary|linkSystemLibrary)\b", build)
    if direct_core_configuration:
        fail(f"unexpected core build dependency via build.zig -> unpolished-peas.{direct_core_configuration[0]}")
    start = build.find("fn addStb(")
    if start < 0:
        fail("missing approved stb build helper at build.zig -> addStb")
    stb = enclosing_brace(build, build.find("{", start))
    paths = set(re.findall(r'path\("([^"]+)"\)', stb))
    unexpected = paths - APPROVED_STB_BUILD_PATHS
    missing = APPROVED_STB_BUILD_PATHS - paths
    if unexpected:
        fail(f"unexpected core C source at build.zig -> addStb -> {sorted(unexpected)[0]}")
    if missing:
        fail(f"missing approved core C source at build.zig -> addStb -> {sorted(missing)[0]}")


def resolve_import(root: Path, source: Path, name: str) -> Path:
    imported = (source.parent / name).resolve()
    source_root = (root / "src").resolve()
    try:
        imported.relative_to(source_root)
    except ValueError:
        fail(f'core source escapes src via import "{name}" at {project_path(root, source)}')
    if not imported.is_file():
        fail(f'missing core source import "{name}" at {project_path(root, source)}')
    return imported


def require_core_import_ceiling(root: Path) -> None:
    entry = (root / "src/unpolished_peas.zig").resolve()
    pending: list[tuple[Path, tuple[Path, ...]]] = [(entry, (entry,))]
    visited: set[Path] = set()
    while pending:
        source, path = pending.pop()
        if source in visited:
            continue
        visited.add(source)
        text = source.read_text()
        for name in IMPORT.findall(text):
            if name in APPROVED_CORE_MODULES:
                continue
            if not name.endswith(".zig"):
                chain = " -> ".join(project_path(root, item) for item in path)
                fail(f'unexpected core module import "{name}" at {chain}')
            imported = resolve_import(root, source, name)
            pending.append((imported, path + (imported,)))
        for name in C_INCLUDE.findall(text):
            if name not in APPROVED_CORE_C_INCLUDES:
                chain = " -> ".join(project_path(root, item) for item in path)
                fail(f'unexpected core C include "{name}" at {chain}')


def check(root: Path) -> None:
    require_manifest_dependencies(root)
    require_build_ceiling(root)
    require_core_import_ceiling(root)


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    try:
        check(root)
    except (OSError, DependencyCeilingError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
