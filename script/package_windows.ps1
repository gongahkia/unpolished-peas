param(
    [string]$OutputDirectory,
    [ValidateSet('bounce', 'topdown', 'puzzle', 'platformer')]
    [string]$Game = 'bounce'
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
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
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $out = Join-Path $repo 'dist/windows'
} elseif ([IO.Path]::IsPathRooted($OutputDirectory)) {
    $out = $OutputDirectory
} else {
    $out = Join-Path $repo $OutputDirectory
}
$stage = Join-Path ([IO.Path]::GetTempPath()) ("unpolished-peas-package-" + [guid]::NewGuid().ToString('N'))
switch ($Game) {
    'bounce' { $build_step = 'package-bounce-sdl'; $source_runtime = 'unpolished-peas-bounce-sdl.exe'; $fixture = 'bounce-project' }
    'topdown' { $build_step = 'package-topdown-sdl'; $source_runtime = 'unpolished-peas-topdown-sdl.exe'; $fixture = 'topdown-project' }
    'puzzle' { $build_step = 'package-puzzle-sdl'; $source_runtime = 'unpolished-peas-puzzle-sdl.exe'; $fixture = 'puzzle-project' }
    'platformer' { $build_step = 'package-platformer-sdl'; $source_runtime = 'unpolished-peas-platformer-sdl.exe'; $fixture = 'platformer-project' }
}
$name = "unpolished-peas-$Game-windows-x86_64"

try {
    Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $package = Join-Path $out $name
    New-Item -ItemType Directory -Force -Path (Join-Path $package 'bin') | Out-Null

    Push-Location $repo
    try {
        & zig build '-Dtarget=x86_64-windows-gnu' '-Doptimize=ReleaseSafe' '-p' $stage $build_step
        if ($LASTEXITCODE -ne 0) { throw "zig build $build_step failed: $LASTEXITCODE" }
        Copy-Item -LiteralPath (Join-Path $stage ('bin/' + $source_runtime)) -Destination (Join-Path $package ('bin/unpolished-peas-' + $Game + '.exe'))
        $shader_compiler = Join-Path $env:SystemRoot 'System32/D3DCompiler_47.dll'
        if (-not (Test-Path -LiteralPath $shader_compiler -PathType Leaf)) { throw "missing Windows shader compiler: $shader_compiler" }
        Copy-Item -LiteralPath $shader_compiler -Destination (Join-Path $package 'bin/D3DCompiler_47.dll')
        Copy-Item -LiteralPath (Join-Path $stage 'assets') -Destination (Join-Path $package 'assets') -Recurse
        & zig build docs
        if ($LASTEXITCODE -ne 0) { throw "zig build docs failed: $LASTEXITCODE" }
        Copy-Item -LiteralPath (Join-Path $repo 'zig-out/docs') -Destination (Join-Path $package 'docs') -Recurse
    } finally {
        Pop-Location
    }

    Set-Content -LiteralPath (Join-Path $package 'launcher.json') -Encoding ascii -NoNewline -Value ('{"version":1,"platform":"windows-x86_64","game":"' + $Game + '","runtime":"bin/unpolished-peas-' + $Game + '.exe","assets":"assets/","docs":"docs/"}')
    Set-Content -LiteralPath (Join-Path $package 'run.cmd') -Encoding ascii -Value @('@echo off', ('"%~dp0bin\unpolished-peas-' + $Game + '.exe" %*'))
    Set-Content -LiteralPath (Join-Path $package 'PACKAGE-MANIFEST.txt') -Encoding ascii -Value @('format=unpolished-peas-package', 'version=1', 'platform=windows-x86_64', ('game=' + $Game), ('runtime=bin/unpolished-peas-' + $Game + '.exe'), 'assets=assets/', 'docs=docs/', 'launcher=launcher.json', 'bundled-runtime=SDL3:static', 'shader-compiler=bin/D3DCompiler_47.dll')

    $epoch_text = $env:SOURCE_DATE_EPOCH
    if ([string]::IsNullOrWhiteSpace($epoch_text)) {
        $epoch_text = & git -C $repo log -1 --format=%ct
        if ($LASTEXITCODE -ne 0) { throw "git log failed: $LASTEXITCODE" }
    }
    [int64]$epoch = 0
    if (-not [int64]::TryParse($epoch_text, [ref]$epoch) -or $epoch -lt 0) { throw 'SOURCE_DATE_EPOCH must be an unsigned Unix timestamp' }
    $timestamp = [DateTimeOffset]::FromUnixTimeSeconds($epoch)
    $archive = Join-Path $out ($name + '.zip')
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $files = Get-ChildItem -LiteralPath $package -Recurse -File | Sort-Object FullName
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($out.Length + 1).Replace('\', '/')
            $entry = $zip.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $timestamp
            $input = [IO.File]::OpenRead($file.FullName)
            $output = $entry.Open()
            try {
                $input.CopyTo($output)
            } finally {
                $output.Dispose()
                $input.Dispose()
            }
        }
    } finally {
        $zip.Dispose()
    }
    $hash = Get-Sha256 $archive
    Set-Content -LiteralPath (Join-Path $out 'SHA256SUMS') -Encoding ascii -NoNewline -Value ($hash + '  ' + [IO.Path]::GetFileName($archive))
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
