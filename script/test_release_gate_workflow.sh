#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
fixture="$(mktemp)"
trap 'rm -f "$fixture"' EXIT

sh script/check_release_gate_workflow.sh
sed '/needs: \[gate, sign\]/d' .github/workflows/release-signing.yml > "$fixture"
if RELEASE_GATE_WORKFLOW="$fixture" sh script/check_release_gate_workflow.sh >/dev/null 2>&1; then
    exit 1
fi
sed '/zig build benchmark-regression/d' .github/workflows/release-signing.yml > "$fixture"
if RELEASE_GATE_WORKFLOW="$fixture" sh script/check_release_gate_workflow.sh >/dev/null 2>&1; then
    exit 1
fi
sed '/gh release create/d' .github/workflows/release-signing.yml > "$fixture"
if RELEASE_GATE_WORKFLOW="$fixture" sh script/check_release_gate_workflow.sh >/dev/null 2>&1; then
    exit 1
fi
sed '/^      contents: write$/d' .github/workflows/release-signing.yml > "$fixture"
if RELEASE_GATE_WORKFLOW="$fixture" sh script/check_release_gate_workflow.sh >/dev/null 2>&1; then
    exit 1
fi
