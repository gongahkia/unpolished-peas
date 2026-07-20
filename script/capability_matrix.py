import argparse
import json
import os
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
MATRIX_PATH = ROOT / "docs/capabilities/v0.1.json"
GUIDE_PATH = ROOT / "docs/guides/capabilities.md"
STATUSES = {"supported", "preview", "unsupported", "removed"}
TARGETS = {"macos", "linux", "windows", "chromium", "firefox", "safari"}
CORE = {
    "lifecycle",
    "drawing_text",
    "keyboard_pointer",
    "audio",
    "assets",
    "fixed_timestep",
    "packaging",
    "deterministic_hooks",
}


def fail(message):
    raise ValueError(message)


def load_matrix():
    try:
        matrix = json.loads(MATRIX_PATH.read_text())
    except json.JSONDecodeError as error:
        fail(f"invalid JSON in {MATRIX_PATH}: {error}")
    if matrix.get("schema_version") != 1:
        fail("schema_version must be 1")
    if matrix.get("contract_version") != "v0.1-draft":
        fail("contract_version must be v0.1-draft")
    if matrix.get("browser_baseline") != "current stable evergreen desktop releases of Chromium, Firefox, and Safari":
        fail("browser_baseline must name Chromium, Firefox, and Safari current stable evergreen desktop releases")
    if set(matrix.get("status_definitions", {})) != STATUSES:
        fail("status_definitions must define supported, preview, unsupported, and removed")
    stable_core = matrix.get("stable_core")
    if not isinstance(stable_core, list) or {entry.get("id") for entry in stable_core} != CORE:
        fail("stable_core must define every required stable-core capability exactly once")
    for entry in stable_core:
        if not isinstance(entry.get("label"), str) or not isinstance(entry.get("requirement"), str):
            fail(f"stable_core {entry.get('id')} requires label and requirement")
    targets = matrix.get("targets")
    if not isinstance(targets, list) or {entry.get("id") for entry in targets} != TARGETS:
        fail("targets must define macos, linux, windows, chromium, firefox, and safari exactly once")
    ci_rows = []
    extended_rows = []
    for target in targets:
        if target.get("kind") not in {"desktop", "browser"}:
            fail(f"target {target.get('id')} has invalid kind")
        renderers = target.get("renderers")
        if not isinstance(renderers, list) or not renderers:
            fail(f"target {target.get('id')} requires renderer entries")
        renderer_ids = set()
        for renderer in renderers:
            renderer_id = renderer.get("id")
            if not isinstance(renderer_id, str) or renderer_id in renderer_ids:
                fail(f"target {target.get('id')} has duplicate or invalid renderer id")
            renderer_ids.add(renderer_id)
            if renderer.get("status") not in STATUSES:
                fail(f"target {target.get('id')}/{renderer_id} has invalid status")
            if set(renderer.get("stable_core", [])) != CORE or len(renderer["stable_core"]) != len(CORE):
                fail(f"target {target.get('id')}/{renderer_id} must name every stable-core capability exactly once")
            ci = renderer.get("ci", {})
            if not isinstance(ci, dict) or set(ci) - {"pull_request", "extended"}:
                fail(f"target {target.get('id')}/{renderer_id} has invalid CI entry")
            pull_request = ci.get("pull_request")
            if pull_request is not None:
                if renderer["status"] != "supported":
                    fail(f"target {target.get('id')}/{renderer_id} has pull-request CI but is not supported")
                runner = pull_request.get("runner")
                command = pull_request.get("command")
                if not isinstance(runner, str) or not isinstance(command, str):
                    fail(f"target {target.get('id')}/{renderer_id} has invalid pull-request CI entry")
                ci_rows.append({"id": f"{target['id']}-{renderer_id}", "runner": runner, "command": command})
            extended = ci.get("extended")
            if extended is not None:
                if target["kind"] != "browser" or renderer["status"] != "preview":
                    fail(f"target {target.get('id')}/{renderer_id} extended CI must be a preview browser renderer")
                runner = extended.get("runner")
                command = extended.get("command")
                if not isinstance(runner, str) or not isinstance(command, str):
                    fail(f"target {target.get('id')}/{renderer_id} has invalid extended CI entry")
                extended_rows.append({"id": f"{target['id']}-{renderer_id}", "runner": runner, "command": command})
        if target["kind"] == "browser" and renderer_ids != {"webgl2", "webgpu"}:
            fail(f"browser target {target.get('id')} must define WebGL 2 and WebGPU")
    if {entry["id"] for entry in ci_rows} != {"macos-sdl_gpu", "linux-sdl_gpu", "windows-sdl_gpu"}:
        fail("pull-request CI must select every supported desktop SDL GPU target and no other target")
    if {entry["id"] for entry in extended_rows} != {"chromium-webgpu", "firefox-webgl2"}:
        fail("extended CI must select Chromium WebGPU parity and Firefox WebGL 2 smoke exactly once")
    for target in targets:
        if target["kind"] != "browser":
            continue
        capabilities = {renderer["id"]: renderer["stable_core"] for renderer in target["renderers"]}
        if capabilities["webgl2"] != capabilities["webgpu"]:
            fail(f"browser target {target['id']} gives WebGL 2 and WebGPU different stable-core requirements")
    return matrix, ci_rows, extended_rows


def render(matrix, ci_rows, extended_rows):
    lines = [
        "# v0.1 capability matrix",
        "",
        "Generated from [`docs/capabilities/v0.1.json`](../capabilities/v0.1.json); do not edit manually.",
        "",
        f"Contract: `{matrix['contract_version']}`.",
        "",
        f"Browser baseline: {matrix['browser_baseline']}.",
        "",
        "## Status",
        "",
    ]
    for status in ("supported", "preview", "unsupported", "removed"):
        lines.append(f"- `{status}`: {matrix['status_definitions'][status]}")
    lines += ["", "## Stable-core requirements", "", "| Area | Requirement |", "| --- | --- |"]
    for capability in matrix["stable_core"]:
        lines.append(f"| {capability['label']} | {capability['requirement']} |")
    lines += ["", "## Target and renderer status", "", "| Target | Renderer | Status | Required PR CI |", "| --- | --- | --- | --- |"]
    ci_by_id = {row["id"]: row for row in ci_rows}
    for target in matrix["targets"]:
        for renderer in target["renderers"]:
            row = ci_by_id.get(f"{target['id']}-{renderer['id']}")
            ci = f"`stable-core-capability` on `{row['runner']}`" if row else "—"
            lines.append(f"| {target['label']} | {renderer['label']} | `{renderer['status']}` | {ci} |")
    lines += [
        "",
        "WebGL 2 and WebGPU deliberately have the same stable-core requirement set. Their status differs only by implementation and release coverage.",
        "",
        "## CI selection",
        "",
        "`.github/workflows/toolchain.yml` obtains the required target matrix from this JSON through `script/capability_matrix.py`; it does not duplicate the selected targets.",
        "",
        "| Matrix row | Runner | Core check |",
        "| --- | --- | --- |",
    ]
    for row in ci_rows:
        lines.append(f"| `{row['id']}` | `{row['runner']}` | `{row['command']}` |")
    lines += ["", "## Extended verification", "", "Preview browser coverage is selected here, separately from the required stable-core pull-request matrix.", "", "| Matrix row | Runner | Renderer check |", "| --- | --- | --- |"]
    for row in extended_rows:
        lines.append(f"| `{row['id']}` | `{row['runner']}` | `{row['command']}` |")
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--check-row")
    parser.add_argument("--check-extended-row")
    parser.add_argument("--render", action="store_true")
    args = parser.parse_args()
    try:
        matrix, ci_rows, extended_rows = load_matrix()
        guide = render(matrix, ci_rows, extended_rows)
        if args.render:
            sys.stdout.write(guide)
            return
        if GUIDE_PATH.read_text() != guide:
            fail("docs/guides/capabilities.md is not the current rendering of docs/capabilities/v0.1.json")
        if args.check_row and args.check_row not in {row["id"] for row in ci_rows}:
            fail(f"unknown pull-request capability row: {args.check_row}")
        if args.check_extended_row and args.check_extended_row not in {row["id"] for row in extended_rows}:
            fail(f"unknown extended capability row: {args.check_extended_row}")
        if args.github_output:
            args.github_output.open("a").write(f"pull_request={json.dumps({'include': ci_rows}, separators=(',', ':'))}\nextended={json.dumps({'include': extended_rows}, separators=(',', ':'))}\n")
    except (OSError, ValueError) as error:
        print(f"capability matrix: {error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
