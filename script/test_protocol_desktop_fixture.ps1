$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("unpolished-peas-protocol-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Push-Location (Join-Path $root "fixtures/protocol-desktop")
    $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $tmp "global-cache"
    $env:ZIG_LOCAL_CACHE_DIR = Join-Path $tmp "local-cache"
    zig build test
    $env:SDL_AUDIODRIVER = "dummy"
    zig build run
} finally {
    Pop-Location
    Remove-Item -Recurse -Force $tmp
}
