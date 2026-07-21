#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
tag="${1:-}"
case "$tag" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) printf '%s\n' 'usage: script/prepare_starter_release.sh vMAJOR.MINOR.PATCH' >&2; exit 64 ;;
esac
version="${tag#v}"
cd "$repo"
if ! git diff --quiet || ! git diff --cached --quiet; then
    printf '%s\n' 'starter release preparation requires a clean tree' >&2
    exit 65
fi
if git rev-parse -q --verify "refs/tags/$tag" > /dev/null || git ls-remote --exit-code --tags origin "refs/tags/$tag" > /dev/null 2>&1; then
    printf 'starter release preparation refused existing tag: %s\n' "$tag" >&2
    exit 65
fi
if ! rg -Fqx "    .version = \"$version\"," build.zig.zon; then
    printf 'starter release preparation requires build.zig.zon version %s\n' "$version" >&2
    exit 65
fi
if rg -Fq '"templates/bounce/build.zig.zon"' build.zig.zon; then
    printf '%s\n' 'starter release preparation requires the generated manifest excluded from package paths' >&2
    exit 65
fi

tmp="$(mktemp -d)"
archive="$tmp/unpolished-peas-$version.tar.gz"
port_file="$tmp/port"
server_pid=''
cleanup() {
    status=$?
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
    if [ -d "$tmp" ]; then rm -r "$tmp"; fi
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

git archive --format=tar.gz --prefix="unpolished-peas-$version/" HEAD > "$archive"
python3 - "$tmp" "$port_file" <<'PY' &
import functools
import http.server
import pathlib
import sys

directory, port_file = sys.argv[1:]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=directory)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
pathlib.Path(port_file).write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
server_pid=$!
for _ in $(seq 1 50); do
    [ -s "$port_file" ] && break
    sleep 0.1
done
if [ ! -s "$port_file" ]; then
    printf '%s\n' 'starter release preparation could not start the local archive server' >&2
    exit 1
fi
port="$(< "$port_file")"
hash="$(ZIG_GLOBAL_CACHE_DIR="$tmp/global" ZIG_LOCAL_CACHE_DIR="$tmp/local" zig fetch "http://127.0.0.1:$port/$(basename -- "$archive")")"
case "$hash" in
    unpolished_peas-*) ;;
    *) printf 'starter release preparation produced invalid hash for %s\n' "$tag" >&2; exit 1 ;;
esac
url="https://github.com/gongahkia/unpolished-peas/archive/refs/tags/$tag.tar.gz"
python3 - "templates/bounce/build.zig.zon" "$url" "$hash" <<'PY'
import pathlib
import sys

path, url, package_hash = sys.argv[1:]
pathlib.Path(path).write_text(f''' .{{
    .name = .unpolished_peas_game,
    .version = "0.0.1",
    .fingerprint = 0x68a23f24006f3ea5, // Changing this has security and trust implications.
    .minimum_zig_version = "0.15.2",
    .dependencies = .{{
        .unpolished_peas = .{{
            .url = "{url}",
            .hash = "{package_hash}",
        }},
    }},
    .paths = .{{
        "build.zig",
        "build.zig.zon",
        "src",
        "assets",
        "README.md",
    }},
}}
'''.removeprefix(" "), encoding="utf-8")
PY
printf 'starter release template prepared: tag=%s url=%s hash=%s\n' "$tag" "$url" "$hash"
