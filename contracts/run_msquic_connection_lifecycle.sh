#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ] || [ ! -f "$2" ]; then
  exit 64
fi
fixture_dir="$(mktemp -d)"
cleanup() { rm -rf "$fixture_dir"; }
trap cleanup EXIT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$fixture_dir/key.pem" -out "$fixture_dir/cert.pem" -subj /CN=localhost -days 1 >/dev/null 2>&1
ln -s "$2" "$fixture_dir/libmsquic.so.2"
LD_LIBRARY_PATH="$fixture_dir" "$1" "$fixture_dir/cert.pem" "$fixture_dir/key.pem"
