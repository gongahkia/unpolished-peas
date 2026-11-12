# Neon Siege authoring friction log

This is a working record for the public-API dogfood tranche. Entries are kept
even when the issue was deliberately not abstracted into Peas.

| Task | Expected developer experience | Actual experience | Workaround | Category | Severity | Action |
|---|---|---|---|---|---|---|
| Own a `RenderSurface` and decoded `Atlas` in a protocol game | Allocate in `init`, release with normal host teardown | `GameContext` initially had no game-safe allocator and `GameProtocol` had no cleanup callback | None was sound without borrowing backend internals | API ergonomics | blocker | Added a host allocator capability and optional protocol `deinit` lifecycle hook. |
| Draw sprite assets on native and browser | Add one small authored image through one public portable asset path | The same embedded PNG now decodes through `Image.decode` on native, headless, and browser/Wasm | No workaround | resolved missing capability | none | Portable embedded image decoding is now the supported small-game path. |
| Use text beyond the debug HUD | Package a user font and call the public font API | The same embedded TTF now rasterizes with `Font.decodeTrueType` on native, headless, and browser/Wasm | No workaround | resolved documentation/capability | none | The authored-assets guide documents the portable font path. |
| Use action edges | Update one stored action map and read `wasPressed` | Works, but requires game-owned allocation and teardown for edge-aware actions | Store `ActionMap` in game state | API ergonomics | low | Keep: explicit ownership is appropriate Zig code. |
| Store progression | Write opaque game bytes and survive failure | Works with a concise six-byte format and injected test store | None | none | none | No framework change. |
| Reuse short SFX | Load once and play overlapping requests | Works; host owns decoded resources and game keeps handles | No individual unload | API ergonomics | low | Keep: this game loads all short SFX at init; do not add unload without a content-lifetime case. |
| Browser sound before first gesture | Ignore failed early SFX and continue | `blocked` and permanently unavailable both produce recoverable play failure | Gameplay ignores the failed output request | platform behavior | low | Keep current behavior; this game does not need a distinction. |
| Low-resolution composition | Render gameplay once at 80x45 and scale nearest | Works headlessly with no per-frame allocation | CPU software surface is deliberately modest | performance | medium | Measure in a graphical run before treating GPU surfaces as a required API. |
| Game rules | Organize enemies, collision, waves, and projectiles | Plain fixed arrays and simple geometry stay readable | Game-owned code | game-specific/non-framework | none | Correctly remains out of Peas. |

## Browser package startup — 2026-11-12

Reproduced from 76a82556 on Intel macOS/Chromium 157 with Zig 0.15.2. The
game package installed a game-named Wasm file while the common bootstrap requests
`unpolished-peas.wasm`. A successful build therefore reached a load-failure shell.
Classification: game packaging bug, high player impact; no engine ABI defect.
Correct the package destination and archive-consumer expectation to the existing
bootstrap contract. Trusted Chromium interaction and strict readbacks then pass;
startup failure and subsequent baseline captures remain under root
`zig-out/diagnostics/two-games-baseline`. Broader verification follows the polish
plan rather than being inferred from this startup check. Historical entries remain.

## Arena/control/resource polish — 2026-11-12 (verification in progress)

The original camera hid threats beyond an 80×45 view; the whole 120×70 arena now
remains visible inside a separate 320×200 world/HUD composition. Spawn warnings
are non-damaging and safely separated from the player. Input/implementation/UI
now agree on held sprint, with independent optional keyboard/right-stick aim,
fixed firing cadence and no sprint invulnerability. Existing post-hit recovery
has static feedback. Title/pause/death/restart and stable score/best fields are
reviewed in actual Chromium captures. These are game design/control improvements,
not a request for camera/AI/arena framework features.

Initial blocked music is retried after readiness rather than requiring a toggle.
Audio sources are explicitly unloaded, layouts release before their font, and
ordinary restarts retain reusable resources. The original six-byte settings format
remains; rejected writes expose pending/retry while preserving play. New original
chirps replace extremely short click samples and retain a reproducible generator.

Existing Neon-only trace/pixel expectations were updated after inspecting labeled
arranged-combat captures: the full-arena camera, prepared authored font/HUD and
wave breath change drawing intentionally. Original asset/engine goldens remain.
Ordinary keyboard/controller routes reach wave four with damage/heal, sprint,
pause, death and restart, without changing game state behind the inputs. Those
checks do not stand in for the remaining native/browser/archive/motion/profiling
verification. Historical friction entries remain above.
