#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(dirname -- "${script_directory}")"
cd "${repository_root}"

rust_bin_dir="${CARGO_HOME:-${HOME}/.cargo}/bin"
if [[ -d "${rust_bin_dir}" ]]; then
  export PATH="${rust_bin_dir}:${PATH}"
fi

if ! command -v wasm-bindgen >/dev/null 2>&1; then
  echo "wasm-bindgen-cli 0.2.128 is required; run 'make setup'" >&2
  exit 1
fi

cargo build --locked --package pxcl-wasm --target wasm32-unknown-unknown --release
wasm-bindgen \
  target/wasm32-unknown-unknown/release/pxcl_wasm.wasm \
  --target web \
  --out-dir crates/pxcl-wasm/pkg \
  --out-name pxcl_wasm
