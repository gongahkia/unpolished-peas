#!/bin/sh
set -eu
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
test_id=audio-lifetime-$(python3 -c 'import uuid; print(uuid.uuid4())')
cleanup() {
    result=$?
    mkdir -p "$repo/zig-out/diagnostics/audio-lifetime"
    cp "$tmp/native.log" "$repo/zig-out/diagnostics/audio-lifetime/native.log" 2>/dev/null || true
    python3 - "$tmp/native.log" "$test_id" <<'PY'
import shutil
import sys
from pathlib import Path
log = Path(sys.argv[1])
if log.exists():
    for line in log.read_text().splitlines():
        if not line.startswith("unpolished-peas app data: "):
            continue
        directory = Path(line.split(": ", 1)[1]).resolve()
        if directory.name == sys.argv[2] and directory.parent.name == "peas-audio-example":
            shutil.rmtree(directory, ignore_errors=True)
PY
    rm -rf "$tmp"
    exit "$result"
}
trap cleanup EXIT HUP INT TERM
cd "$repo"
zig build run-audio-lifetime -Daudio-lifetime-smoke=true \
    -Daudio-lifetime-test-id="$test_id" -j2 --summary all \
    -- --frames 12 >"$tmp/native.log" 2>&1 || { cat "$tmp/native.log"; exit 1; }
cat "$tmp/native.log"
python3 - "$tmp/native.log" <<'PY'
import sys
from pathlib import Path
assert "audio-lifetime-native passed: transitions=8 game_cleanup=true" in Path(sys.argv[1]).read_text()
PY
