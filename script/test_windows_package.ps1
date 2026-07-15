param(
    [string]$OutputDirectory = 'dist/windows',
    [ValidateSet('bounce', 'topdown', 'platformer')]
    [string]$Game = 'bounce'
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("unpolished-peas-package-test-" + [guid]::NewGuid().ToString('N'))
function Get-Sha256([string]$Path) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try {
            return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $algorithm.Dispose()
    }
}
switch ($Game) {
    'bounce' { $fixture = 'topdown' }
    'topdown' { $fixture = 'topdown' }
    'platformer' { $fixture = 'platformer' }
}

try {
    Push-Location $repo
    try {
        & zig build peas -- package windows $OutputDirectory --game $Game
        if ($LASTEXITCODE -ne 0) { throw "zig build peas package windows failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
    if ([IO.Path]::IsPathRooted($OutputDirectory)) {
        $out = $OutputDirectory
    } else {
        $out = Join-Path $repo $OutputDirectory
    }
    $name = "unpolished-peas-$Game-windows-x86_64"
    $archive = Join-Path $out ($name + '.zip')
    $sum = Get-Content -LiteralPath (Join-Path $out 'SHA256SUMS') -Raw
    $hash = Get-Sha256 $archive
    if ($sum -ne ($hash + '  ' + $name + '.zip')) { throw 'checksum manifest mismatch' }
    Expand-Archive -LiteralPath $archive -DestinationPath $tmp
    $package = Join-Path $tmp $name
    $runtime = Join-Path $package ('bin/unpolished-peas-' + $Game + '.exe')
    foreach ($path in @($runtime, (Join-Path $package 'bin/D3DCompiler_47.dll'), (Join-Path $package 'assets'), (Join-Path $package 'docs/api/core.md'), (Join-Path $package 'content/project.up'), (Join-Path $package ('content/cache/scenes/' + $fixture + '.upscene.upc')), (Join-Path $package ('content/cache/assets/' + $fixture + '.upassets.upc')), (Join-Path $package ('content/cache/maps/' + $fixture + '.upmap.upc')), (Join-Path $package 'run.cmd'), (Join-Path $package 'launcher.json'))) {
        if (-not (Test-Path -LiteralPath $path)) { throw "missing package path: $path" }
    }
    $launcher = Get-Content -LiteralPath (Join-Path $package 'launcher.json') -Raw | ConvertFrom-Json
    if ($launcher.version -ne 1 -or $launcher.platform -ne 'windows-x86_64' -or $launcher.game -ne $Game -or $launcher.runtime -ne ('bin/unpolished-peas-' + $Game + '.exe') -or $launcher.assets -ne 'assets/' -or $launcher.docs -ne 'docs/') { throw 'launcher metadata mismatch' }
    $manifest = Get-Content -LiteralPath (Join-Path $package 'PACKAGE-MANIFEST.txt')
    foreach ($line in @('format=unpolished-peas-package', 'version=1', 'platform=windows-x86_64', ('game=' + $Game), ('runtime=bin/unpolished-peas-' + $Game + '.exe'), 'assets=assets/', 'content=content/', 'caches=content/cache/', 'docs=docs/', 'launcher=launcher.json', 'bundled-runtime=SDL3:static', 'shader-compiler=bin/D3DCompiler_47.dll')) {
        if ($manifest -notcontains $line) { throw "missing manifest line: $line" }
    }
    $checker_stage = Join-Path $tmp 'checker'
    Push-Location $repo
    try {
        & zig build '-p' $checker_stage package-layout-checker
        if ($LASTEXITCODE -ne 0) { throw "package layout checker build failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
    $checker = Join-Path $package 'bin/unpolished-peas-test-packaged-layout.exe'
    Copy-Item -LiteralPath (Join-Path $checker_stage 'bin/unpolished-peas-test-packaged-layout.exe') -Destination $checker
    $outside = Join-Path $tmp 'outside-repository'
    New-Item -ItemType Directory -Force -Path $outside | Out-Null
    Push-Location $outside
    try {
        & $checker
        if ($LASTEXITCODE -ne 0) { throw "package layout checker failed: $LASTEXITCODE" }
        & $runtime --frames 2
        if ($LASTEXITCODE -ne 0) { throw "packaged smoke failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
    $corrupt = Join-Path $tmp 'corrupt-cache'
    Copy-Item -LiteralPath $package -Destination $corrupt -Recurse
    [IO.File]::WriteAllBytes((Join-Path $corrupt ('content/cache/scenes/' + $fixture + '.upscene.upc')), [byte[]](0))
    $corrupt_output = (& (Join-Path $corrupt 'bin/unpolished-peas-test-packaged-layout.exe') 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0 -or $corrupt_output -notmatch 'recovery: restore a checksum-verified package archive') { throw 'corrupt cache did not report recovery' }
    $missing = Join-Path $tmp 'missing-assets'
    Copy-Item -LiteralPath $package -Destination $missing -Recurse
    Remove-Item -LiteralPath (Join-Path $missing 'assets') -Recurse -Force
    $missing_output = (& (Join-Path $missing 'bin/unpolished-peas-test-packaged-layout.exe') 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0 -or $missing_output -notmatch 'recovery: restore a checksum-verified package archive') { throw 'missing assets did not report recovery' }
    $repeat = Join-Path $tmp 'repeat'
    Push-Location $repo
    try {
        & zig build peas -- package windows $repeat --game $Game
        if ($LASTEXITCODE -ne 0) { throw "repeat package failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
    if ((Get-Content -LiteralPath (Join-Path $out 'SHA256SUMS') -Raw) -ne (Get-Content -LiteralPath (Join-Path $repeat 'SHA256SUMS') -Raw)) { throw 'non-reproducible archive checksum' }
    @('platform=windows-x86_64', ('game=' + $Game), ('archive=' + $name + '.zip'), 'checksum=verified', 'layout=passed', 'runtime-smoke=passed', 'cache-recovery=passed') | Set-Content -LiteralPath (Join-Path $out 'SMOKE-REPORT.txt') -Encoding ascii
    Get-Content -LiteralPath (Join-Path $out 'SMOKE-REPORT.txt')
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
