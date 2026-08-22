# Changelog

All notable user-facing changes are recorded here. Entries follow
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) categories and use
version tags in the form `v0.x.y`.

## [Unreleased]

### Added

- Added optional browser-only asynchronous clipboard requests through
  `engine.HostContext.AsyncClipboard`. Browser read results and write failures,
  including rejected permission-gated promises, are now observable through
  ordered completions; native synchronous clipboard methods are unchanged.
- Added supported `engine/animation` with validated deterministic `Clip` and
  `Player` sprite-sheet playback, frame durations, loop/once/ping-pong modes,
  stable frame-entry events, and current source rectangles.
- Added finite, positive centre-anchored camera zoom for world-space layers.
  Reference and WebGPU renderers apply it to sprites, tile maps, primitives,
  and text while screen-space layers remain unscaled.

### Changed

- Removed `render.Material` and `render.Sprite.Material`. They accepted shader
  names and parameters that no supported renderer forwarded. Sprites now use
  the documented fixed nearest sampling and source-over blend policy; there is
  no direct replacement until a typed rendering feature is implemented.
- Expanded supported `engine` input with physical common-key constants,
  standard-profile gamepad snapshots, IME preedit transitions, and static host
  input-capability reporting. `KeyShift` remains an aggregate compatibility
  binding for left and right Shift.
- Removed the legacy `engine.Canvas`, `engine.CommandCanvas`, immediate
  `Layer.Draw`/`DrawFunc`, and `engine.Frame` compatibility APIs. Layers now
  use `DrawCommands`, and `Runtime.Draw` accepts `render.Backend` directly.
  See the Canvas migration note in `docs/PUBLIC_API.md`.

## Release entry template

Before a tag, replace the `Unreleased` placeholder with a dated version entry.
List added, changed, deprecated, removed, fixed, and security-relevant changes;
name affected packages, public API migrations, platform evidence, and known
limitations. Do not add an empty version heading only to satisfy the dry-run
check.
