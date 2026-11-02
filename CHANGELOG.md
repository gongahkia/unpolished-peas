# Changelog

## Unreleased

### Fixed

- Preserve native pointer motion across multiple events and buffered controller
  taps when browser slots move; share tick buffering across desktop and web.
- Keep native save staging separate from game keys and concurrent writers;
  allow browser saves to recover after rejected writes or corrupt values.
- Correct WebGL framebuffer orientation and preserve WebGPU material geometry
  and uniforms across queued draws and post passes.
- Preserve accumulated browser pointer motion and held keyboard aliases;
  normalize standard gamepad triggers and allow Tab to leave the canvas.
- End game teardown exactly once even when its cleanup callback fails.
- Give generated browser pages visible loading/error recovery and accessible
  keyboard focus; preserve authored logical dimensions during CSS scaling.
- Align package metadata and guides with the published `1.0.0` version.
- Validate public consumers after release assets are published, accept plain
  and prefixed version tags, and honor manual release dry runs.
- Retain browser failure diagnostics outside temporary directories.
- Refresh the checked-in web demo and its checksums from the current runtime.
- Keep Seed Sprint's controls and large saved scores readable within its canvas.
- Serve the correct archive during release preparation and propagate the
  selected release version into the generated starter manifest.

### Added

- Optional UPR4 session recordings with selected initial saves and checked
  game/build/asset identity, plus isolated headless session initialization.
- Independent headless update/draw controls, portable game-state hashing, and
  a compiled Seed Sprint record/play/save/restart acceptance test.
- Push/pull-request browser contract, interaction, and renderer pixel checks.
- [Product/principles audit](docs/reviews/2026-10-23-product-engineering-audit.md)
  with evidence, remaining product decisions, and verification boundaries.

Public namespace declaration names and renderer comparison tolerances are
unchanged. Developer/test methods are additive; older replay formats and
legacy state hashes remain supported after the immutable release below.

## 1.0.0 — 2026-10-10

### Added

- First [published source release](https://github.com/gongahkia/unpolished-peas/releases/tag/1.0.0).

The published release has no attached prepared source-package archive or
desktop downloads. See the [installation guide](docs/guides/installation.md)
for the usable source-checkout path and the package release contract.
