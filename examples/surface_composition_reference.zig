//! CPU oracle for the shared real-GPU fixture; never depends on a GPU host.
const std = @import("std");
const up = @import("unpolished-peas");
const fixture_module = @import("surface-fixture");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) return error.ExpectedOutputDirectory;
    const output = args[1];
    try std.fs.cwd().makePath(output);
    const fixture = try fixture_module.Fixture.init(allocator, @embedFile("assets/fonts/SourceSans3-Regular.otf"));
    defer fixture.deinit();
    var canvas = try up.graphics.Canvas.init(allocator, fixture_module.width, fixture_module.height);
    defer canvas.deinit();
    var expected = try up.graphics.Canvas.init(allocator, fixture_module.width, fixture_module.height);
    defer expected.deinit();
    for (0..fixture_module.case_count) |index| {
        try fixture.draw(&canvas, @intCast(index));
        try fixture.drawCpu(&expected, &canvas);
        const path = try std.fmt.allocPrint(allocator, "{s}/surface-{d}.rgba", .{ output, index });
        defer allocator.free(path);
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = std.mem.sliceAsBytes(expected.pixels) });
    }
    const path = try std.fs.path.join(allocator, &.{ output, "surface.json" });
    defer allocator.free(path);
    const json = try std.json.Stringify.valueAlloc(allocator, .{ .width = fixture_module.width, .height = fixture_module.height, .cases = fixture_module.case_count, .exact_cases = [_]u32{ 0, 10 }, .tolerance = 6 }, .{});
    defer allocator.free(json);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json });
}
