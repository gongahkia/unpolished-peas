param()

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $IsWindows -or [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne [System.Runtime.InteropServices.Architecture]::X64) {
    throw "unsupported workload baseline target: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)-$([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"
}

Push-Location $repo
try {
    & "$repo/script/record_performance_artifacts.ps1"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & python3 script/check_workload_baseline.py --directory benchmarks/workload-baselines/v1 zig-out/performance/workloads-windows-x86_64.json
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}
