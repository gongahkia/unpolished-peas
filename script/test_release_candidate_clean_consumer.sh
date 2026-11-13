#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
release="$tmp/release"
consumer="$tmp/consumer"
generated="$tmp/generated"
desktop="$tmp/desktop"
web="$tmp/web"
epoch=$(git -C "$repo" log -1 --format=%ct)

mkdir "$release"
tree="$($repo/script/worktree_treeish.sh)"
git -C "$repo" archive --format=tar "$tree" | tar -x -C "$release"
test ! -e "$release/.git"
mkdir -p "$release/templates/starter"
cp "$repo/templates/starter/build.zig.zon" "$release/templates/starter/build.zig.zon"
(cd "$release" && SOURCE_DATE_EPOCH="$epoch" zig build peas -- new "$generated")
test -f "$generated/build.zig.zon"
if grep -r -F -q -- "$repo" "$generated"; then
    printf '%s\n' 'generated starter contains a source-checkout path' >&2
    exit 1
else
    status=$?
    [ "$status" -eq 1 ] || exit "$status"
fi
# Default generation depends on the adjacent clean archive checkout. Leave its
# output untouched; the URL/hash path is covered by the release generation test.
mv "$generated" "$consumer"
(cd "$consumer" && ZIG_GLOBAL_CACHE_DIR="$tmp/consumer-global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/consumer-local-cache" zig build)
(cd "$consumer" && ZIG_GLOBAL_CACHE_DIR="$tmp/consumer-global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/consumer-local-cache" zig build test)
(cd "$consumer" && ZIG_GLOBAL_CACHE_DIR="$tmp/consumer-global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/consumer-local-cache" zig build web)
case "$(uname -s)" in
    Linux) (cd "$consumer" && ZIG_GLOBAL_CACHE_DIR="$tmp/consumer-global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/consumer-local-cache" "$repo/script/run_linux_software_gl.sh" zig build run -- --frames 2) ;;
    Darwin) (cd "$consumer" && ZIG_GLOBAL_CACHE_DIR="$tmp/consumer-global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/consumer-local-cache" env SDL_AUDIODRIVER=dummy zig build run -- --frames 2) ;;
    *) printf 'release candidate gate: unsupported host %s\n' "$(uname -s)" >&2; exit 69 ;;
esac
(cd "$release" && script/test_independent_proof_games.sh)
case "$(uname -s)" in
    Darwin) platform=macos; archive=unpolished-peas-bounce-macos-universal.zip; package=unpolished-peas-bounce-macos-universal ;;
    Linux) platform=linux; archive=unpolished-peas-bounce-linux-x86_64.tar.gz; package=unpolished-peas-bounce-linux-x86_64 ;;
    *) printf 'release candidate gate: unsupported host %s\n' "$(uname -s)" >&2; exit 69 ;;
esac
(cd "$release" && SOURCE_DATE_EPOCH="$epoch" zig build peas -- package "$platform" "$desktop" --game bounce)
case "$platform" in
    macos) (cd "$desktop" && shasum -a 256 --check SHA256SUMS);;
    linux) (cd "$desktop" && sha256sum --check SHA256SUMS);;
esac
mkdir "$tmp/unpacked"
case "$platform" in
    macos) unzip -q "$desktop/$archive" -d "$tmp/unpacked" ;;
    linux) tar -xzf "$desktop/$archive" -C "$tmp/unpacked" ;;
esac
mkdir "$tmp/outside"
case "$platform" in
    linux) (cd "$tmp/outside" && "$repo/script/run_linux_software_gl.sh" "$tmp/unpacked/$package/run.sh" --frames 2 --renderer opengl) ;;
    macos) (cd "$tmp/outside" && SDL_AUDIODRIVER=dummy "$tmp/unpacked/$package/run.sh" --frames 2 --renderer opengl) ;;
esac
(cd "$release" && SOURCE_DATE_EPOCH="$epoch" zig build peas -- package web "$web" --game bounce)
node "$release/script/validate_web_bundle.mjs" "$web/unpolished-peas-bounce-web"
printf '%s\n' 'release-candidate-clean-consumer passed: dependency,new,desktop,web,proof-smoke,no-checkout'
