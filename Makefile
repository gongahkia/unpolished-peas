.PHONY: setup build check dev test

setup:
	pnpm install --frozen-lockfile
	cargo fetch --locked
	command -v wasm-bindgen >/dev/null 2>&1 || cargo install wasm-bindgen-cli --version 0.2.128 --locked
	pnpm exec playwright install firefox chromium
	pnpm build

build:
	pnpm build
	cargo build --workspace --all-features

check:
	./scripts/check.sh

dev:
	pnpm dev

test:
	pnpm test
	cargo test --workspace --all-features
