#!/usr/bin/env python3
import pathlib
import sys
import tempfile


EXPECTED = {
    ("linux", "bounce"): ("linux-x86_64", "unpolished-peas-bounce-linux-x86_64.tar.gz"),
    ("macos", "bounce"): ("macos-universal", "unpolished-peas-bounce-macos-universal.zip"),
    ("windows", "bounce"): ("windows-x86_64", "unpolished-peas-bounce-windows-x86_64.zip"),
    ("linux", "topdown"): ("linux-x86_64", "unpolished-peas-topdown-linux-x86_64.tar.gz"),
    ("macos", "topdown"): ("macos-universal", "unpolished-peas-topdown-macos-universal.zip"),
    ("windows", "topdown"): ("windows-x86_64", "unpolished-peas-topdown-windows-x86_64.zip"),
    ("linux", "platformer"): ("linux-x86_64", "unpolished-peas-platformer-linux-x86_64.tar.gz"),
    ("macos", "platformer"): ("macos-universal", "unpolished-peas-platformer-macos-universal.zip"),
    ("windows", "platformer"): ("windows-x86_64", "unpolished-peas-platformer-windows-x86_64.zip"),
}

COMMON = {
    "checksum": "verified",
    "layout": "passed",
    "runtime-smoke": "passed",
    "renderer-sdl-gpu": "passed",
}
OPENGL_BY_TARGET = {
    "linux": "passed",
    "macos": "passed",
    # windows-2022 has no supported OpenGL 3.3 context. The package must
    # report that explicit selection failed as a host capability, not claim a
    # renderer conformance result it cannot obtain.
    "windows": "capability-unavailable",
}


def parse_report(path: pathlib.Path) -> dict[str, str]:
    report: dict[str, str] = {}
    for line in path.read_text(encoding="ascii").splitlines():
        key, separator, value = line.partition("=")
        if not separator or not key or not value or key in report:
            raise ValueError(f"invalid report line in {path}: {line!r}")
        report[key] = value
    return report


def validate(reports: list[dict[str, str]]) -> None:
    seen: set[tuple[str, str]] = set()
    for report in reports:
        target = next((key for key, (platform, _) in EXPECTED.items() if platform == report.get("platform") and key[1] == report.get("game")), None)
        if target is None or target in seen:
            raise ValueError(f"unexpected package report: {report}")
        platform, archive = EXPECTED[target]
        expected = {"platform": platform, "game": target[1], "archive": archive, "renderer-opengl": OPENGL_BY_TARGET[target[0]]} | COMMON
        if report != expected:
            raise ValueError(f"package parity mismatch for {target[0]}/{target[1]}: {report}")
        seen.add(target)
    if seen != set(EXPECTED):
        raise ValueError(f"missing package reports: {sorted(set(EXPECTED) - seen)}")


def sample_reports() -> list[dict[str, str]]:
    reports = []
    for (target, game), (platform, archive) in EXPECTED.items():
        reports.append({"platform": platform, "game": game, "archive": archive, "renderer-opengl": OPENGL_BY_TARGET[target] } | COMMON)
    return reports


def reports_from(root: pathlib.Path) -> list[dict[str, str]]:
    return [parse_report(path) for path in root.rglob("SMOKE-REPORT.txt")]


def self_test() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        for index, report in enumerate(sample_reports()):
            path = root / str(index) / "SMOKE-REPORT.txt"
            path.parent.mkdir()
            path.write_text("".join(f"{key}={value}\n" for key, value in report.items()), encoding="ascii")
        validate(reports_from(root))
    invalid = sample_reports()
    invalid[0] = invalid[0] | {"layout": "missing"}
    try:
        validate(invalid)
    except ValueError:
        return
    raise AssertionError("invalid package report was accepted")


def main() -> None:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_package_parity.py <reports-directory> | --self-test")
    root = pathlib.Path(sys.argv[1])
    validate(reports_from(root))


if __name__ == "__main__":
    main()
