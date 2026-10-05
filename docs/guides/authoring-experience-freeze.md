# Post-v0.1 authoring-experience freeze

This is an architecture-milestone audit, **not a published `v0.2.0` release**.
The first public release remains unpublished, the repository version remains
`0.1.0`, and project licensing remains undecided. This record says which
authoring additions are ready for the next compatibility baseline and which
remain explicitly experimental tooling.

## Stable v0.1 baseline

The root package continues to expose only these stable namespaces:

```text
core  input  graphics  assets  preview  testSupport
```

`test-core-api` guards the checked-in facade snapshot and the v0.1 core symbol
budget. The v0.1 contract remains the fixed-step `GameProtocol`, deterministic
RNG/replay/headless tooling, Canvas and assets, input, save data, native/browser
packaging, and documented supported targets. This audit does not rename or
remove any v0.1 declaration.

## Candidate next game-facing baseline

The following additions have been exercised by both Neon Siege and Lantern
Leap and are recommended for the next supported game-facing baseline:

| Surface | Classification | Contract decision |
| --- | --- | --- |
| `graphics.SpriteAnimationStep`, `SpriteAnimationMode`, `SpriteAnimationClip`, `SpriteAnimationPlayer` | SUPPORTED PUBLIC API | Freeze as deterministic, game-owned sprite-frame selection. Clips borrow static step data; players have value semantics and advance in fixed updates only. |
| `core.Audio.MusicHandle`, `MusicFormat`, `MusicLoadOptions`, `MusicPlayOptions`, `MusicState`, `loadMusic`, `playMusic`, `pauseMusic`, `resumeMusic`, `stopMusic`, `setMusicVolume` | SUPPORTED PUBLIC API | Freeze as one high-level, bounded incremental music stream that coexists with SFX. OGG/Vorbis is the default; WAV is explicit. |
| `core.Audio.MusicDiagnostics` and `musicDiagnostics` | DEVELOPER OBSERVATION | Useful to diagnostics, but not gameplay control or a telemetry schema. Its fields remain non-versioned observation data until a future audit promotes them. |

`MusicHandle` and `SoundHandle` remain host-owned handles. The source remains
valid for the lifetime of `Audio`; games do not unload individual high-level
audio resources.

## Experimental developer tooling

These are useful, shipped developer workflows, but do not receive the same
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

## Legacy animation status

The older `assets.Animation`, `assets.AnimationPlayer`, and
`assets.AnimationStateMachine` declarations remain **legacy supported** v0.1
APIs. They are not removed or silently changed in this audit. New deterministic
games should prefer `SpriteAnimationClip` and `SpriteAnimationPlayer`; the
legacy float-duration/state-machine model remains for existing authored Atlas
content. See [sprite animation](sprite-animation.md).

## One-off public surface audit

No post-v0.1 authoring declaration was found to be accidentally exposed without
a focused test, guide, or canonical-project use. Existing public declarations
that are not used by all three projects fall into deliberate categories:

- `graphics.Renderer2D`, materials, particles, and post passes are advanced
  rendering APIs documented in [Advanced 2D](advanced-2d.md), not a required
  Canvas path.
- The low-level `assets.AudioMixer`, `Music`, and `AudioStream` types remain
  advanced/legacy mixer surface; ordinary games use `GameContext.audio`.
- Legacy Atlas animation/state-machine types remain compatibility APIs as
  described above.
- Inspector, profiler, and renderer-diagnostics declarations are existing
  diagnostics/advanced surface rather than new ordinary game requirements.

The audit makes no removals: all of these predate the post-v0.1 authoring
cycle or have an explicit advanced/compatibility purpose.

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

Keep the existing checked-in core snapshot as the guard for the current facade
and retain the historical v0.1 capability/core-contract documents unchanged.
This page is the small, reviewable post-v0.1 inventory: it records what the
next snapshot should include without rewriting history or pretending there is
already a public `v0.2.0` tag. At a real milestone decision, copy this approved
inventory into the versioned snapshot/changelog review in one intentional
change.

## Milestone notes draft

### Game authoring

- Adds deterministic, tick-based Atlas-frame animation for new games.
- Confirms two distinct reference-game patterns: Neon Siege for arena action
  and Lantern Leap for scrolling platforming and explicit collision rules.

### Audio

- Adds one high-level bounded incremental music stream alongside reusable WAV
  sound effects, with the same optional-audio behavior on native, browser, and
  headless hosts.

### Developer workflow

- Adds opt-in local diagnostics, native image/font reload, and a browser
  watch/build/serve/full-reload loop without changing production bundles.

### Compatibility

- Keeps the v0.1 facade intact; no game-facing v0.1 API was removed or
  renamed.
- Does not constitute a release announcement, package-version bump, tag, or
  license decision.

## Known limits

- No engine physics, tilemap/content system, checkpoint framework, or camera
  controller; both dogfood games keep those rules in game-owned Zig.
- `RenderSurface` is a CPU/software Canvas, not a GPU render target.
- Text has no shaping or fallback stack.
- High-level audio supports one music stream, not playlists, crossfades, buses,
  or music hot reload.
- Native reload covers registered images/fonts only; browser iteration is a
  complete rebuild and page refresh.
- Apple Silicon and bare-metal Linux runtime validation remain pending; WSLg
  is development evidence only.

No second dogfood game demonstrated a reusable missing subsystem. Future work
should remain evidence-driven rather than treating this list as a feature
checklist.
