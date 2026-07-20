param(
    [string]$PerformanceRoot = 'zig-out/performance'
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($IsWindows) {
    $target = 'windows-x86_64'
} elseif ($IsMacOS) {
    $target = if ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) { 'macos-aarch64' } else { 'macos-x86_64' }
} elseif ($IsLinux -and [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq [System.Runtime.InteropServices.Architecture]::X64) {
    $target = 'linux-x86_64'
} else {
    throw "unsupported benchmark artifact target: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)-$([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"
}
if ([IO.Path]::IsPathRooted($PerformanceRoot)) {
    $output = $PerformanceRoot
} else {
    $output = Join-Path $repo $PerformanceRoot
}
New-Item -ItemType Directory -Force -Path $output | Out-Null

function Record-Benchmark([string]$Step, [string]$Name) {
    Push-Location $repo
    try {
        $lines = & zig build '-Doptimize=ReleaseFast' $Step
        if ($LASTEXITCODE -ne 0) { throw "benchmark failed: $Step ($LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
    [IO.File]::WriteAllText((Join-Path $output $Name), (($lines -join [Environment]::NewLine) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

Record-Benchmark 'benchmark' "$target.json"
Record-Benchmark 'benchmark-proofs' "proof-games-$target.json"
Record-Benchmark 'benchmark-workloads' "workloads-$target.json"
Write-Output "performance artifacts recorded: target=$target"
