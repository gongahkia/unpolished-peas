# Bouncing Square

Requires Zig 0.15.2. The default dependency fetches its pinned SDL3 source; no system SDL installation is required.

```sh
zig build run
```

Arrow keys steer the square. The game callbacks use the stable `GameContext` protocol; source code does not depend on a renderer-specific callback context.

`assets/` is reserved for user-owned raw files. Define atlas frames and animations directly in Zig beside game code.

Before shipping, replace `organization`, `application`, and `title` in `src/main.zig` with stable game-specific values.

`v0.0.3` is withdrawn and must not be used for new projects. A published starter copies one reviewed manifest template with a public engine tag URL and its matching Zig package hash; update both coordinates together for every release.
