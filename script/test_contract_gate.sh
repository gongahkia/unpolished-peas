#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"

sh script/check_contract_gate.sh
fixture="$(mktemp)"
trap 'rm -f "$fixture"' EXIT
sed 's/  pull_request:/  pull_request_target:/' .github/workflows/v1-contract.yml > "$fixture"
if CONTRACT_GATE_WORKFLOW="$fixture" sh script/check_contract_gate.sh >/dev/null 2>&1; then
    exit 1
fi
sed '/runner: macos-14/d' .github/workflows/v1-contract.yml > "$fixture"
if CONTRACT_GATE_WORKFLOW="$fixture" sh script/check_contract_gate.sh >/dev/null 2>&1; then
    exit 1
fi
sed '/runs-on: windows-2025/d' .github/workflows/v1-contract.yml > "$fixture"
if CONTRACT_GATE_WORKFLOW="$fixture" sh script/check_contract_gate.sh >/dev/null 2>&1; then
    exit 1
fi
sed '/runs-on: ubuntu-24.04/d' .github/workflows/v1-contract.yml > "$fixture"
if CONTRACT_GATE_WORKFLOW="$fixture" sh script/check_contract_gate.sh >/dev/null 2>&1; then
    exit 1
fi
sed '/channel: \[pinned, rolling\]/d' .github/workflows/v1-contract.yml > "$fixture"
if CONTRACT_GATE_WORKFLOW="$fixture" sh script/check_contract_gate.sh >/dev/null 2>&1; then
    exit 1
fi
sed '/clang -std=c11/d' .github/workflows/v1-contract.yml > "$fixture"
if CONTRACT_GATE_WORKFLOW="$fixture" sh script/check_contract_gate.sh >/dev/null 2>&1; then
    exit 1
fi
sed '/zig build public-api-regression/d' .github/workflows/v1-contract.yml > "$fixture"
if CONTRACT_GATE_WORKFLOW="$fixture" sh script/check_contract_gate.sh >/dev/null 2>&1; then
    exit 1
fi
sed '/zig build benchmark-harness --/d' .github/workflows/v1-contract.yml > "$fixture"
if CONTRACT_GATE_WORKFLOW="$fixture" sh script/check_contract_gate.sh >/dev/null 2>&1; then
    exit 1
fi
sed '/zig build benchmark-authoritative/d' .github/workflows/v1-contract.yml > "$fixture"
if CONTRACT_GATE_WORKFLOW="$fixture" sh script/check_contract_gate.sh >/dev/null 2>&1; then
    exit 1
fi
sed '/zig build benchmark-sharded-p2p/d' .github/workflows/v1-contract.yml > "$fixture"
if CONTRACT_GATE_WORKFLOW="$fixture" sh script/check_contract_gate.sh >/dev/null 2>&1; then
    exit 1
fi
sed '/zig build benchmark-topology-faults/d' .github/workflows/v1-contract.yml > "$fixture"
if CONTRACT_GATE_WORKFLOW="$fixture" sh script/check_contract_gate.sh >/dev/null 2>&1; then
    exit 1
fi
