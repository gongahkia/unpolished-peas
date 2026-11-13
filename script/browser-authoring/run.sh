#!/bin/sh
set -eu
package=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if ! node -e 'const fs = require("node:fs"); const p = process.argv[1]; try { process.exit(JSON.parse(fs.readFileSync(p + "/package.json")).dependencies.playwright === JSON.parse(fs.readFileSync(p + "/node_modules/playwright/package.json")).version ? 0 : 1); } catch { process.exit(1); }' "$package"; then
    npm --prefix "$package" ci --ignore-scripts --no-audit --no-fund
fi
if [ "${1:-}" = "--contract-tests" ]; then
    shift
    exec node "$package/contract.mjs" "$@"
fi
exec node "$package/run.mjs" "$@"
