#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
sh script/check_provider_dependencies.sh
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
printf '%s\n' "{\"schema_version\":2,\"allowed_licenses\":[\"MIT\"],\"providers\":[{\"name\":\"fixture-provider\",\"license\":\"MIT\",\"source\":\"https://example.invalid/fixture-provider.git\",\"revision\":\"0123456789abcdef0123456789abcdef01234567\",\"version\":\"1.2.3\",\"headers\":{\"url\":\"https://example.invalid/0123456789abcdef0123456789abcdef01234567/include/provider.h\",\"path\":\"include/provider.h\",\"sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"},\"artifacts\":[{\"target\":\"x86_64-linux\",\"url\":\"https://example.invalid/provider-1.2.3.deb\",\"sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"format\":\"deb\",\"library\":\"usr/lib/libmsquic.so.1.2.3\"}]}]}" > "$fixture/manifest.json"
shasum -a 256 "$fixture/manifest.json" | awk '{print $1}' > "$fixture/manifest.sha256"
PROVIDER_MANIFEST="$fixture/manifest.json" PROVIDER_MANIFEST_LOCK="$fixture/manifest.sha256" sh script/check_provider_dependencies.sh
cp "$fixture/manifest.json" "$fixture/original-manifest.json"
printf '\n' >> "$fixture/manifest.json"
if PROVIDER_MANIFEST="$fixture/manifest.json" PROVIDER_MANIFEST_LOCK="$fixture/manifest.sha256" sh script/check_provider_dependencies.sh >/dev/null 2>&1; then
    exit 1
fi
cp "$fixture/original-manifest.json" "$fixture/manifest.json"
sed 's/x86_64-linux/aarch64-macos/' "$fixture/manifest.json" > "$fixture/invalid-manifest.json"
mv "$fixture/invalid-manifest.json" "$fixture/manifest.json"
shasum -a 256 "$fixture/manifest.json" | awk '{print $1}' > "$fixture/manifest.sha256"
if PROVIDER_MANIFEST="$fixture/manifest.json" PROVIDER_MANIFEST_LOCK="$fixture/manifest.sha256" sh script/check_provider_dependencies.sh >/dev/null 2>&1; then
    exit 1
fi
