# Bouncing Square

Requires Zig 0.15.2, SDL3, and `pkg-config`.

macOS:

```sh
brew install sdl3 pkg-config
zig build run
```

Linux:

```sh
sudo apt install libsdl3-dev pkg-config
zig build run
```

Arrow keys steer the square. F3 toggles developer stats. F12 writes a PNG screenshot from the composed GPU frame to the app-data directory printed at startup. Callback failures are logged there and held in the game window until Escape is pressed.

Before shipping, replace `organization`, `application`, and `title` in `src/main.zig` with stable game-specific values.

This project initially points to the engine checkout that created it. Replace the path dependency with a pinned `unpolished-peas` release after the repository has been published.
