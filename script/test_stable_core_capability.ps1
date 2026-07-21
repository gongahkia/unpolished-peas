param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("windows-sdl_gpu")]
    [string]$Row
)

$ErrorActionPreference = "Stop"
function Invoke-Native([string]$Name, [scriptblock]$Command) {
    Write-Output "stable core check: $Name"
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Name failed: $LASTEXITCODE" }
}

Invoke-Native 'capability-matrix' { python3 script/capability_matrix.py --check-row $Row }
Invoke-Native 'format' { zig fmt --check build.zig src examples templates }
Invoke-Native 'core-api' { zig build test-core-api }
Invoke-Native 'core' { zig build test }
Invoke-Native 'support' { zig build test-support }
Invoke-Native 'scenes' { zig build test-scenes }
Invoke-Native 'starter' { zig build test-starter }
Invoke-Native 'starter-template-browser' { zig build test-starter-template-browser }
Invoke-Native 'docs' { zig build test-docs }
