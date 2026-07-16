#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
out="$repo/dist/macos"
game=bounce
out_set=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --game)
            shift
            [ "$#" -gt 0 ] || { printf '%s\n' 'usage: package_macos.sh [output-directory] [--game <bounce|topdown|platformer>]' >&2; exit 64; }
            game=$1
            ;;
        *)
            [ "$out_set" -eq 0 ] || { printf '%s\n' 'usage: package_macos.sh [output-directory] [--game <bounce|topdown|platformer>]' >&2; exit 64; }
            out=$1
            out_set=1
            ;;
    esac
    shift
done
case "$game" in
    bounce) build_step=package-bounce-sdl; source_runtime=unpolished-peas-bounce-sdl; fixture=topdown-project ;;
    topdown) build_step=package-topdown-sdl; source_runtime=unpolished-peas-topdown-sdl; fixture=topdown-project ;;
    platformer) build_step=package-platformer-sdl; source_runtime=unpolished-peas-platformer-sdl; fixture=platformer-project ;;
    *) printf '%s\n' 'package_macos.sh: unsupported game; use bounce, topdown, or platformer' >&2; exit 64 ;;
esac
case "$out" in /*) ;; *) out="$repo/$out" ;; esac
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM

rm -rf "$out"
mkdir -p "$out"
sdk=$(xcrun --show-sdk-path)
for target in aarch64-macos x86_64-macos; do
  zig build -Dmacos-sdk="$sdk" -Dtarget="$target" -Doptimize=ReleaseSafe -p "$stage/$target" "$build_step"
done
name=unpolished-peas-$game-macos-universal
package="$out/$name"
mkdir -p "$package/bin"
lipo -create "$stage/aarch64-macos/bin/$source_runtime" "$stage/x86_64-macos/bin/$source_runtime" -output "$package/bin/unpolished-peas-$game"
cp -R "$stage/aarch64-macos/assets" "$package/assets"
zig build docs
cp -R zig-out/docs "$package/docs"
printf '{"version":1,"platform":"macos-universal","game":"%s","runtime":"bin/unpolished-peas-%s","assets":"assets/","docs":"docs/"}\n' "$game" "$game" > "$package/launcher.json"
printf '%s\n' '#!/bin/sh' "exec \"\$(dirname \"\$0\")/bin/unpolished-peas-$game\" \"\$@\"" > "$package/run.sh"
chmod +x "$package/run.sh"
printf '%s\n' 'format=unpolished-peas-package' 'version=1' 'platform=macos-universal' "game=$game" "runtime=bin/unpolished-peas-$game" 'assets=assets/' 'docs=docs/' 'launcher=launcher.json' 'bundled-runtime=SDL3:static' > "$package/PACKAGE-MANIFEST.txt"
epoch=${SOURCE_DATE_EPOCH:-}
if [ -z "$epoch" ]; then epoch=$(git -C "$repo" log -1 --format=%ct); fi
case "$epoch" in *[!0-9]*|'') printf '%s\n' 'package_macos.sh: SOURCE_DATE_EPOCH must be an unsigned Unix timestamp' >&2; exit 64 ;; esac
mtime=$(date -u -r "$epoch" +%Y%m%d%H%M.%S)
find "$package" -exec touch -t "$mtime" {} +
(
    cd "$out"
    find "$name" -print | LC_ALL=C sort | zip -X -q "$name.zip" -@
)
(
    cd "$out"
    shasum -a 256 "$name.zip" > SHA256SUMS
)
