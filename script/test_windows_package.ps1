param(
    [string]$OutputDirectory = 'dist/windows',
    [ValidateSet('bounce', 'topdown', 'puzzle', 'platformer')]
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
    foreach ($path in @($runtime, (Join-Path $package 'bin/D3DCompiler_47.dll'), (Join-Path $package 'assets'), (Join-Path $package 'docs/api/core.md'), (Join-Path $package 'run.cmd'), (Join-Path $package 'launcher.json'))) {
        if (-not (Test-Path -LiteralPath $path)) { throw "missing package path: $path" }
    }
    $launcher = Get-Content -LiteralPath (Join-Path $package 'launcher.json') -Raw | ConvertFrom-Json
    if ($launcher.version -ne 1 -or $launcher.platform -ne 'windows-x86_64' -or $launcher.game -ne $Game -or $launcher.runtime -ne ('bin/unpolished-peas-' + $Game + '.exe') -or $launcher.assets -ne 'assets/' -or $launcher.docs -ne 'docs/') { throw 'launcher metadata mismatch' }
    $manifest = Get-Content -LiteralPath (Join-Path $package 'PACKAGE-MANIFEST.txt')
    foreach ($line in @('format=unpolished-peas-package', 'version=1', 'platform=windows-x86_64', ('game=' + $Game), ('runtime=bin/unpolished-peas-' + $Game + '.exe'), 'assets=assets/', 'docs=docs/', 'launcher=launcher.json', 'bundled-runtime=SDL3:static', 'shader-compiler=bin/D3DCompiler_47.dll')) {
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
        $env:SDL_AUDIODRIVER = 'dummy'
        & $checker
        if ($LASTEXITCODE -ne 0) { throw "package layout checker failed: $LASTEXITCODE" }
        & $runtime --frames 2 --renderer sdl-gpu
        if ($LASTEXITCODE -ne 0) { throw "SDL GPU packaged smoke failed: $LASTEXITCODE" }

        # windows-2022 has no supported OpenGL 3.3 context. Exercise the
        # explicit selection path, but distinguish that host capability from
        # a broken package. A real-context lane remains required elsewhere.
        $opengl_output = & $runtime --frames 2 --renderer opengl 2>&1
        $opengl_status = $LASTEXITCODE
        $opengl_text = $opengl_output | Out-String
        if ($opengl_status -eq 0) {
            $opengl_result = 'passed'
        } else {
            if ($opengl_text -notmatch 'renderer requested=opengl.*selected=none') { throw "unexpected OpenGL packaged smoke failure: $opengl_text" }
            $opengl_result = 'capability-unavailable'
        }
    } finally {
        Pop-Location
    }
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
    @('platform=windows-x86_64', ('game=' + $Game), ('archive=' + $name + '.zip'), 'checksum=verified', 'layout=passed', 'runtime-smoke=passed', 'renderer-sdl-gpu=passed', ('renderer-opengl=' + $opengl_result)) | Set-Content -LiteralPath (Join-Path $out 'SMOKE-REPORT.txt') -Encoding ascii
    Get-Content -LiteralPath (Join-Path $out 'SMOKE-REPORT.txt')
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
