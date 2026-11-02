#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin"
cat > "$tmp/bin/pkg-config" <<'EOF'
#!/usr/bin/env sh
touch "$UP_PKG_CONFIG_MARKER"
exit 99
EOF
chmod +x "$tmp/bin/pkg-config"

UP_PKG_CONFIG_MARKER="$tmp/pkg-config-used" PATH="$tmp/bin:$PATH" RUN_GENERATED_PROJECT=1 "$repo/script/test_downstream_fixture.sh"
test ! -e "$tmp/pkg-config-used"
printf '%s\n' 'starter-bundled-sdl passed'
