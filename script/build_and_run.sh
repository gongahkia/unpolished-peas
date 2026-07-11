#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="unpolished-peas-tilemap"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BINARY="$ROOT_DIR/zig-out/bin/$APP_NAME"

cd "$ROOT_DIR"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
zig build

case "$MODE" in
  run)
    "$APP_BINARY"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs|--telemetry|telemetry)
    "$APP_BINARY"
    ;;
  --verify|verify)
    "$APP_BINARY" &
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
