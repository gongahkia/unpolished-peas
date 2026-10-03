const sdl = @import("unpolished-peas-sdl3");
const up = @import("unpolished-peas");
const game = @import("game.zig");

/// The desktop entry point deliberately stays tiny. All game state and the
/// fixed-step `GameProtocol` callbacks live in `game.zig`.
pub const Game = struct {
    pub const config: sdl.Config = .{
        .title = "Seed Sprint",
        .organization = "your-name",
        .application = "seed-sprint",
        .width = game.width,
        .height = game.height,
        .scale = 5,
        .pause_policy = .unfocused,
        .clear_color = up.core.Color.rgb(12, 18, 28),
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
};

pub fn main() !void {
    try sdl.playGame(Game);
}

test {
    _ = @import("game.zig");
}
