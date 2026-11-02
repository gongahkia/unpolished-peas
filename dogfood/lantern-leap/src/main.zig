const sdl = @import("unpolished-peas-sdl3");
const up = @import("unpolished-peas");
const game = @import("game.zig");

/// The native wrapper owns host-specific configuration only. The platformer
/// itself imports public Peas modules and shares its game code with browser.
pub const Game = struct {
    pub const config: sdl.Config = .{
        .title = "Lantern Leap",
        .organization = "unpolished-peas",
        .application = "lantern-leap",
        .width = game.width,
        .height = game.height,
        .scale = 4,
        .resizable = true,
        .pause_policy = .unfocused,
        .clear_color = up.core.Color.rgb(4, 7, 18),
        .simulation_seed = game.default_seed,
    };

    state: game.Game = .{},

    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        try self.state.init(ctx);
        // Experimental developer tooling stays at the host boundary. Release
        // and browser builds keep using the same embedded bytes.
        if (self.state.atlas) |atlas| _ = try sdl.developer.registerAtlasImage(atlas, "lantern-leap.png", .{});
        if (self.state.font) |font| _ = try sdl.developer.registerFont(font, "lantern-leap.ttf", .{ .pixel_height = 8, .atlas_width = 128, .atlas_height = 128 });
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
