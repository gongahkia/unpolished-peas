param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('topdown', 'puzzle', 'platformer')]
    [string]$Game
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$diagnostics = if ($env:UP_DIAGNOSTICS_ROOT) { $env:UP_DIAGNOSTICS_ROOT } else { Join-Path $repo "zig-out/diagnostics/proof-matrix/$Game" }
$scenario = 'setup'
$env:UP_DIAGNOSTICS_ROOT = $diagnostics
Set-Location $repo
function Invoke-Scenario([string]$Name, [scriptblock]$Command) {
    $script:scenario = $Name
    Write-Output "proof scenario: $Name"
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Name failed: $LASTEXITCODE" }
}
try {
    $project = "fixtures/$Game-project"
    Invoke-Scenario 'cli-check' { zig build peas -- check $project }
    foreach ($selection in 'unit', 'replay', 'visual') {
        Invoke-Scenario "cli-test-$selection" { zig build peas -- test $selection $project }
    }
    Invoke-Scenario 'integration-fixture' {
        Push-Location $project
        try {
            zig build test
        } finally {
            Pop-Location
        }
    }
    Invoke-Scenario 'inspector' { zig test src/inspector.zig -lc -I vendor/stb -cflags -std=c99 -- src/vendor/stb_image.c -cflags -std=c99 -- src/vendor/stb_truetype.c }
    Invoke-Scenario 'profiler' { zig test src/profiler.zig }
    Invoke-Scenario 'gameplay' { zig build ("test-" + $Game) }
    Invoke-Scenario 'scene' { zig build ("test-" + $Game + "-scene") }
    $env:SDL_AUDIODRIVER = 'dummy'
    Invoke-Scenario 'desktop-smoke' { zig build ("smoke-" + $Game + "-sdl") }
} catch {
    New-Item -ItemType Directory -Force -Path $diagnostics | Out-Null
    @("game=$Game", "scenario=$scenario", "error=$($_.Exception.Message)") | Set-Content -LiteralPath (Join-Path $diagnostics 'failure.log') -Encoding ascii
    throw
} finally {
}
