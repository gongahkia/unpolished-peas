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
cache_count="$(grep -Fc '        uses: actions/cache@5a3ec84eff668545956fd18022155c47e93e2684' "$workflow")"
[ "$cache_count" = 7 ] || fail "workflow must cache immutable Zig build inputs in every pinned SDK job"
grep -Fqx '      - name: Cache immutable Zig build inputs' "$workflow" || fail "workflow must name immutable Zig caches"
grep -Fqx '            .zig-cache' "$workflow" || fail "workflow must cache local Zig build inputs"
grep -Fqx '            ~/.cache/zig' "$workflow" || fail "workflow must cache Zig global inputs"
grep -Fqx "          key: zig-v1-\${{ runner.os }}-\${{ runner.arch }}-0.15.2-\${{ hashFiles('build.zig', 'build.zig.zon', 'packages/**', 'contracts/**', 'script/**') }}" "$workflow" || fail "workflow must use immutable Zig cache keys"
if grep -Fq 'restore-keys:' "$workflow"; then
    fail "workflow must not restore mutable Zig cache prefixes"
fi
grep -Fqx '      - name: Install Zig 0.15.2' "$workflow" || fail "workflow must install Zig 0.15.2"
grep -Fqx '          echo '\''02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239  zig.tar.xz'\'' | sha256sum --check --status' "$workflow" || fail "workflow must verify the Zig archive"
grep -Fqx '  benchmark-harness:' "$workflow" || fail "workflow must define the benchmark harness job"
for field in '      - name: Test result schema and bounds' '        run: zig build benchmark-harness-test' '      - name: Emit deterministic 1,000-peer baseline' '        run: zig build benchmark-harness -- --seed 1 --peers 1000 --groups 10 --steps 64 --payload-bytes 128 --clock-step-ns 1000000' '      - name: Benchmark authoritative 1,000-peer sessions' '        run: zig build benchmark-authoritative -Doptimize=ReleaseFast' '      - name: Benchmark sharded P2P 1,000-peer sessions' '        run: zig build benchmark-sharded-p2p -Doptimize=ReleaseFast' '      - name: Benchmark topology faults' '        run: zig build benchmark-topology-faults -Doptimize=ReleaseFast' '      - name: Benchmark throughput and backpressure' '        run: zig build benchmark-throughput -Doptimize=ReleaseFast' '      - name: Benchmark memory and resource ceilings' '        run: zig build benchmark-memory -Doptimize=ReleaseFast' '      - name: Enforce benchmark regression thresholds' '        run: zig build benchmark-regression'; do
    grep -Fqx "$field" "$workflow" || fail "workflow must retain benchmark harness field: $field"
done
grep -Fqx '  api-compatibility:' "$workflow" || fail "workflow must define the released API compatibility job"
for field in '      - name: Compare released Zig and C contracts' '        run: zig build public-api-regression' '      - name: Compile public compatibility contracts' '        run: zig build compatibility-contract && zig build c-header-contract' '      - name: Package versioned C SDK headers' '        run: zig build c-sdk-headers-package'; do
    grep -Fqx "$field" "$workflow" || fail "workflow must retain released API compatibility field: $field"
done
grep -Fqx '  zig-compatibility:' "$workflow" || fail "workflow must define the Zig compatibility matrix"
for field in '        channel: [pinned, rolling]' '        if: matrix.channel == '\''pinned'\''' '      - name: Install rolling Zig' '        if: matrix.channel == '\''rolling'\''' '          curl --fail --location --retry 3 --silent --show-error --output zig-index.json https://ziglang.org/download/index.json' '          if url != f"https://ziglang.org/builds/zig-x86_64-linux-{version}.tar.xz":' '          if not re.fullmatch(r"[0-9a-f]{64}", checksum):' '          printf '\''%s  zig.tar.xz\n'\'' "$ZIG_SHA256" | sha256sum --check --status' '      - name: Check source compatibility' '      - name: Check C ABI compatibility'; do
    grep -Fqx "$field" "$workflow" || fail "workflow must retain Zig compatibility field: $field"
done
grep -Fqx '  linux-sdk:' "$workflow" || fail "workflow must define the Linux SDK job"
for field in '    runs-on: ubuntu-24.04' '          test "$(uname -m)" = "x86_64"' '      - name: Compile C ABI smoke sources' '          gcc -std=c11 -Wall -Wextra -Werror -c -o .c-abi-compiler/c_abi_types.o -I packages/c-abi/include contracts/fixtures/c_abi_types.c' '          gcc -std=c11 -Wall -Wextra -Werror -c -o .c-abi-compiler/c_abi_consumer.o -I packages/c-abi/include contracts/fixtures/c_abi_consumer.c' '      - name: Build and test SDK artifacts' '      - name: Build C ABI artifact and consumer' '      - name: Build reproducible C SDK libraries' '        run: zig build c-sdk-desktop-reproducible' '      - name: Package versioned static C SDK libraries' '        run: zig build c-sdk-static-package' '      - name: Package versioned shared C SDK libraries' '        run: zig build c-sdk-shared-package'; do
    grep -Fqx "$field" "$workflow" || fail "workflow must retain Linux SDK field: $field"
done
grep -Fqx '  windows-sdk:' "$workflow" || fail "workflow must define the Windows SDK job"
for field in '    runs-on: windows-2025' '        shell: pwsh' '          if ((Get-FileHash zig.zip -Algorithm SHA256).Hash -ne '\''3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c'\'') { throw '\''invalid Zig archive checksum'\'' }' '      - name: Verify native Zig version' '          if ($env:PROCESSOR_ARCHITECTURE -ne '\''AMD64'\'') { throw '\''unexpected Windows architecture'\'' }' '          cl /nologo /std:c11 /W4 /WX /c /I packages\c-abi\include /Fo.c-abi-compiler\c_abi_types.obj contracts\fixtures\c_abi_types.c' '          cl /nologo /std:c11 /W4 /WX /c /I packages\c-abi\include /Fo.c-abi-compiler\c_abi_consumer.obj contracts\fixtures\c_abi_consumer.c' '      - name: Build and test SDK artifacts' '      - name: Build C ABI artifact and consumer'; do
    grep -Fqx "$field" "$workflow" || fail "workflow must retain Windows SDK field: $field"
done
grep -Fqx '  macos-sdk:' "$workflow" || fail "workflow must define the macOS SDK matrix"
grep -Fqx '    runs-on: ${{ matrix.runner }}' "$workflow" || fail "macOS SDK jobs must use their matrix runner"
grep -Fqx '      fail-fast: false' "$workflow" || fail "macOS SDK matrix must not cancel the other architecture"
for field in '          - arch: arm64' '            runner: macos-14' '            zig_arch: aarch64' '            sha256: 3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b' '          - arch: x86_64' '            runner: macos-15-intel' '            zig_arch: x86_64' '            sha256: 375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f' '      - name: Verify native Zig version' '          clang -std=c11 -Wall -Wextra -Werror -c -o .c-abi-compiler/c_abi_types.o -I packages/c-abi/include contracts/fixtures/c_abi_types.c' '          clang -std=c11 -Wall -Wextra -Werror -c -o .c-abi-compiler/c_abi_consumer.o -I packages/c-abi/include contracts/fixtures/c_abi_consumer.c' '      - name: Build and test SDK artifacts' '        run: zig build test' '      - name: Build C ABI artifact and consumer' '        run: zig build c-abi-parity' '      - name: Build reproducible C SDK libraries' '        run: zig build c-sdk-macos-reproducible'; do
    grep -Fqx "$field" "$workflow" || fail "workflow must retain macOS SDK matrix field: $field"
done
for command in 'zig build contract' 'zig build workspace-graph' 'zig build api-contract' 'zig build license-metadata' 'zig build quality' 'zig build dependency-policy' 'zig build zig-sdk-package' 'zig build release-checksums'; do
    grep -Fqx "        run: $command" "$workflow" || fail "workflow must run $command"
done
