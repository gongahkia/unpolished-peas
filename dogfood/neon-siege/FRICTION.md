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
