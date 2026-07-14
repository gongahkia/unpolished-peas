#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
out=${1:-"$repo/dist/linux"}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM

rm -rf "$out"
mkdir -p "$out"
name=unpolished-peas-bounce-linux-x86_64
package="$out/$name"
mkdir -p "$package/bin"
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe -p "$stage" package-bounce-sdl
cp "$stage/bin/unpolished-peas-bounce-sdl" "$package/bin/unpolished-peas-bounce"
cp -R "$stage/assets" "$package/assets"
zig build docs
cp -R zig-out/docs "$package/docs"
cp -R fixtures/topdown-project "$package/content"
zig build contentc -- "$package/content" "$package/content/cache"
printf '%s\n' '{"version":1,"platform":"linux-x86_64","runtime":"bin/unpolished-peas-bounce","assets":"assets/","docs":"docs/"}' > "$package/launcher.json"
printf '%s\n' '#!/bin/sh' 'exec "$(dirname "$0")/bin/unpolished-peas-bounce" "$@"' > "$package/run.sh"
chmod +x "$package/run.sh"
printf '%s\n' 'format=unpolished-peas-package' 'version=1' 'platform=linux-x86_64' 'runtime=bin/unpolished-peas-bounce' 'assets=assets/' 'content=content/' 'caches=content/cache/' 'docs=docs/' 'launcher=launcher.json' 'bundled-runtime=SDL3:static' > "$package/PACKAGE-MANIFEST.txt"
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
