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
git -C "$repo" archive --format=tar HEAD | tar -x -C "$release"
test ! -e "$release/.git"
(cd "$release" && SOURCE_DATE_EPOCH="$epoch" zig build peas -- new "$generated")
test -f "$generated/build.zig.zon"
if rg -Fq "$repo" "$generated"; then exit 1; fi
cp -R "$release/fixtures/release-candidate-consumer" "$consumer"
(cd "$consumer" && ZIG_GLOBAL_CACHE_DIR="$tmp/consumer-global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/consumer-local-cache" zig build)
(cd "$consumer" && ZIG_GLOBAL_CACHE_DIR="$tmp/consumer-global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/consumer-local-cache" zig build run)
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
(cd "$tmp/outside" && SDL_AUDIODRIVER=dummy "$tmp/unpacked/$package/run.sh" --frames 2 --renderer opengl)
(cd "$release" && SOURCE_DATE_EPOCH="$epoch" zig build peas -- package web "$web" --game bounce)
node "$release/script/validate_web_bundle.mjs" "$web/unpolished-peas-bounce-web"
printf '%s\n' 'release-candidate-clean-consumer passed: dependency,new,desktop,web,proof-smoke,no-checkout'
