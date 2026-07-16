#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
source="$tmp/diagnostics"
output="$tmp/support"
mkdir "$source"
printf '{"diagnostics":"%s","token":"secret-token"}\n' "$source" > "$source/environment.json"
printf 'recovery: restore package at %s with secret-token\n' "$source" > "$source/failure.log"
cp "$repo/examples/assets/proof-bounce-reference.png" "$source/screenshot.png"
cd "$repo"
zig build peas -- support-bundle "$source" "$output" --include environment.json --include failure.log --include screenshot.png --redact secret-token --redact-path "$source"
test -f "$output/support-bundle.json"
test -s "$output/screenshot.png"
grep -F '"files":3' "$output/support-bundle.json"
if rg -Fq 'secret-token' "$output"; then exit 1; fi
if rg -Fq "$source" "$output"; then exit 1; fi
printf '%s\n' 'support-bundle-cli passed: manifest,redaction,screenshot'
