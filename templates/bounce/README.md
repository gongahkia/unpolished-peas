# Bouncing Square

Requires Zig 0.15.2. The default dependency fetches its pinned SDL3 source; no system SDL installation is required.

```sh
zig build run
```

Arrow keys steer the square. F3 toggles developer stats. F12 writes a PNG screenshot from the composed GPU frame to the app-data directory printed at startup. Callback failures are logged there and held in the game window until Escape is pressed.

`assets/` is reserved for user-owned raw files. Define atlas frames, animations, and tile maps directly in Zig beside the game code.

Before shipping, replace `organization`, `application`, and `title` in `src/main.zig` with stable game-specific values.

`v0.0.3` is withdrawn and must not be used for new projects. A published starter always pins one non-draft engine tag; update its dependency URL and hash together when upgrading.
