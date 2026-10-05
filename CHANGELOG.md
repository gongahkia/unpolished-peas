# Changelog

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and semantic versioning after its first non-draft release. Every non-draft release gets a dated section using Added, Changed, Deprecated, Removed, Fixed, and Security categories; published sections are immutable except for marked factual corrections. See the [release policy](docs/guides/releases.md#changelog-policy).

## Unreleased

No changes are currently proposed after the v0.1.0 release candidate.

## 0.1.0 — draft, unpublished

### Core

- Fixed-step `GameProtocol`, explicit simulation seeds, deterministic PCG
  random state, optional lifecycle `deinit`, and opaque `SaveStore` data.

### Rendering

- Deterministic CPU Canvas, image/atlas/font drawing, CPU `RenderSurface`, and
  a separate advanced `Renderer2D` path for material, particle, and post work.

### Input

- Normalized keyboard, pointer, gamepad, action-map, and replay input with
  fixed-tick held/pressed/released semantics.

### Audio

- Optional backend-neutral short-SFX playback through `GameContext.audio`,
  with browser activation failures reported as recoverable availability errors.

### Assets

- Embedded PNG, JPEG, TGA, TTF/OTF, WAV, and OGG/Vorbis authored-asset paths,
  plus explicit runtime `AssetStore` roots for native projects.

### Persistence

- Small, opaque cross-platform save blobs through `SaveStore`; this is not a
  general filesystem API.

### Testing

- Headless game runs, input replay, Canvas trace/pixel regression, in-memory
  saves, and public-import/API snapshot coverage.

### Platforms

- Native SDL host and browser build support. Real runtime evidence currently
  covers Intel macOS and WSLg only; see the installation guide for the exact
  platform matrix rather than treating cross-builds as runtime validation.

### Known limitations

- `RenderSurface` is a CPU/software surface, not a GPU render target.
- Canvas is intended for small authored 2D and low-resolution workflows;
  `Renderer2D` is the separate advanced GPU-oriented route.
- No project code license or published v0.1.0 tag/archive exists yet.

## 0.0.3 — withdrawn

- This draft tag does not provide the `sdl.playGame` API used by the current starter template.
- Do not start a new project from this tag.
