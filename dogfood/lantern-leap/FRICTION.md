# Lantern Leap authoring friction log

This second dogfood game deliberately records what a platformer required in
practice. Items remain here even when Peas should not abstract them.

| Area | Expected | Actual | Workaround | Category | Severity | Framework action? |
| --- | --- | --- | --- | --- | --- | --- |
| Static platform collision | A small level can move and resolve an 8×8 player against rectangles | Move-X then move-Y AABB code is compact and readable | Game-owned `Rect` loop | game-specific | none | No physics API: one game’s axis-aligned rules do not justify one. |
| Scrolling camera | Follow player horizontally and keep HUD fixed | `Camera2D` plus a game-owned clamp is direct | Two clamped coordinates | API ergonomics | low | None. A camera-controller policy would be genre-specific. |
| Idle/run/jump frames | Choose clips in update and draw an atlas frame | `isCurrentClip` plus `play` avoids accidental restart; `advance(1)` is explicit | Three-game-state branch | API ergonomics | none | No change. This is the intended animation boundary. |
| Level content | One small authored stage without a content system | Static arrays of rectangles and positions are sufficient | `level.zig` | game-specific | none | No tilemap/editor abstraction. |
| Checkpoint/progress | Persist tiny game-owned values and tolerate failure | Three explicit bytes work naturally through `SaveStore` | Ignore recoverable store errors | none | none | No serialization/checkpoint framework. |
| Browser iteration | Rebuild and refresh a rich reference game | Existing `dev-web` workflow applies unchanged | None | resolved tooling | none | Existing browser developer workflow is adequate. |
| Native asset edits | Update sheet/font without restart during development | Existing desktop registration covers the atlas/font | Host-wrapper registration | discoverability | low | README points to the opt-in workflow; no game/runtime API change. |
