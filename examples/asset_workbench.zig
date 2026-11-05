const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const game = @import("asset_workbench_game.zig");

const Desktop = struct {
    pub const config: sdl.Config = .{ .title = "Peas asset workbench", .organization = "unpolished-peas", .application = "asset-workbench", .width = game.width, .height = game.height, .scale = 3 };
    state: game.Game = .{},

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

test {
    _ = game;
}
