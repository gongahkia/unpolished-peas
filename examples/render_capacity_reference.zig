//! Run the identical GameProtocol workload without a window for pixel evidence.
const std = @import("std");
const up = @import("unpolished-peas");
const workload = @import("render_capacity_game.zig");
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 5) return error.ExpectedWidthHeightLinearOutput;
    const width = try std.fmt.parseInt(u32, args[1], 10);
    const height = try std.fmt.parseInt(u32, args[2], 10);
    workload.linear = try std.fmt.parseInt(u32, args[3], 10) != 0;
    var runner = try up.testSupport.HeadlessGameRunner(workload.Game).init(allocator, width, height);
    defer runner.deinit();
    runner.canvas.detachTrace();
    runner.game.tick = 37;
    runner.game.placeSprites();
    runner.game.frozen = true;
    try runner.draw(0);
    if (runner.game.samples[0].allocation_events != 0) return error.DrawAllocated;
    try std.fs.cwd().writeFile(.{ .sub_path = args[4], .data = std.mem.sliceAsBytes(runner.canvas.pixels) });
}
