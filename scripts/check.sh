#!/usr/bin/env bash
set -euo pipefail

rust_bin_dir="${CARGO_HOME:-${HOME}/.cargo}/bin"
if [[ -d "${rust_bin_dir}" ]]; then
  export PATH="${rust_bin_dir}:${PATH}"
fi

pnpm format:check
pnpm lint
pnpm typecheck
pnpm test
pnpm test:e2e
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace --all-features
cargo build --workspace --all-features
cargo build --package pxcl-wasm --target wasm32-unknown-unknown --release
./scripts/verify-release-artifacts.sh
