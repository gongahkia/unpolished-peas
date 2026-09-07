.PHONY: setup build check dev test

setup:
	pnpm install --frozen-lockfile
	cargo fetch --locked
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
