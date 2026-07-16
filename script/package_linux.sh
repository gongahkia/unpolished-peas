#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
out="$repo/dist/linux"
game=bounce
out_set=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --game)
            shift
            [ "$#" -gt 0 ] || { printf '%s\n' 'usage: package_linux.sh [output-directory] [--game <bounce|topdown|platformer>]' >&2; exit 64; }
            game=$1
            ;;
        *)
            [ "$out_set" -eq 0 ] || { printf '%s\n' 'usage: package_linux.sh [output-directory] [--game <bounce|topdown|platformer>]' >&2; exit 64; }
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
    *) printf '%s\n' 'package_linux.sh: unsupported game; use bounce, topdown, or platformer' >&2; exit 64 ;;
esac
case "$out" in /*) ;; *) out="$repo/$out" ;; esac
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM

rm -rf "$out"
mkdir -p "$out"
name=unpolished-peas-$game-linux-x86_64
package="$out/$name"
mkdir -p "$package/bin"
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe -p "$stage" "$build_step"
cp "$stage/bin/$source_runtime" "$package/bin/unpolished-peas-$game"
cp -R "$stage/assets" "$package/assets"
zig build docs
cp -R zig-out/docs "$package/docs"
printf '{"version":1,"platform":"linux-x86_64","game":"%s","runtime":"bin/unpolished-peas-%s","assets":"assets/","docs":"docs/"}\n' "$game" "$game" > "$package/launcher.json"
printf '%s\n' '#!/bin/sh' "exec \"\$(dirname \"\$0\")/bin/unpolished-peas-$game\" \"\$@\"" > "$package/run.sh"
chmod +x "$package/run.sh"
printf '%s\n' 'format=unpolished-peas-package' 'version=1' 'platform=linux-x86_64' "game=$game" "runtime=bin/unpolished-peas-$game" 'assets=assets/' 'docs=docs/' 'launcher=launcher.json' 'bundled-runtime=SDL3:static' > "$package/PACKAGE-MANIFEST.txt"
epoch=$(git -C "$repo" log -1 --format=%ct)
if date --version >/dev/null 2>&1; then
    mtime=$(date -u -d "@$epoch" +%Y%m%d%H%M.%S)
else
    mtime=$(date -u -r "$epoch" +%Y%m%d%H%M.%S)
fi
find "$package" -exec touch -t "$mtime" {} +
(
    cd "$out"
    tar --format ustar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$epoch" -cf "$name.tar" "$name"
    gzip -n "$name.tar"
    sha256sum "$name.tar.gz" > SHA256SUMS
)
