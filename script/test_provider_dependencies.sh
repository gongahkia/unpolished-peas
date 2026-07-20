#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
sh script/check_provider_dependencies.sh
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
printf 'fixture-provider' > "$fixture/provider.bin"
checksum="$(shasum -a 256 "$fixture/provider.bin" | awk '{print $1}')"
printf '%s\n' "{\"schema_version\":1,\"allowed_licenses\":[\"MIT\"],\"providers\":[{\"name\":\"fixture-provider\",\"license\":\"MIT\",\"source\":\"https://example.invalid/fixture-provider.git\",\"revision\":\"0123456789abcdef0123456789abcdef01234567\",\"artifact\":\"provider.bin\",\"sha256\":\"$checksum\"}]}" > "$fixture/manifest.json"
shasum -a 256 "$fixture/manifest.json" | awk '{print $1}' > "$fixture/manifest.sha256"
PROVIDER_MANIFEST="$fixture/manifest.json" PROVIDER_MANIFEST_LOCK="$fixture/manifest.sha256" sh script/check_provider_dependencies.sh
cp "$fixture/manifest.json" "$fixture/original-manifest.json"
printf '\n' >> "$fixture/manifest.json"
if PROVIDER_MANIFEST="$fixture/manifest.json" PROVIDER_MANIFEST_LOCK="$fixture/manifest.sha256" sh script/check_provider_dependencies.sh >/dev/null 2>&1; then
    exit 1
fi
cp "$fixture/original-manifest.json" "$fixture/manifest.json"
printf x >> "$fixture/provider.bin"
if PROVIDER_MANIFEST="$fixture/manifest.json" PROVIDER_MANIFEST_LOCK="$fixture/manifest.sha256" sh script/check_provider_dependencies.sh >/dev/null 2>&1; then
    exit 1
fi
