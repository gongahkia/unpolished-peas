#!/bin/sh
set -eu

command -v npx >/dev/null 2>&1 || { printf '%s\n' 'playwright CLI requires npx on PATH.' >&2; exit 69; }
has_session=0
for argument in "$@"; do
    case "$argument" in --session|--session=*) has_session=1; break ;; esac
done
if [ "$has_session" -eq 0 ] && [ -n "${PLAYWRIGHT_CLI_SESSION:-}" ]; then
    exec npx --yes --package @playwright/cli playwright-cli --session "$PLAYWRIGHT_CLI_SESSION" "$@"
fi
exec npx --yes --package @playwright/cli playwright-cli "$@"
