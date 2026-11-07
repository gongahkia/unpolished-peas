const std = @import("std");
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const workload = @import("render_capacity_game.zig");
const options = @import("capacity-options");
const Desktop = struct {
    pub const config: sdl.Config = .{
        .title = "Peas GameProtocol rendering capacity",
        .organization = "peas-render-capacity",
        .application = "isolated-benchmark",
        .width = options.width,
        .height = options.height,
        .scale = 1280 / options.width,
        .developer_tools = false,
        .cpu_profiler = false,
        .renderer = .sdl_gpu,
    };
    state: workload.Game = .{},
    pub fn init(self: *Desktop, ctx: *up.core.GameContext) !void {
        workload.linear = options.linear;
        try self.state.init(ctx);
    }
    pub fn update(self: *Desktop, ctx: *up.core.GameContext, dt: f32) !void {
        try self.state.update(ctx, dt);
    }
    pub fn draw(self: *Desktop, ctx: *up.core.GameContext) !void {
        // Let a newly created desktop window settle before collecting steady
        // state samples. These delays occur only in discarded warm-up frames.
        if (self.state.count == 0) std.Thread.sleep(std.time.ns_per_s);
        if (self.state.count < 120) std.Thread.sleep(16 * std.time.ns_per_ms);
        try self.state.draw(ctx);
    }
    pub fn deinit(self: *Desktop, ctx: *up.core.GameContext) !void {
        const json = try std.json.Stringify.valueAlloc(std.heap.page_allocator, .{ .samples = self.state.samples[0..self.state.count], .dropped = self.state.dropped }, .{});
        defer std.heap.page_allocator.free(json);
        // The native host has already waited for GPU idle before deinit.
        std.debug.print("peas-game-samples {s}\n", .{json});
        try self.state.deinit(ctx);
    }
};
pub fn main() !void {
    try sdl.playGame(Desktop);
}
