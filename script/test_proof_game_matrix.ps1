param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('topdown', 'platformer')]
    [string]$Game
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$diagnostics = if ($env:UP_DIAGNOSTICS_ROOT) { $env:UP_DIAGNOSTICS_ROOT } else { Join-Path $repo "zig-out/diagnostics/proof-matrix/$Game" }
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("unpolished-peas-$Game-" + [System.Guid]::NewGuid().ToString('N'))
$scenario = 'setup'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:UP_DIAGNOSTICS_ROOT = $diagnostics
Set-Location $repo
function Invoke-Scenario([string]$Name, [scriptblock]$Command) {
    $script:scenario = $Name
    & $Command
}
try {
    $project = "fixtures/$Game-project"
    Invoke-Scenario 'cli-check' { zig build peas -- check $project }
    Invoke-Scenario 'cli-compile' { zig build peas -- compile $project (Join-Path $tmp 'content') }
    foreach ($selection in 'unit', 'replay', 'visual', 'integration') {
        Invoke-Scenario "cli-test-$selection" { zig build peas -- test $selection $project }
    }
    Invoke-Scenario 'inspector-reload-profiler' { zig build test }
    if ($Game -eq 'topdown') {
        Invoke-Scenario 'headless' { zig build test-topdown-scene }
        Invoke-Scenario 'gameplay' { zig build test-topdown }
        Invoke-Scenario 'network' { zig build test-topdown-multiplayer }
        Invoke-Scenario 'host' { zig build test-topdown-hosts }
        $env:SDL_AUDIODRIVER = 'dummy'
        Invoke-Scenario 'desktop-smoke' { zig build smoke-topdown-sdl }
    } else {
        Invoke-Scenario 'headless' { zig build test-platformer }
        Invoke-Scenario 'physics' { zig build test-box2d }
        Invoke-Scenario 'shared-network' { zig build test-topdown-multiplayer }
        $env:SDL_AUDIODRIVER = 'dummy'
        Invoke-Scenario 'desktop-smoke' { zig build smoke-platformer-sdl }
    }
} catch {
    New-Item -ItemType Directory -Force -Path $diagnostics | Out-Null
    @("game=$Game", "scenario=$scenario", "error=$($_.Exception.Message)") | Set-Content -LiteralPath (Join-Path $diagnostics 'failure.log') -Encoding ascii
    throw
} finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
}
