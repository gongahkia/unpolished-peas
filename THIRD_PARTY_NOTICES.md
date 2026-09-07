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
typescript-eslint 8.69.0 (MIT), and Prettier 3.9.6 (MIT). The locked transitive graph additionally
contains packages under MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC, MPL-2.0, and
BlueOak-1.0.0. Exact package names, versions, resolved integrity values, and dependency edges are in
`pnpm-lock.yaml`; `pnpm licenses list` reproduces the licence inventory. These build/test packages
are not cartridge assets.

No third-party game code, palette, font, artwork, or audio is included. The built-in palette,
bitmap font, icon, labels, game graphics, and synth compositions are original project assets.
Standalone cartridge exports contain the original dependency-free player plus author-owned
cartridge material; they do not embed the Node development toolchain or a third-party game engine.

This notice is the authoritative inventory for the current private alpha. The upstream package
directories installed by `make setup` contain their complete licence and notice texts. Any future
external binary redistribution of the Studio must accompany the applicable upstream texts required
by those terms; no such publication or deployment is performed by this repository.
