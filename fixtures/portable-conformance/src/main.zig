const std = @import("std");
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const game = @import("game.zig");
const scenario = @import("scenario.zig");
const options = @import("conformance-options");

pub const Desktop = struct {
    pub const config: sdl.Config = .{
        .title = "Peas portable conformance",
        .organization = options.organization,
        .application = if (std.mem.eql(u8, options.native_phase, "interactive")) "portable-conformance" else options.organization,
        .width = game.width,
        .height = game.height,
        .scale = 2,
        .simulation_seed = game.default_seed,
    };
    state: game.Game = .{},

    pub fn init(self: *Desktop, ctx: *up.core.GameContext) !void {
        try self.state.init(ctx);
        errdefer self.state.deinit(ctx) catch unreachable;
        if (std.mem.eql(u8, options.native_phase, "write")) {
            if (self.state.score != 0 or self.state.name_len != 0) return error.NativeStoreNotIsolated;
            var scripted = ctx.*;
            for (0..scenario.ticks) |tick| {
                const input = try scenario.input(tick);
                scripted.input = &input;
                try self.state.update(&scripted, 1.0 / 60.0);
            }
            try expected(&self.state);
            std.debug.print("portable native write passed: score=4 name=Zoë你好 rebound=R\n", .{});
        } else if (std.mem.eql(u8, options.native_phase, "read")) {
            try expected(&self.state);
            std.debug.print("portable native restart passed: score=4 name=Zoë你好 rebound=R\n", .{});
        }
    }
    pub fn update(self: *Desktop, ctx: *up.core.GameContext, dt: f32) !void {
        try self.state.update(ctx, dt);
    }
    pub fn draw(self: *Desktop, ctx: *up.core.GameContext) !void {
        try self.state.draw(ctx);
    }
    pub fn deinit(self: *Desktop, ctx: *up.core.GameContext) !void {
        try self.state.deinit(ctx);
        if (self.state.cleanup_calls != 1) return error.IncorrectNativeCleanupCount;
        std.debug.print("portable native cleanup passed: exactly once\n", .{});
    }
};

fn expected(state: *const game.Game) !void {
    if (state.score != 4 or state.one != 1 or state.two != 1 or !state.rebound or !std.mem.eql(u8, state.name[0..state.name_len], "Zoë你好")) return error.NativeProgressMismatch;
}
pub fn main() !void {
    const path = try sdl.appDataPath(std.heap.page_allocator, Desktop.config.organization, Desktop.config.application);
    defer std.heap.page_allocator.free(path);
    std.debug.print("portable native store: {s}\n", .{path});
    try sdl.playGame(Desktop);
}
test {
    _ = @import("tests.zig");
}
