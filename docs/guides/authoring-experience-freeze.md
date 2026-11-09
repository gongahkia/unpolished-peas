# Authoring APIs and compatibility

This inventory describes the current checkout and its relationship to the
`1.0.0` baseline. It records recommended APIs, later additions, compatibility
paths and experimental tooling. Package metadata is not a feature manifest
for the October tag; see [release availability](releases.md#current-release).
This document does
not announce another release.

## Stable v1.0 baseline

The root package exposes six namespaces:

```text
core  input  graphics  assets  preview  testSupport
```

Namespace membership alone does not make every operation portable or stable.
The [core contract](core-contract.md) defines the compatibility boundary;
[API boundaries](../api/boundaries.md) distinguishes portable game services,
native helpers, advanced rendering and preview developer tooling.
`test-core-api` checks the reviewed declaration snapshot and core symbol budget.
Existing callbacks, deterministic hooks and supported declarations remain
available. No API changes are made by this documentation consolidation.

## Recommended game-authoring path

Use `GameContext` callbacks, named input actions, CPU Canvas, embedded assets,
optional host audio/saves and explicit cleanup. Put rules, collision, scene
selection and animation state in ordinary game-owned Zig. Start with
[Seed Sprint](../../templates/starter/README.md); use the
[task index](../index.md#add-something-to-your-game) to add a feature.

These shared APIs are exercised by both Neon Siege and Lantern Leap. This
is evidence of their use in those games, not a claim that every later API was
used by both games or published in the October tag.

| Surface | Classification | Authoritative usage guide |
| --- | --- | --- |
| `assets.AssetCollection`, `assets.Atlas.decode` | SUPPORTED PUBLIC API ADDITION; optional game ownership of related embedded resources | [Asset recipes](asset-recipes.md) |
| `graphics.SpriteAnimationStep`, `SpriteAnimationMode`, `SpriteAnimationClip`, `SpriteAnimationPlayer` | SUPPORTED PUBLIC API; game-owned clips/player state advanced in fixed updates | [Sprite animation](sprite-animation.md) |
| `core.Audio.MusicHandle` and load/play/pause/resume/stop controls | SUPPORTED PUBLIC API; one high-level music stream alongside SFX | [Audio](audio-assets.md) |
| `core.Audio.MusicDiagnostics` / `musicDiagnostics` | DEVELOPER OBSERVATION; non-versioned diagnostic fields, not gameplay state | [Developer diagnostics](developer-diagnostics.md) |

## Later checkout additions

These have focused compiled examples and validation. They do not imply a
release, broader platform support or use by every reference game.

| Addition | Status and boundary | Usage and evidence |
| --- | --- | --- |
| Physical keys, rebinding and Unicode text/composition | Portable input extension; old normalized key IDs retained. Exhaustive `ActionBinding` switches must handle the added `physical_key` case. Physical IME hardware validation remains separate. | [Input](input.md), [wire/source compatibility](input-v2-compatibility.md) |
| Session replay with selected initial saves | Optional developer recording; controlled seed/input/environment, not arbitrary game-memory snapshots | [Testing](testing.md#reproduce-a-session-that-depends-on-saved-progress) |
| `Font.measureText`, `Font.layoutText` and nested `TextLayout` | Authored-font measurement/wrapping/alignment; no shaping or fallback-font stack. Existing debug layout/direct font drawing retained. | [Authored text](authored-text-layout.md), compiled menu/dialogue example |
| `Audio.unloadSound` / `unloadMusic` | Explicit release and slot reuse; games omitting unload keep host-lifetime behavior | [Audio lifetimes](audio-lifetimes.md), compiled scene-transition example |
| `graphics.SurfaceCompositor`, `Renderer2D.composeSurfaces` and opt-in `Canvas.preserve_alpha` | OPT-IN PROTOTYPE; SDL GPU/WebGL 2 composition of CPU surfaces. Default Canvas behavior retained. | [GPU surface composition](gpu-surface-composition.md), [measured decision](../reviews/2026-11-08-gpu-surface-composition.md) |

Input, font and audio additions retain the six root namespaces and core symbol
budget. The compositor intentionally adds one reviewed `graphics` declaration
to the snapshot. Browser runtime contract 7 and JavaScript host ABI 6 append
the surface callback; ship matching Wasm and host modules. This is distinct
from the input ABI v1/v2 and UPR replay formats. The
[compositor contract](gpu-surface-composition.md) records compatibility and
unsupported backends. The snapshot matcher and existing goldens remain strict.

## Experimental developer tooling

These workflows are available in the current checkout, but do not receive the same
game-facing compatibility commitment:

| Area | Classification | Boundary |
| --- | --- | --- |
| Native overlay, inspector, local JSON diagnostics | EXPERIMENTAL DEVELOPER TOOLING | SDL-host only, opt-in, local, no telemetry, and disabled outside developer configuration. |
| `sdl.developer.registerAtlasImage` / `registerFont` | EXPERIMENTAL DEVELOPER API | Native wrapper helper for explicitly registered PNG/JPEG/TGA and TTF/OTF sources. Browser rebuilds instead. |
| `zig build dev-web` | BUILD/TOOLING CONTRACT | Local polling, rebuild, snapshot serving, and full-page SSE refresh. It is not a `GameProtocol` feature or HMR. |

See [developer tools](developer-tools.md) for activation controls. Developer
events never enter replay input or save data.

## Canonical projects

| Capability | Seed Sprint | Neon Siege | Lantern Leap |
| --- | ---: | ---: | ---: |
| `GameProtocol`, fixed update, ActionMap | yes | yes | yes |
| Headless seed/replay/trace/pixel tests | yes | yes | yes |
| SaveStore | yes | yes | yes |
| Short WAV SFX | yes | yes | yes |
| Atlas/authored image/font | minimal starter assets | yes | yes |
| Camera and RenderSurface | small test exercise | yes | yes |
| `SpriteAnimationPlayer` | — | yes | yes |
| Streamed music | — | yes | yes |
| Native image/font reload registration | — | yes | yes |
| Project-local `dev-web` | yes | yes | yes |

Read Seed Sprint first. Read Neon Siege for arena/action, resources, and many
active actors. Read Lantern Leap for scrolling, simple collision, traversal,
checkpoints, and explicit animation switching. All three consume supported
package modules; archive-style consumer tests prove no source-checkout import
is required.

The focused chess, asset, input, font-layout and audio-lifetime examples
supplement these three projects. They demonstrate individual workflows without
becoming competing starter architectures. The compositor fixture is a
correctness probe, not a fourth canonical game.

## Legacy animation status

The older `assets.Animation`, `assets.AnimationPlayer`, and
`assets.AnimationStateMachine` declarations remain **legacy supported** v1.0
APIs. They are not removed or silently changed in this audit. New deterministic
games should prefer `SpriteAnimationClip` and `SpriteAnimationPlayer`; the
legacy float-duration/state-machine model remains for existing authored Atlas
content. See [sprite animation](sprite-animation.md).

## Ownership and determinism

- Sprite clips borrow game-owned immutable step slices; players copy playback
  state independently and allocate nothing during `advance` or `currentFrame`.
- High-level music retains encoded bytes plus bounded decoder/buffer state;
  one active stream replaces only previous music, never SFX playback.
- Native reload decodes a complete replacement before atomically swapping it;
  invalid edits retain the old image/font.
- Diagnostics and browser rebuilding are host/development behavior. They do
  not mutate fixed simulation state or serialize into UPR replay files.

## Production isolation

Normal native packages do not enable diagnostics, source polling, or developer
shortcuts without explicit developer configuration. Normal `zig build web`
output has no `EventSource`, `/_peas/reload`, watcher metadata, or source-tree
dependency. `dev-web` is a local wrapper around that same production build.

## Snapshot and versioning strategy

Keep the checked-in snapshot strict and review intentional additions against
[core compatibility](core-contract.md) and [release policy](releases.md).
A snapshot update records a deliberate surface change; it does not promote
experimental APIs or browser preview status. Breaking changes require the
version and migration decisions specified by that policy.

## Known limits and next work

- Game-specific rules such as collision, level layout and checkpoints remain
  game code; there is no general engine physics, scene or tilemap subsystem.
- `RenderSurface` owns CPU pixels. The opt-in compositor does not turn it into
  a GPU render target or accelerate ordinary sprite/text rasterization.
- Authored text has no shaping, bidi layout, fallback-font stack or dynamic
  glyph streaming. Asset decoding is synchronous; there is no portable async
  content loader.
- High-level audio has one music stream. Crossfades, playlists and buses are
  outside that high-level service.
- Custom materials require platform-specific shader artifacts. Native reload
  covers registered images/fonts; browser iteration rebuilds and refreshes.
- [Platform evidence](platforms.md) retains the open hardware/manual checks;
  [release status](releases.md) retains package and licensing decisions.

New subsystems need a concrete game requirement or measured bottleneck. These
limits are not a list of features that every small-game framework must add.
