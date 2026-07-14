param([string]$OutputDirectory = 'dist/windows')

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("unpolished-peas-package-test-" + [guid]::NewGuid().ToString('N'))

try {
    Push-Location $repo
    try {
        & zig build peas -- package windows $OutputDirectory
        if ($LASTEXITCODE -ne 0) { throw "zig build peas package windows failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
    if ([IO.Path]::IsPathRooted($OutputDirectory)) {
        $out = $OutputDirectory
    } else {
        $out = Join-Path $repo $OutputDirectory
    }
    $name = 'unpolished-peas-bounce-windows-x86_64'
    $archive = Join-Path $out ($name + '.zip')
    $sum = Get-Content -LiteralPath (Join-Path $out 'SHA256SUMS') -Raw
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    if ($sum -ne ($hash + '  ' + $name + '.zip')) { throw 'checksum manifest mismatch' }
    Expand-Archive -LiteralPath $archive -DestinationPath $tmp
    $package = Join-Path $tmp $name
    $game = Join-Path $package 'bin/unpolished-peas-bounce.exe'
    foreach ($path in @($game, (Join-Path $package 'bin/D3DCompiler_47.dll'), (Join-Path $package 'assets'), (Join-Path $package 'docs/api/core.md'), (Join-Path $package 'run.cmd'), (Join-Path $package 'launcher.json'))) {
        if (-not (Test-Path -LiteralPath $path)) { throw "missing package path: $path" }
    }
    $launcher = Get-Content -LiteralPath (Join-Path $package 'launcher.json') -Raw | ConvertFrom-Json
    if ($launcher.version -ne 1 -or $launcher.platform -ne 'windows-x86_64' -or $launcher.runtime -ne 'bin/unpolished-peas-bounce.exe' -or $launcher.assets -ne 'assets/' -or $launcher.docs -ne 'docs/') { throw 'launcher metadata mismatch' }
    $manifest = Get-Content -LiteralPath (Join-Path $package 'PACKAGE-MANIFEST.txt')
    foreach ($line in @('format=unpolished-peas-package', 'version=1', 'platform=windows-x86_64', 'runtime=bin/unpolished-peas-bounce.exe', 'assets=assets/', 'docs=docs/', 'launcher=launcher.json', 'bundled-runtime=SDL3:static', 'shader-compiler=bin/D3DCompiler_47.dll')) {
        if ($manifest -notcontains $line) { throw "missing manifest line: $line" }
    }
    $outside = Join-Path $tmp 'outside-repository'
    New-Item -ItemType Directory -Force -Path $outside | Out-Null
    Push-Location $outside
    try {
        & $game --frames 2
        if ($LASTEXITCODE -ne 0) { throw "packaged smoke failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
    $repeat = Join-Path $tmp 'repeat'
    Push-Location $repo
    try {
        & zig build peas -- package windows $repeat
        if ($LASTEXITCODE -ne 0) { throw "repeat package failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
    if ((Get-Content -LiteralPath (Join-Path $out 'SHA256SUMS') -Raw) -ne (Get-Content -LiteralPath (Join-Path $repeat 'SHA256SUMS') -Raw)) { throw 'non-reproducible archive checksum' }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
