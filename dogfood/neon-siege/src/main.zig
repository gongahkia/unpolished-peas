const sdl = @import("unpolished-peas-sdl3");
const up = @import("unpolished-peas");
const game = @import("game.zig");

/// Desktop hosting remains deliberately thin: the actual game only knows the
/// public GameProtocol context and never imports SDL/backend implementation.
pub const Game = struct {
    pub const config: sdl.Config = .{
        .title = "Neon Siege",
        .organization = "unpolished-peas",
        .application = "neon-siege",
        .width = game.width,
        .height = game.height,
        .scale = 5,
        .resizable = true,
        .pause_policy = .unfocused,
        .clear_color = up.core.Color.rgb(3, 5, 13),
        .simulation_seed = game.default_seed,
    };

    state: game.Game = .{},

    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        try self.state.init(ctx);
    }

    pub fn update(self: *Game, ctx: *up.core.GameContext, elapsed_seconds: f32) !void {
        try self.state.update(ctx, elapsed_seconds);
    }

    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        try self.state.draw(ctx);
    }

    pub fn deinit(self: *Game, ctx: *up.core.GameContext) !void {
        try self.state.deinit(ctx);
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}

test {
    _ = @import("game.zig");
}
