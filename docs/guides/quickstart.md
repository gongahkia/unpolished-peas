# Quickstart

Create a project, validate it, then run it:

```sh
zig build peas -- new ../my-game
zig build peas -- check ../my-game --target linux
zig build peas -- run ../my-game -- --frames 2
```

Runnable references:

- [SDL bouncing square](../../examples/bounce_sdl.zig)
- [Explicit state loop](../../examples/explicit_loop.zig)
