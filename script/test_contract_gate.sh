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
