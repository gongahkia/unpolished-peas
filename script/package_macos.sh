#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
out=${1:-"$repo/dist/macos"}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM

rm -rf "$out"
mkdir -p "$out"
sdk=$(xcrun --show-sdk-path)
for target in aarch64-macos x86_64-macos; do
  zig build -Dmacos-sdk="$sdk" -Dtarget="$target" -Doptimize=ReleaseSafe -p "$stage/$target" package-bounce-sdl
done
app="$out/unpolished-peas-bounce.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/assets" "$app/Contents/Docs"
lipo -create "$stage/aarch64-macos/bin/unpolished-peas-bounce-sdl" "$stage/x86_64-macos/bin/unpolished-peas-bounce-sdl" -output "$app/Contents/MacOS/unpolished-peas-bounce"
cp -R "$stage/aarch64-macos/assets/." "$app/Contents/assets/"
zig build docs
cp -R zig-out/docs/. "$app/Contents/Docs/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>unpolished-peas-bounce</string><key>CFBundleIdentifier</key><string>dev.unpolishedpeas.bounce</string><key>CFBundleName</key><string>unpolished-peas Bounce</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
printf '%s\n' 'runtime=Contents/MacOS/unpolished-peas-bounce' 'assets=Contents/assets/' 'docs=Contents/Docs/' > "$app/Contents/PACKAGE-MANIFEST.txt"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/unpolished-peas-bounce-macos-universal.zip"
(
    cd "$out"
    shasum -a 256 unpolished-peas-bounce-macos-universal.zip > SHA256SUMS
)
