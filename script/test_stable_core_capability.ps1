param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("windows-sdl_gpu")]
    [string]$Row
)

$ErrorActionPreference = "Stop"
python3 script/capability_matrix.py --check-row $Row
zig fmt --check build.zig src examples templates
zig build test-core-api
zig build test
zig build test-support
zig build test-scenes
zig build test-starter
zig build test-starter-template-browser
zig build test-docs
