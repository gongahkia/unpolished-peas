# `Unpolished Peas` 🫛

A small framework for building 2D games in [Zig](https://ziglang.org/) that compile to [native](https://ziglang.org/learn/build-system/) and [browser](https://github.com/zigtools/playground) builds.

## Stack

* [Zig 0.15.2](https://ziglang.org/)
* [SDL3](https://wiki.libsdl.org/SDL3/FrontPage)
* [WASM](https://webassembly.org/)

## Screenshots

...

## Usage

> [!NOTE]  
> For a more detailed guide, refer to the [quickstart guide](docs/guides/quickstart.md) or check out `Unpolished Peas` in action within [Seed Sprint](templates/starter/README.md) or [Neon Siege](dogfood/neon-siege/README.md).

It's pretty easy to get started with `Unpolished Peas`. Below are a couple of code snippets.

### Drawing text

```zig
pub fn draw(_: *Game, ctx: *sdl.Context) void {
    ctx.text("Hello world!", 40, 30, up.core.Color.white);
}
```

### Drawing an image

```zig
image: up.assets.ImageHandle,

pub fn init(ctx: *sdl.Context) !Game {
    return .{ .image = try ctx.loadImage("ball.png") };
}

pub fn draw(self: *Game, ctx: *sdl.Context) !void {
    try ctx.image(self.image, 40, 30);
}
```

### Playing a sound

```zig
sound: up.assets.AudioHandle,

pub fn init(ctx: *sdl.Context) !Game {
    return .{ .sound = try ctx.loadSound("blip.wav") };
}

pub fn update(self: *Game, ctx: *sdl.Context) !void {
    if (ctx.input.wasPressed(.action)) {
        _ = try ctx.audio.playSound(try ctx.assets.trySoundPtr(self.sound), .{});
    }
}
```

## Support

See [platform status](docs/guides/platforms.md) for the updated suport matrix.

## Other docs

* [Learning path](docs/index.md) 
* [Game protocol](docs/guides/game-protocol.md)
* [Core contract](docs/guides/core-contract.md) 
* [Installation](docs/guides/installation.md)
* [Release policy](docs/guides/releases.md) 
* [Local documentation](docs/index.md) 
