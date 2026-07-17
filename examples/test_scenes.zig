const std = @import("std");
const up = @import("unpolished-peas");
const bounce = @import("bounce.zig");

const golden_path = "proof-bounce-reference.png";
const expected_hash: u64 = 0x88b572d8695fbf0b;
const diagnostics_path = "zig-out/scenes/bounce";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    var update_golden = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--update-golden")) update_golden = true;
    }
    var assets = try up.assets.AssetStore.initExecutable(allocator);
    defer assets.deinit();
    var canvas = try renderBounce(allocator);
    defer canvas.deinit();
    if (update_golden) return writeGolden(allocator, &assets, golden_path, canvas);
    try assertGolden(allocator, &assets, golden_path, canvas, expected_hash, diagnostics_path);
}

fn renderBounce(allocator: std.mem.Allocator) !up.graphics.Canvas {
    var canvas = try up.graphics.Canvas.init(allocator, bounce.width, bounce.height);
    var clock = up.core.StepClock.init(60);
    var ball = bounce.Ball{};
    var frame: u32 = 0;
    while (frame < 180) : (frame += 1) {
        const steps = clock.push(1.0 / 60.0);
        var step: u32 = 0;
        while (step < steps) : (step += 1) ball.update(clock.step_seconds, @floatFromInt(canvas.width), @floatFromInt(canvas.height));
        canvas.clear(up.core.Color.rgb(14, 18, 24));
        var x: i32 = 0;
        while (x < @as(i32, @intCast(canvas.width))) : (x += 16) canvas.line(x, 0, x, @intCast(canvas.height - 1), up.core.Color.rgb(32, 39, 50));
        var y: i32 = 0;
        while (y < @as(i32, @intCast(canvas.height))) : (y += 16) canvas.line(0, y, @intCast(canvas.width - 1), y, up.core.Color.rgb(32, 39, 50));
        canvas.strokeRect(0, 0, @intCast(canvas.width), @intCast(canvas.height), up.core.Color.rgb(91, 104, 124));
        canvas.fillCircle(@intFromFloat(ball.pos.x), @intFromFloat(ball.pos.y), ball.radius, up.core.Color.rgb(255, 198, 74));
        canvas.drawText("UNPOLISHED", 4, 4, up.core.Color.rgb(225, 232, 240));
    }
    return canvas;
}

fn writeGolden(allocator: std.mem.Allocator, assets: *up.assets.AssetStore, path: []const u8, canvas: up.graphics.Canvas) !void {
    const output_path = try assets.assetPath(allocator, path);
    defer allocator.free(output_path);
    try canvas.writePngFile(output_path);
}

fn assertGolden(allocator: std.mem.Allocator, assets: *up.assets.AssetStore, path: []const u8, canvas: up.graphics.Canvas, hash: u64, diagnostics: []const u8) !void {
    const golden = try assets.loadImage(path);
    try up.testSupport.assertGolden(allocator, canvas, try assets.tryImage(golden), .{ .expected_hash = hash, .diagnostics_path = diagnostics });
}
