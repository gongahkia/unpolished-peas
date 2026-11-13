const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const chess = @import("chess_game.zig");
const Desktop = struct {
    pub const config: sdl.Config = .{ .title = "Peas / local two-player chess", .organization = "peas-examples", .application = "local-chess", .width = chess.width, .height = chess.height, .scale = 1 };
    state: chess.Game = .{},
    pub fn init(self: *Desktop, ctx: *up.core.GameContext) !void {
        try self.state.init(ctx);
    }
    pub fn update(self: *Desktop, ctx: *up.core.GameContext, dt: f32) !void {
        try self.state.update(ctx, dt);
    }
    pub fn draw(self: *Desktop, ctx: *up.core.GameContext) !void {
        try self.state.draw(ctx);
    }
    pub fn deinit(self: *Desktop, ctx: *up.core.GameContext) !void {
        try self.state.deinit(ctx);
    }
};
pub fn main() !void {
    try sdl.playGame(Desktop);
}
