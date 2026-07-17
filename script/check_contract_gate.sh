#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
workflow="${CONTRACT_GATE_WORKFLOW:-$root/.github/workflows/v1-contract.yml}"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[ -f "$workflow" ] || fail "missing v1 contract workflow"
grep -Fqx '  pull_request:' "$workflow" || fail "workflow must run on pull requests"
if grep -Fq 'pull_request_target:' "$workflow"; then
    fail "workflow must not use pull_request_target"
fi
grep -Fqx '  contents: read' "$workflow" || fail "workflow must use read-only contents permission"
grep -Fqx '      - uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10' "$workflow" || fail "workflow must pin checkout"
grep -Fqx '      - name: Install Zig 0.15.2' "$workflow" || fail "workflow must install Zig 0.15.2"
grep -Fqx '          echo '\''02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239  zig.tar.xz'\'' | sha256sum --check --status' "$workflow" || fail "workflow must verify the Zig archive"
grep -Fqx '  zig-compatibility:' "$workflow" || fail "workflow must define the Zig compatibility matrix"
for field in '        channel: [pinned, rolling]' '        if: matrix.channel == '\''pinned'\''' '      - name: Install rolling Zig' '        if: matrix.channel == '\''rolling'\''' '          curl --fail --location --retry 3 --silent --show-error --output zig-index.json https://ziglang.org/download/index.json' '          if url != f"https://ziglang.org/builds/zig-x86_64-linux-{version}.tar.xz":' '          if not re.fullmatch(r"[0-9a-f]{64}", checksum):' '          printf '\''%s  zig.tar.xz\n'\'' "$ZIG_SHA256" | sha256sum --check --status' '      - name: Check source compatibility' '      - name: Check C ABI compatibility'; do
    grep -Fqx "$field" "$workflow" || fail "workflow must retain Zig compatibility field: $field"
done
grep -Fqx '  linux-sdk:' "$workflow" || fail "workflow must define the Linux SDK job"
for field in '    runs-on: ubuntu-24.04' '          test "$(uname -m)" = "x86_64"' '      - name: Build and test SDK artifacts' '      - name: Build C ABI artifact and consumer'; do
    grep -Fqx "$field" "$workflow" || fail "workflow must retain Linux SDK field: $field"
done
grep -Fqx '  windows-sdk:' "$workflow" || fail "workflow must define the Windows SDK job"
for field in '    runs-on: windows-2025' '        shell: pwsh' '          if ((Get-FileHash zig.zip -Algorithm SHA256).Hash -ne '\''3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c'\'') { throw '\''invalid Zig archive checksum'\'' }' '      - name: Verify native Zig version' '          if ($env:PROCESSOR_ARCHITECTURE -ne '\''AMD64'\'') { throw '\''unexpected Windows architecture'\'' }' '      - name: Build and test SDK artifacts' '      - name: Build C ABI artifact and consumer'; do
    grep -Fqx "$field" "$workflow" || fail "workflow must retain Windows SDK field: $field"
done
grep -Fqx '  macos-sdk:' "$workflow" || fail "workflow must define the macOS SDK matrix"
grep -Fqx '    runs-on: ${{ matrix.runner }}' "$workflow" || fail "macOS SDK jobs must use their matrix runner"
grep -Fqx '      fail-fast: false' "$workflow" || fail "macOS SDK matrix must not cancel the other architecture"
for field in '          - arch: arm64' '            runner: macos-14' '            zig_arch: aarch64' '            sha256: 3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b' '          - arch: x86_64' '            runner: macos-15-intel' '            zig_arch: x86_64' '            sha256: 375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f' '      - name: Verify native Zig version' '      - name: Build and test SDK artifacts' '        run: zig build test' '      - name: Build C ABI artifact and consumer' '        run: zig build c-abi-parity'; do
    grep -Fqx "$field" "$workflow" || fail "workflow must retain macOS SDK matrix field: $field"
done
for command in 'zig build contract' 'zig build workspace-graph' 'zig build api-contract' 'zig build license-metadata' 'zig build quality' 'zig build dependency-policy'; do
    grep -Fqx "        run: $command" "$workflow" || fail "workflow must run $command"
done
