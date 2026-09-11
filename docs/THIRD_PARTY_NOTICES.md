# Third-party notices

PX-240C is private proprietary software. This notice inventories dependencies; it does not grant a
license to PX-240C source, cartridges, identity, art, font, music, or other first-party material.

The Rust graph recorded in `Cargo.lock` uses MIT, Apache-2.0, MIT OR Apache-2.0, Unlicense OR MIT,
or combined MIT/Apache-2.0/Unicode-3.0 terms. Direct crates are clap 4.6.6, serde 1.0.229,
serde_json 1.0.151, toml 1.1.5+spec-1.1.0, and wasm-bindgen 0.2.128. Exact transitive versions and
declared SPDX expressions are in `Cargo.lock` and reproducible with `cargo metadata`.

The JavaScript development graph's direct packages are TypeScript 6.0.3 (Apache-2.0), Vite 8.2.2
(MIT), Vitest 5.0.0 (MIT), ESLint 10.10.0 (MIT), `@eslint/js` 10.0.1 (MIT), typescript-eslint
8.69.0 (MIT), Prettier 3.9.6 (MIT), and `@playwright/test` 1.63.0 (Apache-2.0). Locked transitives
also declare MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC, MPL-2.0, and BlueOak-1.0.0. Exact
names, versions, integrity values, and edges are in `pnpm-lock.yaml`; `pnpm licenses list`
reproduces the inventory. Build/test packages and Playwright browser binaries are not cartridge
assets or embedded runtime dependencies.

No third-party game code, palette, font, artwork, or audio is bundled. The console palette, bitmap
font, icon, labels, graphics, and synth compositions are original. `px240c.ttf` is generated from
the same first-party glyph matrix. Standalone exports contain the dependency-free first-party
player and author-owned cartridge material, not the Node toolchain or a third-party game engine.

Installed upstream package directories contain their full licenses and notices. Any external binary
distribution must accompany notices required by those terms; this repository task does not publish
or deploy one. The root `THIRD_PARTY_NOTICES.md` retains the matching workspace-level inventory.
