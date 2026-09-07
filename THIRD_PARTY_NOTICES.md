# Third-party notices

PX-240C is private proprietary software. Its package manifests and lockfiles identify exact library
versions. Runtime redistribution will include only dependencies required by the exported player.

The Rust dependency graph resolved in `Cargo.lock` uses MIT, Apache-2.0, MIT OR Apache-2.0,
Unlicense OR MIT, or combined MIT/Apache-2.0/Unicode-3.0 terms. Direct crates are clap 4.6.6,
serde 1.0.229, serde_json 1.0.151, toml 1.1.5+spec-1.1.0, and wasm-bindgen 0.2.128. Exact
transitive crate versions and declared SPDX expressions are recorded in `Cargo.lock` and available
through `cargo metadata`.

The JavaScript development toolchain's direct packages are TypeScript 6.0.3 (Apache-2.0), Vite
8.2.2 (MIT), Vitest 5.0.0 (MIT), ESLint 10.10.0 (MIT), `@eslint/js` 10.0.1 (MIT),
typescript-eslint 8.69.0 (MIT), and Prettier 3.9.6 (MIT). Exact transitive versions are recorded in
`pnpm-lock.yaml`. These build/test tools are not shipped as cartridge assets.

No third-party game code, palette, font, artwork, or audio is included. The built-in palette and
bitmap font are original project assets. Full upstream notice/license-text collection remains a
release-candidate audit item before redistribution outside this private repository.
