const std = @import("std");
const up = @import("unpolished");

const expected_hash: u64 = 0;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var assets = up.AssetStore.init(allocator, std.fs.cwd());
    defer assets.deinit();
    const ball = try assets.loadPng("examples/assets/ball.png");

    var canvas = try up.Canvas.init(allocator, 64, 48);
    defer canvas.deinit();

    canvas.clear(up.Color.rgb(14, 18, 24));
    canvas.fillRect(4, 4, 12, 10, up.Color.rgb(255, 198, 74));
    canvas.drawImage(assets.image(ball), 24, 16);
    canvas.drawText("TEST", 4, 36, up.Color.white);

    const got = hashCanvas(canvas);
    if (got != expected_hash) {
        try std.fs.cwd().makePath("zig-out");
        try canvas.writePpmFile("zig-out/scene-fail.ppm");
        var buffer: [256]u8 = undefined;
        var writer = std.fs.File.stderr().writer(&buffer);
        const err = &writer.interface;
        try err.print("scene hash mismatch: expected 0x{x}, got 0x{x}\n", .{ expected_hash, got });
        try err.flush();
        return error.SceneHashMismatch;
    }
}

fn hashCanvas(canvas: up.Canvas) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    for (canvas.pixels) |p| {
        hasher.update(&.{ p.r, p.g, p.b, p.a });
    }
    return hasher.final();
}
