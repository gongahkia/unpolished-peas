param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $out = Join-Path $repo 'dist/windows'
} elseif ([IO.Path]::IsPathRooted($OutputDirectory)) {
    $out = $OutputDirectory
} else {
    $out = Join-Path $repo $OutputDirectory
}
$stage = Join-Path ([IO.Path]::GetTempPath()) ("unpolished-peas-package-" + [guid]::NewGuid().ToString('N'))
$name = 'unpolished-peas-bounce-windows-x86_64'

try {
    Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $package = Join-Path $out $name
    New-Item -ItemType Directory -Force -Path (Join-Path $package 'bin') | Out-Null

    Push-Location $repo
    try {
        & zig build '-Dtarget=x86_64-windows-gnu' '-Doptimize=ReleaseSafe' '-p' $stage 'package-bounce-sdl'
        if ($LASTEXITCODE -ne 0) { throw "zig build package-bounce-sdl failed: $LASTEXITCODE" }
        Copy-Item -LiteralPath (Join-Path $stage 'bin/unpolished-peas-bounce-sdl.exe') -Destination (Join-Path $package 'bin/unpolished-peas-bounce.exe')
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

    Set-Content -LiteralPath (Join-Path $package 'launcher.json') -Encoding ascii -NoNewline -Value '{"version":1,"platform":"windows-x86_64","runtime":"bin/unpolished-peas-bounce.exe","assets":"assets/","docs":"docs/"}'
    Set-Content -LiteralPath (Join-Path $package 'run.cmd') -Encoding ascii -Value @('@echo off', '"%~dp0bin\unpolished-peas-bounce.exe" %*')
    Set-Content -LiteralPath (Join-Path $package 'PACKAGE-MANIFEST.txt') -Encoding ascii -Value @('format=unpolished-peas-package', 'version=1', 'platform=windows-x86_64', 'runtime=bin/unpolished-peas-bounce.exe', 'assets=assets/', 'docs=docs/', 'launcher=launcher.json', 'bundled-runtime=SDL3:static', 'shader-compiler=bin/D3DCompiler_47.dll')

    $epoch = [int64](& git -C $repo log -1 --format=%ct)
    if ($LASTEXITCODE -ne 0) { throw "git log failed: $LASTEXITCODE" }
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
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $out 'SHA256SUMS') -Encoding ascii -NoNewline -Value ($hash + '  ' + [IO.Path]::GetFileName($archive))
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
